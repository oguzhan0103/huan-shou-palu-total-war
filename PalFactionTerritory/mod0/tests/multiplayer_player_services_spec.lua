package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local MultiplayerPlayerServices =
    require("pwft.multiplayer_player_services")

local HOST_UID = "11111111222222223333333344444444"
local REMOTE_UID = "AAAAAAAA222222223333333344444444"

local function context(player_uid)
    local bus = {
        generation = nil,
        channels = {},
        settlements = {},
    }
    function bus:bind_world(generation)
        self.generation = generation
        return { ok = true, reason = "bound" }
    end
    function bus:unbind_world()
        self.generation = nil
        return { ok = true, reason = "unbound" }
    end
    function bus:register_channel(definition)
        self.channels[definition.channelId] = definition
        return { ok = true, reason = "registered" }
    end
    function bus:settle(input)
        self.settlements[#self.settlements + 1] = input.operationId
        return { ok = true, reason = "settled", operationId = input.operationId }
    end
    local pal = { content = {} }
    function pal:register_content(faction_id, content)
        self.content[faction_id] = content
        return { ok = true, reason = "registered" }
    end
    return {
        playerUid = player_uid,
        rewardDeliveryBus = bus,
        palReconciliation = pal,
    }
end

local services = MultiplayerPlayerServices.create()
assert(services:bind_world(7).ok)
local host = context(HOST_UID)
local remote = context(REMOTE_UID)
assert(services:attach_context(host).ok)
assert(services:attach_context(remote).ok)
assert(host.rewardDeliveryBus.generation == 7)
assert(remote.rewardDeliveryBus.generation == 7)

local channel = {
    schemaVersion = "1.0.0",
    channelId = "spec.multiplayer.reward",
    providerId = "spec.provider",
    rewardKind = "item",
    nativeItemId = "StainlessSteel",
    maximumUnitsPerDelivery = 2,
}
assert(services:register_reward_channel(channel).ok)
assert(host.rewardDeliveryBus.channels[channel.channelId] ~= nil)
assert(remote.rewardDeliveryBus.channels[channel.channelId] ~= nil)

local faction_id = "pwft.faction.desert_pal_tribe"
local pal_content = {
    contentPackId = "spec.multiplayer.pal",
    contentVersion = "1.0.0",
    tokenQuota = 3,
    maximumAffinityPerDiscourse = 10,
}
assert(services:register_pal_content(faction_id, pal_content).ok)
assert(host.palReconciliation.content[faction_id] ~= nil)
assert(remote.palReconciliation.content[faction_id] ~= nil)

local settled = services:settle_reward(REMOTE_UID, {
    operationId = "spec.remote.reward.1",
})
assert(settled.ok and settled.playerUid == REMOTE_UID)
assert(#host.rewardDeliveryBus.settlements == 0)
assert(#remote.rewardDeliveryBus.settlements == 1)

local late_uid = "BBBBBBBB222222223333333344444444"
local late = context(late_uid)
assert(services:attach_context(late).ok)
assert(late.rewardDeliveryBus.channels[channel.channelId] ~= nil)
assert(late.palReconciliation.content[faction_id] ~= nil)

local status = services:status()
assert(status.playerContextCount == 3)
assert(status.rewardChannelCount == 1)
assert(status.palContentCount == 1)
assert(status.rewardSettlementCount == 1)
assert(status.capabilities.perPlayerRewardLedger == true)
assert(status.capabilities.perPlayerPalReconciliation == true)

assert(services:detach_context(REMOTE_UID, "spec-logout").ok)
assert(services:settle_reward(REMOTE_UID, {
    operationId = "spec.remote.reward.after-logout",
}).reason == "multiplayer-reward-player-context-unavailable")
assert(services:unbind_world("spec-complete").ok)
assert(services:status().playerContextCount == 0)

print("PASS multiplayer player services broadcast content, replay late joins, route rewards to exact player ledgers, and clear world contexts")
