local FactionNpcAttitudeBus = {}

local API_VERSION = "1.0.0"
local SNAPSHOT_SCHEMA_VERSION = "1.0.0"

local ALLOWED_TRIGGERS = {
    ["actor-loaded"] = true,
    ["relation-changed"] = true,
    ["ending-changed"] = true,
    ["manual-refresh"] = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local cloned = {}
    for key, item in pairs(value) do cloned[copy(key)] = copy(item) end
    return cloned
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function count(table_value)
    local total = 0
    for _ in pairs(table_value) do total = total + 1 end
    return total
end

local function operation_owners(results)
    local owners = {}
    for event_id, record in pairs(results or {}) do
        local operation_id = record.input and record.input.operationId
        if type(operation_id) == "string" and operation_id ~= "" then
            assert(owners[operation_id] == nil, "duplicate NPC attitude operation ID")
            owners[operation_id] = event_id
        end
    end
    return owners
end

local function ensure_progression_state(faction_api)
    local progression = faction_api.progression
    if type(progression) ~= "table" or type(progression.state) ~= "table" then
        return nil
    end
    local state = progression.state.factionNpcAttitudes
    if state == nil then
        state = {
            schemaVersion = SNAPSHOT_SCHEMA_VERSION,
            results = {},
            refreshSequence = 0,
        }
        progression.state.factionNpcAttitudes = state
    end
    assert(state.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported progression-backed NPC attitude state schema")
    state.results = state.results or {}
    state.refreshSequence = state.refreshSequence or 0
    return state
end

local function provider_metadata(definition)
    return {
        providerId = definition.providerId,
        authoritySource = definition.authoritySource,
        enabled = definition.enabled,
    }
end

local function normalize_whitelist(options)
    local source = options.providerWhitelist or {}
    assert(type(source) == "table", "NPC attitude provider whitelist must be a table")
    local whitelist = {}
    for provider_id, authority_source in pairs(source) do
        require_text(provider_id, "whitelisted provider ID")
        whitelist[provider_id] = require_text(
            authority_source,
            "whitelisted provider authority source"
        )
    end
    return whitelist
end

local function normalize_provider(instance, definition)
    assert(type(definition) == "table", "NPC attitude provider definition is required")
    local provider_id = require_text(definition.providerId, "provider ID")
    local authority_source = require_text(definition.authoritySource, "provider authority source")
    assert(
        instance.providerWhitelist[provider_id] == authority_source,
        "NPC attitude provider is not whitelisted"
    )
    assert(type(definition.applyIntent) == "function", "NPC attitude provider must implement applyIntent")
    return {
        providerId = provider_id,
        authoritySource = authority_source,
        applyIntent = definition.applyIntent,
        enabled = definition.enabled ~= false,
    }
end

local function normalize_binding(instance, definition)
    assert(type(definition) == "table", "NPC attitude actor binding is required")
    local provider_id = require_text(definition.providerId, "binding provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled and type(provider.applyIntent) == "function",
        "binding provider is unavailable")
    local faction_id = require_text(definition.factionId, "binding faction ID")
    assert(instance.factionApi:faction_status(faction_id) ~= nil, "binding references an unknown faction")
    return {
        bindingId = require_text(definition.bindingId, "binding ID"),
        providerId = provider_id,
        factionId = faction_id,
        actorKey = require_text(definition.actorKey, "binding actor key"),
        actorClassKey = require_text(definition.actorClassKey, "binding actor class key"),
        actorRef = definition.actorRef,
        lastDisposition = nil,
        playerInitiatedAggression = false,
    }
end

local function normalized_policy(ending_runtime)
    if ending_runtime == nil then
        return {
            completed = false,
            worldDisposition = "conditional",
            factionDispositionById = {},
        }
    end
    local ok, policy = pcall(ending_runtime.post_ending_policy, ending_runtime)
    assert(ok and type(policy) == "table", "ending runtime returned an invalid post-ending policy")
    policy.factionDispositionById = policy.factionDispositionById or {}
    return policy
end

local function desired_disposition(instance, faction_id, player_initiated_aggression)
    local faction = instance.factionApi:faction_status(faction_id)
    assert(type(faction) == "table", "unknown NPC faction")
    if player_initiated_aggression then
        return "hostile", "player-initiated-aggression"
    end

    local policy = normalized_policy(instance.endingRuntime)
    if policy.completed == true then
        local faction_override = policy.factionDispositionById[faction_id]
        if faction_override == "friendly" then
            return "friendly", "ending-faction-override"
        elseif faction_override == "hostile" then
            return "hostile", "ending-faction-override"
        elseif faction_override == "non_hostile_until_attacked" then
            return "non-hostile", "ending-faction-override"
        end
        if policy.worldDisposition == "pacified" then
            return "non-hostile", "ending-world-override"
        elseif policy.worldDisposition == "hostile" then
            return "hostile", "ending-world-override"
        end
    end

    if faction.relation == "Hostile" then return "hostile", "faction-relation" end
    if faction.relation == "Friendly" or faction.relation == "Player" then
        return "friendly", "faction-relation"
    end
    return "neutral", "faction-relation"
end

local function normalize_refresh(instance, event)
    assert(type(event) == "table", "NPC attitude refresh event is required")
    assert(event.schemaVersion == "1.0.0", "unsupported NPC attitude event schema")
    assert(event.authoritative == true, "NPC attitude event must be authoritative")
    local provider_id = require_text(event.providerId, "event provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled and type(provider.applyIntent) == "function",
        "event provider is unavailable")
    assert(event.authoritySource == provider.authoritySource, "event authority source is not trusted")
    local trigger = require_text(event.trigger, "event trigger")
    assert(ALLOWED_TRIGGERS[trigger], "unsupported NPC attitude trigger")
    local binding_id = require_text(event.bindingId, "event binding ID")
    local binding = instance.bindings[binding_id]
    assert(binding ~= nil, "event binding is unavailable")
    assert(binding.providerId == provider_id, "event binding provider mismatch")
    assert(event.actorKey == binding.actorKey, "event actor does not exactly match the binding")
    assert(event.actorClassKey == binding.actorClassKey,
        "event actor class does not exactly match the binding")
    assert(event.playerInitiatedAggression == nil or type(event.playerInitiatedAggression) == "boolean",
        "playerInitiatedAggression must be boolean")
    return {
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = provider_id,
        authoritySource = event.authoritySource,
        trigger = trigger,
        eventId = require_text(event.eventId, "event ID"),
        operationId = require_text(event.operationId, "operation ID"),
        bindingId = binding_id,
        factionId = binding.factionId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        playerInitiatedAggression = event.playerInitiatedAggression == true,
    }, binding, provider
end

local function same_refresh(first, second)
    return first.providerId == second.providerId
        and first.authoritySource == second.authoritySource
        and first.trigger == second.trigger
        and first.operationId == second.operationId
        and first.bindingId == second.bindingId
        and first.factionId == second.factionId
        and first.actorKey == second.actorKey
        and first.actorClassKey == second.actorClassKey
        and first.playerInitiatedAggression == second.playerInitiatedAggression
end

local function normalize_snapshot(snapshot)
    assert(type(snapshot) == "table", "NPC attitude snapshot is required")
    assert(snapshot.schemaVersion == SNAPSHOT_SCHEMA_VERSION, "unsupported NPC attitude snapshot schema")
    assert(type(snapshot.providers) == "table", "NPC attitude snapshot providers are required")
    assert(type(snapshot.results) == "table", "NPC attitude snapshot results are required")
    local restored = {
        providers = {},
        results = copy(snapshot.results),
        operationOwners = {},
    }
    for _, definition in ipairs(snapshot.providers) do
        local provider_id = require_text(definition.providerId, "restored provider ID")
        assert(restored.providers[provider_id] == nil, "duplicate restored provider")
        restored.providers[provider_id] = {
            providerId = provider_id,
            authoritySource = require_text(definition.authoritySource, "restored provider authority source"),
            enabled = definition.enabled ~= false,
            applyIntent = nil,
        }
    end
    for event_id, record in pairs(restored.results) do
        require_text(event_id, "restored event ID")
        assert(type(record) == "table" and type(record.input) == "table"
            and type(record.outcome) == "table", "restored NPC attitude result is invalid")
        local operation_id = require_text(record.input.operationId, "restored operation ID")
        assert(restored.operationOwners[operation_id] == nil, "duplicate restored operation ID")
        restored.operationOwners[operation_id] = event_id
    end
    return restored
end

function FactionNpcAttitudeBus.create(faction_api, ending_runtime, options)
    assert(type(faction_api) == "table" and type(faction_api.faction_status) == "function",
        "faction API is required")
    assert(ending_runtime == nil or type(ending_runtime.post_ending_policy) == "function",
        "ending runtime is invalid")
    options = options or {}
    local progression_state = options.snapshot == nil
        and ensure_progression_state(faction_api) or nil
    local restored = options.snapshot and normalize_snapshot(options.snapshot) or {
        providers = {}, results = {}, operationOwners = {},
    }
    if progression_state ~= nil then
        restored.results = progression_state.results
        restored.operationOwners = operation_owners(restored.results)
    end
    local instance = setmetatable({
        version = API_VERSION,
        factionApi = faction_api,
        endingRuntime = ending_runtime,
        providerWhitelist = normalize_whitelist(options),
        providers = restored.providers,
        bindings = {},
        results = restored.results,
        operationOwners = restored.operationOwners,
        progressionState = progression_state,
        refreshSequence = progression_state and progression_state.refreshSequence or 0,
        acceptedCount = 0,
        rejectedCount = 0,
        duplicateCount = 0,
        capabilities = {
            contentNeutralFactionAttitudes = true,
            exactActorAndClassBinding = true,
            relationChangeRefresh = true,
            postEndingDispositionOverride = true,
            playerAggressionException = true,
            providerWhitelist = true,
            retryAfterProviderFailure = true,
            serializableRestoreWithoutUObjects = true,
            progressionSidecarIdempotency = progression_state ~= nil,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionNpcAttitudeBus })
    local progression = faction_api.progression
    if type(progression) == "table"
        and type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.faction-npc-attitude-bus.v1",
            function() return instance:rebind_progression_state() end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function FactionNpcAttitudeBus:rebind_progression_state()
    local ok, state = pcall(ensure_progression_state, self.factionApi)
    if not ok then
        return result(false, "NPC-attitude-snapshot-invalid", { error = tostring(state) })
    end
    self.progressionState = state
    if state ~= nil then
        self.results = state.results
        self.operationOwners = operation_owners(self.results)
        self.refreshSequence = state.refreshSequence
    end
    -- All actor bindings contain world-lifetime identity and optional UObject
    -- references. They must be rediscovered after a restore/world load.
    self.bindings = {}
    return result(true, "NPC-attitude-progression-state-rebound")
end

function FactionNpcAttitudeBus:register_provider(definition)
    local ok, provider = pcall(normalize_provider, self, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-NPC-attitude-provider", { validationError = tostring(provider) })
    end
    local existing = self.providers[provider.providerId]
    if existing ~= nil then
        if existing.authoritySource ~= provider.authoritySource then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "NPC-attitude-provider-id-conflict")
        end
        existing.applyIntent = provider.applyIntent
        existing.enabled = provider.enabled
        return result(true, "NPC-attitude-provider-ready", { providerId = provider.providerId })
    end
    self.providers[provider.providerId] = provider
    return result(true, "NPC-attitude-provider-registered", { providerId = provider.providerId })
end

function FactionNpcAttitudeBus:bind_actor(definition)
    local ok, binding = pcall(normalize_binding, self, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-NPC-attitude-binding", { validationError = tostring(binding) })
    end
    local existing = self.bindings[binding.bindingId]
    if existing ~= nil then
        if existing.providerId ~= binding.providerId or existing.factionId ~= binding.factionId
            or existing.actorKey ~= binding.actorKey or existing.actorClassKey ~= binding.actorClassKey then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "NPC-attitude-binding-id-conflict")
        end
        existing.actorRef = binding.actorRef
        return result(true, "NPC-attitude-actor-rebound", { bindingId = binding.bindingId })
    end
    self.bindings[binding.bindingId] = binding
    return result(true, "NPC-attitude-actor-bound", {
        bindingId = binding.bindingId,
        factionId = binding.factionId,
    })
end

function FactionNpcAttitudeBus:refresh(event)
    local ok, normalized, binding, provider = pcall(normalize_refresh, self, event)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-NPC-attitude-event", {
            validationError = tostring(normalized), stateChanged = false,
        })
    end
    local existing = self.results[normalized.eventId]
    if existing ~= nil then
        if not same_refresh(existing.input, normalized) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "NPC-attitude-event-id-conflict", { stateChanged = false })
        end
        self.duplicateCount = self.duplicateCount + 1
        local duplicate = copy(existing.outcome)
        duplicate.duplicateOfReason = duplicate.reason
        duplicate.reason = "duplicate-NPC-attitude-event"
        duplicate.stateChanged = false
        duplicate.idempotent = true
        return duplicate
    end
    local operation_owner = self.operationOwners[normalized.operationId]
    if operation_owner ~= nil and operation_owner ~= normalized.eventId then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "NPC-attitude-operation-id-conflict", { stateChanged = false })
    end

    local effective_aggression = normalized.playerInitiatedAggression
        or binding.playerInitiatedAggression == true
    local disposition, basis = desired_disposition(
        self,
        normalized.factionId,
        effective_aggression
    )
    local intent = {
        schemaVersion = "1.0.0",
        kind = "set-faction-NPC-disposition",
        eventId = normalized.eventId,
        operationId = normalized.operationId,
        bindingId = normalized.bindingId,
        factionId = normalized.factionId,
        actorKey = normalized.actorKey,
        actorClassKey = normalized.actorClassKey,
        trigger = normalized.trigger,
        disposition = disposition,
        basis = basis,
        playerInitiatedAggression = effective_aggression,
        PalworldSaveMutation = false,
    }
    local invoked, provider_result = pcall(provider.applyIntent, copy(intent), binding.actorRef)
    if not invoked or type(provider_result) ~= "table" or provider_result.ok ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "NPC-attitude-provider-failed", {
            retryable = true,
            detail = invoked and copy(provider_result) or tostring(provider_result),
            intent = copy(intent),
            stateChanged = false,
        })
    end
    local outcome = result(true, "NPC-attitude-applied", {
        eventId = normalized.eventId,
        operationId = normalized.operationId,
        bindingId = normalized.bindingId,
        factionId = normalized.factionId,
        disposition = disposition,
        basis = basis,
        providerResult = copy(provider_result),
        intent = copy(intent),
        stateChanged = true,
        PalworldSaveMutation = false,
    })
    local persisted_outcome = copy(outcome)
    -- Provider responses may contain transient native handles. They are useful
    -- to the immediate caller but must never enter a serializable snapshot.
    persisted_outcome.providerResult = nil
    self.results[normalized.eventId] = {
        input = copy(normalized),
        outcome = persisted_outcome,
    }
    self.operationOwners[normalized.operationId] = normalized.eventId
    binding.lastDisposition = disposition
    binding.playerInitiatedAggression = effective_aggression
    if self.progressionState ~= nil then
        self.progressionState.results = self.results
        self.progressionState.refreshSequence = self.refreshSequence
    end
    self.acceptedCount = self.acceptedCount + 1
    return outcome
end

function FactionNpcAttitudeBus:refresh_faction(faction_id, context)
    assert(faction_id == nil or (type(faction_id) == "string" and faction_id ~= ""),
        "refresh faction ID must be nil or a non-empty string")
    context = context or {}
    assert(type(context) == "table", "NPC attitude refresh context must be a table")
    local binding_ids = {}
    for binding_id, binding in pairs(self.bindings) do
        if faction_id == nil or binding.factionId == faction_id then
            binding_ids[#binding_ids + 1] = binding_id
        end
    end
    table.sort(binding_ids)
    local responses = {}
    for _, binding_id in ipairs(binding_ids) do
        local binding = self.bindings[binding_id]
        local provider = self.providers[binding.providerId]
        local desired = desired_disposition(
            self,
            binding.factionId,
            binding.playerInitiatedAggression
                or context.playerInitiatedAggression == true
        )
        if context.force == true or binding.lastDisposition ~= desired then
            self.refreshSequence = self.refreshSequence + 1
            if self.progressionState ~= nil then
                self.progressionState.refreshSequence = self.refreshSequence
            end
            local event_id = string.format(
                "NPC-attitude-refresh:%08d:%s",
                self.refreshSequence,
                binding_id
            )
            responses[#responses + 1] = self:refresh({
                schemaVersion = "1.0.0",
                authoritative = true,
                providerId = binding.providerId,
                authoritySource = provider.authoritySource,
                trigger = context.trigger or "relation-changed",
                eventId = event_id,
                operationId = event_id,
                bindingId = binding_id,
                actorKey = binding.actorKey,
                actorClassKey = binding.actorClassKey,
                playerInitiatedAggression =
                    context.playerInitiatedAggression == true,
            })
        end
    end
    local failed = 0
    for _, response in ipairs(responses) do
        if not response.ok then failed = failed + 1 end
    end
    return result(failed == 0,
        failed == 0 and "NPC-attitude-faction-refreshed"
            or "NPC-attitude-faction-refresh-partial",
        {
            factionId = faction_id,
            bindingCount = #binding_ids,
            appliedCount = #responses,
            failedCount = failed,
            responses = responses,
        })
end

function FactionNpcAttitudeBus:unbind_actor(definition)
    assert(type(definition) == "table", "NPC attitude unbind request is required")
    local binding_id = require_text(definition.bindingId, "unbind binding ID")
    local binding = self.bindings[binding_id]
    if binding == nil then return result(true, "NPC-attitude-actor-already-unbound", { bindingId = binding_id }) end
    if definition.providerId ~= binding.providerId or definition.actorKey ~= binding.actorKey
        or definition.actorClassKey ~= binding.actorClassKey then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "NPC-attitude-unbind-exact-match-required")
    end
    self.bindings[binding_id] = nil
    return result(true, "NPC-attitude-actor-unbound", { bindingId = binding_id })
end

function FactionNpcAttitudeBus:clear_world()
    local removed = count(self.bindings)
    self.bindings = {}
    return result(true, "NPC-attitude-world-cleared", { removedBindingCount = removed })
end

function FactionNpcAttitudeBus:status()
    local ready = 0
    for _, provider in pairs(self.providers) do
        if provider.enabled and type(provider.applyIntent) == "function" then ready = ready + 1 end
    end
    return {
        apiVersion = self.version,
        providerCount = count(self.providers),
        readyProviderCount = ready,
        bindingCount = count(self.bindings),
        resultCount = count(self.results),
        acceptedCount = self.acceptedCount,
        rejectedCount = self.rejectedCount,
        duplicateCount = self.duplicateCount,
        bindingsPersisted = false,
        progressionSidecarIdempotency = self.progressionState ~= nil,
        serializableStateOnly = true,
        PalworldSaveMutation = false,
    }
end

function FactionNpcAttitudeBus:export_snapshot()
    local providers = {}
    for _, provider in pairs(self.providers) do
        table.insert(providers, provider_metadata(provider))
    end
    table.sort(providers, function(first, second) return first.providerId < second.providerId end)
    return {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = providers,
        results = copy(self.results),
    }
end

return FactionNpcAttitudeBus
