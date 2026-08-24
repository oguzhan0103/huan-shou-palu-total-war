package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Production = require("pwft.ending_effect_native_production")
local Definitions =
    require("pwft_b7_unique_pals.ending_effect_bindings")

local registered_definition = nil
local handler = nil
local bus = {}
function bus:register_provider(definition, callback)
    registered_definition = definition
    handler = callback
    return { ok = true, reason = "registered" }
end
local ending_runtime = {}
function ending_runtime:post_ending_policy()
    return { completed = true, worldDisposition = "pacified" }
end
local rayne_city = "pwft.foundation.b7.city.rayne"
local city = {
    id = rayne_city,
    factionId = "pwft.faction.rayne_syndicate",
    status = "destroyed",
    ownerFactionId = "pwft.faction.rayne_syndicate",
}
local strategic_world = {}
function strategic_world:city_status(id)
    return id == rayne_city and city or nil
end
local refreshes = {}
local attitude_bus = {}
function attitude_bus:refresh_faction(faction_id, context)
    refreshes[#refreshes + 1] = {
        factionId = faction_id,
        context = context,
    }
    return {
        ok = true,
        reason = "refreshed",
        bindingCount = 1,
        appliedCount = 1,
    }
end
local deactivated = {}
local merchant_runtime = {}
function merchant_runtime:deactivate_faction(faction_id, reason)
    deactivated[#deactivated + 1] = faction_id .. ":" .. reason
    return { ok = true, reason = "deactivated" }
end
local economy_runtime = {}
function economy_runtime:deactivate_faction(faction_id, reason)
    deactivated[#deactivated + 1] = faction_id .. ":" .. reason
    return { ok = true, reason = "deactivated" }
end
local presented = {}
local production = Production.create(
    bus,
    ending_runtime,
    strategic_world,
    attitude_bus,
    {
        adapters = {
            presentTitle = function(title_key)
                presented[#presented + 1] = title_key
                return true, "spec-title-surface"
            end,
        },
    }
)
assert(production:set_merchant_runtimes(
    merchant_runtime,
    economy_runtime
).ok)
local activated = production:activate(Definitions)
assert(activated.ok and activated.factionCityMappingCount == 5)
assert(#registered_definition.effectKinds == 4)
assert(registered_definition.idempotentDeliveryIds == true)
assert(registered_definition.readOnlyInput == true)

local function output(id, kind, extra)
    local value = {
        deliveryId = id,
        kind = kind,
        readOnly = true,
    }
    for key, child in pairs(extra or {}) do value[key] = child end
    return value
end
local context = { scopeId = "spec.scope" }
local title = handler(output("d1", "set_title", {
    titleKey = "pwft.loc.ending.title",
}), context)
assert(title.ok and title.applied and title.deliveryId == "d1")
assert(presented[1] == "pwft.loc.ending.title")
local world = handler(output("d2", "set_world_disposition", {
    value = "pacified",
}), context)
assert(world.ok and refreshes[1].factionId == nil)
local faction = handler(output("d3", "set_faction_disposition", {
    factionId = "pwft.faction.rayne_syndicate",
    value = "friendly",
}), context)
assert(faction.ok)
assert(refreshes[2].factionId == "pwft.faction.rayne_syndicate")
local transitioned = handler(output("d4", "city_transition", {
    cityId = rayne_city,
    status = "destroyed",
    ownerFactionId = "pwft.faction.rayne_syndicate",
}), context)
assert(transitioned.ok and #deactivated == 2)
local spawn_policy = production:faction_spawn_policy(
    "pwft.faction.rayne_syndicate",
    "merchant-guild-counter"
)
assert(spawn_policy.ok and spawn_policy.suppressSpawn == true)
assert(production:faction_spawn_policy(
    "pwft.faction.feybreak_army",
    "merchant-guild-counter"
).suppressSpawn == false)
local duplicate = handler(output("d4", "city_transition", {
    cityId = rayne_city,
    status = "destroyed",
}), context)
assert(duplicate.ok and duplicate.idempotent == true)
assert(#deactivated == 2)
local status = production:status()
assert(status.deliveryCount == 4)
assert(status.duplicateDeliveryCount == 1)
assert(status.modelCommitAuthority == false)
assert(status.PalworldSaveMutation == false)

print("PASS ending native production presents titles, refreshes NPC attitudes, enforces destroyed-city merchant policy, and keeps model authority disabled")
