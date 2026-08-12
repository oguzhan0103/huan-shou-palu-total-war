local StrategicWorldNativeBus = {}

local API_VERSION = "1.0.0"
local SNAPSHOT_SCHEMA_VERSION = "1.0.0"

local ALLOWED_EVENT_KINDS = {
    ["unique-pal-captured"] = "unique-pal",
    ["city-captured"] = "city-anchor",
    ["boss-damage"] = "city-boss",
    ["boss-death"] = "city-boss",
    ["city-loaded"] = "city-anchor",
}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function require_boolean(value, name)
    assert(type(value) == "boolean", name .. " must be boolean")
    return value
end

local function safe_call(callback, ...)
    local ok, response = pcall(callback, ...)
    if not ok then
        return nil, tostring(response)
    end
    if type(response) ~= "table" or type(response.ok) ~= "boolean" then
        return nil, "strategic-world-returned-invalid-result"
    end
    return response, nil
end

local function owner_key(owner)
    return tostring(owner.kind) .. ":" .. tostring(owner.id or "")
end

local function normalize_owner(owner, name)
    assert(type(owner) == "table", name .. " must be a table")
    local kind = require_text(owner.kind, name .. " kind")
    assert(
        kind == "unclaimed"
            or kind == "wild"
            or kind == "player"
            or kind == "faction",
        name .. " kind is unsupported"
    )
    if kind == "player" or kind == "faction" then
        return {
            kind = kind,
            id = require_text(owner.id, name .. " ID"),
        }
    end
    assert(owner.id == nil, name .. " cannot include an ID")
    return { kind = kind }
end

local function normalize_provider(definition)
    assert(type(definition) == "table", "provider definition is required")
    local provider_id = require_text(definition.providerId, "provider ID")
    local authority_source = require_text(
        definition.authoritySource,
        "provider authority source"
    )
    assert(
        type(definition.allowedEventKinds) == "table"
            and #definition.allowedEventKinds > 0,
        "provider allowed event kinds are required"
    )
    local allowed = {}
    for _, event_kind in ipairs(definition.allowedEventKinds) do
        require_text(event_kind, "provider event kind")
        assert(ALLOWED_EVENT_KINDS[event_kind] ~= nil, "unknown provider event kind")
        assert(allowed[event_kind] == nil, "duplicate provider event kind")
        allowed[event_kind] = true
    end
    return {
        providerId = provider_id,
        authoritySource = authority_source,
        allowedEventKinds = allowed,
        enabled = definition.enabled ~= false,
    }
end

local function normalize_binding(instance, definition)
    assert(type(definition) == "table", "native binding is required")
    local provider_id = require_text(definition.providerId, "binding provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled, "binding provider is unavailable")
    local binding_kind = require_text(definition.bindingKind, "binding kind")
    assert(
        binding_kind == "unique-pal"
            or binding_kind == "city-anchor"
            or binding_kind == "city-boss",
        "binding kind is unsupported"
    )
    local strategic_id = require_text(
        definition.strategicId,
        "binding strategic ID"
    )
    if binding_kind == "unique-pal" then
        assert(
            instance.strategicWorld:unique_pal_status(strategic_id) ~= nil,
            "binding references an unknown unique Pal"
        )
    else
        assert(
            instance.strategicWorld:city_status(strategic_id) ~= nil,
            "binding references an unknown city"
        )
    end
    return {
        bindingId = require_text(definition.bindingId, "binding ID"),
        providerId = provider_id,
        bindingKind = binding_kind,
        strategicId = strategic_id,
        actorKey = require_text(definition.actorKey, "binding actor key"),
        actorClassKey = definition.actorClassKey
            and require_text(definition.actorClassKey, "binding actor class key")
            or nil,
    }
end

local function normalize_event(instance, event)
    assert(type(event) == "table", "native strategic event is required")
    assert(event.schemaVersion == "1.0.0", "unsupported native strategic event schema")
    require_boolean(event.authoritative, "native strategic event authority")
    assert(event.authoritative, "native strategic event must be authoritative")
    local provider_id = require_text(event.providerId, "event provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled, "event provider is unavailable")
    assert(
        event.authoritySource == provider.authoritySource,
        "event authority source is not trusted"
    )
    local event_kind = require_text(event.eventKind, "event kind")
    local expected_binding_kind = ALLOWED_EVENT_KINDS[event_kind]
    assert(expected_binding_kind ~= nil, "event kind is unsupported")
    assert(provider.allowedEventKinds[event_kind], "provider cannot publish this event kind")
    local binding_id = require_text(event.bindingId, "event binding ID")
    local binding = instance.bindings[binding_id]
    assert(binding ~= nil, "event binding is unavailable")
    assert(binding.providerId == provider_id, "event binding provider mismatch")
    assert(
        binding.bindingKind == expected_binding_kind,
        "event binding kind mismatch"
    )
    assert(
        event.actorKey == binding.actorKey,
        "event actor does not exactly match the binding"
    )
    if binding.actorClassKey ~= nil then
        assert(
            event.actorClassKey == binding.actorClassKey,
            "event actor class does not exactly match the binding"
        )
    end
    return {
        schemaVersion = "1.0.0",
        authoritative = true,
        authoritySource = event.authoritySource,
        providerId = provider_id,
        eventKind = event_kind,
        eventId = require_text(event.eventId, "event ID"),
        operationId = require_text(event.operationId, "operation ID"),
        bindingId = binding_id,
        bindingKind = binding.bindingKind,
        strategicId = binding.strategicId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        proposedHealth = event.proposedHealth,
        expectedOwner = event.expectedOwner and copy(event.expectedOwner) or nil,
        newOwner = event.newOwner and copy(event.newOwner) or nil,
        newOwnerFactionId = event.newOwnerFactionId,
        destructionActor = event.destructionActor
            and copy(event.destructionActor)
            or nil,
    }
end

local function same_event(first, second)
    return first.eventKind == second.eventKind
        and first.providerId == second.providerId
        and first.authoritySource == second.authoritySource
        and first.bindingId == second.bindingId
        and first.actorKey == second.actorKey
        and first.actorClassKey == second.actorClassKey
        and first.strategicId == second.strategicId
        and first.operationId == second.operationId
        and first.proposedHealth == second.proposedHealth
        and first.newOwnerFactionId == second.newOwnerFactionId
        and owner_key(first.expectedOwner or { kind = "unclaimed" })
            == owner_key(second.expectedOwner or { kind = "unclaimed" })
        and owner_key(first.newOwner or { kind = "unclaimed" })
            == owner_key(second.newOwner or { kind = "unclaimed" })
        and owner_key(first.destructionActor or { kind = "unclaimed" })
            == owner_key(second.destructionActor or { kind = "unclaimed" })
end

local function dispatch(instance, event)
    local context = {
        sourceId = event.providerId,
        reason = "native-adapter:" .. event.eventKind,
        authority = event.authoritySource,
        eventId = event.eventId,
        bindingId = event.bindingId,
        actorKey = event.actorKey,
    }
    if event.eventKind == "unique-pal-captured" then
        local expected = normalize_owner(event.expectedOwner, "expected owner")
        local requested = normalize_owner(event.newOwner, "new owner")
        return safe_call(
            instance.strategicWorld.transfer_unique_pal,
            instance.strategicWorld,
            event.strategicId,
            expected,
            requested,
            event.operationId,
            context
        )
    end
    if event.eventKind == "city-captured" then
        return safe_call(
            instance.strategicWorld.occupy_city,
            instance.strategicWorld,
            event.strategicId,
            require_text(event.newOwnerFactionId, "new city owner faction ID"),
            event.operationId,
            context
        )
    end
    if event.eventKind == "city-loaded" then
        local city = instance.strategicWorld:city_status(event.strategicId)
        if city == nil then
            return result(false, "unknown-city"), nil
        end
        return result(true, "city-native-state-ready", {
            city = copy(city),
            desiredState = {
                loaded = true,
                status = city.status,
                ownerFactionId = city.ownerFactionId,
                destroyed = city.status == "destroyed",
            },
        }), nil
    end
    local actor = normalize_owner(
        event.destructionActor,
        "city destruction actor"
    )
    if event.eventKind == "boss-damage" then
        assert(
            type(event.proposedHealth) == "number",
            "boss proposed health must be numeric"
        )
        return safe_call(
            instance.strategicWorld.boss_health_gate,
            instance.strategicWorld,
            event.strategicId,
            actor,
            event.proposedHealth
        )
    end
    if event.eventKind == "boss-death" then
        local gate, gate_error = safe_call(
            instance.strategicWorld.boss_health_gate,
            instance.strategicWorld,
            event.strategicId,
            actor,
            0
        )
        if gate == nil then
            return nil, gate_error
        end
        if not gate.ok then
            return gate, nil
        end
        if gate.appliedHealth ~= 0
            or gate.destructionAuthorized ~= true then
            gate.reason = "boss-death-denied-one-hp-protection"
            gate.cityDestroyed = false
            return gate, nil
        end
        return safe_call(
            instance.strategicWorld.destroy_city,
            instance.strategicWorld,
            event.strategicId,
            actor,
            event.operationId,
            context
        )
    end
    return result(false, "unsupported-native-strategic-event"), nil
end

local function normalize_snapshot(snapshot)
    assert(type(snapshot) == "table", "native strategic bus snapshot is required")
    assert(
        snapshot.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported native strategic bus snapshot schema"
    )
    assert(type(snapshot.providers) == "table", "native strategic providers are required")
    assert(type(snapshot.results) == "table", "native strategic results are required")
    local normalized = {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = {},
        results = {},
        operationOwners = {},
    }
    for _, definition in ipairs(snapshot.providers) do
        local provider = normalize_provider(definition)
        assert(normalized.providers[provider.providerId] == nil, "duplicate restored provider")
        normalized.providers[provider.providerId] = provider
    end
    for event_id, record in pairs(snapshot.results) do
        require_text(event_id, "restored event ID")
        assert(type(record) == "table", "restored result record is invalid")
        assert(type(record.input) == "table", "restored input is required")
        assert(type(record.outcome) == "table", "restored outcome is required")
        require_text(record.input.operationId, "restored operation ID")
        assert(
            normalized.operationOwners[record.input.operationId] == nil,
            "duplicate restored operation ID"
        )
        normalized.results[event_id] = copy(record)
        normalized.operationOwners[record.input.operationId] = event_id
    end
    return normalized
end

local function persist_snapshot(instance)
    local progression = instance.progression
    if progression ~= nil and type(progression.state) == "table" then
        progression.state.strategicWorldNativeBus =
            instance:export_snapshot()
    end
end

local function notify(instance, event)
    persist_snapshot(instance)
    if instance.onChange ~= nil then
        local called, message = pcall(instance.onChange, nil, copy(event))
        if not called then instance.lastNotificationError = tostring(message) end
    end
end

function StrategicWorldNativeBus.create(strategic_world, options)
    assert(type(strategic_world) == "table", "strategic-world service is required")
    for _, method_name in ipairs({
        "unique_pal_status",
        "city_status",
        "transfer_unique_pal",
        "occupy_city",
        "boss_health_gate",
        "destroy_city",
    }) do
        assert(
            type(strategic_world[method_name]) == "function",
            "strategic-world service lacks " .. method_name
        )
    end
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "native strategic bus onChange must be a function")
    local progression = strategic_world.progression
    local progression_snapshot = progression
        and progression.state
        and progression.state.strategicWorldNativeBus
        or nil
    local restored = (options.snapshot or progression_snapshot)
        and normalize_snapshot(options.snapshot or progression_snapshot)
        or {
            providers = {},
            results = {},
            operationOwners = {},
        }
    local instance = setmetatable({
        version = API_VERSION,
        strategicWorld = strategic_world,
        progression = progression,
        providers = restored.providers,
        bindings = {},
        results = restored.results,
        operationOwners = restored.operationOwners,
        acceptedCount = 0,
        rejectedCount = 0,
        duplicateCount = 0,
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            providerRegistration = true,
            exactActorBinding = true,
            authoritativeEventsOnly = true,
            operationIdempotency = true,
            bossOneHpGateBeforeDestruction = true,
            stateChangeOutput = true,
            serializableRestoreWithoutUObjects = true,
            strategicWorldWhitelistOnly = true,
            PalworldSaveMutation = false,
        },
    }, { __index = StrategicWorldNativeBus })
    persist_snapshot(instance)
    if progression ~= nil
        and type(progression.register_restore_listener) == "function" then
        progression:register_restore_listener(
            "pwft.strategic-world-native-bus.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
    end
    return instance
end

function StrategicWorldNativeBus:rebind_progression_state()
    local snapshot = self.progression
        and self.progression.state.strategicWorldNativeBus
        or nil
    local called, restored = pcall(normalize_snapshot, snapshot or {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = {},
        results = {},
    })
    if not called then
        return result(false, "native-strategic-snapshot-invalid", {
            validationError = tostring(restored),
        })
    end
    self.providers = restored.providers
    self.results = restored.results
    self.operationOwners = restored.operationOwners
    self.bindings = {}
    persist_snapshot(self)
    return result(true, "native-strategic-state-rebound", {
        bindingsCleared = true,
    })
end

function StrategicWorldNativeBus:register_provider(definition)
    local ok, provider = pcall(normalize_provider, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-native-strategic-provider", {
            validationError = tostring(provider),
        })
    end
    local existing = self.providers[provider.providerId]
    if existing ~= nil then
        if existing.authoritySource ~= provider.authoritySource then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "native-strategic-provider-id-conflict")
        end
        for event_kind in pairs(existing.allowedEventKinds) do
            if provider.allowedEventKinds[event_kind] ~= true then
                self.rejectedCount = self.rejectedCount + 1
                return result(false, "native-strategic-provider-id-conflict")
            end
        end
        for event_kind in pairs(provider.allowedEventKinds) do
            if existing.allowedEventKinds[event_kind] ~= true then
                self.rejectedCount = self.rejectedCount + 1
                return result(false, "native-strategic-provider-id-conflict")
            end
        end
        return result(true, "native-strategic-provider-already-registered", {
            providerId = provider.providerId,
        })
    end
    self.providers[provider.providerId] = provider
    notify(self, {
        type = "native-strategic-provider-registered",
        providerId = provider.providerId,
    })
    return result(true, "native-strategic-provider-registered", {
        providerId = provider.providerId,
    })
end

function StrategicWorldNativeBus:bind_actor(definition)
    local ok, binding = pcall(normalize_binding, self, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-native-strategic-binding", {
            validationError = tostring(binding),
        })
    end
    local existing = self.bindings[binding.bindingId]
    if existing ~= nil then
        if existing.providerId ~= binding.providerId
            or existing.bindingKind ~= binding.bindingKind
            or existing.strategicId ~= binding.strategicId
            or existing.actorKey ~= binding.actorKey
            or existing.actorClassKey ~= binding.actorClassKey then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "native-strategic-binding-id-conflict")
        end
        return result(true, "native-strategic-binding-already-registered", {
            bindingId = binding.bindingId,
        })
    end
    self.bindings[binding.bindingId] = binding
    return result(true, "native-strategic-actor-bound", {
        bindingId = binding.bindingId,
        bindingKind = binding.bindingKind,
        strategicId = binding.strategicId,
    })
end

function StrategicWorldNativeBus:unbind_world()
    local count = 0
    for _ in pairs(self.bindings) do
        count = count + 1
    end
    self.bindings = {}
    return result(true, "native-strategic-world-unbound", {
        removedBindingCount = count,
    })
end

function StrategicWorldNativeBus:ingest(event)
    local ok, normalized = pcall(normalize_event, self, event)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-native-strategic-event", {
            validationError = tostring(normalized),
            stateChanged = false,
        })
    end
    local existing = self.results[normalized.eventId]
    if existing ~= nil then
        if not same_event(existing.input, normalized) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "native-strategic-event-id-conflict", {
                eventId = normalized.eventId,
                stateChanged = false,
            })
        end
        self.duplicateCount = self.duplicateCount + 1
        local duplicate = copy(existing.outcome)
        duplicate.duplicateOfReason = duplicate.reason
        duplicate.reason = "duplicate-native-strategic-event"
        duplicate.stateChanged = false
        duplicate.idempotent = true
        return duplicate
    end
    local operation_owner = self.operationOwners[normalized.operationId]
    if operation_owner ~= nil and operation_owner ~= normalized.eventId then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "native-strategic-operation-id-conflict", {
            operationId = normalized.operationId,
            stateChanged = false,
        })
    end

    local before_revision = self.strategicWorld:status().revision
    local dispatched, dispatch_error = dispatch(self, normalized)
    if dispatched == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "native-strategic-dispatch-error", {
            validationError = dispatch_error,
            stateChanged = false,
        })
    end
    local after_revision = self.strategicWorld:status().revision
    local outcome = copy(dispatched)
    outcome.eventId = normalized.eventId
    outcome.operationId = normalized.operationId
    outcome.eventKind = normalized.eventKind
    outcome.bindingId = normalized.bindingId
    outcome.strategicId = normalized.strategicId
    outcome.stateChanged = after_revision > before_revision
    outcome.beforeRevision = before_revision
    outcome.afterRevision = after_revision
    outcome.PalworldSaveMutation = false
    self.results[normalized.eventId] = {
        input = copy(normalized),
        outcome = copy(outcome),
    }
    self.operationOwners[normalized.operationId] = normalized.eventId
    if outcome.ok then
        self.acceptedCount = self.acceptedCount + 1
    else
        self.rejectedCount = self.rejectedCount + 1
    end
    notify(self, {
        type = "native-strategic-event-recorded",
        eventId = normalized.eventId,
        operationId = normalized.operationId,
        eventKind = normalized.eventKind,
        stateChanged = outcome.stateChanged,
        accepted = outcome.ok == true,
    })
    return outcome
end

function StrategicWorldNativeBus:export_snapshot()
    local providers = {}
    for _, provider in pairs(self.providers) do
        local event_kinds = {}
        for event_kind in pairs(provider.allowedEventKinds) do
            event_kinds[#event_kinds + 1] = event_kind
        end
        table.sort(event_kinds)
        providers[#providers + 1] = {
            providerId = provider.providerId,
            authoritySource = provider.authoritySource,
            allowedEventKinds = event_kinds,
            enabled = provider.enabled,
        }
    end
    table.sort(providers, function(first, second)
        return first.providerId < second.providerId
    end)
    return {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = providers,
        results = copy(self.results),
    }
end

function StrategicWorldNativeBus:status()
    local provider_count = 0
    local binding_count = 0
    local result_count = 0
    for _ in pairs(self.providers) do provider_count = provider_count + 1 end
    for _ in pairs(self.bindings) do binding_count = binding_count + 1 end
    for _ in pairs(self.results) do result_count = result_count + 1 end
    return {
        apiVersion = self.version,
        providerCount = provider_count,
        bindingCount = binding_count,
        resultCount = result_count,
        acceptedCount = self.acceptedCount,
        rejectedCount = self.rejectedCount,
        duplicateCount = self.duplicateCount,
        progressionSidecarState = self.progression ~= nil,
        lastNotificationError = self.lastNotificationError,
        bindingsPersisted = false,
        serializableStateOnly = true,
        PalworldSaveMutation = false,
    }
end

return StrategicWorldNativeBus
