local Keys = require("minimal-content-pack.localization_keys").byName

return {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "example.minimal.foundation",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "example.minimal.unique.keystone",
            speciesId = "ExampleMinimalPalSpecies",
            displayNameKey = Keys.uniquePalName,
            initialOwner = { kind = "wild" },
            tags = { "example.minimal.tag.author-sdk" },
        },
    },
    cities = {
        {
            id = "example.minimal.city.primary",
            factionId = "pwft.faction.rayne_syndicate",
            displayNameKey = Keys.cityName,
            requiredUniquePalId = "example.minimal.unique.keystone",
            initialOwnerFactionId = "pwft.faction.rayne_syndicate",
            restorable = true,
            tags = { "example.minimal.tag.author-sdk" },
        },
    },
}
