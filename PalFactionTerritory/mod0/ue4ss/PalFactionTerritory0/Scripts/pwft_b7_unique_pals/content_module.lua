local function activate(context)
    assert(type(context) == "table"
            and type(context.uniquePalBossNativeProduction) == "table"
            and type(context.uniquePalWorldEffectNativeProduction)
                == "table"
            and type(context.strategicWorldNativeProduction)
                == "table"
            and type(context.factionNpcAttitudeNativeProduction)
                == "table"
            and type(context.endingEffectNativeProduction)
                == "table",
        "B7 unique-Pal production adapters are required")
    local strategic_activated =
        context.strategicWorldNativeProduction:activate(
            require("pwft_b7_unique_pals.strategic_native_bindings")
        )
    if not strategic_activated.ok then return strategic_activated end
    local boss_activated = context.uniquePalBossNativeProduction:activate(
        require("pwft_b7_unique_pals.native_bindings")
    )
    if not boss_activated.ok then return boss_activated end
    local world_activated =
        context.uniquePalWorldEffectNativeProduction:activate(
            require("pwft_b7_unique_pals.world_effect_bindings")
        )
    if not world_activated.ok then return world_activated end
    local attitude_activated =
        context.factionNpcAttitudeNativeProduction:activate(
            require("pwft_b7_unique_pals.npc_attitude_bindings")
        )
    if not attitude_activated.ok then return attitude_activated end
    local ending_activated =
        context.endingEffectNativeProduction:activate(
            require("pwft_b7_unique_pals.ending_effect_bindings")
        )
    if not ending_activated.ok then return ending_activated end
    return {
        ok = true,
        reason = "b7-unique-pal-production-activated",
        strategicCityAnchorBindingCount =
            strategic_activated.cityAnchorBindingCount,
        bossBindingCount = boss_activated.bindingCount,
        worldEffectTargetBindingCount =
            world_activated.targetBindingCount,
        nativeDeliveryBindingCount =
            world_activated.nativeDeliveryBindingCount,
        worldGeneration = world_activated.worldGeneration,
        NPCattitudeDefinitionCount =
            attitude_activated.definitionCount,
        endingFactionCityMappingCount =
            ending_activated.factionCityMappingCount,
        storyContentIncluded = false,
    }
end

return {
    bundle = require("pwft_b7_unique_pals.bundle"),
    activate = activate,
    storyContentIncluded = false,
    defaultEnabled = true,
}
