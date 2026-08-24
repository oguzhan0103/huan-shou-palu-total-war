local PROVIDER_ID = "pwft.native.strategic-world.production"

local entries = {
    {
        suffix = "rayne",
        uniquePalId = "pwft.unique.pinkcat",
        cityId = "pwft.foundation.b7.city.rayne",
        anchorId = "Tower_Grass",
    },
    {
        suffix = "pidf",
        uniquePalId = "pwft.unique.anubis",
        cityId = "pwft.foundation.b7.city.pidf",
        anchorId = "Tower_Desert",
    },
    {
        suffix = "free-pal-alliance",
        uniquePalId = "pwft.unique.weasel_dragon",
        cityId = "pwft.foundation.b7.city.free-pal-alliance",
        anchorId = "Tower_Forest",
    },
    {
        suffix = "eternal-pyre",
        uniquePalId = "pwft.unique.black_metal_dragon",
        cityId = "pwft.foundation.b7.city.eternal-pyre",
        anchorId = "Tower_Volcano",
    },
    {
        suffix = "sakurajima",
        uniquePalId = "pwft.unique.ronin",
        cityId = "pwft.foundation.b7.city.sakurajima",
        anchorId = "Tower_Sakurajima",
    },
}

local anchors = {}
local unique_pal_cities = {}
for _, entry in ipairs(entries) do
    anchors[#anchors + 1] = {
        bindingId = "pwft.native.strategic.anchor." .. entry.suffix,
        cityId = entry.cityId,
        -- PalLocationPoint IDs are the exact native location identity used
        -- by the existing tower/territory probe; no broad actor scan is
        -- authorized by this descriptor.
        actorKey = "PalLocationPoint:" .. entry.anchorId,
        actorClassKey = "/Script/Pal.PalLocationPoint",
    }
    unique_pal_cities[entry.uniquePalId] = {
        cityId = entry.cityId,
        uniquePalBindingId =
            "pwft.native.strategic.unique-pal." .. entry.suffix,
        cityBossBindingId =
            "pwft.native.strategic.city-boss." .. entry.suffix,
    }
end

return {
    provider = {
        providerId = PROVIDER_ID,
        authoritySource =
            "pwft.native.strategic-world.authority",
        enabled = true,
    },
    cityAnchors = anchors,
    uniquePalCities = unique_pal_cities,
    storyContentIncluded = false,
}
