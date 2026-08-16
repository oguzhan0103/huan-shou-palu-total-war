package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local NativeCharacterAdapter =
    require("pwft.native_character_adapter")

local function valid_object(full_name)
    local object = {
        fullName = full_name,
        destroyed = false,
    }
    function object:IsValid()
        return not self.destroyed
    end
    function object:GetFullName()
        return self.fullName
    end
    function object:K2_DestroyActor()
        self.destroyed = true
    end
    return object
end

local world = valid_object("PalPlayerController ManagerWorld")
local string_library = valid_object("KismetStringLibrary Default")
function string_library:Conv_StringToName(value)
    return "NativeName:" .. value
end

local controller_class = valid_object("Class PalAIController")
local controller = valid_object("BP_NPCAIController_C ManagerMerchant")
local manager = valid_object("PalNPCManager Test")
manager.NPCAIControllerBaseClass = controller_class
local spawn_requests = {}
local spawn_callbacks = {}
local handles = {}
local null_handle_read_count = 0

local function make_actor(index)
    local actor = valid_object(
        "BP_NPC_Male_Trader01_v04_C ManagerMerchant"
            .. tostring(index)
    )
    function actor:GetController()
        return controller
    end
    local vendor = valid_object("BP_PalShopVenderDataComponent Manager")
    vendor.itemShopSimpleLotteryTableName = { Key = "before" }
    vendor.itemShopLotteryType = 0
    vendor.ItemShopRestockMinute = 0
    function vendor:SetupShopData()
        self.setupCount = (self.setupCount or 0) + 1
    end
    actor.BP_PalShopVenderDataComponent = vendor
    return actor
end

local character_manager = valid_object("PalCharacterManager Test")
local handles_by_id = {}
function character_manager:GetIndividualHandle(id)
    return handles_by_id[id]
end

function manager:SpawnNPCForServer(spawn_info, callback)
    assert(type(callback) == "function")
    table.insert(spawn_requests, spawn_info)
    local actor = make_actor(#spawn_requests)
    local handle = valid_object(
        "PalIndividualCharacterHandle Manager"
            .. tostring(#spawn_requests)
    )
    handle.actor = actor
    function handle:TryGetIndividualActor()
        return self.actor
    end
    function handle:Despawn()
        self.despawnCount = (self.despawnCount or 0) + 1
    end
    table.insert(handles, handle)
    local spawn_id = "instance-id-" .. tostring(#spawn_requests)
    handles_by_id[spawn_id] = handle
    table.insert(spawn_callbacks, function()
        callback({
            get = function()
                return spawn_id
            end,
        })
    end)
    -- Reproduce Build 24467282: the reflected ReturnValue is a nullptr
    -- UObject wrapper even though the asynchronous spawn is accepted.
    local null_handle = valid_object("nullptr")
    null_handle.destroyed = true
    function null_handle:TryGetIndividualActor()
        null_handle_read_count = null_handle_read_count + 1
        error("nullptr must never be dereferenced")
    end
    return null_handle
end

local network_shop = valid_object("PalNetworkShopComponent Manager")
function network_shop:SetupShopDataForActor_ToServer(actor)
    self.setupActor = actor
    self.setupCount = (self.setupCount or 0) + 1
end
local transmitter = valid_object("PalNetworkTransmitter Manager")
function transmitter:GetShop()
    return network_shop
end
local utility = valid_object("PalUtility Default")
function utility:GetNPCManager(context)
    assert(context == world)
    return manager
end
function utility:GetCharacterManager(context)
    assert(context == world)
    return character_manager
end
function utility:GetNetworkTransmitter(actor)
    assert(actor ~= nil)
    return transmitter
end

local static_objects = {
    ["/Script/Engine.Default__KismetStringLibrary"] =
        string_library,
    ["/Script/Pal.Default__PalUtility"] = utility,
}
local delayed = {}
local ready_actor = nil
local adapter = NativeCharacterAdapter.create({
    staticFindObject = function(path)
        return static_objects[path]
    end,
    fName = false,
    worldContextProvider = function()
        return world
    end,
    restockMinutes = 30,
    merchantLevel = 30,
    nativeSetupMaxAttempts = 4,
    executeWithDelay = function(_, callback)
        table.insert(delayed, callback)
    end,
    executeInGameThread = function(callback)
        callback()
    end,
})

local plan = {
    runtimeId = "economy-fixed:test-manager",
    characterId = "NPC_Male_Trader01_v04",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/"
            .. "BP_NPC_Male_Trader01_v04."
            .. "BP_NPC_Male_Trader01_v04_C",
    salesChannel = "ItemShop",
    shopRowName = "PFT_Economy_FPA",
    merchantLevel = 30,
    location = { X = 100, Y = 200, Z = 300 },
    rotation = { Pitch = 0, Yaw = 45, Roll = 0 },
}
local record
record = adapter:spawn_merchant_via_npc_manager(
    plan,
    {
        onReady = function(actor, handle)
            ready_actor = actor
            assert(handle == record or handle == handles[1])
        end,
    }
)
-- The first manager poll may run before PalNPCManager emits its delegate.
table.remove(delayed, 1)()
assert(record.ready == false)
assert(null_handle_read_count == 0)
table.remove(spawn_callbacks, 1)()
while #delayed > 0 do
    table.remove(delayed, 1)()
end
assert(record.ready == true)
assert(#record.gameThreadCallbacks >= 2)
assert(record.spawnId == "instance-id-1")
assert(record.handle == handles[1])
assert(ready_actor == handles[1].actor)
assert(null_handle_read_count == 0)
assert(#spawn_requests == 1)
assert(spawn_requests[1].ControllerClass == controller_class)
assert(spawn_requests[1].CharacterID
    == "NativeName:NPC_Male_Trader01_v04")
assert(spawn_requests[1].Level == 30)
assert(spawn_requests[1].Location.X == 100)
assert(spawn_requests[1].Yaw == 45)
assert(ready_actor.BP_PalShopVenderDataComponent
    .itemShopSimpleLotteryTableName.Key
    == "NativeName:PFT_Economy_FPA")
assert(network_shop.setupActor == ready_actor)

local removed = adapter:despawn(record, "manager-test")
assert(removed.ok)
assert(handles[1].despawnCount == 1)
-- Native manager Despawn is the single authoritative lifecycle operation;
-- the adapter must not K2_DestroyActor the same pawn a second time.
assert(handles[1].actor.destroyed ~= true)
assert(adapter:status().activeCount == 0)

local reentered = adapter:spawn_merchant_via_npc_manager(
    plan,
    {}
)
table.remove(spawn_callbacks, 1)()
while #delayed > 0 do
    table.remove(delayed, 1)()
end
assert(reentered.ready == true)
assert(#spawn_requests == 2)
assert(null_handle_read_count == 0)

-- World reload may happen while SpawnNPCForServer's delegate and its first
-- resolver poll are both still queued.  The unload path must invalidate only
-- Lua-owned lifecycle state: neither stale callback may dereference the old
-- character manager or handle after the UWorld has gone away.
local abandoned_plan = {
    runtimeId = "economy-fixed:test-manager-abandon",
    characterId = plan.characterId,
    characterClassPath = plan.characterClassPath,
    salesChannel = plan.salesChannel,
    shopRowName = plan.shopRowName,
    merchantLevel = plan.merchantLevel,
    location = plan.location,
    rotation = plan.rotation,
}
local abandoned_record = adapter:spawn_merchant_via_npc_manager(
    abandoned_plan,
    {
        onReady = function()
            error("abandoned record must never become ready")
        end,
        onError = function()
            error("abandoned record must never report an async error")
        end,
    }
)
assert(abandoned_record.pending == true)
assert(type(abandoned_record.callbacks.onReady) == "function")
local stale_poll = table.remove(delayed, 1)
local stale_spawn_callback = table.remove(spawn_callbacks, 1)
assert(type(stale_poll) == "function")
assert(type(stale_spawn_callback) == "function")

local old_manager_reads = 0
local old_handle_reads = 0
local old_character_manager = abandoned_record.characterManager
function old_character_manager:GetIndividualHandle()
    old_manager_reads = old_manager_reads + 1
    error("old character manager must not be touched after abandon")
end
local old_handle = handles[#handles]
function old_handle:IsValid()
    old_handle_reads = old_handle_reads + 1
    error("old handle must not be touched after abandon")
end
function old_handle:TryGetIndividualActor()
    old_handle_reads = old_handle_reads + 1
    error("old handle must not be touched after abandon")
end

local abandoned = adapter:abandon_world_records(
    "merchant-presence-world-reload"
)
assert(abandoned.ok == true)
assert(abandoned.abandonedCount == 2)
assert(abandoned_record.cancelled == true)
assert(abandoned_record.pending == false)
assert(type(abandoned_record.callbacks) == "table")
assert(next(abandoned_record.callbacks) == nil)
assert(adapter:status().activeCount == 0)

stale_spawn_callback()
stale_poll()
assert(old_manager_reads == 0)
assert(old_handle_reads == 0)
assert(abandoned_record.spawnId == nil)

-- Dropping the adapter registry must release the runtime ID immediately.  A
-- new world can request the same merchant before any stale callbacks drain.
local after_abandon = adapter:spawn_merchant_via_npc_manager(
    abandoned_plan,
    {}
)
assert(after_abandon ~= abandoned_record)
assert(after_abandon.pending == true)
assert(adapter:status().activeCount == 1)

print(
    "PASS PalNPCManager async instance-ID callback, null-return "
        .. "safety, merchant lifecycle, shop setup, cleanup, world-abandon "
        .. "callback fencing, and reentry"
)
