local PROVIDER_ID = "pwft.native.unique-pal-world-effect.production"

local entries = {
    {
        suffix = "rayne",
        uniquePalId = "pwft.unique.pinkcat",
        speciesId = "PinkCat",
        targetKind = "faction",
        targetId = "pwft.faction.rayne_syndicate",
        factionId = "pwft.faction.rayne_syndicate",
        cityId = "pwft.foundation.b7.city.rayne",
        legacyMerchantClass =
            "/Game/Pal/Blueprint/Character/NPC/Fat/"
                .. "BP_NPC_DarkTrader.BP_NPC_DarkTrader_C",
    },
    {
        suffix = "pidf",
        uniquePalId = "pwft.unique.anubis",
        speciesId = "Anubis",
        targetKind = "faction",
        targetId = "pwft.faction.pidf",
        factionId = "pwft.faction.pidf",
        cityId = "pwft.foundation.b7.city.pidf",
        legacyMerchantClass =
            "/Game/Pal/Blueprint/Character/NPC/Normal/"
                .. "BP_NPC_Male_Trader01_v06."
                .. "BP_NPC_Male_Trader01_v06_C",
    },
    {
        suffix = "free-pal-alliance",
        uniquePalId = "pwft.unique.weasel_dragon",
        speciesId = "WeaselDragon",
        targetKind = "faction",
        targetId = "pwft.faction.free_pal_alliance",
        factionId = "pwft.faction.free_pal_alliance",
        cityId = "pwft.foundation.b7.city.free-pal-alliance",
        legacyMerchantClass =
            "/Game/Pal/Blueprint/Character/NPC/Normal/"
                .. "BP_NPC_Male_Trader01_v04."
                .. "BP_NPC_Male_Trader01_v04_C",
    },
    {
        suffix = "eternal-pyre",
        uniquePalId = "pwft.unique.black_metal_dragon",
        speciesId = "BlackMetalDragon",
        targetKind = "faction",
        targetId = "pwft.faction.eternal_pyre",
        factionId = "pwft.faction.eternal_pyre",
        cityId = "pwft.foundation.b7.city.eternal-pyre",
        legacyMerchantClass =
            "/Game/Pal/Blueprint/Character/NPC/Normal/"
                .. "BP_NPC_Male_Trader01_v05."
                .. "BP_NPC_Male_Trader01_v05_C",
    },
    {
        suffix = "sakurajima",
        uniquePalId = "pwft.unique.ronin",
        speciesId = "Ronin",
        targetKind = "strategic-target",
        targetId = "pwft.island.sakurajima",
        factionId = "pwft.faction.moonflower",
        cityId = "pwft.foundation.b7.city.sakurajima",
        legacyMerchantClass =
            "/Game/Pal/Blueprint/Character/NPC/Normal/"
                .. "BP_NPC_Male_Trader01_v08."
                .. "BP_NPC_Male_Trader01_v08_C",
    },
}

local target_bindings = {}
local delivery_bindings = {}
local definitions = {}

for _, entry in ipairs(entries) do
    local binding_id = "pwft.native.unique-pal-world-effect.binding."
        .. entry.suffix
    local text_key = "pwft.native.warning.unique-pal-war." .. entry.suffix
    local defense_key = "pwft.native.settlement-raid.unique-pal-defense."
        .. entry.suffix
    local background_key = "pwft.native.background-war.unique-pal."
        .. entry.suffix
    local ransom_key = "pwft.native.commerce.unique-pal-ransom."
        .. entry.suffix
    local delivery_key = "pwft.native.pal-delivery.unique-pal."
        .. entry.suffix
    target_bindings[#target_bindings + 1] = {
        bindingId = binding_id,
        providerId = PROVIDER_ID,
        targetKind = entry.targetKind,
        targetId = entry.targetId,
        buildId = "24575825",
        nativeRoutes = {
            textPresenterKey = text_key,
            defenseRaidKey = defense_key,
            backgroundWarResolverKey = background_key,
            ransomPaymentKey = ransom_key,
            palDeliveryKey = delivery_key,
        },
        -- These are the exact Mod-owned spawn gates used by the current
        -- merchant/guard runtime. They deliberately do not claim a broad
        -- scan over unrelated base-game actors.
        spawnBindings = {
            {
                spawnKind = "merchant-guild-counter",
                spawnerKey = "pwft.runtime.faction-economy-merchant:"
                    .. entry.factionId,
                actorClassKeys = {
                    "/Game/Pal/Blueprint/Character/NPC/Normal/"
                        .. "BP_NPC_Male_Trader01_v04."
                        .. "BP_NPC_Male_Trader01_v04_C",
                },
            },
            {
                spawnKind = "visiting-caravan",
                spawnerKey = "pwft.runtime.faction-merchant-caravan:"
                    .. entry.factionId,
                actorClassKeys = { entry.legacyMerchantClass },
            },
        },
        cleanupActorBindings = {
            {
                actorBindingId =
                    "pwft.actor.merchant-guild-counter." .. entry.suffix,
                actorClassKey =
                    "/Game/Pal/Blueprint/Character/NPC/Normal/"
                        .. "BP_NPC_Male_Trader01_v04."
                        .. "BP_NPC_Male_Trader01_v04_C",
            },
            {
                actorBindingId =
                    "pwft.actor.visiting-caravan." .. entry.suffix,
                actorClassKey = entry.legacyMerchantClass,
            },
        },
        cityBindings = {
            {
                cityId = entry.cityId,
                cityAnchorKey = "pwft.strategic-world.city-anchor:"
                    .. entry.cityId,
                residentSpawnerKeys = {
                    "pwft.spawn-policy.settlement-resident:"
                        .. entry.factionId,
                },
                functionSpawnerKeys = {
                    "pwft.spawn-policy.merchant-guild-counter:"
                        .. entry.factionId,
                    "pwft.spawn-policy.faction-function-npc:"
                        .. entry.factionId,
                },
            },
        },
        merchantCounterFactionIds = { entry.factionId },
        verification = {
            currentBuild = true,
            spawners = true,
            actorClasses = true,
            nativeRoutes = true,
            cityAnchors = true,
            merchantCounters = true,
        },
    }
    delivery_bindings[#delivery_bindings + 1] = {
        bindingId = "pwft.native.unique-pal-delivery.binding."
            .. entry.suffix,
        targetBindingId = binding_id,
        providerId = PROVIDER_ID,
        palDeliveryKey = delivery_key,
        speciesByUniquePalId = {
            [entry.uniquePalId] = entry.speciesId,
        },
    }
    definitions[entry.uniquePalId] = {
        uniquePalId = entry.uniquePalId,
        speciesId = entry.speciesId,
        targetKind = entry.targetKind,
        targetId = entry.targetId,
        factionId = entry.factionId,
        cityId = entry.cityId,
    }
end

return {
    provider = {
        providerId = PROVIDER_ID,
        authoritySource =
            "pwft.native.unique-pal-world-effect.authority",
        enabled = true,
    },
    targetBindings = target_bindings,
    nativeDeliveryBindings = delivery_bindings,
    definitionsByUniquePalId = definitions,
    storyContentIncluded = false,
}
