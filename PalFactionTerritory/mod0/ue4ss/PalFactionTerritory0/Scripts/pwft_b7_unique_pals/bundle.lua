local Manifest = require("pwft_b7_unique_pals.manifest")

return {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = Manifest,
    questTemplates = {},
    strategicWorld = require("pwft_b7_unique_pals.strategic_world"),
    uniquePalCampaign =
        require("pwft_b7_unique_pals.unique_pal_campaign"),
    endingRoutes = require("pwft_b7_unique_pals.ending_routes"),
    localization = {
        schemaVersion = "1.0.0",
        contentPackId = Manifest.contentPackId,
        contentVersion = Manifest.contentVersion,
        catalogs = require("pwft_b7_unique_pals.localization_catalogs"),
    },
}
