local PROVIDER_ID = "pwft.native.unique-pal-boss.production"
local BUILD_ID = "24575825"

local function balance()
    return {
        profileId = "raid-slab",
        level = 80,
        healthMultiplier = 12,
        damageMultiplier = 2.5,
        -- The native Boss parameter rows keep their own receive-damage,
        -- status and capture curves. These three values truthfully mean that
        -- this adapter adds no unverified reflected mutation on top of them.
        damageReductionMultiplier = 1,
        statusResistanceMultiplier = 1,
        captureDifficultyMultiplier = 1,
        captureAllowed = true,
    }
end

local function binding(
    unique_pal_id,
    species_id,
    boss_character_id,
    display_name,
    actor_class
)
    return {
        bindingId = "pwft.native.unique-pal-boss.binding."
            .. string.match(unique_pal_id, "([^%.]+)$"),
        providerId = PROVIDER_ID,
        uniquePalId = unique_pal_id,
        speciesId = species_id,
        bossCharacterId = boss_character_id,
        displayNameZhHans = display_name,
        bossSpawnerKey = "PalNPCManager.SpawnNPCForServer:"
            .. boss_character_id,
        expectedActorClassKey = actor_class,
        locationKey = "pwft.location.dynamic.player-front-event-arena",
        buildId = BUILD_ID,
        verification = {
            speciesId = true,
            -- Build 24575825 has already accepted this manager route with a
            -- Boss character row and returned a stable individual handle.
            spawnerKey = true,
            actorClassKey = true,
        },
        balance = balance(),
    }
end

return {
    bindings = {
        binding(
            "pwft.unique.pinkcat",
            "PinkCat",
            "BOSS_PinkCat",
            "捣蛋猫",
            "/Game/Pal/Blueprint/Character/Monster/PalActorBP/PinkCat/BP_PinkCat_BOSS.BP_PinkCat_BOSS_C"
        ),
        binding(
            "pwft.unique.anubis",
            "Anubis",
            "Boss_Anubis",
            "阿努比斯",
            "/Game/Pal/Blueprint/Character/Monster/PalActorBP/Anubis/BP_Anubis_MiddleBoss.BP_Anubis_MiddleBoss_C"
        ),
        binding(
            "pwft.unique.weasel_dragon",
            "WeaselDragon",
            "BOSS_WeaselDragon",
            "疾漩鼬",
            "/Game/Pal/Blueprint/Character/Monster/PalActorBP/WeaselDragon/BP_WeaselDragon_BOSS.BP_WeaselDragon_BOSS_C"
        ),
        binding(
            "pwft.unique.black_metal_dragon",
            "BlackMetalDragon",
            "BOSS_BlackMetalDragon",
            "魔渊龙",
            "/Game/Pal/Blueprint/Character/Monster/PalActorBP/BlackMetalDragon/BP_BlackMetalDragon_BOSS.BP_BlackMetalDragon_BOSS_C"
        ),
        binding(
            "pwft.unique.ronin",
            "Ronin",
            "BOSS_Ronin",
            "浪刃武士",
            "/Game/Pal/Blueprint/Character/Monster/PalActorBP/Ronin/BP_Ronin_Boss.BP_Ronin_Boss_C"
        ),
    },
}
