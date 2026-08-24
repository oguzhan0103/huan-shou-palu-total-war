local Keys = require("pwft_b7_unique_pals.localization_keys").byName
local Manifest = require("pwft_b7_unique_pals.manifest")

return {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = Manifest.contentPackId,
    contentVersion = Manifest.contentVersion,
    uniquePals = {
        {
            id = "pwft.unique.pinkcat",
            speciesId = "PinkCat",
            displayNameKey = Keys.pinkCat,
            initialOwner = { kind = "wild" },
        },
        {
            id = "pwft.unique.anubis",
            speciesId = "Anubis",
            displayNameKey = Keys.anubis,
            initialOwner = { kind = "wild" },
        },
        {
            id = "pwft.unique.weasel_dragon",
            speciesId = "WeaselDragon",
            displayNameKey = Keys.weaselDragon,
            initialOwner = { kind = "wild" },
        },
        {
            id = "pwft.unique.black_metal_dragon",
            speciesId = "BlackMetalDragon",
            displayNameKey = Keys.blackMetalDragon,
            initialOwner = { kind = "wild" },
        },
        {
            id = "pwft.unique.ronin",
            speciesId = "Ronin",
            displayNameKey = Keys.ronin,
            initialOwner = { kind = "wild" },
        },
    },
    cities = {
        {
            id = "pwft.foundation.b7.city.rayne",
            factionId = "pwft.faction.rayne_syndicate",
            displayNameKey = Keys.rayneCity,
            requiredUniquePalId = "pwft.unique.pinkcat",
            initialOwnerFactionId = "pwft.faction.rayne_syndicate",
            restorable = true,
        },
        {
            id = "pwft.foundation.b7.city.pidf",
            factionId = "pwft.faction.pidf",
            displayNameKey = Keys.pidfCity,
            requiredUniquePalId = "pwft.unique.anubis",
            initialOwnerFactionId = "pwft.faction.pidf",
            restorable = true,
        },
        {
            id = "pwft.foundation.b7.city.free-pal-alliance",
            factionId = "pwft.faction.free_pal_alliance",
            displayNameKey = Keys.freePalCity,
            requiredUniquePalId = "pwft.unique.weasel_dragon",
            initialOwnerFactionId = "pwft.faction.free_pal_alliance",
            restorable = true,
        },
        {
            id = "pwft.foundation.b7.city.eternal-pyre",
            factionId = "pwft.faction.eternal_pyre",
            displayNameKey = Keys.eternalPyreCity,
            requiredUniquePalId = "pwft.unique.black_metal_dragon",
            initialOwnerFactionId = "pwft.faction.eternal_pyre",
            restorable = true,
        },
        {
            id = "pwft.foundation.b7.city.sakurajima",
            factionId = "pwft.faction.moonflower",
            displayNameKey = Keys.sakurajimaCity,
            requiredUniquePalId = "pwft.unique.ronin",
            initialOwnerFactionId = "pwft.faction.moonflower",
            restorable = true,
        },
    },
}
