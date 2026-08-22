package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Production = require("pwft.unique_pal_native_delivery_production")

local generation = 3
local adapter_bind_count = 0
local registered_definition = nil
local registered_adapter = nil
local handled_delivery = nil
local world_effect_bus = {
    status = function()
        return { worldGeneration = generation }
    end,
}
local adapter = {
    bind_world = function(_, value)
        assert(value == generation)
        adapter_bind_count = adapter_bind_count + 1
        return { ok = true, reason = "bound" }
    end,
    status = function()
        return {
            buildId = "24575825",
            objectDumpSha256 =
                "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78",
            allowMutatingDelivery = true,
            capabilities = {
                currentBuildSignatureBound = true,
                capacityPreflight = true,
                serverAuthoritativeSpawn = true,
                stableIndividualIdentity = true,
                serverAuthoritativeCapture = true,
                exactStorageReadback = true,
                directContainerMutation = false,
                PalworldSaveMutation = false,
            },
        }
    end,
}
local bridge = {
    register_binding = function(_, definition, bound_adapter)
        registered_definition = definition
        registered_adapter = bound_adapter
        return {
            ok = true,
            reason = "native-pal-delivery-binding-registered",
            bindingId = definition.bindingId,
            targetBindingId = definition.targetBindingId,
        }
    end,
    handle_delivery = function(_, payload, context)
        handled_delivery = { payload = payload, context = context }
        return { ok = true, reason = "native-pal-delivery-accepted" }
    end,
}
local config = {
    enabled = true,
    buildId = "24575825",
    objectDumpSha256 =
        "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78",
    deliveryLevel = 80,
    approvedSpeciesByUniquePalId = {
        ["pwft.unique.pinkcat"] = "PinkCat",
        ["pwft.unique.anubis"] = "Anubis",
        ["pwft.unique.weasel_dragon"] = "WeaselDragon",
        ["pwft.unique.black_metal_dragon"] = "BlackMetalDragon",
        ["pwft.unique.ronin"] = "Ronin",
    },
}
local production = Production.create(
    bridge,
    adapter,
    world_effect_bus,
    config
)

local definition = {
    bindingId = "pwft.binding.production.pidf",
    targetBindingId = "pwft.binding.world.pidf",
    providerId = "pwft.provider.production.unique-pal",
    palDeliveryKey = "PFT_Pal_Delivery_PIDF",
    worldGeneration = generation,
    speciesByUniquePalId = {
        ["pwft.unique.anubis"] = "Anubis",
    },
}
local registered = production:register(definition)
assert(registered.ok and registered.productionReady)
assert(adapter_bind_count == 1)
assert(registered_adapter == adapter)
assert(registered_definition.buildId == "24575825")
assert(registered_definition.verifiedBuildId == "24575825")
assert(registered_definition.currentBuildVerified == true)
assert(registered_definition.serverAuthoritativeSpawn == true)
assert(registered_definition.serverAuthoritativeCapture == true)
assert(registered_definition.capacityPreflight == true)
assert(registered_definition.storageVerification == true)
assert(registered_definition.stableIndividualIdentity == true)
assert(registered_definition.speciesByUniquePalId["pwft.unique.anubis"]
    == "Anubis")

local duplicate = production:register(definition)
assert(duplicate.ok)
assert(adapter_bind_count == 2)
assert(production:status().activeBindingCount == 1)
assert(production:status().registrationCount == 1)
assert(production:status().approvedSpeciesCount == 5)
assert(production:status().feybreakTentativeEnabled == false)

-- A map load increments the world-effect generation and clears the bridge's
-- native binding.  The same trusted content activation must be allowed to
-- register the identical static route for the new generation.
generation = generation + 1
definition.worldGeneration = generation
local rebound = production:register(definition)
assert(rebound.ok)
assert(adapter_bind_count == 3)
assert(production:status().activeBindingCount == 1)
assert(production:status().registrationCount == 1)
assert(production:status().worldRebindCount == 1)

local wrong_species = {}
for key, value in pairs(definition) do wrong_species[key] = value end
wrong_species.targetBindingId = "pwft.binding.world.rayne"
wrong_species.bindingId = "pwft.binding.production.rayne"
wrong_species.speciesByUniquePalId = {
    ["pwft.unique.anubis"] = "PinkCat",
}
assert(production:register(wrong_species).reason
    == "invalid-production-native-pal-delivery-binding")

local tentative = {}
for key, value in pairs(definition) do tentative[key] = value end
tentative.targetBindingId = "pwft.binding.world.feybreak"
tentative.bindingId = "pwft.binding.production.feybreak"
tentative.speciesByUniquePalId = {
    ["pwft.unique.feybreak"] = "UnknownCloudWhirl",
}
assert(production:register(tentative).reason
    == "invalid-production-native-pal-delivery-binding")

local stale = {}
for key, value in pairs(definition) do stale[key] = value end
stale.worldGeneration = generation - 1
assert(production:register(stale).reason
    == "invalid-production-native-pal-delivery-binding")

local delivery = production:handle_delivery(
    { deliveryKind = "pal-delivery", deliveryId = "spec.delivery.1" },
    { bindingId = definition.targetBindingId }
)
assert(delivery.ok)
assert(handled_delivery.payload.deliveryId == "spec.delivery.1")
assert(production:status().deliveryRequestCount == 1)
assert(production:status().directContainerMutation == false)
assert(production:status().PalworldSaveMutation == false)

print("PASS production unique-Pal delivery exposes only the five confirmed Build-24575825 mappings, derives strict bridge verification facts, binds the accepted native adapter per world generation, and keeps tentative Feybreak fail-closed")
