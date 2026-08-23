local UniquePalWorldEffectBus = {}

local API_VERSION = "1.0.0"
local SNAPSHOT_SCHEMA_VERSION = "1.0.0"
local WAR_RESULT_AUTHORITY = "pwft.unique-pal-war-result.v1"
local RANSOM_AUTHORITY = "pwft.native-ransom-payment.v1"

local DELIVERY_KINDS = {
    ["war-notice"] = true,
    ["player-defense-request"] = true,
    ["world-spawn-suppression"] = true,
    ["loaded-actor-cleanup"] = true,
    ["empty-city"] = true,
    ["merchant-filter"] = true,
    ["ransom-offer"] = true,
    ["pal-delivery"] = true,
}

local GENERATION_REPLAY_KINDS = {
    ["world-spawn-suppression"] = true,
    ["loaded-actor-cleanup"] = true,
    ["empty-city"] = true,
    ["merchant-filter"] = true,
    ["player-defense-request"] = true,
    ["ransom-offer"] = true,
}

local EVENT_DELIVERIES = {
    ["unique-pal-destruction-war-declared"] = { "war-notice" },
    ["unique-pal-destruction-target-destroyed"] = {
        "war-notice",
        "world-spawn-suppression",
        "loaded-actor-cleanup",
        "empty-city",
        "merchant-filter",
    },
    ["unique-pal-destruction-target-survived"] = { "war-notice" },
    ["unique-pal-ransom-settled"] = { "war-notice", "pal-delivery" },
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

local function split_target_key(value)
    require_text(value, "unique-Pal destruction target key")
    local separator = string.find(value, ":", 1, true)
    assert(separator ~= nil, "unique-Pal destruction target key is invalid")
    return string.sub(value, 1, separator - 1),
        string.sub(value, separator + 1)
end

local function normalize_text_array(values, name, allow_empty)
    assert(type(values) == "table", name .. " must be an array")
    local output, seen = {}, {}
    for index, value in ipairs(values) do
        require_text(value, name .. " entry " .. tostring(index))
        assert(seen[value] == nil, name .. " contains a duplicate")
        seen[value] = true
        output[#output + 1] = value
    end
    assert(allow_empty or #output > 0, name .. " cannot be empty")
    table.sort(output)
    return output
end

local function normalize_provider(definition)
    assert(type(definition) == "table",
        "unique-Pal world-effect provider definition is required")
    assert(definition.idempotentDeliveryIds == true,
        "world-effect provider must guarantee idempotent delivery IDs")
    assert(definition.generationFencedCallbacks == true,
        "world-effect provider must generation-fence callbacks")
    assert(type(definition.deliveryKinds) == "table"
            and #definition.deliveryKinds > 0,
        "world-effect provider delivery kinds are required")
    local kinds = {}
    for _, kind in ipairs(definition.deliveryKinds) do
        require_text(kind, "world-effect provider delivery kind")
        assert(DELIVERY_KINDS[kind] == true,
            "world-effect provider delivery kind is not whitelisted")
        assert(kinds[kind] == nil,
            "duplicate world-effect provider delivery kind")
        kinds[kind] = true
    end
    return {
        providerId = stable_id(definition.providerId,
            "world-effect provider ID"),
        authoritySource = stable_id(definition.authoritySource,
            "world-effect provider authority source"),
        deliveryKinds = kinds,
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

local function normalize_spawn_bindings(values)
    assert(type(values) == "table"
            and #values > 0,
        "destroyed-target spawn bindings are required")
    local output, seen = {}, {}
    for index, value in ipairs(values) do
        assert(type(value) == "table",
            "spawn binding must be a table")
        local spawner_key = require_text(value.spawnerKey,
            "spawn binding spawner key")
        assert(seen[spawner_key] == nil,
            "duplicate destroyed-target spawner key")
        seen[spawner_key] = true
        output[#output + 1] = {
            spawnKind = require_text(value.spawnKind,
                "spawn binding kind"),
            spawnerKey = spawner_key,
            actorClassKeys = normalize_text_array(
                value.actorClassKeys,
                "spawn binding actor class keys",
                false
            ),
            sourceIndex = index,
        }
    end
    table.sort(output, function(first, second)
        return first.spawnerKey < second.spawnerKey
    end)
    return output
end

local function normalize_cleanup_bindings(values)
    assert(type(values) == "table",
        "loaded actor cleanup bindings must be an array")
    local output, seen = {}, {}
    for _, value in ipairs(values) do
        assert(type(value) == "table",
            "loaded actor cleanup binding must be a table")
        local binding_id = require_text(value.actorBindingId,
            "cleanup actor binding ID")
        assert(seen[binding_id] == nil,
            "duplicate cleanup actor binding ID")
        seen[binding_id] = true
        output[#output + 1] = {
            actorBindingId = binding_id,
            actorClassKey = require_text(value.actorClassKey,
                "cleanup actor class key"),
        }
    end
    table.sort(output, function(first, second)
        return first.actorBindingId < second.actorBindingId
    end)
    return output
end

local function normalize_city_bindings(values)
    assert(type(values) == "table",
        "empty-city bindings must be an array")
    local output, seen = {}, {}
    for _, value in ipairs(values) do
        assert(type(value) == "table", "empty-city binding must be a table")
        local city_id = stable_id(value.cityId, "empty-city ID")
        assert(seen[city_id] == nil, "duplicate empty-city ID")
        seen[city_id] = true
        output[#output + 1] = {
            cityId = city_id,
            cityAnchorKey = require_text(value.cityAnchorKey,
                "empty-city anchor key"),
            residentSpawnerKeys = normalize_text_array(
                value.residentSpawnerKeys,
                "resident spawner keys",
                false
            ),
            functionSpawnerKeys = normalize_text_array(
                value.functionSpawnerKeys,
                "function NPC spawner keys",
                false
            ),
        }
    end
    table.sort(output, function(first, second)
        return first.cityId < second.cityId
    end)
    return output
end

local function normalize_binding(instance, definition)
    assert(type(definition) == "table",
        "unique-Pal world-effect target binding is required")
    local target_kind = require_text(definition.targetKind,
        "world-effect target kind")
    assert(target_kind == "faction" or target_kind == "strategic-target",
        "world-effect target kind is unsupported")
    local target_id = stable_id(definition.targetId,
        "world-effect target ID")
    local target = instance.campaign:target_status(target_kind, target_id)
    assert(target ~= nil, "world-effect destruction target is unknown")
    local target_key = target_kind .. ":" .. target_id
    local provider_id = stable_id(definition.providerId,
        "world-effect binding provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled,
        "world-effect binding provider is unavailable")
    assert(instance.handlers[provider_id] ~= nil,
        "world-effect provider handler must be active before binding")
    assert(type(definition.nativeRoutes) == "table",
        "world-effect native routes are required")
    local routes = definition.nativeRoutes
    assert(type(definition.verification) == "table",
        "world-effect binding verification is required")
    local verification = definition.verification
    for _, field in ipairs({
        "currentBuild", "spawners", "actorClasses", "nativeRoutes",
    }) do
        assert(verification[field] == true,
            "world-effect binding verification missing: " .. field)
    end
    local city_bindings = normalize_city_bindings(
        definition.cityBindings or {})
    local merchant_factions = normalize_text_array(
        definition.merchantCounterFactionIds or {},
        "merchant counter faction IDs",
        true
    )
    if #city_bindings > 0 then
        assert(verification.cityAnchors == true,
            "empty-city anchors must be verified")
    end
    if #merchant_factions > 0 then
        assert(verification.merchantCounters == true,
            "merchant counters must be verified")
    end
    local affected = {}
    for _, faction_id in ipairs(target.affectedFactionIds or {}) do
        affected[faction_id] = true
    end
    for _, city in ipairs(city_bindings) do
        local city_status = instance.campaign.strategicWorld
            :city_status(city.cityId)
        local city_definition = instance.campaign.strategicWorld
            .cityDefinitions[city.cityId]
        assert(city_status ~= nil and city_definition ~= nil,
            "empty-city binding must reference a registered city")
        assert(affected[city_definition.factionId] == true,
            "empty-city binding must belong to an affected faction")
    end
    for _, faction_id in ipairs(merchant_factions) do
        stable_id(faction_id, "merchant counter faction ID")
        assert(affected[faction_id] == true,
            "merchant filter faction must be affected by the target")
    end
    return {
        bindingId = stable_id(definition.bindingId,
            "world-effect binding ID"),
        providerId = provider_id,
        targetKey = target_key,
        targetKind = target_kind,
        targetId = target_id,
        buildId = require_text(definition.buildId,
            "verified Palworld build ID"),
        nativeRoutes = {
            textPresenterKey = require_text(routes.textPresenterKey,
                "world-effect text presenter key"),
            defenseRaidKey = require_text(routes.defenseRaidKey,
                "player defense raid key"),
            backgroundWarResolverKey = require_text(
                routes.backgroundWarResolverKey,
                "background war resolver key"),
            ransomPaymentKey = require_text(routes.ransomPaymentKey,
                "ransom payment key"),
            palDeliveryKey = require_text(routes.palDeliveryKey,
                "unique-Pal delivery key"),
        },
        spawnBindings = normalize_spawn_bindings(
            definition.spawnBindings),
        cleanupActorBindings = normalize_cleanup_bindings(
            definition.cleanupActorBindings or {}),
        cityBindings = city_bindings,
        merchantCounterFactionIds = merchant_factions,
        worldGeneration = instance.worldGeneration,
    }
end

local function normalize_snapshot(snapshot)
    require_serializable(snapshot, "unique-Pal world-effect snapshot")
    assert(type(snapshot) == "table",
        "unique-Pal world-effect snapshot is required")
    assert(snapshot.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported unique-Pal world-effect snapshot schema")
    local restored = {
        providers = {},
        deliveries = copy(snapshot.deliveries or {}),
        callbackSignatures = copy(snapshot.callbackSignatures or {}),
        ransomOffers = copy(snapshot.ransomOffers or {}),
        worldGeneration = non_negative_integer(
            snapshot.worldGeneration or 0,
            "unique-Pal world-effect generation"),
    }
    for _, definition in ipairs(snapshot.providers or {}) do
        local provider = normalize_provider(definition)
        assert(restored.providers[provider.providerId] == nil,
            "duplicate restored world-effect provider")
        restored.providers[provider.providerId] = provider
    end
    return restored
end

local function persist_snapshot(instance)
    if instance.progression ~= nil
        and type(instance.progression.state) == "table" then
        instance.progression.state.uniquePalWorldEffectBus =
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

local function event_key(event)
    return require_text(
        event.resolutionId or event.transactionId
            or event.warId or event.eventId,
        "world-effect source event key"
    )
end

local function target_key_for_event(instance, event)
    if event.targetKey ~= nil then return event.targetKey end
    if event.warId ~= nil then
        local war = instance.campaign:war_status(event.warId)
        if war ~= nil then return war.targetKey end
    end
    if event.uniquePalId ~= nil then
        local campaign = instance.campaign:campaign_status(event.uniquePalId)
        if campaign and campaign.definition and campaign.definition.target then
            return campaign.definition.target.kind .. ":"
                .. campaign.definition.target.id
        end
    end
    return nil
end

local function delivery_id(event, kind)
    return "unique-pal-world." .. event_key(event) .. "." .. kind
end

local function make_payload(instance, delivery, binding)
    local event = delivery.sourceEvent
    local war = event.warId
        and instance.campaign:war_status(event.warId) or nil
    local unique_pal_id = event.uniquePalId or (war and war.uniquePalId)
    local campaign = unique_pal_id
        and instance.campaign:campaign_status(unique_pal_id) or nil
    local payload = {
        schemaVersion = "1.0.0",
        deliveryId = delivery.deliveryId,
        deliveryKind = delivery.deliveryKind,
        sourceEventType = event.type,
        targetKey = delivery.targetKey,
        uniquePalId = unique_pal_id,
        speciesId = campaign and campaign.definition
            and campaign.definition.boss
            and campaign.definition.boss.speciesId or nil,
        warId = event.warId,
        resolutionId = event.resolutionId,
        transactionId = event.transactionId,
        offerId = event.offerId,
        route = event.route or (war and war.route),
        attackerFactionId = event.attackerFactionId
            or (war and war.attackerFactionId),
        targetKind = binding.targetKind,
        targetId = binding.targetId,
        buildId = binding.buildId,
        nativeRoutes = copy(binding.nativeRoutes),
        spawnBindings = copy(binding.spawnBindings),
        cleanupActorBindings = copy(binding.cleanupActorBindings),
        cityBindings = copy(binding.cityBindings),
        merchantCounterFactionIds = copy(
            binding.merchantCounterFactionIds),
        playerId = event.playerId,
        currency = event.currency,
        amount = event.amount,
        previousHolderFactionId = event.previousHolderFactionId,
        preserveBuildings = delivery.deliveryKind == "empty-city" and true
            or nil,
        suppressResidents = delivery.deliveryKind == "empty-city" and true
            or nil,
        suppressFunctionNpcs = delivery.deliveryKind == "empty-city" and true
            or nil,
        exactBoundActorsOnly = delivery.deliveryKind
                == "loaded-actor-cleanup" and true or nil,
        broadActorScanAllowed = false,
        deleteMapActors = false,
        PalworldSaveMutation = false,
        worldGeneration = instance.worldGeneration,
    }
    return payload
end

local function delivery_is_current(instance, delivery)
    if delivery.deliveryKind == "player-defense-request" then
        local war = instance.campaign:war_status(delivery.sourceEvent.warId)
        return war ~= nil and war.status == "pending"
            and war.route == "player-defense"
    end
    if delivery.deliveryKind == "ransom-offer" then
        local offer = instance.ransomOffers[delivery.sourceEvent.offerId]
        if offer == nil or offer.status ~= "open" then return false end
        local quote = instance.campaign:ransom_quote(
            offer.uniquePalId,
            offer.playerId
        )
        return quote.ok
            and quote.holderFactionId == offer.holderFactionId
            and quote.currency == offer.currency
            and quote.amount == offer.amount
    end
    return true
end

local function apply_delivery(instance, delivery)
    if delivery.status == "cancelled" then return end
    if delivery.status == "awaiting-confirmation" then
        if delivery.requestedGeneration == instance.worldGeneration then
            return
        end
        delivery.status = "pending"
    end
    if delivery.status == "applied" then
        if not GENERATION_REPLAY_KINDS[delivery.deliveryKind]
            or delivery.appliedGeneration == instance.worldGeneration then
            return
        end
        delivery.status = "pending"
    end
    if not delivery_is_current(instance, delivery) then
        delivery.status = "cancelled"
        delivery.lastError = "stale-unique-pal-world-delivery"
        return
    end
    local binding = instance.bindingsByTargetKey[delivery.targetKey]
    if binding == nil or binding.worldGeneration ~= instance.worldGeneration then
        delivery.status = "pending"
        delivery.lastError = "verified-world-effect-binding-unavailable"
        return
    end
    local provider = instance.providers[binding.providerId]
    local handler = instance.handlers[binding.providerId]
    if provider == nil or provider.enabled ~= true
        or provider.deliveryKinds[delivery.deliveryKind] ~= true
        or type(handler) ~= "function" then
        delivery.status = "pending"
        delivery.lastError = "unique-pal-world-effect-provider-unavailable"
        return
    end
    delivery.attemptCount = (delivery.attemptCount or 0) + 1
    delivery.payload = make_payload(instance, delivery, binding)
    local called, response = pcall(handler, copy(delivery.payload), {
        providerId = provider.providerId,
        bindingId = binding.bindingId,
        buildId = binding.buildId,
        worldGeneration = instance.worldGeneration,
        idempotentDeliveryId = true,
        exactBoundActorsOnly = true,
    })
    local confirmed = false
    if type(response) == "table" then
        if delivery.deliveryKind == "player-defense-request"
            or delivery.deliveryKind == "ransom-offer" then
            confirmed = response.accepted == true
        elseif delivery.deliveryKind == "pal-delivery" then
            confirmed = response.delivered == true
                or response.accepted == true
        else
            confirmed = response.applied == true
        end
    end
    if not called then
        delivery.status = "pending"
        delivery.lastError = "provider-error:" .. tostring(response)
    elseif type(response) ~= "table" or response.ok ~= true
        or response.deliveryId ~= delivery.deliveryId or not confirmed then
        delivery.status = "pending"
        delivery.lastError = type(response) == "table"
                and tostring(response.reason
                    or "provider-did-not-confirm-world-effect")
            or "provider-returned-invalid-result"
    else
        delivery.status = delivery.deliveryKind == "pal-delivery"
                and response.delivered ~= true
                and "awaiting-confirmation"
            or "applied"
        delivery.lastError = nil
        delivery.providerReason = response.reason
        delivery.providerRequestId = response.requestId
            or response.nativeRaidId or response.nativeOfferId
        delivery.providerIndividualKey = response.individualKey
        delivery.appliedGeneration = instance.worldGeneration
        if delivery.status == "awaiting-confirmation" then
            delivery.requestedGeneration = instance.worldGeneration
        end
        if delivery.deliveryKind == "ransom-offer" then
            local offer = instance.ransomOffers[
                delivery.sourceEvent.offerId]
            if offer ~= nil then
                offer.nativeOfferId = delivery.providerRequestId
                offer.worldGeneration = instance.worldGeneration
            end
        end
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

local function callback_signature(input, kind)
    return table.concat({
        kind,
        tostring(input.providerId),
        tostring(input.authoritySource),
        tostring(input.bindingId),
        tostring(input.worldGeneration),
        tostring(input.warId),
        tostring(input.offerId),
        tostring(input.nativeRaidId),
        tostring(input.nativeOfferId),
        tostring(input.deliveryId),
        tostring(input.nativeDeliveryId),
        tostring(input.nativeIndividualKey),
        tostring(input.defenseRaidKey),
        tostring(input.backgroundWarResolverKey),
        tostring(input.ransomPaymentKey),
        tostring(input.palDeliveryKey),
        tostring(input.playerId),
        tostring(input.uniquePalId),
        tostring(input.speciesId),
        tostring(input.currency),
        tostring(input.amount),
        tostring(input.paid),
        tostring(input.attackerWon),
        tostring(input.playerParticipated),
        tostring(input.playerSideWon),
    }, "|")
end

local function duplicate_callback(instance, callback_id, signature)
    local previous = instance.callbackSignatures[callback_id]
    if previous == nil then return nil end
    if previous.signature ~= signature then
        return result(false, "unique-pal-world-callback-id-conflict", {
            callbackId = callback_id,
        })
    end
    local response = copy(previous.response)
    response.ok = true
    response.duplicateOfReason = response.reason
    response.reason = "duplicate-unique-pal-world-callback"
    response.idempotent = true
    return response
end

local function validate_callback(instance, input, kind, target_key)
    assert(type(input) == "table", "unique-Pal world callback is required")
    local callback_id = require_text(input.callbackId,
        "unique-Pal world callback ID")
    local signature = callback_signature(input, kind)
    local duplicate = duplicate_callback(instance, callback_id, signature)
    if duplicate ~= nil then return nil, callback_id, signature, duplicate end
    local provider = instance.providers[input.providerId]
    if provider == nil or provider.enabled ~= true
        or provider.authoritySource ~= input.authoritySource then
        return nil, callback_id, signature,
            result(false, "unique-pal-world-callback-authority-rejected")
    end
    local binding = instance.bindingsByTargetKey[target_key]
    if binding == nil or binding.bindingId ~= input.bindingId
        or binding.providerId ~= input.providerId then
        return nil, callback_id, signature,
            result(false, "unique-pal-world-callback-binding-rejected")
    end
    if input.worldGeneration ~= instance.worldGeneration
        or binding.worldGeneration ~= instance.worldGeneration then
        return nil, callback_id, signature,
            result(false, "unique-pal-world-callback-generation-rejected")
    end
    return { provider = provider, binding = binding },
        callback_id, signature, nil
end

local function commit_callback(instance, callback_id, signature, response)
    if response.ok then
        instance.callbackSignatures[callback_id] = {
            signature = signature,
            response = copy(response),
        }
        notify(instance, {
            type = "unique-pal-world-callback-committed",
            callbackId = callback_id,
            callbackReason = response.reason,
        })
    end
    return response
end

function UniquePalWorldEffectBus.create(campaign, options)
    assert(type(campaign) == "table"
            and type(campaign.war_status) == "function"
            and type(campaign.target_status) == "function"
            and type(campaign.campaign_status) == "function"
            and type(campaign.faction_spawn_policy) == "function"
            and type(campaign.merchant_spawn_policy) == "function"
            and type(campaign.ransom_quote) == "function"
            and type(campaign.settle_ransom) == "function"
            and type(campaign.settle_destruction_war) == "function",
        "unique-Pal campaign with world-effect API is required")
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "unique-Pal world-effect onChange must be a function")
    local progression = campaign.progression
    local stored = progression and progression.state
        and progression.state.uniquePalWorldEffectBus or nil
    local restored = stored and normalize_snapshot(stored) or {
        providers = {}, deliveries = {}, callbackSignatures = {},
        ransomOffers = {}, worldGeneration = 0,
    }
    local instance = setmetatable({
        version = API_VERSION,
        campaign = campaign,
        progression = progression,
        providers = restored.providers,
        handlers = {},
        bindingsByTargetKey = {},
        deliveries = restored.deliveries,
        callbackSignatures = restored.callbackSignatures,
        ransomOffers = restored.ransomOffers,
        worldGeneration = restored.worldGeneration + 1,
        rejectedCount = 0,
        retryCount = 0,
        lastNotificationError = nil,
        onChange = options.onChange,
        capabilities = {
            factionSpawnSuppressionPolicy = true,
            exactLoadedActorCleanup = true,
            emptyCityWithoutBuildingDeletion = true,
            merchantCounterFiltering = true,
            backgroundWarTextAndResult = true,
            playerDefenseNativeRequestAndResult = true,
            ransomOfferAndNativePayment = true,
            uniquePalDeliveryRetry = true,
            generationFencedCallbacks = true,
            broadActorScan = false,
            modelAuthority = false,
            directUEMutation = false,
            PalworldSaveMutation = false,
        },
    }, { __index = UniquePalWorldEffectBus })
    persist_snapshot(instance)
    if progression ~= nil
        and type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.unique-pal-world-effect-bus.v1",
            function() return instance:rebind_progression_state() end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function UniquePalWorldEffectBus:rebind_progression_state()
    local snapshot = self.progression
        and self.progression.state.uniquePalWorldEffectBus or nil
    local called, restored = pcall(normalize_snapshot, snapshot or {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = {}, deliveries = {}, callbackSignatures = {},
        ransomOffers = {}, worldGeneration = self.worldGeneration,
    })
    if not called then
        return result(false, "unique-pal-world-effect-snapshot-invalid", {
            validationError = tostring(restored),
        })
    end
    self.providers = restored.providers
    self.deliveries = restored.deliveries
    self.callbackSignatures = restored.callbackSignatures
    self.ransomOffers = restored.ransomOffers
    self.worldGeneration = math.max(
        self.worldGeneration,
        restored.worldGeneration
    ) + 1
    self.handlers = {}
    self.bindingsByTargetKey = {}
    persist_snapshot(self)
    return result(true, "unique-pal-world-effect-state-rebound", {
        handlersCleared = true,
        bindingsCleared = true,
        worldGeneration = self.worldGeneration,
    })
end

function UniquePalWorldEffectBus:register_provider(definition, handler)
    local ok, provider = pcall(normalize_provider, definition)
    if not ok or type(handler) ~= "function" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-unique-pal-world-effect-provider", {
            validationError = ok
                    and "provider-handler-must-be-a-function"
                or tostring(provider),
        })
    end
    local existing = self.providers[provider.providerId]
    if existing ~= nil and not provider_equal(existing, provider) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "unique-pal-world-effect-provider-id-conflict")
    end
    self.providers[provider.providerId] = provider
    self.handlers[provider.providerId] = handler
    notify(self, {
        type = existing and "unique-pal-world-effect-provider-rebound"
            or "unique-pal-world-effect-provider-registered",
        providerId = provider.providerId,
        worldGeneration = self.worldGeneration,
    })
    return result(true,
        existing and "unique-pal-world-effect-provider-rebound"
            or "unique-pal-world-effect-provider-registered", {
            providerId = provider.providerId,
            worldGeneration = self.worldGeneration,
        })
end

function UniquePalWorldEffectBus:bind_target(definition)
    local called, binding = pcall(normalize_binding, self, definition)
    if not called then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-unique-pal-world-effect-binding", {
            validationError = tostring(binding),
        })
    end
    local existing = self.bindingsByTargetKey[binding.targetKey]
    if existing ~= nil and not deep_equal(existing, binding) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "unique-pal-world-effect-binding-conflict", {
            targetKey = binding.targetKey,
        })
    end
    self.bindingsByTargetKey[binding.targetKey] = binding
    local reconciled = self:reconcile_target(binding.targetKey)
    notify(self, {
        type = existing and "unique-pal-world-effect-binding-refreshed"
            or "unique-pal-world-effect-binding-activated",
        bindingId = binding.bindingId,
        targetKey = binding.targetKey,
        worldGeneration = self.worldGeneration,
    })
    return result(true,
        existing and "unique-pal-world-effect-binding-refreshed"
            or "unique-pal-world-effect-binding-activated", {
            bindingId = binding.bindingId,
            targetKey = binding.targetKey,
            reconciliation = reconciled,
        })
end

function UniquePalWorldEffectBus:handle_campaign_event(event)
    assert(type(event) == "table", "unique-Pal campaign event is required")
    local kinds = EVENT_DELIVERIES[event.type]
    if kinds == nil then
        return result(true,
            "unique-pal-event-does-not-require-world-effect", {
                eventType = event.type,
                deliveryCount = 0,
            })
    end
    local target_key = target_key_for_event(self, event)
    if target_key == nil then
        return result(false, "unique-pal-world-effect-target-unresolved")
    end
    local expanded = copy(kinds)
    if event.type == "unique-pal-destruction-war-declared"
        and event.route == "player-defense" then
        expanded[#expanded + 1] = "player-defense-request"
    end
    local applied, pending, cancelled = 0, 0, 0
    for _, kind in ipairs(expanded) do
        local id = delivery_id(event, kind)
        local delivery = self.deliveries[id]
        if delivery == nil then
            delivery = {
                deliveryId = id,
                deliveryKind = kind,
                targetKey = target_key,
                sourceEvent = copy(event),
                status = "pending",
                attemptCount = 0,
            }
            self.deliveries[id] = delivery
        elseif delivery.deliveryKind ~= kind
            or delivery.targetKey ~= target_key then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "unique-pal-world-delivery-id-conflict", {
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
        type = "unique-pal-world-delivery-recorded",
        sourceEventType = event.type,
        targetKey = target_key,
        appliedCount = applied,
        pendingCount = pending,
        cancelledCount = cancelled,
    })
    return result(pending == 0,
        pending == 0 and "unique-pal-world-delivery-applied"
            or "unique-pal-world-delivery-pending", {
            deliveryCount = #expanded,
            appliedCount = applied,
            pendingCount = pending,
            cancelledCount = cancelled,
            retryable = pending > 0,
        })
end

function UniquePalWorldEffectBus:retry_pending(target_key)
    self.retryCount = self.retryCount + 1
    local applied, pending, cancelled = 0, 0, 0
    for _, id in ipairs(sorted_keys(self.deliveries)) do
        local delivery = self.deliveries[id]
        if target_key == nil or delivery.targetKey == target_key then
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
        pending == 0 and "unique-pal-world-deliveries-retried"
            or "unique-pal-world-deliveries-still-pending", {
            appliedCount = applied,
            pendingCount = pending,
            cancelledCount = cancelled,
            retryable = pending > 0,
        })
end

function UniquePalWorldEffectBus:reconcile_target(target_key)
    local kind, id = split_target_key(target_key)
    local target = self.campaign:target_status(kind, id)
    if target == nil then
        return result(false, "unknown-unique-pal-world-effect-target")
    end
    if target.status == "destroyed" then
        local synthetic = {
            type = "unique-pal-destruction-target-destroyed",
            warId = target.destroyedByWarId,
            uniquePalId = target.destroyedByUniquePalId,
            attackerFactionId = target.destroyedByFactionId,
            targetKey = target.key,
            resolutionId = target.destroyedResolutionId,
        }
        return self:handle_campaign_event(synthetic)
    end
    return self:retry_pending(target_key)
end

function UniquePalWorldEffectBus:faction_spawn_policy(faction_id, spawn_kind)
    return self.campaign:faction_spawn_policy(faction_id, spawn_kind)
end

function UniquePalWorldEffectBus:merchant_counter_policy(faction_id)
    return self.campaign:merchant_spawn_policy(faction_id)
end

function UniquePalWorldEffectBus:offer_ransom(
    unique_pal_id,
    player_id,
    offer_id
)
    local quote = self.campaign:ransom_quote(unique_pal_id, player_id)
    if not quote.ok then return quote end
    require_text(offer_id, "unique-Pal ransom offer ID")
    local status = self.campaign:campaign_status(unique_pal_id)
    local target = status.definition.target
    local target_key = target.kind .. ":" .. target.id
    local binding = self.bindingsByTargetKey[target_key]
    if binding == nil then
        return result(false, "verified-ransom-provider-binding-required")
    end
    local existing = self.ransomOffers[offer_id]
    local offer = {
        offerId = offer_id,
        uniquePalId = unique_pal_id,
        playerId = player_id,
        holderFactionId = quote.holderFactionId,
        targetKey = target_key,
        currency = quote.currency,
        amount = quote.amount,
        activeWarId = quote.activeWarId,
        providerId = binding.providerId,
        bindingId = binding.bindingId,
        worldGeneration = self.worldGeneration,
        status = "open",
    }
    if existing ~= nil then
        for _, field in ipairs({
            "offerId", "uniquePalId", "playerId", "holderFactionId",
            "targetKey", "currency", "amount", "activeWarId",
            "providerId", "bindingId", "worldGeneration",
        }) do
            if existing[field] ~= offer[field] then
                return result(false, "unique-pal-ransom-offer-id-conflict")
            end
        end
    end
    self.ransomOffers[offer_id] = existing or offer
    local event = {
        type = "unique-pal-ransom-offer",
        eventId = offer_id,
        offerId = offer_id,
        uniquePalId = unique_pal_id,
        playerId = player_id,
        targetKey = target_key,
        currency = quote.currency,
        amount = quote.amount,
        previousHolderFactionId = quote.holderFactionId,
    }
    local id = delivery_id(event, "ransom-offer")
    local delivery = self.deliveries[id]
    if delivery == nil then
        delivery = {
            deliveryId = id,
            deliveryKind = "ransom-offer",
            targetKey = target_key,
            sourceEvent = event,
            status = "pending",
            attemptCount = 0,
        }
        self.deliveries[id] = delivery
    end
    apply_delivery(self, delivery)
    local current = self.ransomOffers[offer_id]
    if delivery.status == "applied" then
        current.nativeOfferId = delivery.providerRequestId
    end
    notify(self, {
        type = "unique-pal-ransom-offer-recorded",
        offerId = offer_id,
        uniquePalId = unique_pal_id,
        deliveryStatus = delivery.status,
    })
    return result(delivery.status == "applied",
        delivery.status == "applied"
                and "unique-pal-ransom-offer-presented"
            or "unique-pal-ransom-offer-pending", {
            offer = copy(current),
            retryable = delivery.status == "pending",
        })
end

function UniquePalWorldEffectBus:confirm_ransom_payment(input)
    assert(type(input) == "table", "ransom payment callback is required")
    local offer = self.ransomOffers[input.offerId]
    if offer == nil then return result(false, "unknown-unique-pal-ransom-offer") end
    local context, callback_id, signature, failure = validate_callback(
        self,
        input,
        "ransom-payment",
        offer.targetKey
    )
    if failure ~= nil then return failure end
    if offer.status ~= "open"
        or offer.providerId ~= input.providerId
        or offer.bindingId ~= input.bindingId
        or offer.worldGeneration ~= input.worldGeneration
        or offer.nativeOfferId ~= input.nativeOfferId then
        return result(false, "unique-pal-ransom-offer-callback-rejected")
    end
    if input.ransomPaymentKey
            ~= context.binding.nativeRoutes.ransomPaymentKey then
        return result(false, "unique-pal-ransom-payment-route-rejected")
    end
    if input.uniquePalId ~= offer.uniquePalId
        or input.playerId ~= offer.playerId
        or input.currency ~= offer.currency
        or input.amount ~= offer.amount then
        return result(false, "unique-pal-ransom-payment-quote-mismatch")
    end
    if input.paid ~= true then
        return result(false, "unique-pal-ransom-payment-not-confirmed")
    end
    local response = self.campaign:settle_ransom({
        transactionId = callback_id,
        uniquePalId = input.uniquePalId,
        playerId = input.playerId,
        authoritySource = RANSOM_AUTHORITY,
        currency = input.currency,
        amount = input.amount,
        paid = true,
    })
    if response.ok then
        offer.status = "settled"
        offer.transactionId = callback_id
    end
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalWorldEffectBus:confirm_pal_delivery(input)
    assert(type(input) == "table",
        "unique-Pal native delivery callback is required")
    local delivery = self.deliveries[input.deliveryId]
    if delivery == nil or delivery.deliveryKind ~= "pal-delivery" then
        return result(false, "unknown-unique-pal-native-delivery")
    end
    local context, callback_id, signature, failure = validate_callback(
        self,
        input,
        "pal-delivery",
        delivery.targetKey
    )
    if failure ~= nil then return failure end
    local event = delivery.sourceEvent
    if delivery.status ~= "awaiting-confirmation"
        or delivery.providerRequestId ~= input.nativeDeliveryId
        or (delivery.providerIndividualKey ~= nil
            and delivery.providerIndividualKey
                ~= input.nativeIndividualKey)
        or delivery.requestedGeneration ~= input.worldGeneration then
        return result(false, "unique-pal-native-delivery-callback-rejected")
    end
    if input.palDeliveryKey
            ~= context.binding.nativeRoutes.palDeliveryKey then
        return result(false, "unique-pal-native-delivery-route-rejected")
    end
    if input.uniquePalId ~= event.uniquePalId
        or input.playerId ~= event.playerId then
        return result(false, "unique-pal-native-delivery-identity-rejected")
    end
    local campaign = self.campaign:campaign_status(input.uniquePalId)
    local expected_species = campaign and campaign.definition
        and campaign.definition.boss
        and campaign.definition.boss.speciesId or nil
    if input.speciesId ~= nil and input.speciesId ~= expected_species then
        return result(false, "unique-pal-native-delivery-species-rejected")
    end
    if campaign == nil or campaign.owner == nil
        or campaign.owner.kind ~= "player"
        or campaign.owner.id ~= input.playerId then
        return result(false, "unique-pal-native-delivery-owner-rejected")
    end
    delivery.status = "applied"
    delivery.appliedGeneration = input.worldGeneration
    delivery.lastError = nil
    delivery.providerReason =
        "authoritative-native-pal-delivery-confirmed"
    local response = result(true,
        "unique-pal-native-delivery-confirmed", {
            deliveryId = delivery.deliveryId,
            nativeDeliveryId = input.nativeDeliveryId,
            nativeIndividualKey = input.nativeIndividualKey,
            uniquePalId = input.uniquePalId,
            speciesId = expected_species,
            playerId = input.playerId,
        })
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalWorldEffectBus:confirm_player_defense(input)
    assert(type(input) == "table", "player defense callback is required")
    local war = self.campaign:war_status(input.warId)
    if war == nil then return result(false, "unknown-destruction-war") end
    local context, callback_id, signature, failure = validate_callback(
        self, input, "player-defense", war.targetKey)
    if failure ~= nil then return failure end
    local request_id = "unique-pal-world." .. input.warId
        .. ".player-defense-request"
    local delivery = self.deliveries[request_id]
    if war.status ~= "pending" or war.route ~= "player-defense"
        or delivery == nil or delivery.status ~= "applied"
        or delivery.providerRequestId ~= input.nativeRaidId then
        return result(false, "unique-pal-player-defense-callback-rejected")
    end
    if input.defenseRaidKey ~= context.binding.nativeRoutes.defenseRaidKey then
        return result(false, "unique-pal-player-defense-route-rejected")
    end
    if type(input.playerParticipated) ~= "boolean"
        or type(input.playerSideWon) ~= "boolean" then
        return result(false, "unique-pal-player-defense-result-required")
    end
    local response = self.campaign:settle_destruction_war({
        warId = input.warId,
        resolutionId = callback_id,
        authoritySource = WAR_RESULT_AUTHORITY,
        playerParticipated = input.playerParticipated,
        playerSideWon = input.playerSideWon,
    })
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalWorldEffectBus:confirm_background_war(input)
    assert(type(input) == "table", "background war callback is required")
    local war = self.campaign:war_status(input.warId)
    if war == nil then return result(false, "unknown-destruction-war") end
    local context, callback_id, signature, failure = validate_callback(
        self, input, "background-war", war.targetKey)
    if failure ~= nil then return failure end
    if war.status ~= "pending" or war.route ~= "background" then
        return result(false, "unique-pal-background-war-callback-rejected")
    end
    if input.backgroundWarResolverKey
            ~= context.binding.nativeRoutes.backgroundWarResolverKey then
        return result(false, "unique-pal-background-war-route-rejected")
    end
    if type(input.attackerWon) ~= "boolean" then
        return result(false, "unique-pal-background-war-result-required")
    end
    local response = self.campaign:settle_destruction_war({
        warId = input.warId,
        resolutionId = callback_id,
        authoritySource = WAR_RESULT_AUTHORITY,
        attackerWon = input.attackerWon,
    })
    return commit_callback(self, callback_id, signature, response)
end

function UniquePalWorldEffectBus:unbind_world(reason)
    self.worldGeneration = self.worldGeneration + 1
    self.handlers = {}
    self.bindingsByTargetKey = {}
    persist_snapshot(self)
    return result(true, "unique-pal-world-effects-unbound", {
        reason = reason or "world-unloading",
        worldGeneration = self.worldGeneration,
        handlersCleared = true,
        bindingsCleared = true,
    })
end

function UniquePalWorldEffectBus:export_snapshot()
    local providers = {}
    for _, provider in pairs(self.providers) do
        local kinds = {}
        for kind in pairs(provider.deliveryKinds) do kinds[#kinds + 1] = kind end
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
        ransomOffers = copy(self.ransomOffers),
        worldGeneration = self.worldGeneration,
    }
    require_serializable(snapshot, "unique-Pal world-effect snapshot")
    return snapshot
end

function UniquePalWorldEffectBus:delivery_status(delivery_id)
    local delivery = self.deliveries[delivery_id]
    if delivery == nil then return nil end
    return copy(delivery)
end

function UniquePalWorldEffectBus:provider_status(provider_id)
    local provider = self.providers[provider_id]
    if provider == nil then return nil end
    return copy(provider)
end

function UniquePalWorldEffectBus:ransom_offer_status(offer_id)
    local offer = self.ransomOffers[offer_id]
    if offer == nil then return nil end
    return copy(offer)
end

function UniquePalWorldEffectBus:status()
    local provider_count, handler_count, binding_count = 0, 0, 0
    local fully_capable_provider_count = 0
    local fully_operational_binding_count = 0
    for provider_id, provider in pairs(self.providers) do
        provider_count = provider_count + 1
        local complete = provider.enabled == true
            and type(self.handlers[provider_id]) == "function"
        for delivery_kind in pairs(DELIVERY_KINDS) do
            if provider.deliveryKinds[delivery_kind] ~= true then
                complete = false
            end
        end
        if complete then
            fully_capable_provider_count =
                fully_capable_provider_count + 1
        end
    end
    for _ in pairs(self.handlers) do handler_count = handler_count + 1 end
    for _, binding in pairs(self.bindingsByTargetKey) do
        binding_count = binding_count + 1
        if #binding.spawnBindings > 0
            and #binding.cleanupActorBindings > 0
            and #binding.cityBindings > 0
            and #binding.merchantCounterFactionIds > 0 then
            fully_operational_binding_count =
                fully_operational_binding_count + 1
        end
    end
    local applied, pending, cancelled = delivery_counts(self)
    return {
        apiVersion = self.version,
        providerCount = provider_count,
        fullyCapableProviderCount = fully_capable_provider_count,
        activeProviderHandlerCount = handler_count,
        activeTargetBindingCount = binding_count,
        fullyOperationalTargetBindingCount =
            fully_operational_binding_count,
        appliedDeliveryCount = applied,
        pendingDeliveryCount = pending,
        cancelledDeliveryCount = cancelled,
        ransomOfferCount = (function()
            local count = 0
            for _ in pairs(self.ransomOffers) do count = count + 1 end
            return count
        end)(),
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
        exactBoundActorsOnly = true,
        broadActorScan = false,
        modelAuthority = false,
        directUEMutation = false,
        PalworldSaveMutation = false,
        capabilities = copy(self.capabilities),
    }
end

return UniquePalWorldEffectBus
