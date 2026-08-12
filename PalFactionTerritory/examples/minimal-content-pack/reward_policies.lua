local Manifest = require("minimal-content-pack.manifest")

return {
    schemaVersion = "pwft.reward-policy.pack.v1",
    contentPackId = Manifest.contentPackId,
    policies = {
        {
            id = "example.minimal.reward.quest-completion",
            sourceKind = "quest",
            difficultyBands = {
                { minimumScore = 0, multiplierBps = 10000 },
                { minimumScore = 80, multiplierBps = 15000 },
            },
            milestoneEvery = 3,
            milestoneBonusBps = 5000,
            rewards = {
                {
                    channelId = "example.minimal.reward.channel.quest",
                    baseUnits = 1,
                    maximumUnits = 2,
                },
            },
        },
    },
}
