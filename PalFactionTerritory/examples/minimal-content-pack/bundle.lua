local Manifest = require("minimal-content-pack.manifest")

return {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = Manifest,
    questTemplates = {
        require("minimal-content-pack.quest_template"),
    },
    strategicWorld = require("minimal-content-pack.strategic_world"),
    endingRoutes = require("minimal-content-pack.ending_routes"),
    palDiscourse = require("minimal-content-pack.pal_discourse"),
    localization = {
        schemaVersion = "1.0.0",
        contentPackId = Manifest.contentPackId,
        contentVersion = Manifest.contentVersion,
        catalogs = require("minimal-content-pack.localization_catalogs"),
    },
}
