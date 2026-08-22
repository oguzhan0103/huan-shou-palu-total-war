local UniquePalBossProviderBus = {}

local API_VERSION = "1.0.0"
local SNAPSHOT_SCHEMA_VERSION = "1.0.0"
local SPAWN_AUTHORITY = "pwft.native-unique-pal-boss-spawn.v1"
local DEFEAT_AUTHORITY = "pwft.native-unique-pal-boss-defeat.v1"
local CAPTURE_AUTHORITY = "pwft.native-unique-pal-capture.v1"

local DELIVERY_KINDS = {
    announce = true,
    spawn = true,
    open = true,
    close = true,
    cooldown = true,
}

local EVENT_DELIVERIES = {
    ["unique-pal-opening-announced"] = { "announce" },
    ["unique-pal-boss-spawn-requested"] = { "spawn" },
    ["unique-pal-opening-started"] = { "open" },
    ["unique-pal-captured-by-player"] = { "close", "cooldown" },
    ["unique-pal-boss-defeated"] = { "close", "cooldown" },
    ["unique-pal-opening-expired-assigned"] = { "close", "cooldown" },
    ["unique-pal-opening-expired-unassigned"] = { "close", "cooldown" },
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
end

local function deep_equal(first, second)
    if type(first) ~= type(second) then return false end
    if type(first) ~= "table" then return first == second end
    for key, value in pairs(first) do
        if not deep_equal(value, second[key]) then return false end
    end
    for key in pairs(second) do
        if first[key] == nil then return false end
    end
    return true
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function stable_id(value, name)
    require_text(value, name)
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil,
        name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil,
        name .. " cannot contain an empty namespace segment")
    return value
end

local function positive_number(value, name)
    assert(type(value) == "number" and value > 0,
        name .. " must be a positive number")
    return value
end

local function positive_integer(value, name)
    positive_number(value, name)
    assert(value == math.floor(value), name .. " must be an integer")
    return value
end

local function non_negative_integer(value, name)
    assert(type(value) == "number" and value >= 0
            and value == math.floor(value),
        name .. " must be a non-negative integer")
    return value
end

local function require_serializable(value, path, seen)
    local kind = type(value)
    if kind == "nil" or kind == "string"
        or kind == "number" or kind == "boolean" then
        return
    end
    assert(kind == "table", path .. " contains a non-serializable value")
    seen = seen or {}
    assert(seen[value] == nil, path .. " contains a cycle")
    seen[value] = true
    for key, child in pairs(value) do
        local key_kind = type(key)
        assert(key_kind == "string" or key_kind == "number",
            path .. " contains an invalid key")
        require_serializable(child, path .. "." .. tostring(key), seen)
    end
    seen[value] = nil
end

local function sorted_keys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function normalize_provider(definition)
    assert(type(definition) == "table",
        "unique-Pal Boss provider definition is required")
    assert(definition.idempotentDeliveryIds == true,
        "unique-Pal Boss provider must guarantee idempotent delivery IDs")
    assert(definition.generationFencedCallbacks == true,
        "unique-Pal Boss provider must generation-fence callbacks")
    assert(type(definition.deliveryKinds) == "table"
            and #definition.deliveryKinds > 0,
        "unique-Pal Boss provider delivery kinds are required")
    local delivery_kinds = {}
    for _, delivery_kind in ipairs(definition.deliveryKinds) do
        require_text(delivery_kind, "unique-Pal Boss delivery kind")
        assert(DELIVERY_KINDS[delivery_kind] == true,
            "unique-Pal Boss delivery kind is not whitelisted")
        assert(delivery_kinds[delivery_kind] == nil,
            "duplicate unique-Pal Boss delivery kind")
        delivery_kinds[delivery_kind] = true
    end
    return {
        providerId = stable_id(definition.providerId,
            "unique-Pal Boss provider ID"),
        authoritySource = stable_id(definition.authoritySource,
            "unique-Pal Boss provider authority source"),
        deliveryKinds = delivery_kinds,
        idempotentDeliveryIds = true,
        generationFencedCallbacks = true,
        enabled = definition.enabled ~= false,
    }
end

local function provider_equal(first, second)
    if first.authoritySource ~= second.authoritySource
        or first.enabled ~= second.enabled then
        return false
    end
    for kind in pairs(first.deliveryKinds) do
        if second.deliveryKinds[kind] ~= true then return false end
    end
    for kind in pairs(second.deliveryKinds) do
        if first.deliveryKinds[kind] ~= true then return false end
    end
    return true
end

local function normalize_balance(balance)
    assert(type(balance) == "table",
        "raid-slab Boss balance profile is required")
    assert(balance.profileId == "raid-slab",
        "unique-Pal Boss balance profile must be raid-slab")
    assert(balance.captureAllowed == true,
        "unique-Pal Boss balance must remain capturable")
    return {
        profileId = "raid-slab",
        level = positive_integer(balance.level,
            "raid-slab Boss level"),
        healthMultiplier = positive_number(balance.healthMultiplier,
            "raid-slab Boss health multiplier"),
        damageMultiplier = positive_number(balance.damageMultiplier,
            "raid-slab Boss damage multiplier"),
        damageReductionMultiplier = positive_number(
            balance.damageReductionMultiplier,
            "raid-slab Boss damage-reduction multiplier"),
        statusResistanceMultiplier = positive_number(
            balance.statusResistanceMultiplier,
            "raid-slab Boss status-resistance multiplier"),
        captureDifficultyMultiplier = positive_number(
            balance.captureDifficultyMultiplier,
            "raid-slab Boss capture-difficulty multiplier"),
        captureAllowed = true,
    }
end

local function normalize_binding(instance, definition)
    assert(type(definition) == "table",
        "unique-Pal Boss native binding is required")
    local unique_pal_id = stable_id(definition.uniquePalId,
        "bound unique Pal ID")
    local campaign = instance.campaign:campaign_status(unique_pal_id)
    assert(campaign ~= nil, "bound unique-Pal campaign is unknown")
    local boss = campaign.definition and campaign.definition.boss or nil
    assert(type(boss) == "table",
        "bound unique-Pal Boss definition is unavailable")
    assert(boss.bindingStatus == "bound",
        "content pack Boss binding must be bound before native activation")
    assert(definition.speciesId == boss.speciesId,
        "native binding species must match the campaign definition")

    local provider_id = stable_id(definition.providerId,
        "unique-Pal Boss binding provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled,
        "unique-Pal Boss binding provider is unavailable")
    assert(instance.handlers[provider_id] ~= nil,
        "unique-Pal Boss provider handler must be active before binding")

    local route = require_text(definition.route,
        "unique-Pal Boss native route")
    assert(route == "native-existing" or route == "replacement-slot",
        "unique-Pal Boss native route is unsupported")
    local slot_id = definition.nativeBossSlotId
    if route == "native-existing" then
        assert(boss.nativeBossAvailable == true,
            "native-existing route requires an existing native Boss")
        if boss.nativeBossSlotId ~= nil then
            assert(slot_id == boss.nativeBossSlotId,
                "native Boss slot must match the campaign definition")
        end
    else
        assert(boss.nativeBossAvailable == false,
            "replacement-slot route is only allowed without a native Boss")
        require_text(slot_id, "replacement Boss slot ID")
        assert(slot_id == boss.nativeBossSlotId,
            "replacement Boss slot must match the campaign definition")
    end

    assert(type(definition.verification) == "table",
        "unique-Pal Boss binding verification is required")
    local verification = definition.verification
    assert(verification.speciesId == true,
        "unique-Pal species ID must be verified")
    assert(verification.spawnerKey == true,
        "unique-Pal Boss spawner key must be verified")
    assert(verification.actorClassKey == true,
        "unique-Pal Boss actor class must be verified")
    if route == "replacement-slot" then
        assert(verification.slotId == true,
            "replacement Boss slot must be verified")
    end

    return {
        bindingId = stable_id(definition.bindingId,
            "unique-Pal Boss binding ID"),
        providerId = provider_id,
        uniquePalId = unique_pal_id,
        speciesId = boss.speciesId,
        route = route,
        nativeBossSlotId = slot_id,
        bossSpawnerKey = require_text(definition.bossSpawnerKey,
            "unique-Pal Boss spawner key"),
        expectedActorClassKey = require_text(
            definition.expectedActorClassKey,
            "unique-Pal Boss expected actor class key"),
        locationKey = require_text(definition.locationKey,
            "unique-Pal Boss location key"),
        buildId = require_text(definition.buildId,
            "verified Palworld build ID"),
        verification = {
            speciesId = true,
            spawnerKey = true,
            actorClassKey = true,
            slotId = route == "replacement-slot" and true or nil,
        },
        balance = normalize_balance(definition.balance),
        worldGeneration = instance.worldGeneration,
    }
end

local function normalize_snapshot(snapshot)
    require_serializable(snapshot, "unique-Pal Boss provider snapshot")
    assert(type(snapshot) == "table",
        "unique-Pal Boss provider snapshot is required")
    assert(snapshot.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported unique-Pal Boss provider snapshot schema")
    local restored = {
        providers = {},
        deliveries = copy(snapshot.deliveries or {}),
        callbackSignatures = copy(snapshot.callbackSignatures or {}),
        worldGeneration = non_negative_integer(
            snapshot.worldGeneration or 0,
            "unique-Pal Boss world generation"),
    }
    for _, definition in ipairs(snapshot.providers or {}) do
        local provider = normalize_provider(definition)
        assert(restored.providers[provider.providerId] == nil,
            "duplicate restored unique-Pal Boss provider")
        restored.providers[provider.providerId] = provider
    end
    return restored
end

local function persist_snapshot(instance)
    local progression = instance.progression
    if progression ~= nil and type(progression.state) == "table" then
        progression.state.uniquePalBossProviderBus =
            instance:export_snapshot()
    end
end

local function notify(instance, event)
    persist_snapshot(instance)
    if instance.onChange ~= nil then
        local called, message = pcall(instance.onChange, copy(event))
        if not called then instance.lastNotificationError = tostring(message) end
    end
end

local function delivery_id(event_id, delivery_kind)
    return "unique-pal-native." .. event_id .. "." .. delivery_kind
end

local function make_payload(instance, event, delivery_kind, binding)
    local status = instance.campaign:campaign_status(event.uniquePalId)
    local definition = status and status.definition or nil
    return {
        schemaVersion = "1.0.0",
        deliveryId = delivery_id(event.eventId, delivery_kind),
        deliveryKind = delivery_kind,
        uniquePalId = event.uniquePalId,
        eventId = event.eventId,
        eventType = event.type,
        speciesId = definition and definition.boss.speciesId or nil,
        nativeBossSlotId = binding and binding.nativeBossSlotId
            or (definition and definition.boss.nativeBossSlotId),
        bossSpawnerKey = binding and binding.bossSpawnerKey or nil,
        expectedActorClassKey = binding
            and binding.expectedActorClassKey or nil,
        locationKey = binding and binding.locationKey or nil,
        nativeRoute = binding and binding.route or nil,
        balance = binding and copy(binding.balance) or nil,
        noticeTick = event.noticeTick,
        openTick = event.openTick,
        closeTick = event.closeTick,
        spawnId = event.spawnId,
        actorBindingId = event.actorBindingId,
        nativeDespawnRequired = event.nativeDespawnRequired == true
            or event.nativeDespawnDuplicateRequired == true,
        cooldownPresentationRequired = delivery_kind == "cooldown",
        worldGeneration = instance.worldGeneration,
        PalworldSaveMutation = false,
    }
end

local function delivery_is_current(instance, delivery)
    if delivery.deliveryKind ~= "announce"
        and delivery.deliveryKind ~= "spawn"
        and delivery.deliveryKind ~= "open" then
        return true
    end
    local status = instance.campaign:campaign_status(delivery.uniquePalId)
    if status == nil or status.eventId ~= delivery.eventId then return false end
    if delivery.deliveryKind == "announce" then
        return status.phase == "announced"
            or status.phase == "activation-pending"
            or status.phase == "open"
    end
    if delivery.deliveryKind == "spawn" then
        return status.phase == "activation-pending"
    end
    return status.phase == "open"
end

local function apply_delivery(instance, delivery)
    if delivery.status == "applied" or delivery.status == "cancelled" then
        return
    end
    if not delivery_is_current(instance, delivery) then
        delivery.status = "cancelled"
        delivery.lastError = "stale-unique-pal-campaign-delivery"
        return
    end
    local binding = instance.bindings[delivery.uniquePalId]
    if binding == nil or binding.worldGeneration ~= instance.worldGeneration then
        delivery.status = "pending"
        delivery.lastError = "verified-unique-pal-boss-binding-unavailable"
        return
    end
    local provider = instance.providers[binding.providerId]
    local handler = instance.handlers[binding.providerId]
    if provider == nil or provider.enabled ~= true
        or provider.deliveryKinds[delivery.deliveryKind] ~= true
        or type(handler) ~= "function" then
        delivery.status = "pending"
        delivery.lastError = "unique-pal-boss-provider-unavailable"
        return
    end
    delivery.attemptCount = (delivery.attemptCount or 0) + 1
    delivery.payload = make_payload(instance, delivery.sourceEvent,
        delivery.deliveryKind, binding)
    local called, response = pcall(handler, copy(delivery.payload), {
        providerId = provider.providerId,
        bindingId = binding.bindingId,
        buildId = binding.buildId,
        worldGeneration = instance.worldGeneration,
        idempotentDeliveryId = true,
        generationFencedCallbacks = true,
    })
    local accepted = delivery.deliveryKind == "spawn"
        and type(response) == "table" and response.accepted == true
        or delivery.deliveryKind ~= "spawn"
            and type(response) == "table" and response.applied == true
    if not called then
        delivery.status = "pending"
        delivery.lastError = "provider-error:" .. tostring(response)
    elseif type(response) ~= "table" or response.ok ~= true
        or response.deliveryId ~= delivery.deliveryId or not accepted then
        delivery.status = "pending"
        delivery.lastError = type(response) == "table"
                and tostring(response.reason
                    or "provider-did-not-confirm-delivery")
            or "provider-returned-invalid-result"
    else
        delivery.status = "applied"
        delivery.lastError = nil
        delivery.providerReason = response.reason
        delivery.providerRequestId = response.requestId
        delivery.appliedGeneration = instance.worldGeneration
    end
end

local function delivery_counts(instance)
    local applied, pending, cancelled = 0, 0, 0
    for _, delivery in pairs(instance.deliveries) do
        if delivery.status == "applied" then
            applied = applied + 1
        elseif delivery.status == "cancelled" then
            cancelled = cancelled + 1
        else
            pending = pending + 1
        end
    end
    return applied, pending, cancelled
end

local function callback_signature(input, callback_kind)
    return table.concat({
        callback_kind,
        tostring(input.providerId),
        tostring(input.authoritySource),
        tostring(input.bindingId),
        tostring(input.uniquePalId),
        tostring(input.eventId),
        tostring(input.speciesId),
        tostring(input.bossSpawnerKey),
        tostring(input.actorBindingId),
        tostring(input.actorClassKey),
        tostring(input.worldGeneration),
        tostring(input.logicalTick),
        tostring(input.playerId),
    }, "|")
end

local function duplicate_callback(instance, callback_id, signature)
    local previous = instance.callbackSignatures[callback_id]
    if previous == nil then return nil end
    if previous.signature ~= signature then
        return result(false, "native-unique-pal-callback-id-conflict", {
            callbackId = callback_id,
        })
    end
    local response = copy(previous.response)
    response.ok = true
    response.duplicateOfReason = response.reason
    response.reason = "duplicate-native-unique-pal-callback"
    response.idempotent = true
    return response
end

local function commit_callback(instance, callback_id, signature, response)
    if response.ok then
        instance.callbackSignatures[callback_id] = {
            signature = signature,
            response = copy(response),
        }
        notify(instance, {
            type = "native-unique-pal-callback-committed",
            callbackId = callback_id,
            callbackReason = response.reason,
        })
    end
    return response
end

local function validate_callback(instance, input, callback_kind)
    assert(type(input) == "table", "native unique-Pal callback is required")
    local callback_id = require_text(input.callbackId,
        "native unique-Pal callback ID")
    local signature = callback_signature(input, callback_kind)
    local duplicate = duplicate_callback(instance, callback_id, signature)
    if duplicate ~= nil then return nil, callback_id, signature, duplicate end
    local provider = instance.providers[input.providerId]
    if provider == nil or provider.enabled ~= true
        or provider.authoritySource ~= input.authoritySource then
        return nil, callback_id, signature,
            result(false, "native-unique-pal-callback-authority-rejected")
    end
    local binding = instance.bindings[input.uniquePalId]
    if binding == nil or binding.bindingId ~= input.bindingId
        or binding.providerId ~= input.providerId then
        return nil, callback_id, signature,
            result(false, "native-unique-pal-callback-binding-rejected")
    end
    if input.worldGeneration ~= instance.worldGeneration
        or binding.worldGeneration ~= instance.worldGeneration then
        return nil, callback_id, signature,
            result(false, "native-unique-pal-callback-generation-rejected")
    end
    if input.speciesId ~= binding.speciesId
        or input.bossSpawnerKey ~= binding.bossSpawnerKey
        or input.actorClassKey ~= binding.expectedActorClassKey then
        return nil, callback_id, signature,
            result(false, "native-unique-pal-callback-identity-rejected")
    end
    require_text(input.actorBindingId,
        "native unique-Pal actor binding ID")
    local status = instance.campaign:campaign_status(input.uniquePalId)
    if status == nil or status.eventId ~= input.eventId then
        return nil, callback_id, signature,
            result(false, "native-unique-pal-callback-event-rejected")
    end
    return {
        provider = provider,
        binding = binding,
        status = status,
    }, callback_id, signature, nil
end

function UniquePalBossProviderBus.create(campaign, options)
    assert(type(campaign) == "table"
            and type(campaign.campaign_status) == "function"
            and type(campaign.boss_spawn_policy) == "function"
            and type(campaign.confirm_boss_spawn) == "function"
            and type(campaign.capture) == "function"
            and type(campaign.defeat) == "function"
            and type(campaign.advance) == "function",
        "unique-Pal campaign with native callback API is required")
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "unique-Pal Boss provider onChange must be a function")
    local progression = campaign.progression
    local stored = progression and progression.state
        and progression.state.uniquePalBossProviderBus or nil
    local restored = stored and normalize_snapshot(stored) or {
        providers = {},
        deliveries = {},
        callbackSignatures = {},
        worldGeneration = 0,
    }
    local instance = setmetatable({
        version = API_VERSION,
        campaign = campaign,
        progression = progression,
        providers = restored.providers,
        handlers = {},
        bindings = {},
        deliveries = restored.deliveries,
        callbackSignatures = restored.callbackSignatures,
        worldGeneration = restored.worldGeneration + 1,
        rejectedCount = 0,
        retryCount = 0,
        lastNotificationError = nil,
        onChange = options.onChange,
        capabilities = {
            bossWhitelistPolicy = true,
            exactNativeBossBinding = true,
            nativeExistingBossRoute = true,
            replacementBossSlotRoute = true,
            configurableRaidSlabBalance = true,
            nativeOpeningPresentation = true,
            authoritativeSpawnCallback = true,
            authoritativeDefeatCallback = true,
            authoritativeCaptureCallback = true,
            authoritativeTimeoutCallback = true,
            generationFencedCallbacks = true,
            modelAuthority = false,
            directUEMutation = false,
            PalworldSaveMutation = false,
        },
    }, { __index = UniquePalBossProviderBus })
    persist_snapshot(instance)
    if progression ~= nil
        and type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.unique-pal-boss-provider-bus.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function UniquePalBossProviderBus:rebind_progression_state()
    local snapshot = self.progression
        and self.progression.state.uniquePalBossProviderBus or nil
    local called, restored = pcall(normalize_snapshot, snapshot or {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = {},
        deliveries = {},
        callbackSignatures = {},
        worldGeneration = self.worldGeneration,
    })
    if not called then
        return result(false, "unique-pal-boss-provider-snapshot-invalid", {
            validationError = tostring(restored),
        })
    end
    self.providers = restored.providers
    self.deliveries = restored.deliveries
    self.callbackSignatures = restored.callbackSignatures
    self.worldGeneration = math.max(
        self.worldGeneration,
        restored.worldGeneration
    ) + 1
    self.handlers = {}
    self.bindings = {}
    persist_snapshot(self)
    return result(true, "unique-pal-boss-provider-state-rebound", {
        handlersCleared = true,
        bindingsCleared = true,
        worldGeneration = self.worldGeneration,
    })
end

function UniquePalBossProviderBus:register_provider(definition, handler)
    local ok, provider = pcall(normalize_provider, definition)
    if not ok or type(handler) ~= "function" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-unique-pal-boss-provider", {
            validationError = ok
                    and "provider-handler-must-be-a-function"
                or tostring(provider),
        })
    end
    local existing = self.providers[provider.providerId]
    if existing ~= nil and not provider_equal(existing, provider) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "unique-pal-boss-provider-id-conflict")
    end
    self.providers[provider.providerId] = provider
    self.handlers[provider.providerId] = handler
    notify(self, {
        type = existing and "unique-pal-boss-provider-rebound"
            or "unique-pal-boss-provider-registered",
        providerId = provider.providerId,
        worldGeneration = self.worldGeneration,
    })
    return result(true,
        existing and "unique-pal-boss-provider-rebound"
            or "unique-pal-boss-provider-registered", {
            providerId = provider.providerId,
            worldGeneration = self.worldGeneration,
        })
end

function UniquePalBossProviderBus:bind(definition)
    local called, binding = pcall(normalize_binding, self, definition)
    if not called then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-unique-pal-boss-binding", {
            validationError = tostring(binding),
        })
    end
    local existing = self.bindings[binding.uniquePalId]
    if existing ~= nil and not deep_equal(existing, binding) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "unique-pal-boss-binding-conflict", {
            uniquePalId = binding.uniquePalId,
        })
    end
    self.bindings[binding.uniquePalId] = binding
    local retry = self:retry_pending(binding.uniquePalId)
    notify(self, {
        type = existing and "unique-pal-boss-binding-refreshed"
            or "unique-pal-boss-binding-activated",
        uniquePalId = binding.uniquePalId,
        bindingId = binding.bindingId,
        nativeRoute = binding.route,
        worldGeneration = self.worldGeneration,
    })
    return result(true,
        existing and "unique-pal-boss-binding-refreshed"
            or "unique-pal-boss-binding-activated", {
            uniquePalId = binding.uniquePalId,
            bindingId = binding.bindingId,
            nativeRoute = binding.route,
            retry = retry,
        })
end

function UniquePalBossProviderBus:handle_campaign_event(event)
    assert(type(event) == "table",
        "unique-Pal campaign event is required")
    local kinds = EVENT_DELIVERIES[event.type]
    if kinds == nil then
        return result(true, "unique-pal-campaign-event-does-not-require-native-delivery", {
            eventType = event.type,
            deliveryCount = 0,
        })
    end
    stable_id(event.uniquePalId, "unique-Pal campaign event ID")
    require_text(event.eventId, "unique-Pal opening event ID")
    local applied, pending, cancelled = 0, 0, 0
    for _, kind in ipairs(kinds) do
        local id = delivery_id(event.eventId, kind)
        local delivery = self.deliveries[id]
        if delivery == nil then
            delivery = {
                deliveryId = id,
                deliveryKind = kind,
                uniquePalId = event.uniquePalId,
                eventId = event.eventId,
                sourceEvent = copy(event),
                status = "pending",
                attemptCount = 0,
            }
            self.deliveries[id] = delivery
        elseif delivery.uniquePalId ~= event.uniquePalId
            or delivery.eventId ~= event.eventId
            or delivery.deliveryKind ~= kind
            or not deep_equal(delivery.sourceEvent, event) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "unique-pal-native-delivery-id-conflict", {
                deliveryId = id,
            })
        end
        apply_delivery(self, delivery)
        if delivery.status == "applied" then
            applied = applied + 1
        elseif delivery.status == "cancelled" then
            cancelled = cancelled + 1
        else
            pending = pending + 1
        end
    end
    notify(self, {
        type = "unique-pal-native-delivery-recorded",
        sourceEventType = event.type,
        uniquePalId = event.uniquePalId,
        eventId = event.eventId,
        appliedCount = applied,
        pendingCount = pending,
        cancelledCount = cancelled,
    })
    return result(pending == 0,
        pending == 0 and "unique-pal-native-delivery-applied"
            or "unique-pal-native-delivery-pending", {
            deliveryCount = #kinds,
            appliedCount = applied,
            pendingCount = pending,
            cancelledCount = cancelled,
            retryable = pending > 0,
        })
end

function UniquePalBossProviderBus:retry_pending(unique_pal_id)
    if unique_pal_id ~= nil then
        stable_id(unique_pal_id, "unique Pal retry filter")
    end
    self.retryCount = self.retryCount + 1
    local applied, pending, cancelled = 0, 0, 0
    for _, id in ipairs(sorted_keys(self.deliveries)) do
        local delivery = self.deliveries[id]
        if unique_pal_id == nil or delivery.uniquePalId == unique_pal_id then
            apply_delivery(self, delivery)
            if delivery.status == "applied" then
                applied = applied + 1
            elseif delivery.status == "cancelled" then
                cancelled = cancelled + 1
            else
                pending = pending + 1
            end
        end
    end
    persist_snapshot(self)
    return result(pending == 0,
        pending == 0 and "unique-pal-native-deliveries-retried"
            or "unique-pal-native-deliveries-still-pending", {
            appliedCount = applied,
            pendingCount = pending,
            cancelledCount = cancelled,
            retryable = pending > 0,
        })
end

function UniquePalBossProviderBus:boss_spawn_policy(species_id)
    local policy = self.campaign:boss_spawn_policy(species_id)
    if not policy.ok then return policy end
    local binding = self.bindings[policy.uniquePalId]
    if binding == nil or binding.worldGeneration ~= self.worldGeneration then
        return result(false, "verified-unique-pal-boss-binding-required", {
            uniquePalId = policy.uniquePalId,
            speciesId = species_id,
            phase = policy.phase,
            eventId = policy.eventId,
            suppressNativeBossSpawn = true,
            reversibleConfigurationOnly = true,
        })
    end
    return result(true, "verified-unique-pal-boss-spawn-authorized", {
        uniquePalId = policy.uniquePalId,
        speciesId = species_id,
        phase = policy.phase,
        eventId = policy.eventId,
        bindingId = binding.bindingId,
        providerId = binding.providerId,
        nativeRoute = binding.route,
        nativeBossSlotId = binding.nativeBossSlotId,
        bossSpawnerKey = binding.bossSpawnerKey,
        expectedActorClassKey = binding.expectedActorClassKey,
        locationKey = binding.locationKey,
        buildId = binding.buildId,
        balance = copy(binding.balance),
        worldGeneration = self.worldGeneration,
        suppressNativeBossSpawn = false,
        PalworldSaveMutation = false,
    })
end

function UniquePalBossProviderBus:confirm_spawn(input)
    local context, callback_id, signature, failure =
        validate_callback(self, input, "spawn")
    if failure ~= nil then return failure end
    non_negative_integer(input.logicalTick,
        "native unique-Pal spawn logical tick")
    if context.status.phase ~= "activation-pending" then
        return result(false, "native-unique-pal-spawn-not-pending")
    end
    local response = self.campaign:confirm_boss_spawn({
        spawnId = callback_id,
        uniquePalId = input.uniquePalId,
        eventId = input.eventId,
        actorBindingId = input.actorBindingId,
        logicalTick = input.logicalTick,
        authoritySource = SPAWN_AUTHORITY,
    })
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalBossProviderBus:confirm_capture(input)
    local context, callback_id, signature, failure =
        validate_callback(self, input, "capture")
    if failure ~= nil then return failure end
    if context.status.phase ~= "open"
        or context.status.actorBindingId ~= input.actorBindingId then
        return result(false, "native-unique-pal-capture-instance-rejected")
    end
    local response = self.campaign:capture({
        captureId = callback_id,
        uniquePalId = input.uniquePalId,
        eventId = input.eventId,
        playerId = input.playerId,
        authoritySource = CAPTURE_AUTHORITY,
    })
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalBossProviderBus:confirm_defeat(input)
    local context, callback_id, signature, failure =
        validate_callback(self, input, "defeat")
    if failure ~= nil then return failure end
    non_negative_integer(input.logicalTick,
        "native unique-Pal defeat logical tick")
    if context.status.phase ~= "open"
        or context.status.actorBindingId ~= input.actorBindingId then
        return result(false, "native-unique-pal-defeat-instance-rejected")
    end
    local response = self.campaign:defeat({
        defeatId = callback_id,
        uniquePalId = input.uniquePalId,
        eventId = input.eventId,
        spawnId = context.status.nativeSpawnId,
        actorBindingId = input.actorBindingId,
        logicalTick = input.logicalTick,
        authoritySource = DEFEAT_AUTHORITY,
    })
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalBossProviderBus:confirm_timeout(input)
    local context, callback_id, signature, failure =
        validate_callback(self, input, "timeout")
    if failure ~= nil then return failure end
    local logical_tick = non_negative_integer(input.logicalTick,
        "native unique-Pal timeout logical tick")
    if context.status.phase ~= "open"
        or context.status.actorBindingId ~= input.actorBindingId then
        return result(false, "native-unique-pal-timeout-instance-rejected")
    end
    if logical_tick < context.status.closeTick then
        return result(false, "native-unique-pal-timeout-too-early", {
            closeTick = context.status.closeTick,
        })
    end
    local response = self.campaign:advance(
        logical_tick,
        "native-timeout." .. callback_id
    )
    if response.ok then
        local after = self.campaign:campaign_status(input.uniquePalId)
        if after ~= nil and after.phase == "open" then
            return result(false, "native-unique-pal-timeout-not-applied")
        end
        response.timeoutCallbackId = callback_id
        response.uniquePalId = input.uniquePalId
        response.eventId = input.eventId
    end
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalBossProviderBus:unbind_world(reason)
    self.worldGeneration = self.worldGeneration + 1
    self.handlers = {}
    self.bindings = {}
    persist_snapshot(self)
    return result(true, "unique-pal-boss-world-unbound", {
        reason = reason or "world-unloading",
        worldGeneration = self.worldGeneration,
        handlersCleared = true,
        bindingsCleared = true,
    })
end

function UniquePalBossProviderBus:export_snapshot()
    local providers = {}
    for _, provider in pairs(self.providers) do
        local kinds = {}
        for kind in pairs(provider.deliveryKinds) do
            kinds[#kinds + 1] = kind
        end
        table.sort(kinds)
        providers[#providers + 1] = {
            providerId = provider.providerId,
            authoritySource = provider.authoritySource,
            deliveryKinds = kinds,
            idempotentDeliveryIds = true,
            generationFencedCallbacks = true,
            enabled = provider.enabled,
        }
    end
    table.sort(providers, function(first, second)
        return first.providerId < second.providerId
    end)
    local snapshot = {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = providers,
        deliveries = copy(self.deliveries),
        callbackSignatures = copy(self.callbackSignatures),
        worldGeneration = self.worldGeneration,
    }
    require_serializable(snapshot, "unique-Pal Boss provider snapshot")
    return snapshot
end

function UniquePalBossProviderBus:status()
    local provider_count, handler_count, binding_count = 0, 0, 0
    for _ in pairs(self.providers) do provider_count = provider_count + 1 end
    for _ in pairs(self.handlers) do handler_count = handler_count + 1 end
    for _ in pairs(self.bindings) do binding_count = binding_count + 1 end
    local applied, pending, cancelled = delivery_counts(self)
    return {
        apiVersion = self.version,
        providerCount = provider_count,
        activeProviderHandlerCount = handler_count,
        activeBindingCount = binding_count,
        appliedDeliveryCount = applied,
        pendingDeliveryCount = pending,
        cancelledDeliveryCount = cancelled,
        callbackCount = (function()
            local count = 0
            for _ in pairs(self.callbackSignatures) do count = count + 1 end
            return count
        end)(),
        worldGeneration = self.worldGeneration,
        rejectedCount = self.rejectedCount,
        retryCount = self.retryCount,
        lastNotificationError = self.lastNotificationError,
        handlersPersisted = false,
        bindingsPersisted = false,
        exactVerifiedBindingsOnly = true,
        modelAuthority = false,
        directUEMutation = false,
        PalworldSaveMutation = false,
        capabilities = copy(self.capabilities),
    }
end

return UniquePalBossProviderBus
