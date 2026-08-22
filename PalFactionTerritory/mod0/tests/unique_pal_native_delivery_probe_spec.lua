package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local NativeDeliveryProbe =
    require("pwft.unique_pal_native_delivery_probe")

local calls = {}
local function called(name)
    calls[name] = (calls[name] or 0) + 1
end
local empty_slot = {
    IsEmpty = function()
        called("IsEmpty")
        return true
    end,
    GetSlotIndex = function()
        called("GetSlotIndex")
        return 17
    end,
    GetSlotId = function()
        called("GetSlotId")
        return 4017
    end,
}
local container = {
    FindEmptySlot = function()
        called("FindEmptySlot")
        return empty_slot
    end,
}
local storage = {
    TargetContainer = container,
    GetPageNum = function()
        called("GetPageNum")
        return 16
    end,
    GetPageIndexExistEmptySlot = function(_, start_page)
        called("GetPageIndexExistEmptySlot")
        assert(start_page == 0)
        return 3
    end,
}
local player_state = {
    GetPalStorage = function()
        called("GetPalStorage")
        return storage
    end,
}
local controller = {
    GetPalPlayerState = function()
        called("GetPalPlayerState")
        return player_state
    end,
}
local probe = NativeDeliveryProbe.create({
    buildId = "24575825",
    objectDumpSha256 =
        "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78",
    readOnly = true,
    adapters = {
        getPlayerController = function()
            called("getPlayerController")
            return controller
        end,
    },
})

assert(probe:bind_world(5).ok)
local outcome = probe:probe(5)
assert(outcome.ok)
assert(outcome.capacityAvailable == true)
assert(outcome.pageCount == 16)
assert(outcome.firstEmptyPageIndex == 3)
assert(outcome.emptySlotIndex == 17)
assert(outcome.emptySlotId == 4017)
assert(outcome.readOnly == true)
for _, name in ipairs({
    "getPlayerController",
    "GetPalPlayerState",
    "GetPalStorage",
    "GetPageNum",
    "GetPageIndexExistEmptySlot",
    "FindEmptySlot",
    "IsEmpty",
    "GetSlotIndex",
    "GetSlotId",
}) do
    assert(calls[name] == 1, "expected one read call: " .. name)
end
for _, forbidden in ipairs({
    "SpawnNPCForServer",
    "PalCaptureSuccess",
    "Add",
    "Set",
    "Remove",
    "Save",
}) do
    assert(calls[forbidden] == nil,
        "probe attempted mutation: " .. forbidden)
end

local status = probe:status()
assert(status.successCount == 1)
assert(status.capabilities.palStorageRead == true)
assert(status.capabilities.createIndividual == false)
assert(status.capabilities.capturePal == false)
assert(status.capabilities.directContainerMutation == false)
assert(status.capabilities.PalworldSaveMutation == false)

assert(probe:unbind_world("spec-unload").ok)
local stale = probe:probe(5)
assert(not stale.ok)
assert(stale.reason == "native-delivery-probe-generation-stale")
assert(stale.retryable == false)

local full_probe = NativeDeliveryProbe.create({
    buildId = "24575825",
    objectDumpSha256 = string.rep("A", 64),
    readOnly = true,
    adapters = {
        getPlayerController = function()
            return {
                GetPalPlayerState = function()
                    return {
                        GetPalStorage = function()
                            return {
                                TargetContainer = container,
                                GetPageNum = function() return 16 end,
                                GetPageIndexExistEmptySlot = function()
                                    return -1
                                end,
                            }
                        end,
                    }
                end,
            }
        end,
    },
})
full_probe:bind_world(1)
local full = full_probe:probe(1)
assert(full.ok)
assert(full.reason == "native-delivery-storage-full")
assert(full.capacityAvailable == false)
assert(full.emptySlotIndex == nil)

local not_ready_probe = NativeDeliveryProbe.create({
    buildId = "24575825",
    objectDumpSha256 = string.rep("B", 64),
    readOnly = true,
    adapters = {
        getPlayerController = function() return nil end,
    },
})
not_ready_probe:bind_world(1)
local not_ready = not_ready_probe:probe(1)
assert(not not_ready.ok)
assert(not_ready.reason == "local-player-controller-not-ready")
assert(not_ready.retryable == true)

local find_all_probe = NativeDeliveryProbe.create({
    buildId = "24575825",
    objectDumpSha256 = string.rep("C", 64),
    readOnly = true,
    adapters = {
        getPlayerController = function() return nil end,
        findAllOf = function(class_name)
            assert(class_name == "PalPlayerController")
            controller.IsLocalPlayerController = function()
                called("IsLocalPlayerController")
                return true
            end
            return { controller }
        end,
    },
})
find_all_probe:bind_world(8)
local find_all_outcome = find_all_probe:probe(8)
assert(find_all_outcome.ok)
assert(find_all_outcome.sources.controller
    == "FindAllOf(PalPlayerController)")
assert(calls.IsLocalPlayerController == 1)

print("unique Pal native delivery read-only probe tests passed")
