package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local RewardPolicy = require("pwft.reward_policy")
local RewardDeliveryBus = require("pwft.reward_delivery_bus")

local PLAYER_UID = "11111111222222223333333344444444"
local BUILD_ID = "24575825"

local function new_policy(snapshot)
    local progression = Progression.create(Registry.progression, snapshot)
    local policy = RewardPolicy.create(progression, {
        authority = "spec.reward.authority",
    })
    if snapshot == nil then
        assert(policy:register_pack({
            schemaVersion = "pwft.reward-policy.pack.v1",
            contentPackId = "spec.reward.delivery.pack",
            policies = {
                {
                    id = "spec.reward.delivery.boss",
                    sourceKind = "boss",
                    difficultyBands = {
                        { minimumScore = 0, multiplierBps = 10000 },
                    },
                    rewards = {
                        {
                            channelId = "spec.reward.item.primary",
                            baseUnits = 2,
                            maximumUnits = 2,
                        },
                        {
                            channelId = "spec.reward.item.secondary",
                            baseUnits = 1,
                            maximumUnits = 1,
                        },
                    },
                },
            },
        }).ok)
    end
    return progression, policy
end

local function settlement(id, participated, won)
    return {
        schemaVersion = "pwft.reward-settlement.v1",
        authority = "spec.reward.authority",
        operationId = id,
        contentPackId = "spec.reward.delivery.pack",
        policyId = "spec.reward.delivery.boss",
        sourceKind = "boss",
        difficultyScore = 100,
        playerParticipated = participated,
        playerSideWon = won,
    }
end

local function fake_adapter(mode, counts)
    counts = counts or { ItemA = 10, ItemB = 20 }
    local adapter = {
        mode = mode or "sync",
        counts = counts,
        dispatchCount = 0,
        worldGeneration = nil,
    }
    function adapter:status()
        return {
            buildId = BUILD_ID,
            capabilities = {
                stablePlayerIdentity = true,
                serverAuthoritativeGrant = true,
                exactInventoryReadback = true,
                directCurrencyMutation = false,
                directSavePayloadMutation = false,
            },
        }
    end
    function adapter:bind_world(generation)
        self.worldGeneration = generation
        return { ok = true, reason = "bound" }
    end
    function adapter:unbind_world()
        self.worldGeneration = nil
        return { ok = true, reason = "unbound" }
    end
    function adapter:preflight(request)
        if self.mode == "reject-preflight" then
            return { ok = false, reason = "not-ready", retryable = true }
        end
        return {
            ok = true,
            beforeCount = self.counts[request.nativeItemId] or 0,
            inventoryKey = "inventory:" .. request.playerUid,
            nativeRoute = "spec.server-authoritative-item-route",
        }
    end
    local function confirmation(request, before_count, after_count)
        return {
            ok = true,
            applied = true,
            deliveryId = request.deliveryId,
            attemptId = request.attemptId,
            playerUid = request.playerUid,
            nativeItemId = request.nativeItemId,
            buildId = request.buildId,
            worldGeneration = request.worldGeneration,
            beforeCount = before_count,
            afterCount = after_count,
            nativeResult = "spec-confirmed",
        }
    end
    function adapter:dispatch(request, preflight)
        self.dispatchCount = self.dispatchCount + 1
        if self.mode == "reject-dispatch" then
            return {
                ok = false,
                reason = "safe-rejection",
                retryable = true,
                mutationStarted = false,
            }
        end
        if self.mode == "ambiguous" then
            self.counts[request.nativeItemId] =
                preflight.beforeCount + request.units + 1
            return {
                ok = false,
                reason = "ambiguous-native-result",
                mutationStarted = true,
            }
        end
        self.counts[request.nativeItemId] =
            preflight.beforeCount + request.units
        if self.mode == "async" then
            return { ok = true, accepted = true, mutationStarted = true }
        end
        return confirmation(request, preflight.beforeCount,
            self.counts[request.nativeItemId])
    end
    function adapter:verify(record)
        local current = self.counts[record.nativeItemId] or 0
        if current == record.expectedCount then
            return confirmation(record, record.beforeCount, current)
        end
        return {
            ok = false,
            reason = "not-confirmed",
            pending = current < record.expectedCount,
        }
    end
    return adapter
end

local function provider(adapter)
    return {
        providerId = "spec.reward.native.provider",
        authoritySource = "spec.reward.native.authority",
        rewardKind = "item",
        buildId = BUILD_ID,
        routeKey = "spec.reward.item.route",
        currentBuildVerified = true,
        serverAuthoritativeGrant = true,
        exactInventoryReadback = true,
        stablePlayerIdentity = true,
        modelAuthority = false,
    }, adapter
end

local function channel(channel_id, item_id)
    return {
        schemaVersion = "pwft.reward-delivery-channel.v1",
        channelId = channel_id,
        providerId = "spec.reward.native.provider",
        rewardKind = "item",
        nativeItemId = item_id,
        maximumUnitsPerDelivery = 10,
    }
end

local progression, policy = new_policy()
local saved = 0
local adapter = fake_adapter()
local bus = RewardDeliveryBus.create(progression, policy, {
    identityResolver = function()
        return { playerUid = PLAYER_UID, profileKey = "spec.profile" }
    end,
    persistFence = function()
        saved = saved + 1
        return { ok = true }
    end,
})
assert(bus:register_provider(provider(adapter)).ok)
assert(bus:register_channel(channel(
    "spec.reward.item.primary", "ItemA")).ok)
assert(bus:bind_world(1).ok)

local combined = bus:settle(
    settlement("spec.reward.delivery.op.combined", true, true),
    { dispatch = false }
)
assert(combined.ok
    and combined.reason == "reward-settlement-and-delivery-accepted")
assert(combined.deliveryAccepted == true)
assert(bus:delivery_status(
    "spec.reward.delivery.op.combined:spec.reward.item.primary").stage
    == "pending")

assert(policy:settle(settlement("spec.reward.delivery.op.1", true, true)).ok)
assert(policy:operation_status("spec.reward.delivery.op.1")
    .rewardIntents[1] ~= nil)
local accepted = bus:accept_operation("spec.reward.delivery.op.1")
assert(accepted.ok and accepted.createdDeliveryCount == 2)
local primary_id = "spec.reward.delivery.op.1:spec.reward.item.primary"
local secondary_id = "spec.reward.delivery.op.1:spec.reward.item.secondary"
assert(bus:delivery_status(primary_id).stage == "applied")
assert(bus:delivery_status(secondary_id).stage == "pending")
assert(adapter.counts.ItemA == 12)
assert(adapter.dispatchCount == 1)
assert(saved >= 2)

local replay = bus:accept_operation("spec.reward.delivery.op.1")
assert(replay.ok and replay.idempotent == true)
assert(adapter.dispatchCount == 1)
assert(adapter.counts.ItemA == 12)

assert(bus:register_channel(channel(
    "spec.reward.item.secondary", "ItemB")).ok)
assert(bus:process_pending(secondary_id).ok)
assert(bus:delivery_status(secondary_id).stage == "applied")
assert(adapter.counts.ItemB == 21)

assert(policy:settle(settlement(
    "spec.reward.delivery.op.defeat", true, false)).ok)
local defeat = bus:accept_operation("spec.reward.delivery.op.defeat")
assert(defeat.ok and defeat.createdDeliveryCount == 0)

local snapshot = progression:export_snapshot()
local restored_progression, restored_policy = new_policy(snapshot)
local restored_adapter = fake_adapter("sync", adapter.counts)
local restored_bus = RewardDeliveryBus.create(
    restored_progression, restored_policy, {
        identityResolver = function()
            return { playerUid = PLAYER_UID, profileKey = "spec.profile" }
        end,
        persistFence = function() return true end,
    })
assert(restored_bus:register_provider(provider(restored_adapter)).ok)
assert(restored_bus:register_channel(channel(
    "spec.reward.item.primary", "ItemA")).ok)
assert(restored_bus:register_channel(channel(
    "spec.reward.item.secondary", "ItemB")).ok)
assert(restored_bus:bind_world(2).ok)
assert(restored_bus:accept_operation("spec.reward.delivery.op.1").idempotent)
assert(restored_adapter.dispatchCount == 0)

local reject_progression, reject_policy = new_policy()
assert(reject_policy:settle(settlement(
    "spec.reward.delivery.op.reject", true, true)).ok)
local reject_adapter = fake_adapter("reject-dispatch")
local reject_bus = RewardDeliveryBus.create(
    reject_progression, reject_policy, {
        identityResolver = function()
            return { playerUid = PLAYER_UID, profileKey = "spec.profile" }
        end,
        persistFence = function() return true end,
    })
assert(reject_bus:register_provider(provider(reject_adapter)).ok)
assert(reject_bus:register_channel(channel(
    "spec.reward.item.primary", "ItemA")).ok)
assert(reject_bus:bind_world(1).ok)
local rejected = reject_bus:accept_operation("spec.reward.delivery.op.reject")
assert(rejected.ok)
assert(reject_bus:delivery_status(
    "spec.reward.delivery.op.reject:spec.reward.item.primary").stage
    == "pending")

local ambiguous_progression, ambiguous_policy = new_policy()
assert(ambiguous_policy:settle(settlement(
    "spec.reward.delivery.op.ambiguous", true, true)).ok)
local ambiguous_adapter = fake_adapter("ambiguous")
local ambiguous_bus = RewardDeliveryBus.create(
    ambiguous_progression, ambiguous_policy, {
        identityResolver = function()
            return { playerUid = PLAYER_UID, profileKey = "spec.profile" }
        end,
        persistFence = function() return true end,
    })
assert(ambiguous_bus:register_provider(provider(ambiguous_adapter)).ok)
assert(ambiguous_bus:register_channel(channel(
    "spec.reward.item.primary", "ItemA")).ok)
assert(ambiguous_bus:bind_world(1).ok)
assert(ambiguous_bus:accept_operation(
    "spec.reward.delivery.op.ambiguous").ok)
local ambiguous_id =
    "spec.reward.delivery.op.ambiguous:spec.reward.item.primary"
assert(ambiguous_bus:delivery_status(ambiguous_id).stage
    == "reconciliation-required")
assert(not ambiguous_bus:process_pending(ambiguous_id).ok)
assert(ambiguous_adapter.dispatchCount == 1)

local fenced_progression, fenced_policy = new_policy()
assert(fenced_policy:settle(settlement(
    "spec.reward.delivery.op.fence", true, true)).ok)
local fenced_adapter = fake_adapter()
local fenced_bus = RewardDeliveryBus.create(
    fenced_progression, fenced_policy, {
        identityResolver = function()
            return { playerUid = PLAYER_UID, profileKey = "spec.profile" }
        end,
        persistFence = function()
            return { ok = false, reason = "disk-unavailable" }
        end,
    })
assert(fenced_bus:register_provider(provider(fenced_adapter)).ok)
assert(fenced_bus:register_channel(channel(
    "spec.reward.item.primary", "ItemA")).ok)
assert(fenced_bus:bind_world(1).ok)
assert(fenced_bus:accept_operation("spec.reward.delivery.op.fence").ok)
assert(fenced_adapter.dispatchCount == 0)
assert(fenced_bus:delivery_status(
    "spec.reward.delivery.op.fence:spec.reward.item.primary").stage
    == "pending")

local callbacks = {}
local async_progression, async_policy = new_policy()
assert(async_policy:settle(settlement(
    "spec.reward.delivery.op.async", true, true)).ok)
local async_adapter = fake_adapter("async")
local async_bus = RewardDeliveryBus.create(
    async_progression, async_policy, {
        identityResolver = function()
            return { playerUid = PLAYER_UID, profileKey = "spec.profile" }
        end,
        persistFence = function() return true end,
        schedule = function(_, callback)
            callbacks[#callbacks + 1] = callback
            return true
        end,
    })
assert(async_bus:register_provider(provider(async_adapter)).ok)
assert(async_bus:register_channel(channel(
    "spec.reward.item.primary", "ItemA")).ok)
assert(async_bus:bind_world(1).ok)
assert(async_bus:accept_operation("spec.reward.delivery.op.async").ok)
local async_id = "spec.reward.delivery.op.async:spec.reward.item.primary"
assert(async_bus:delivery_status(async_id).stage == "dispatching")
assert(#callbacks == 1)
callbacks[1]()
assert(async_bus:delivery_status(async_id).stage == "applied")

assert(bus:status().capabilities.modelAuthority == false)
assert(bus:status().capabilities.currencyMutation == false)
assert(bus:status().capabilities.automaticRedispatchAfterAmbiguity == false)

print("PASS reward delivery persists intent replay, fences native mutation, applies exact item readback once, and fail-closes ambiguous recovery")
