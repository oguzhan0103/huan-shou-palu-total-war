local Manifest = require("minimal-content-pack.manifest")

return {
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = Manifest.contentPackId,
    contentVersion = Manifest.contentVersion,
    uniquePals = {{
        id = "example.minimal.unique.keystone",
        target = {
            kind = "faction",
            id = "pwft.faction.rayne_syndicate",
            affectedFactionIds = {
                "pwft.faction.rayne_syndicate",
            },
        },
        boss = {
            speciesId = "ExampleMinimalPalSpecies",
            nativeBossAvailable = false,
            -- Fill this and change bindingStatus to `bound` only after the
            -- replacement Boss spawner has been verified in the target build.
            nativeBossSlotId = nil,
            bindingStatus = "pending",
            strengthProfile = "raid-slab",
        },
        schedule = {
            minimumIntervalTicks = 3,
            maximumIntervalTicks = 7,
            noticeTicks = 1,
            openTicks = 1,
        },
        -- Deliberately extreme example value. Authors must rebalance it for
        -- their own economy and confirm payment through the native provider.
        ransomPrice = 100000000,
        candidateFactionIds = {
            "pwft.faction.pidf",
        },
        tags = {
            "example.minimal.tag.author-sdk",
        },
    }},
}
