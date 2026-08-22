local FactionConsequenceRouter = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"

local ACTOR_REASON_ROLES = {
    ["friendly-fire"] = "faction-member",
    ["civilian-harm"] = "civilian",
}

local CONTENT_REASON_CODES = {
    ["contract-breach"] = true,
    ["mission-failure"] = true,
}

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do
        output[copy(key, seen)] = copy(item, seen)
    end
    return output
end

local function require_text(value, label)
    assert(type(value) == "string" and value ~= "", label .. " must be a non-empty string")
    return value
end

local function require_positive_number(value, label)
    assert(type(value) == "number" and value > 0 and value < math.huge,
        label .. " must be a finite positive number")
    return value
end

local function stable_sorted_keys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then return left < right end
        return type(left) < type(right)
    end)
    return keys
end

local function stable_encode(value)
    local value_type = type(value)
    if value_type == "nil" then return "n" end
    if value_type == "boolean" then return value and "b1" or "b0" end
    if value_type == "number" then return "d" .. tostring(value) end
    if value_type == "string" then return "s" .. #value .. ":" .. value end
    assert(value_type == "table", "unsupported consequence signature value")
    local parts = { "t{" }
    for _, key in ipairs(stable_sorted_keys(value)) do
        parts[#parts + 1] = stable_encode(key)
        parts[#parts + 1] = stable_encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function count(values)
    local total = 0
    for _ in pairs(values or {}) do total = total + 1 end
    return total
end

local function ensure_state(faction_api)
    local progression = assert(faction_api.progression,
        "faction consequence router requires progression")
    progression.state.factionConsequences =
        progression.state.factionConsequences or {
            schemaVersion = STATE_SCHEMA_VERSION,
            processedEvents = {},
        }
    local state = progression.state.factionConsequences
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported faction consequence state schema")
    state.processedEvents = state.processedEvents or {}
    return state
end

local function provider_routes(faction_api)
    local source = faction_api.progression.contract.reputationSources
        .consequence
    local routing = assert(source.routingPolicy,
        "faction consequence routing policy is required")
    local providers = {}
    local reason_owners = {}
    for _, definition in ipairs(routing.providers or {}) do
        local provider = {
            providerId = require_text(definition.id,
                "consequence provider ID"),
            authoritySource = require_text(definition.authoritySource,
                "consequence provider authority source"),
            reasonCodes = {},
        }
        assert(providers[provider.providerId] == nil,
            "duplicate consequence provider ID")
        for _, reason_code in ipairs(definition.reasonCodes or {}) do
            require_text(reason_code, "consequence reason code")
            assert(reason_owners[reason_code] == nil,
                "duplicate consequence reason provider")
            provider.reasonCodes[reason_code] = true
            reason_owners[reason_code] = provider.providerId
        end
        providers[provider.providerId] = provider
    end
    return providers, reason_owners, source.maximumPenaltyPerEvent,
        source.authority, routing.eventSchemaVersion
end

local function operation_owners(processed_events)
    local owners = {}
    for event_id, record in pairs(processed_events or {}) do
        local operation_id = record.input and record.input.operationId
        if operation_id ~= nil then
            assert(owners[operation_id] == nil
                or owners[operation_id] == event_id,
                "consequence operation is owned by multiple events")
            owners[operation_id] = event_id
        end
    end
    return owners
end

local function normalize_binding(instance, definition)
    assert(type(definition) == "table",
        "faction consequence actor binding is required")
    assert(definition.schemaVersion == "1.0.0",
        "unsupported faction consequence actor binding schema")
    local provider_id = require_text(definition.providerId,
        "actor consequence provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil, "actor consequence provider is unavailable")
    assert(provider.reasonCodes[definition.reasonCode] == true,
        "actor consequence reason is not owned by the provider")
    local expected_role = ACTOR_REASON_ROLES[definition.reasonCode]
    assert(expected_role ~= nil,
        "actor binding requires an actor consequence reason")
    assert(definition.actorRole == expected_role,
        "actor consequence role does not match its reason")
    local faction_id = require_text(definition.factionId,
        "actor consequence faction ID")
    local faction = instance.factionApi:faction_status(faction_id)
    assert(faction ~= nil and faction.kind == "Human",
        "actor consequence binding requires a human faction")
    assert(definition.worldGeneration == instance.worldGeneration,
        "actor consequence binding belongs to a stale world generation")
    assert(definition.actorRef ~= nil,
        "actor consequence binding requires an exact actor reference")
    return {
        schemaVersion = "1.0.0",
        bindingId = require_text(definition.bindingId,
            "actor consequence binding ID"),
        providerId = provider_id,
        authoritySource = provider.authoritySource,
        reasonCode = definition.reasonCode,
        factionId = faction_id,
        actorRole = definition.actorRole,
        actorKey = require_text(definition.actorKey,
            "actor consequence actor key"),
        actorClassKey = require_text(definition.actorClassKey,
            "actor consequence actor class key"),
        worldGeneration = definition.worldGeneration,
        actorRef = definition.actorRef,
    }
end

local function same_binding(first, second)
    return first.providerId == second.providerId
        and first.authoritySource == second.authoritySource
        and first.reasonCode == second.reasonCode
        and first.factionId == second.factionId
        and first.actorRole == second.actorRole
        and first.actorKey == second.actorKey
        and first.actorClassKey == second.actorClassKey
        and first.worldGeneration == second.worldGeneration
end

local function normalize_event(instance, event)
    assert(type(event) == "table",
        "faction consequence event is required")
    assert(event.schemaVersion == instance.eventSchemaVersion,
        "unsupported faction consequence event schema")
    assert(event.authoritative == true,
        "faction consequence event must be authoritative")
    assert(event.modelGenerated ~= true,
        "model-generated faction consequences are forbidden")
    local provider_id = require_text(event.providerId,
        "consequence event provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil, "consequence event provider is unavailable")
    assert(event.authoritySource == provider.authoritySource,
        "consequence event authority source is not trusted")
    local reason_code = require_text(event.reasonCode,
        "consequence event reason code")
    assert(provider.reasonCodes[reason_code] == true,
        "consequence reason is not owned by its provider")
    local faction_id = require_text(event.factionId,
        "consequence faction ID")
    local faction = instance.factionApi:faction_status(faction_id)
    assert(faction ~= nil and faction.kind == "Human",
        "faction consequences apply only to human factions")
    local penalty = require_positive_number(event.penalty,
        "faction consequence penalty")
    assert(penalty <= instance.maximumPenaltyPerEvent,
        "faction consequence exceeds the per-event maximum")

    local normalized = {
        schemaVersion = instance.eventSchemaVersion,
        authoritative = true,
        eventId = require_text(event.eventId,
            "consequence event ID"),
        operationId = require_text(event.operationId,
            "consequence operation ID"),
        providerId = provider_id,
        authoritySource = provider.authoritySource,
        reasonCode = reason_code,
        factionId = faction_id,
        penalty = penalty,
        contextId = require_text(event.contextId,
            "consequence context ID"),
    }

    local expected_role = ACTOR_REASON_ROLES[reason_code]
    if expected_role ~= nil then
        assert(event.nativeConfirmed == true,
            "actor consequence requires native confirmation")
        assert(event.playerInitiated == true,
            "actor consequence requires player-initiated harm")
        assert(event.worldGeneration == instance.worldGeneration,
            "actor consequence belongs to a stale world generation")
        local binding_id = require_text(event.bindingId,
            "actor consequence binding ID")
        local binding = instance.bindings[binding_id]
        assert(binding ~= nil,
            "actor consequence binding is unavailable")
        assert(binding.providerId == provider_id,
            "actor consequence provider does not match its binding")
        assert(binding.reasonCode == reason_code,
            "actor consequence reason does not match its binding")
        assert(binding.factionId == faction_id,
            "actor consequence faction does not match its binding")
        assert(binding.actorRole == expected_role,
            "actor consequence role does not match its binding")
        assert(event.actorKey == binding.actorKey,
            "actor consequence actor does not exactly match its binding")
        assert(event.actorRef == binding.actorRef,
            "actor consequence actor reference does not exactly match its binding")
        assert(event.actorClassKey == binding.actorClassKey,
            "actor consequence class does not exactly match its binding")
        normalized.nativeConfirmed = true
        normalized.playerInitiated = true
        normalized.worldGeneration = event.worldGeneration
        normalized.bindingId = binding_id
        normalized.actorKey = binding.actorKey
        normalized.actorClassKey = binding.actorClassKey
        normalized.actorRole = binding.actorRole
        normalized.nativeEventId = require_text(event.nativeEventId,
            "actor consequence native event ID")
    elseif CONTENT_REASON_CODES[reason_code] then
        normalized.contentPackId = require_text(event.contentPackId,
            "content consequence pack ID")
        normalized.actionId = require_text(event.actionId,
            "content consequence action ID")
    else
        assert(reason_code == "war-consequence",
            "unsupported faction consequence reason")
        normalized.warId = require_text(event.warId,
            "war consequence war ID")
        normalized.resolutionId = require_text(event.resolutionId,
            "war consequence resolution ID")
    end
    return normalized
end

function FactionConsequenceRouter.create(faction_api, options)
    assert(type(faction_api) == "table",
        "faction API is required")
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "faction consequence onChange must be a function")
    local providers, reason_owners, maximum_penalty,
        consequence_authority, event_schema = provider_routes(faction_api)
    local state = ensure_state(faction_api)
    local instance = setmetatable({
        version = API_VERSION,
        factionApi = faction_api,
        providers = providers,
        reasonOwners = reason_owners,
        maximumPenaltyPerEvent = maximum_penalty,
        consequenceAuthority = consequence_authority,
        eventSchemaVersion = event_schema,
        state = state,
        operationOwners = operation_owners(state.processedEvents),
        bindings = {},
        worldGeneration = 1,
        onChange = options.onChange,
        acceptedCount = 0,
        rejectedCount = 0,
        duplicateCount = 0,
        capabilities = {
            humanFactionsOnly = true,
            exactActorAndClassBinding = true,
            nativeConfirmationRequired = true,
            contentActionConsequences = true,
            warConsequences = true,
            operationIdempotency = true,
            worldGenerationFencing = true,
            modelMayDispatch = false,
            arbitraryClientMayDispatch = false,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionConsequenceRouter })
    local progression = faction_api.progression
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.faction-consequence-router.v1",
            function() return instance:rebind_progression_state() end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function FactionConsequenceRouter:rebind_progression_state()
    local ok, state = pcall(ensure_state, self.factionApi)
    if not ok then
        return result(false, "faction-consequence-state-invalid", {
            validationError = tostring(state),
        })
    end
    self.state = state
    self.operationOwners = operation_owners(state.processedEvents)
    self.bindings = {}
    self.worldGeneration = self.worldGeneration + 1
    return result(true, "faction-consequence-state-rebound", {
        worldGeneration = self.worldGeneration,
    })
end

function FactionConsequenceRouter:bind_actor(definition)
    local ok, binding = pcall(normalize_binding, self, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-faction-consequence-actor-binding", {
            validationError = tostring(binding),
        })
    end
    local existing = self.bindings[binding.bindingId]
    if existing ~= nil then
        if not same_binding(existing, binding) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "faction-consequence-binding-id-conflict")
        end
        existing.actorRef = binding.actorRef
        return result(true, "faction-consequence-actor-binding-ready", {
            bindingId = binding.bindingId,
            worldGeneration = self.worldGeneration,
        })
    end
    self.bindings[binding.bindingId] = binding
    return result(true, "faction-consequence-actor-bound", {
        bindingId = binding.bindingId,
        factionId = binding.factionId,
        worldGeneration = self.worldGeneration,
    })
end

function FactionConsequenceRouter:unbind_actor(binding_id, actor_ref)
    require_text(binding_id, "actor consequence binding ID")
    local binding = self.bindings[binding_id]
    if binding == nil then
        return result(true, "faction-consequence-actor-already-unbound", {
            bindingId = binding_id,
            removed = false,
        })
    end
    if actor_ref ~= nil and actor_ref ~= binding.actorRef then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "faction-consequence-actor-reference-mismatch", {
            bindingId = binding_id,
            removed = false,
        })
    end
    self.bindings[binding_id] = nil
    return result(true, "faction-consequence-actor-unbound", {
        bindingId = binding_id,
        removed = true,
    })
end

function FactionConsequenceRouter:dispatch(event)
    local ok, normalized = pcall(normalize_event, self, event)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-faction-consequence-event", {
            validationError = tostring(normalized),
            stateChanged = false,
        })
    end
    local signature = stable_encode(normalized)
    local existing = self.state.processedEvents[normalized.eventId]
    if existing ~= nil then
        if existing.signature ~= signature then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "faction-consequence-event-id-conflict", {
                stateChanged = false,
            })
        end
        self.duplicateCount = self.duplicateCount + 1
        local duplicate = copy(existing.outcome)
        duplicate.duplicateOfReason = duplicate.reason
        duplicate.reason = "duplicate-faction-consequence-event"
        duplicate.originalApplied = duplicate.applied
        duplicate.applied = 0
        duplicate.stateChanged = false
        duplicate.idempotent = true
        return duplicate
    end
    local operation_owner = self.operationOwners[normalized.operationId]
    if operation_owner ~= nil
        and operation_owner ~= normalized.eventId then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "faction-consequence-operation-id-conflict", {
            stateChanged = false,
        })
    end

    local outcome = self.factionApi:apply_reputation_delta(
        normalized.factionId,
        -normalized.penalty,
        {
            source = "consequence",
            operationId = normalized.operationId,
            authority = self.consequenceAuthority,
            reasonCode = normalized.reasonCode,
            contextId = normalized.contextId,
        }
    )
    if type(outcome) ~= "table" or outcome.ok ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return outcome
    end
    local persisted_outcome = {
        ok = true,
        reason = outcome.reason,
        factionId = normalized.factionId,
        eventId = normalized.eventId,
        operationId = normalized.operationId,
        providerId = normalized.providerId,
        reasonCode = normalized.reasonCode,
        requested = -normalized.penalty,
        applied = outcome.applied,
        before = outcome.before,
        after = outcome.after,
        beforeRankId = outcome.beforeRankId,
        rankId = outcome.rankId,
        relation = outcome.relation,
        demoted = outcome.demoted == true,
        stateChanged = outcome.applied ~= 0,
    }
    self.state.processedEvents[normalized.eventId] = {
        signature = signature,
        input = copy(normalized),
        outcome = copy(persisted_outcome),
    }
    self.operationOwners[normalized.operationId] = normalized.eventId
    self.acceptedCount = self.acceptedCount + 1
    local response = copy(persisted_outcome)
    if self.onChange ~= nil then
        local notified, notification_error = pcall(
            self.onChange,
            normalized.factionId,
            {
                type = "faction-consequence-recorded",
                factionId = normalized.factionId,
                eventId = normalized.eventId,
                operationId = normalized.operationId,
                reasonCode = normalized.reasonCode,
                applied = outcome.applied,
            },
            self.factionApi:faction_status(normalized.factionId)
        )
        response.notificationOk = notified
        if not notified then
            response.notificationError = tostring(notification_error)
        end
    end
    return response
end

function FactionConsequenceRouter:unbind_world(reason)
    local removed = count(self.bindings)
    self.bindings = {}
    self.worldGeneration = self.worldGeneration + 1
    return result(true, "faction-consequence-world-unbound", {
        removedBindingCount = removed,
        worldGeneration = self.worldGeneration,
        detail = reason or "world-unload",
    })
end

function FactionConsequenceRouter:event_status(event_id)
    require_text(event_id, "consequence event ID")
    local record = self.state.processedEvents[event_id]
    return record and copy(record) or nil
end

function FactionConsequenceRouter:status()
    return {
        apiVersion = self.version,
        providerCount = count(self.providers),
        reasonRouteCount = count(self.reasonOwners),
        activeBindingCount = count(self.bindings),
        processedEventCount = count(self.state.processedEvents),
        worldGeneration = self.worldGeneration,
        maximumPenaltyPerEvent = self.maximumPenaltyPerEvent,
        acceptedCount = self.acceptedCount,
        rejectedCount = self.rejectedCount,
        duplicateCount = self.duplicateCount,
        exactActorAndClassBinding = true,
        nativeConfirmationRequired = true,
        modelMayDispatch = false,
        PalworldSaveMutation = false,
    }
end

return FactionConsequenceRouter
