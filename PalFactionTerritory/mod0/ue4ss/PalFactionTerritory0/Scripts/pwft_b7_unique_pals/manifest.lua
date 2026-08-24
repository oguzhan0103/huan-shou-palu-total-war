local Localization = require("pwft_b7_unique_pals.localization_keys")

return {
    schemaVersion = "1.0.0",
    contentPackId = "pwft.foundation.b7.unique-pals",
    contentVersion = "1.0.0",
    namespace = "pwft.foundation.b7",
    localizationNamespace = Localization.namespace,
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = {
        "pwft.world.unique-pals",
        "pwft.world.unique-pal-campaign",
        "pwft.world.city-states",
        "pwft.world.endings",
    },
    localizationKeys = Localization.catalog,
}
