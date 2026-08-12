local Manifest = require("minimal-content-pack.manifest")

return {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = Manifest,
    questTemplates = {
        require("minimal-content-pack.quest_template"),
    },
    strategicWorld = require("minimal-content-pack.strategic_world"),
    endingRoutes = require("minimal-content-pack.ending_routes"),
    contentActions = require("minimal-content-pack.content_actions"),
    leaderGuards = require("minimal-content-pack.leader_guards"),
    rewardPolicies = require("minimal-content-pack.reward_policies"),
    palDiscourse = require("minimal-content-pack.pal_discourse"),
    localization = {
        schemaVersion = "1.0.0",
        contentPackId = Manifest.contentPackId,
        contentVersion = Manifest.contentVersion,
        catalogs = require("minimal-content-pack.localization_catalogs"),
    },
}
