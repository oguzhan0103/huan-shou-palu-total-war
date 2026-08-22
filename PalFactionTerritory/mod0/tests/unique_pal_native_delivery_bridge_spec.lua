package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local NativeDeliveryBridge =
    require("pwft.unique_pal_native_delivery_bridge")

local generation = 11
local provider_id = "spec.unique-pal.delivery.provider"
local authority = "spec.unique-pal.delivery.authority"
local target_binding_id = "spec.unique-pal.delivery.target-binding"
local native_binding_id = "spec.unique-pal.delivery.native-binding"
local build_id = "build-24575825"
local route_key = "PalDelivery:Spec"
local deliveries = {}
local callback_count = 0

local bus = {}
function bus:status()
    return { worldGeneration = generation }
end
function bus:provider_status(requested_provider_id)
    if requested_provider_id ~= provider_id then return nil end
    return {
        providerId = provider_id,
        authoritySource = authority,
        enabled = true,
        deliveryKinds = { ["pal-delivery"] = true },
    }
end
function bus:delivery_status(delivery_id)
    local value = deliveries[delivery_id]
    if value == nil then return nil end
    local copy = {}
    for key, child in pairs(value) do copy[key] = child end
    return copy
end
function bus:confirm_pal_delivery(input)
    callback_count = callback_count + 1
    assert(input.callbackId == "pwft.native-pal-delivery."
        .. input.deliveryId)
    assert(input.providerId == provider_id)
    assert(input.authoritySource == authority)
    assert(input.bindingId == target_binding_id)
    assert(input.worldGeneration == generation)
    assert(input.nativeDeliveryId
        == input.deliveryId .. ":native-delivery")
    assert(input.nativeIndividualKey
        == input.deliveryId .. ":individual")
    assert(input.palDeliveryKey == route_key)
    assert(input.uniquePalId == "spec.unique-pal.delivery.anubis")
    assert(input.speciesId == "Anubis")
    assert(input.playerId == "local-player")
    deliveries[input.deliveryId].status = "applied"
    return {
        ok = true,
        reason = "unique-pal-native-delivery-confirmed",
        deliveryId = input.deliveryId,
        nativeDeliveryId = input.nativeDeliveryId,
        nativeIndividualKey = input.nativeIndividualKey,
    }
end

local preflight_count = 0
local create_count = 0
local commit_count = 0
local verify_count = 0
local rollback_count = 0
local adapter = {}
function adapter:preflight(request)
    preflight_count = preflight_count + 1
    assert(request.uniquePalId == "spec.unique-pal.delivery.anubis")
    assert(request.speciesId == "Anubis")
    return { ok = true, capacityAvailable = true }
end
function adapter:create_individual(request)
    create_count = create_count + 1
    return {
        ok = true,
        nativeDeliveryId = request.deliveryId .. ":native-delivery",
        individualKey = request.deliveryId .. ":individual",
    }
end
function adapter:commit_capture(
    request,
    native_delivery_id,
    individual_key
)
    commit_count = commit_count + 1
    assert(native_delivery_id == request.deliveryId .. ":native-delivery")
    assert(individual_key == request.deliveryId .. ":individual")
    return { ok = true, accepted = true }
end
function adapter:verify_storage(request, native_delivery_id, individual_key)
    verify_count = verify_count + 1
    if verify_count == 1 then
        return {
            ok = true,
            delivered = false,
            reason = "spec-storage-readback-pending",
        }
    end
    return {
        ok = true,
        delivered = true,
        individualKey = individual_key,
    }
end
function adapter:rollback(request, native_delivery_id, individual_key)
    rollback_count = rollback_count + 1
    assert(native_delivery_id == request.deliveryId .. ":native-delivery")
    assert(individual_key == request.deliveryId .. ":individual")
    return { ok = true, rolledBack = true }
end

local scheduled_callbacks = {}
local bridge = NativeDeliveryBridge.create(bus, {
    maxAutomaticAttempts = 3,
    schedule = function(_, callback)
        table.insert(scheduled_callbacks, callback)
        return true
    end,
})
local definition = {
    bindingId = native_binding_id,
    targetBindingId = target_binding_id,
    providerId = provider_id,
    buildId = build_id,
    verifiedBuildId = build_id,
    currentBuildVerified = false,
    serverAuthoritativeSpawn = true,
    serverAuthoritativeCapture = true,
    capacityPreflight = true,
    storageVerification = true,
    stableIndividualIdentity = true,
    palDeliveryKey = route_key,
    worldGeneration = generation,
    speciesByUniquePalId = {
        ["spec.unique-pal.delivery.anubis"] = "Anubis",
    },
}
assert(bridge:register_binding(definition, adapter).reason
    == "invalid-native-pal-delivery-binding")
definition.currentBuildVerified = true
assert(bridge:register_binding(definition, adapter).ok)

local function payload(delivery_id)
    return {
        deliveryId = delivery_id,
        deliveryKind = "pal-delivery",
        targetKey = "faction:pwft.faction.pidf",
        uniquePalId = "spec.unique-pal.delivery.anubis",
        speciesId = "Anubis",
        playerId = "local-player",
        buildId = build_id,
        worldGeneration = generation,
        nativeRoutes = { palDeliveryKey = route_key },
    }
end
local context = {
    providerId = provider_id,
    bindingId = target_binding_id,
    buildId = build_id,
    worldGeneration = generation,
}

local delivery_id = "spec.unique-pal.delivery.1"
deliveries[delivery_id] = {
    deliveryId = delivery_id,
    deliveryKind = "pal-delivery",
    status = "pending",
}
local accepted = bridge:handle_delivery(payload(delivery_id), context)
assert(accepted.ok and accepted.accepted == true)
assert(accepted.individualKey == delivery_id .. ":individual")
assert(preflight_count == 1 and create_count == 1)
assert(#bridge.retainedScheduledCallbacks == 1)
assert(scheduled_callbacks[1]
    == bridge.retainedScheduledCallbacks[1])
deliveries[delivery_id].status = "awaiting-confirmation"
deliveries[delivery_id].providerRequestId = accepted.requestId
deliveries[delivery_id].providerIndividualKey = accepted.individualKey

local first_process = bridge:process_pending(delivery_id)
assert(not first_process.ok
    and first_process.reason == "spec-storage-readback-pending")
assert(commit_count == 1 and verify_count == 1 and callback_count == 0)
local second_process = bridge:process_pending(delivery_id)
assert(second_process.ok)
assert(commit_count == 1 and verify_count == 2 and callback_count == 1)
local duplicate_process = bridge:process_pending(delivery_id)
assert(duplicate_process.ok and duplicate_process.idempotent == true)
assert(commit_count == 1 and verify_count == 2 and callback_count == 1)
local duplicate_accept = bridge:handle_delivery(payload(delivery_id), context)
assert(duplicate_accept.ok and duplicate_accept.idempotent == true)
assert(preflight_count == 1 and create_count == 1)

local wrong_species = payload("spec.unique-pal.delivery.wrong-species")
wrong_species.speciesId = "SheepBall"
deliveries[wrong_species.deliveryId] = {
    deliveryId = wrong_species.deliveryId,
    deliveryKind = "pal-delivery",
    status = "pending",
}
assert(bridge:handle_delivery(wrong_species, context).reason
    == "invalid-native-pal-delivery-request")

local rollback_delivery_id = "spec.unique-pal.delivery.rollback"
deliveries[rollback_delivery_id] = {
    deliveryId = rollback_delivery_id,
    deliveryKind = "pal-delivery",
    status = "pending",
}
local rollback_accepted = bridge:handle_delivery(
    payload(rollback_delivery_id),
    context
)
assert(rollback_accepted.ok)
assert(bridge:unbind_world("spec-world-unload").ok)
assert(rollback_count == 1)
local status = bridge:status()
assert(status.bindingCount == 0)
assert(status.currentNativeBindings == 0)
assert(status.directContainerMutation == false)
assert(status.debugCaptureApiAllowed == false)
assert(status.PalworldSaveMutation == false)
assert(status.exactIndividualIdentityRequired == true)

local malformed_rollback_count = 0
local malformed_adapter = {}
function malformed_adapter:preflight()
    return { ok = true, capacityAvailable = true }
end
function malformed_adapter:create_individual()
    return {
        ok = true,
        nativeDeliveryId = "invalid delivery id",
        individualKey = "invalid individual key",
    }
end
function malformed_adapter:commit_capture()
    error("malformed identity must never reach capture")
end
function malformed_adapter:verify_storage()
    error("malformed identity must never reach storage readback")
end
function malformed_adapter:rollback()
    malformed_rollback_count = malformed_rollback_count + 1
    return { ok = true, rolledBack = true }
end
local malformed_bridge = NativeDeliveryBridge.create(bus)
assert(malformed_bridge:register_binding(definition, malformed_adapter).ok)
local malformed_delivery_id = "spec.unique-pal.delivery.malformed"
deliveries[malformed_delivery_id] = {
    deliveryId = malformed_delivery_id,
    deliveryKind = "pal-delivery",
    status = "pending",
}
local malformed = malformed_bridge:handle_delivery(
    payload(malformed_delivery_id),
    context
)
assert(not malformed.ok
    and malformed.reason == "native-pal-individual-identity-invalid")
assert(malformed.retryable == false)
assert(malformed_rollback_count == 1)
assert(malformed_bridge:status().rollbackCount == 1)

print("PASS unique-Pal native delivery bridge fail-closes unverified builds, preflights storage capacity, creates and captures once, readbacks the exact individual before confirmation, retries without duplication, and rolls back only uncommitted world-scoped creations")
