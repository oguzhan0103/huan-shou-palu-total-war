package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local RewardItemNativeAdapter = require("pwft.reward_item_native_adapter")

local PLAYER_UID = "11111111222222223333333344444444"
local BUILD_ID = "24575825"
local HASH = "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78"

local function inventory(owner_uid, initial_count, add_extra)
    local object = {
        OwnerPlayerUId = owner_uid,
        count = initial_count,
    }
    function object:IsValid() return true end
    function object:GetFullName() return "PalPlayerInventoryData SpecInventory" end
    function object:CountItemNum() return self.count end
    function object:AddItem_ServerInternal(_, units)
        self.count = self.count + units + (add_extra or 0)
        return "Success"
    end
    return object
end

local function controller(player_uid, has_authority, network_component)
    local transmitter = nil
    if network_component ~= nil then
        transmitter = {}
        function transmitter:IsValid() return true end
        function transmitter:GetPlayer() return network_component end
    end
    local object = { Transmitter = transmitter }
    function object:IsValid() return true end
    function object:GetPlayerUId() return player_uid end
    function object:HasAuthority() return has_authority end
    function object:IsLocalPlayerController() return true end
    return object
end

local function create_adapter(local_controller, inventories)
    return RewardItemNativeAdapter.create({
        enabled = true,
        buildId = BUILD_ID,
        objectDumpSha256 = HASH,
        currentBuildVerified = true,
    }, {
        adapters = {
            getPlayerController = function() return local_controller end,
            findAllOf = function(class_name)
                assert(class_name == "PalPlayerInventoryData")
                return inventories
            end,
            makeName = function(value) return value end,
        },
    })
end

local function request(id, units)
    return {
        deliveryId = id,
        attemptId = id .. ":attempt:1",
        operationId = id .. ":operation",
        channelId = "spec.reward.item",
        units = units,
        rewardKind = "item",
        nativeItemId = "StainlessSteel",
        providerId = "spec.reward.provider",
        authoritySource = "spec.reward.authority",
        buildId = BUILD_ID,
        routeKey = "spec.reward.route",
        playerUid = PLAYER_UID,
        profileKey = "spec.profile",
        worldGeneration = 1,
    }
end

local host_inventory = inventory(PLAYER_UID, 7)
local host_adapter = create_adapter(
    controller(PLAYER_UID, true), { host_inventory })
assert(host_adapter:bind_world(1).ok)
local host_request = request("spec.reward.host", 3)
local host_preflight = host_adapter:preflight(host_request)
assert(host_preflight.ok)
assert(host_preflight.beforeCount == 7)
assert(host_preflight.exactOwnerMatched == true)
assert(host_preflight.nativeRoute
    == "PalPlayerInventoryData.AddItem_ServerInternal")
local host_delivery = host_adapter:dispatch(host_request, host_preflight)
assert(host_delivery.ok and host_delivery.applied == true)
assert(host_delivery.beforeCount == 7 and host_delivery.afterCount == 10)
assert(host_inventory.count == 10)

local network_inventory = inventory(PLAYER_UID, 20)
local network_component = {}
function network_component:IsValid() return true end
function network_component:RequestAddItem_ToServer(_, units)
    network_inventory.count = network_inventory.count + units
end
local client_adapter = create_adapter(
    controller(PLAYER_UID, false, network_component),
    { network_inventory })
assert(client_adapter:bind_world(1).ok)
local client_request = request("spec.reward.client", 4)
local client_preflight = client_adapter:preflight(client_request)
assert(client_preflight.ok)
assert(client_preflight.nativeRoute
    == "PalNetworkPlayerComponent.RequestAddItem_ToServer")
local client_delivery = client_adapter:dispatch(
    client_request, client_preflight)
assert(client_delivery.ok and client_delivery.accepted == true)
local client_record = {
    deliveryId = client_request.deliveryId,
    attemptId = client_request.attemptId,
    playerUid = PLAYER_UID,
    nativeItemId = "StainlessSteel",
    buildId = BUILD_ID,
    worldGeneration = 1,
    beforeCount = 20,
    expectedCount = 24,
}
local client_verified = client_adapter:verify(client_record)
assert(client_verified.ok and client_verified.applied == true)
assert(client_verified.afterCount == 24)

local wrong_inventory = inventory(
    "AAAAAAAAAAAAAAAABBBBBBBBBBBBBBBB", 5)
local wrong_adapter = create_adapter(
    controller(PLAYER_UID, true), { wrong_inventory })
assert(wrong_adapter:bind_world(1).ok)
assert(wrong_adapter:preflight(request("spec.reward.wrong", 1)).reason
    == "exact-player-inventory-not-ready")

local ambiguous_inventory = inventory(PLAYER_UID, 3, 1)
local ambiguous_adapter = create_adapter(
    controller(PLAYER_UID, true), { ambiguous_inventory })
assert(ambiguous_adapter:bind_world(1).ok)
local ambiguous_request = request("spec.reward.ambiguous", 2)
local ambiguous_preflight = ambiguous_adapter:preflight(ambiguous_request)
local ambiguous = ambiguous_adapter:dispatch(
    ambiguous_request, ambiguous_preflight)
assert(not ambiguous.ok and ambiguous.mutationStarted == true)
assert(ambiguous.reason
    == "reward-item-server-internal-readback-ambiguous")

local duplicate_inventory = inventory(PLAYER_UID, 1)
local duplicate_adapter = create_adapter(
    controller(PLAYER_UID, true),
    { duplicate_inventory, duplicate_inventory })
assert(duplicate_adapter:bind_world(1).ok)
assert(duplicate_adapter:preflight(request("spec.reward.duplicate", 1)).reason
    == "exact-player-inventory-ambiguous")

assert(host_adapter:unbind_world("spec-complete").ok)
local status = host_adapter:status()
assert(status.worldGeneration == nil)
assert(status.capabilities.serverAuthoritativeGrant == true)
assert(status.capabilities.exactInventoryReadback == true)
assert(status.capabilities.directCurrencyMutation == false)
assert(status.capabilities.directSavePayloadMutation == false)

print("PASS reward item adapter matches exact OwnerPlayerUId, uses host/server routes, confirms exact count deltas, and rejects ambiguous inventory state")
