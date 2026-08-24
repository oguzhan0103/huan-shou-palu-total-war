local Manifest = require("minimal-content-pack.manifest")

-- Authoring skeleton only: content authors replace the fictional IDs/classes
-- and composition. Core owns validation, caps and lifecycle; a separately
-- whitelisted native provider owns actual spawning/follow/combat/despawn.
return {
    schemaVersion = "1.0.0",
    contentPackId = Manifest.contentPackId,
    contentVersion = Manifest.contentVersion,
    leaders = {
        {
            leaderId = "example.minimal.leader.city-steward",
            factionId = "pwft.faction.rayne_syndicate",
            actorClassKey = "BP_ExampleCitySteward_C",
            formations = {
                {
                    formationId = "example.minimal.guard.city-steward",
                    members = {
                        {
                            -- Core supplies one verified default archetype per
                            -- human faction. Authors may register more through
                            -- PWFT_NPC_LEADER_GUARD_NATIVE_PRODUCTION_V1.
                            archetypeId =
                                "pwft.faction.rayne_syndicate.default-guard",
                            count = 2,
                        },
                    },
                    allowedSceneKinds = { "city", "field" },
                    limits = {
                        perLeader = 1,
                        perFaction = 2,
                        perScene = 2,
                    },
                },
            },
        },
    },
}
