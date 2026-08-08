local Keys = require("minimal-content-pack.localization_keys").byName

return {
    schemaVersion = "pwft.ending-routes.pack.v1",
    contentPackId = "example.minimal.foundation",
    contentVersion = "1.0.0",
    routes = {
        {
            id = "example.minimal.ending.route.preserve",
            displayNameKey = Keys.preserveRouteName,
            priority = 300,
            conditions = {
                {
                    kind = "flag_equals",
                    key = "example.minimal.flag.route.preserve",
                    value = true,
                },
                {
                    kind = "unique_pal_owner",
                    uniquePalIds = { "example.minimal.unique.keystone" },
                    ownerKind = "player",
                },
            },
            effects = {
                { kind = "set_title", titleKey = Keys.preserveTitle },
                { kind = "set_world_disposition", value = "pacified" },
                {
                    kind = "city_transition",
                    cityId = "example.minimal.city.primary",
                    status = "active",
                    ownerFactionId = "pwft.faction.rayne_syndicate",
                },
            },
        },
        {
            id = "example.minimal.ending.route.transfer",
            displayNameKey = Keys.transferRouteName,
            priority = 200,
            conditions = {
                {
                    kind = "flag_equals",
                    key = "example.minimal.flag.route.transfer",
                    value = true,
                },
            },
            effects = {
                { kind = "set_title", titleKey = Keys.transferTitle },
                { kind = "set_world_disposition", value = "conditional" },
                {
                    kind = "city_transition",
                    cityId = "example.minimal.city.primary",
                    status = "occupied",
                    ownerFactionId = "pwft.faction.pidf",
                },
            },
        },
        {
            id = "example.minimal.ending.route.remove",
            displayNameKey = Keys.removeRouteName,
            priority = 100,
            conditions = {
                {
                    kind = "flag_equals",
                    key = "example.minimal.flag.route.remove",
                    value = true,
                },
            },
            effects = {
                { kind = "set_title", titleKey = Keys.removeTitle },
                { kind = "set_world_disposition", value = "hostile" },
                {
                    kind = "city_transition",
                    cityId = "example.minimal.city.primary",
                    status = "destroyed",
                },
            },
        },
    },
}
