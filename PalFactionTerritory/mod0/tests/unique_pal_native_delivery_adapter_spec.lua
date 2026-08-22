package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local NativeDeliveryAdapter =
    require("pwft.unique_pal_native_delivery_adapter")

local BUILD_ID = "24575825"
local DUMP_SHA = string.rep("a", 64)
local generation = 17

local function valid_object(name)
    local object = {
        name = name,
        destroyed = false,
    }
    function object:IsValid()
        return self.destroyed ~= true
    end
    return object
end

local function guid(seed)
    return {
        A = seed,
        B = seed + 1,
        C = seed + 2,
        D = seed + 3,
    }
end

local function make_handle(seed, actor)
    local handle = valid_object("handle-" .. tostring(seed))
    handle.actor = actor
    handle.individualId = {
        PlayerUId = guid(seed),
        InstanceId = guid(seed + 100),
    }
    function handle:GetIndividualID()
        return self.individualId
    end
    function handle:TryGetIndividualActor()
        return self.actor
    end
    return handle
end

local player = valid_object("local-player-character")
function player:K2_GetActorLocation()
    return { X = 1000, Y = 2000, Z = 3000 }
end

local empty_slot = valid_object("empty-slot")
function empty_slot:IsEmpty() return true end

local stored_slot = valid_object("stored-slot")
stored_slot.handle = nil
function stored_slot:IsEmpty()
    return self.handle == nil
end
function stored_slot:GetHandle()
    return self.handle
end

local direct_mutation_count = 0
local container = valid_object("pal-storage-container")
function container:FindEmptySlot()
    return empty_slot
end
function container:FindByHandle()
    if self.readbackUnavailable == true then return nil end
    return stored_slot
end
for _, method_name in ipairs({
    "Add",
    "AddHandle",
    "SetHandle",
    "Insert",
    "Remove",
}) do
    container[method_name] = function()
        direct_mutation_count = direct_mutation_count + 1
        error("direct container mutation is forbidden")
    end
end

local storage = valid_object("pal-storage")
storage.TargetContainer = container
storage.emptyPage = 4
function storage:GetPageIndexExistEmptySlot(start_page)
    assert(start_page == 0)
    return self.emptyPage
end

local state = valid_object("pal-player-state")
function state:GetPalStorage() return storage end

local controller = valid_object("local-player-controller")
function controller:IsLocalPlayerController() return true end
function controller:GetPalPlayerState() return state end
function controller:GetDefaultPlayerCharacter() return player end

local controller_class = valid_object("pal-ai-controller-class")
local manager = valid_object("pal-npc-manager")
manager.NPCAIControllerBaseClass = controller_class
local spawn_requests = {}
local spawned_handles = {}
function manager:SpawnNPCForServer(spawn_info, callback)
    assert(callback == nil)
    table.insert(spawn_requests, spawn_info)
    local handle = make_handle(
        #spawn_requests,
        nil
    )
    table.insert(spawned_handles, handle)
    return handle
end

local capture_count = 0
local utility = valid_object("pal-utility")
function utility:GetNPCManager(world_context)
    assert(world_context == controller)
    return manager
end
function utility:PalCaptureSuccess(attacker, monster)
    assert(attacker == player)
    assert(monster == spawned_handles[#spawned_handles].actor
        or monster == spawned_handles[1].actor)
    capture_count = capture_count + 1
end

local string_library = valid_object("kismet-string-library")
function string_library:Conv_StringToName(value)
    return "FName:" .. value
end

local function static_find(path)
    if path == "/Script/Pal.Default__PalUtility" then
        return utility
    end
    if path == "/Script/Engine.Default__KismetStringLibrary" then
        return string_library
    end
    return nil
end

local adapters = {
    getPlayerController = function() return controller end,
    staticFindObject = static_find,
}

local function request(delivery_id, species_id)
    return {
        deliveryId = delivery_id,
        speciesId = species_id or "Anubis",
        buildId = BUILD_ID,
        worldGeneration = generation,
    }
end

-- The production default is fail-closed. Read-only capacity checks are still
-- available, but no native Pal may be created until an explicit binding gate
-- enables the mutating transaction.
local disabled = NativeDeliveryAdapter.create({
    buildId = BUILD_ID,
    objectDumpSha256 = DUMP_SHA,
    adapters = adapters,
})
assert(disabled:bind_world(generation).ok)
local disabled_preflight = disabled:preflight(
    request("spec.delivery.disabled")
)
assert(disabled_preflight.ok
    and disabled_preflight.capacityAvailable == true)
local disabled_create = disabled:create_individual(
    request("spec.delivery.disabled"),
    disabled_preflight
)
assert(disabled_create.ok == false)
assert(disabled_create.reason
    == "native-pal-delivery-mutation-disabled")
assert(#spawn_requests == 0)

local adapter = NativeDeliveryAdapter.create({
    buildId = BUILD_ID,
    objectDumpSha256 = DUMP_SHA,
    allowMutatingDelivery = true,
    adapters = adapters,
    deliveryLevel = 50,
    spawnOffset = { X = 20, Y = -30, Z = 40 },
})
assert(adapter:bind_world(generation).ok)

local delivery = request("spec.delivery.anubis")
local preflight = adapter:preflight(delivery)
assert(preflight.ok and preflight.capacityAvailable == true)
assert(preflight.readOnly == true)
local created = adapter:create_individual(delivery, preflight)
assert(created.ok)
assert(created.nativeDeliveryId
    == "pwft.native-pal-delivery.spec.delivery.anubis")
assert(string.match(created.individualKey,
    "^pal%-%x+%-%x+$") ~= nil)
assert(#spawn_requests == 1)
assert(spawn_requests[1].ControllerClass == controller_class)
assert(spawn_requests[1].CharacterID == "FName:Anubis")
assert(spawn_requests[1].Level == 50)
assert(spawn_requests[1].Location.X == 1020)
assert(spawn_requests[1].Location.Y == 1970)
assert(spawn_requests[1].Location.Z == 3040)

local duplicate_create = adapter:create_individual(
    delivery,
    preflight
)
assert(duplicate_create.ok and duplicate_create.idempotent == true)
assert(duplicate_create.individualKey == created.individualKey)
assert(#spawn_requests == 1)

-- SpawnNPCForServer can return a stable handle before the Pal actor exists.
-- Capture must retry without issuing another spawn or a premature capture.
local actor_pending = adapter:commit_capture(
    delivery,
    created.nativeDeliveryId,
    created.individualKey
)
assert(actor_pending.ok == false and actor_pending.retryable == true)
assert(string.find(actor_pending.reason,
    "native-pal-individual-actor-not-ready", 1, true) ~= nil)
assert(capture_count == 0 and #spawn_requests == 1)

local first_actor = valid_object("spawned-anubis")
function first_actor:K2_DestroyActor()
    self.destroyed = true
end
spawned_handles[1].actor = first_actor
local captured = adapter:commit_capture(
    delivery,
    created.nativeDeliveryId,
    created.individualKey
)
assert(captured.ok and captured.accepted == true)
assert(capture_count == 1)
local duplicate_capture = adapter:commit_capture(
    delivery,
    created.nativeDeliveryId,
    created.individualKey
)
assert(duplicate_capture.ok and duplicate_capture.idempotent == true)
assert(capture_count == 1)

-- A valid slot is insufficient: the stable PalInstanceID must match the
-- exact individual returned by the original server spawn.
stored_slot.handle = make_handle(999, valid_object("wrong-pal"))
local mismatch = adapter:verify_storage(
    delivery,
    created.nativeDeliveryId,
    created.individualKey
)
assert(mismatch.ok == false and mismatch.retryable == false)
assert(mismatch.reason == "native-pal-storage-individual-mismatch")
stored_slot.handle = spawned_handles[1]
local verified = adapter:verify_storage(
    delivery,
    created.nativeDeliveryId,
    created.individualKey
)
assert(verified.ok and verified.delivered == true)
assert(verified.individualKey == created.individualKey)
assert(direct_mutation_count == 0)

local existing = adapter:preflight(delivery)
assert(existing.ok and existing.existingDelivered == true)
assert(existing.nativeDeliveryId == created.nativeDeliveryId)
assert(existing.individualKey == created.individualKey)
local committed_rollback = adapter:rollback(
    delivery,
    created.nativeDeliveryId,
    created.individualKey,
    "spec-after-capture"
)
assert(committed_rollback.ok == false)
assert(committed_rollback.reason
    == "native-pal-delivery-already-committed")
assert(first_actor.destroyed == false)

-- Only an exact, uncommitted creation is eligible for rollback.
local rollback_delivery = request("spec.delivery.rollback", "WeaselDragon")
local rollback_preflight = adapter:preflight(rollback_delivery)
local rollback_created = adapter:create_individual(
    rollback_delivery,
    rollback_preflight
)
local rollback_actor = valid_object("spawned-weasel-dragon")
function rollback_actor:K2_DestroyActor()
    self.destroyed = true
end
spawned_handles[2].actor = rollback_actor
local wrong_identity_rollback = adapter:rollback(
    rollback_delivery,
    rollback_created.nativeDeliveryId,
    created.individualKey,
    "spec-wrong-identity"
)
assert(wrong_identity_rollback.ok == false)
assert(rollback_actor.destroyed == false)
local rolled_back = adapter:rollback(
    rollback_delivery,
    rollback_created.nativeDeliveryId,
    rollback_created.individualKey,
    "spec-before-capture"
)
assert(rolled_back.ok and rolled_back.rolledBack == true)
assert(rollback_actor.destroyed == true)
assert(direct_mutation_count == 0)

-- A world transition destroys only remaining uncommitted spawned actors,
-- preserves committed gameplay state, and drops every stale UObject reference.
local unload_delivery = request("spec.delivery.unload", "BlackFurDragon")
local unload_created = adapter:create_individual(
    unload_delivery,
    adapter:preflight(unload_delivery)
)
local unload_actor = valid_object("spawned-black-fur-dragon")
function unload_actor:K2_DestroyActor()
    self.destroyed = true
end
spawned_handles[3].actor = unload_actor
local unbound = adapter:unbind_world("spec-world-transition")
assert(unbound.ok)
assert(unbound.clearedRecordCount == 2)
assert(unbound.destroyedUncommittedCount == 1)
assert(unbound.preservedCommittedCount == 1)
assert(unload_actor.destroyed == true)
assert(first_actor.destroyed == false)
assert(adapter:status().activeRecordCount == 0)
assert(adapter:status().worldBound == false)

local stale = adapter:preflight(delivery)
assert(stale.ok == false
    and stale.reason == "native-pal-delivery-generation-stale")
local build_mismatch = request("spec.delivery.build-mismatch")
build_mismatch.worldGeneration = adapter:status().worldGeneration
build_mismatch.buildId = "wrong-build"
adapter:bind_world(build_mismatch.worldGeneration)
assert(adapter:preflight(build_mismatch).reason
    == "native-pal-delivery-build-mismatch")

storage.emptyPage = -1
local full_request = request("spec.delivery.full")
full_request.worldGeneration = adapter:status().worldGeneration
local full = adapter:preflight(full_request)
assert(full.ok and full.capacityAvailable == false)
storage.emptyPage = 4

local missing_controller = NativeDeliveryAdapter.create({
    buildId = BUILD_ID,
    objectDumpSha256 = DUMP_SHA,
    adapters = {
        getPlayerController = function() return nil end,
    },
})
assert(missing_controller:bind_world(generation).ok)
local unavailable = missing_controller:preflight(
    request("spec.delivery.no-controller")
)
assert(unavailable.ok == false and unavailable.retryable == true)
assert(unavailable.reason == "local-player-controller-not-ready")

local status = adapter:status()
assert(status.allowMutatingDelivery == true)
assert(status.capabilities.currentBuildSignatureBound == true)
assert(status.capabilities.capacityPreflight == true)
assert(status.capabilities.serverAuthoritativeSpawn == true)
assert(status.capabilities.stableIndividualIdentity == true)
assert(status.capabilities.serverAuthoritativeCapture == true)
assert(status.capabilities.exactStorageReadback == true)
assert(status.capabilities.directContainerMutation == false)
assert(status.capabilities.PalworldSaveMutation == false)
assert(direct_mutation_count == 0)

print("PASS unique-Pal native delivery adapter defaults mutation off, preflights capacity, spawns once through PalNPCManager, captures once through PalUtility, verifies the exact PalInstanceID by storage readback, rolls back only uncommitted actors, and clears world-scoped UObjects")
