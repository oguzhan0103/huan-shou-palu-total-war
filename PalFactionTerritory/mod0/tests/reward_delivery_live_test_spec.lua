package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local RewardDeliveryLiveTest = require("pwft.reward_delivery_live_test")

local policy = { registerCount = 0 }
function policy:register_pack()
    self.registerCount = self.registerCount + 1
    return { ok = true, reason = self.registerCount == 1
        and "reward-policy-pack-registered"
        or "reward-policy-pack-already-registered" }
end

local bus = {
    channelCount = 0,
    settleCount = 0,
    delivery = nil,
}
function bus:register_channel()
    self.channelCount = self.channelCount + 1
    return { ok = true, reason = self.channelCount == 1
        and "reward-delivery-channel-registered"
        or "reward-delivery-channel-rebound" }
end
function bus:settle(input)
    self.settleCount = self.settleCount + 1
    if self.delivery == nil then
        self.delivery = {
            stage = "applied",
            beforeCount = 8,
            afterCount = 9,
            dispatchAttemptCount = 1,
        }
    end
    return {
        ok = true,
        reason = "reward-settlement-and-delivery-accepted",
        policyOutcome = {
            reason = self.settleCount == 1
                and "reward-intents-calculated"
                or "duplicate-reward-settlement",
        },
        operationId = input.operationId,
    }
end
function bus:delivery_status() return self.delivery end

local bound_callback = nil
local live = RewardDeliveryLiveTest.create(bus, policy, {
    enabled = true,
    key = "F8",
    requireControlModifier = true,
    operationId = "pwft.qa.reward-item.20260824.1",
    contentPackId = "pwft.qa.reward-item",
    policyId = "pwft.qa.reward-item.boss",
    channelId = "pwft.qa.reward-item.channel.stainless-steel",
    providerId = "pwft.native.reward-item.production",
    nativeItemId = "StainlessSteel",
    units = 1,
}, {
    registerKeyBind = function(_, modifiers, callback)
        assert(modifiers[1] == "CONTROL")
        bound_callback = callback
        return true
    end,
    keyTable = { F8 = "F8" },
    modifierKey = { CONTROL = "CONTROL" },
    executeInGameThread = function(callback) callback() end,
})

assert(live:start().ok)
assert(bound_callback ~= nil)
bound_callback()
assert(live:status().lastResult.deliveryStage == "applied")
assert(live:status().lastResult.beforeCount == 8)
assert(live:status().lastResult.afterCount == 9)
bound_callback()
assert(live:status().lastResult.idempotent == true)
assert(live:status().lastResult.dispatchAttemptCount == 1)
assert(bus.settleCount == 2)
assert(live:status().successCount == 2)

local disabled = RewardDeliveryLiveTest.create(bus, policy, {
    enabled = false,
    key = "F8",
    requireControlModifier = true,
    operationId = "pwft.qa.reward-item.20260824.2",
    contentPackId = "pwft.qa.reward-item",
    policyId = "pwft.qa.reward-item.boss",
    channelId = "pwft.qa.reward-item.channel.stainless-steel",
    providerId = "pwft.native.reward-item.production",
    nativeItemId = "StainlessSteel",
    units = 1,
})
assert(disabled:start().reason == "reward-delivery-live-test-disabled")

print("PASS reward delivery live-test binds only when explicitly enabled, runs one fixed item operation, and proves repeat-key idempotency")
