package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionCommerce = require("pwft.faction_commerce")
local FactionMerchantRuntime =
    require("pwft.faction_merchant_runtime")
local FactionProgression = require("pwft.faction_progression")

local progression = FactionProgression.create(Registry.progression)
local api = FactionApi.create(progression)
local commerce = FactionCommerce.create(Registry.commerce, api)
local vendor_bindings = {}
local vendor_metadata = {}
local unregistered_vendors = {}
local bridge = {
    register_vendor_actor = function(
        _,
        faction_id,
        actor,
        metadata
    )
        vendor_bindings[faction_id] = actor
        vendor_metadata[faction_id] = metadata
        return true
    end,
    unregister_vendor_actor = function(_, actor)
        table.insert(unregistered_vendors, actor)
        return true
    end,
}

local spawned_merchants = {}
local spawned_guards = {}
local despawned = {}
local adapter = {
    spawn_merchant = function(_, plan)
        table.insert(spawned_merchants, plan)
        return "merchant-actor:" .. plan.runtimeId
    end,
    spawn_guard = function(_, plan)
        table.insert(spawned_guards, plan)
        return "guard-actor:" .. plan.runtimeId
    end,
    despawn = function(_, actor)
        table.insert(despawned, actor)
        return true
    end,
}

local pending = FactionMerchantRuntime.create(
    Registry.commerce,
    api,
    bridge
)
assert(pending:status().adapterReady == false)
assert(pending:status().marketReferenceFastTravelPointId == "FTPoint90")
assert(
    pending:status().marketPublicFastTravelPolicy
        == "preserve_native_unrestricted"
)
assert(
    pending.capabilities.neutralPublicMarketIsland
        == true
)
assert(Registry.fastTravelPointToIsland["FTPoint90"] == nil)
assert(pending:activate_market().reason
    == "native-merchant-adapter-pending")

local runtime = FactionMerchantRuntime.create(
    Registry.commerce,
    api,
    bridge,
    adapter
)
local root = { X = 1000, Y = 2000, Z = 300 }
local rotation = { Pitch = 0, Yaw = 90, Roll = 0 }
local activated = runtime:activate_market(root, rotation)
assert(activated.ok)
assert(#activated.spawned == 6)
assert(#activated.skipped == 1)
assert(#spawned_merchants == 6)
assert(runtime:status().fixedActiveCount == 6)
local existing_rayne_actor = "existing-rayne-merchant"
assert(runtime:bind_existing_fixed(
    "pwft.faction.rayne_syndicate",
    existing_rayne_actor,
    {
        existingRuntimeBinding = "rayneMerchant",
    }
).ok)
assert(runtime:status().fixedActiveCount == 7)
assert(
    vendor_metadata["pwft.faction.rayne_syndicate"]
        .mode
        == "fixed-market"
)
assert(
    vendor_bindings["pwft.faction.free_pal_alliance"]
        ~= nil
)
assert(
    vendor_metadata["pwft.faction.free_pal_alliance"]
        .mode
        == "fixed-market"
)
assert(
    vendor_metadata["pwft.faction.free_pal_alliance"]
        .commercialTruce
        == true
)

local fpa_plan = runtime:fixed_plan(
    "pwft.faction.free_pal_alliance",
    root,
    rotation
)
assert(fpa_plan.mode == "fixed-market")
assert(fpa_plan.commercialTruce == true)
assert(fpa_plan.characterId == "NPC_Male_Trader01_v04")
assert(fpa_plan.shopRowName == "CaravanShop4")
assert(math.floor(fpa_plan.location.X + 0.5) == 1600)
assert(math.floor(fpa_plan.location.Y + 0.5) == 2000)

local caravan = runtime:dispatch_caravan(
    "pwft.faction.free_pal_alliance",
    "visit-001",
    { X = 500, Y = 600, Z = 50 },
    { Pitch = 0, Yaw = 0, Roll = 0 }
)
assert(caravan.ok)
assert(
    vendor_metadata["pwft.faction.free_pal_alliance"]
        .mode
        == "visiting-caravan"
)
assert(
    vendor_metadata["pwft.faction.free_pal_alliance"]
        .commercialTruce
        == false
)
assert(#caravan.guardActors == 1)
assert(#spawned_guards == 1)
assert(spawned_guards[1].characterId == "NPC_Believer")
assert(
    spawned_guards[1].characterClassPath
        == "/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Believer.BP_NPC_Believer_C"
)
assert(runtime:status().caravanActiveCount == 1)
assert(
    api:join_human(
        "pwft.faction.rayne_syndicate",
        "merchant-lifecycle-join-rayne"
    ).ok
)
local relation_recall = runtime:on_relation_changed(
    "pwft.faction.free_pal_alliance",
    "relation-change"
)
assert(relation_recall.ok)
assert(relation_recall.reason == "caravan-recalled")
assert(relation_recall.relation == "Hostile")
assert(#despawned == 2)
assert(#unregistered_vendors == 1)
assert(
    runtime:dispatch_caravan(
        "pwft.faction.free_pal_alliance",
        "visit-001",
        root,
        rotation
    ).reason
        == "hostile-faction-caravan-unavailable"
)
local deactivated = runtime:deactivate_market(
    "test-market-shutdown"
)
assert(deactivated.ok)
assert(#deactivated.removedFactionIds == 6)
assert(
    #deactivated.preservedExternalFactionIds
        == 1
)
assert(runtime:status().fixedActiveCount == 1)
assert(runtime:status().marketDeactivateCount == 1)
assert(runtime:status().recalledCaravanCount == 1)
assert(#despawned == 8)

local hostile_snapshot = progression:export_snapshot()
hostile_snapshot.factions[
    "pwft.faction.eternal_pyre"
].reputation = -10
local hostile_progression = FactionProgression.create(
    Registry.progression,
    hostile_snapshot
)
local hostile_api = FactionApi.create(hostile_progression)
local hostile_runtime = FactionMerchantRuntime.create(
    Registry.commerce,
    hostile_api,
    bridge,
    adapter
)
assert(hostile_runtime:dispatch_caravan(
    "pwft.faction.eternal_pyre",
    "visit-hostile",
    root,
    rotation
).reason == "hostile-faction-caravan-unavailable")
assert(hostile_runtime:fixed_plan(
    "pwft.faction.eternal_pyre",
    root,
    rotation
).commercialTruce == true)

print("PASS fixed faction market and guarded visiting-caravan runtime plans")
