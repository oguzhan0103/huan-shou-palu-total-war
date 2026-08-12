package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local RewardPolicy = require("pwft.reward_policy")

local progression = Progression.create(Registry.progression)
local policy = RewardPolicy.create(progression, {
    authority = "spec.authoritative-reward.v1",
})
local pack = {
    schemaVersion = "pwft.reward-policy.pack.v1",
    contentPackId = "spec.reward.pack",
    policies = {
        {
            id = "spec.reward.boss",
            sourceKind = "boss",
            difficultyBands = {
                { minimumScore = 0, multiplierBps = 10000 },
                { minimumScore = 50, multiplierBps = 15000 },
                { minimumScore = 80, multiplierBps = 20000 },
            },
            milestoneEvery = 2,
            milestoneBonusBps = 5000,
            rewards = {
                {
                    channelId = "spec.reward.channel.boss",
                    baseUnits = 10,
                    maximumUnits = 22,
                },
            },
        },
    },
}
assert(policy:register_pack(pack).reason == "reward-policy-pack-registered")
assert(policy:register_pack(pack).reason
    == "reward-policy-pack-already-registered")

local function event(id, difficulty, participated, won)
    return {
        schemaVersion = "pwft.reward-settlement.v1",
        authority = "spec.authoritative-reward.v1",
        operationId = id,
        contentPackId = "spec.reward.pack",
        policyId = "spec.reward.boss",
        sourceKind = "boss",
        difficultyScore = difficulty,
        playerParticipated = participated,
        playerSideWon = won,
    }
end

local standard = policy:settle(event("spec.reward.op.1", 10, true, true))
assert(standard.ok and standard.reason == "reward-intents-calculated")
assert(standard.multiplierBps == 10000)
assert(standard.rewardIntents[1].units == 10)
assert(standard.nativeApplied == false)

local extreme = policy:settle(event("spec.reward.op.2", 90, true, true))
assert(extreme.ok and extreme.multiplierBps == 20000)
assert(extreme.milestoneGuarantee == true)
assert(extreme.rewardIntents[1].units == 22) -- 20 + 5, capped at 22.

local defeat = policy:settle(event("spec.reward.op.3", 100, true, false))
assert(defeat.ok and defeat.reason == "reward-not-earned")
assert(#defeat.rewardIntents == 0)
assert(policy:status("spec.reward.boss").eligibleWins == 2)

local absent = policy:settle(event("spec.reward.op.4", 100, false, true))
assert(absent.ok and absent.reason == "reward-not-earned")
assert(#absent.rewardIntents == 0)

local duplicate = policy:settle(event("spec.reward.op.2", 90, true, true))
assert(duplicate.ok and duplicate.reason == "duplicate-reward-settlement")
assert(#duplicate.rewardIntents == 0)
assert(policy:status("spec.reward.boss").eligibleWins == 2)

local conflict = policy:settle(event("spec.reward.op.2", 50, true, true))
assert(not conflict.ok and conflict.reason == "reward-operation-id-conflict")

local untrusted = event("spec.reward.op.untrusted", 90, true, true)
untrusted.authority = "ollama.model.output"
assert(policy:settle(untrusted).reason == "reward-authority-not-trusted")
local injected = event("spec.reward.op.injected", 90, true, true)
injected.rewardUnits = 999999
assert(policy:settle(injected).reason == "settlement-field-not-allowed")

local lower_reward = policy:settle(event("spec.reward.op.5", 0, true, true))
local higher_reward = policy:settle(event("spec.reward.op.6", 50, true, true))
assert(higher_reward.rewardIntents[1].units
    >= lower_reward.rewardIntents[1].units)

local invalid_pack = {
    schemaVersion = "pwft.reward-policy.pack.v1",
    contentPackId = "spec.reward.invalid",
    policies = {
        {
            id = "spec.reward.invalid.policy",
            sourceKind = "quest",
            difficultyBands = {
                { minimumScore = 0, multiplierBps = 15000 },
                { minimumScore = 50, multiplierBps = 10000 },
            },
            rewards = {
                { channelId = "spec.reward.bad", baseUnits = 1,
                    maximumUnits = 1 },
            },
        },
    },
}
assert(policy:register_pack(invalid_pack).reason
    == "invalid-reward-policy-pack")

local snapshot = progression:export_snapshot()
local replacement = Progression.create(Registry.progression, snapshot)
local restored_policy = RewardPolicy.create(replacement, {
    authority = "spec.authoritative-reward.v1",
})
assert(restored_policy:status("spec.reward.boss").eligibleWins == 4)
local restored_duplicate = restored_policy:settle(
    event("spec.reward.op.6", 50, true, true)
)
assert(restored_duplicate.reason == "duplicate-reward-settlement")
assert(#restored_duplicate.rewardIntents == 0)
assert(restored_policy:status().capabilities.directInventoryMutation == false)
assert(restored_policy:status().capabilities.currencyMutation == false)
assert(restored_policy:status().capabilities.palworldSaveMutation == false)
assert(restored_policy:status().nativeAdapterEnabled == false)

local live_root = Progression.create(Registry.progression)
local live_policy = RewardPolicy.create(live_root, {
    authority = "spec.authoritative-reward.v1",
})
assert(live_policy:register_pack(pack).ok)
assert(live_root:restore_snapshot(snapshot).ok)
assert(live_policy:status("spec.reward.boss").eligibleWins == 4)

print("PASS reward policy scales high difficulty upward, caps deterministic milestone rewards, rejects model authority, and persists idempotency")
