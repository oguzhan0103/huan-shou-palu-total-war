local Localization = require("minimal-content-pack.localization_keys")

return {
    schemaVersion = "1.0.0",
    contentPackId = "example.minimal.foundation",
    contentVersion = "1.0.0",
    namespace = "example.minimal",
    localizationNamespace = Localization.namespace,
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = {
        "pwft.quest.templates",
        "pwft.pal.discourse",
        "pwft.world.unique-pals",
        "pwft.world.city-states",
        "pwft.world.endings",
    },
    localizationKeys = Localization.catalog,
}
