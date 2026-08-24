local Keys = require("pwft_b5_acceptance.localization_keys")

return {
    schemaVersion = "1.0.0",
    contentPackId = "pwft.foundation.b5-acceptance",
    contentVersion = "1.0.0",
    namespace = "pwft.foundation",
    localizationNamespace = Keys.namespace,
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = { "pwft.quest.templates" },
    localizationKeys = Keys.catalog,
}
