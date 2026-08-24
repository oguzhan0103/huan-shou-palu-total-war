local Keys = require("pwft_b7_unique_pals.localization_keys").byName
local Manifest = require("pwft_b7_unique_pals.manifest")

return {
    schemaVersion = "pwft.ending-routes.pack.v1",
    contentPackId = Manifest.contentPackId,
    contentVersion = Manifest.contentVersion,
    routes = {
        {
            id = "pwft.foundation.b7.ending.all-unique-pals",
            displayNameKey = Keys.allLordRoute,
            priority = 100,
            conditions = {
                {
                    kind = "unique_pal_owner",
                    uniquePalIds = {
                        "pwft.unique.pinkcat",
                        "pwft.unique.anubis",
                        "pwft.unique.weasel_dragon",
                        "pwft.unique.black_metal_dragon",
                        "pwft.unique.ronin",
                    },
                    ownerKind = "player",
                },
            },
            effects = {
                { kind = "set_title", titleKey = Keys.allLordTitle },
                { kind = "set_world_disposition", value = "pacified" },
            },
        },
    },
}
