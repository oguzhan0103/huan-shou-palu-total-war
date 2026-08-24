package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local StrategicWorldNativeBus =
    require("pwft.strategic_world_native_bus")
local Production =
    require("pwft.strategic_world_native_production")
local WorldPack = require("pwft_b7_unique_pals.strategic_world")
local Definitions =
    require("pwft_b7_unique_pals.strategic_native_bindings")

local progression = Progression.create(Registry.progression)
local world = StrategicWorld.create(progression)
assert(world:register_pack(WorldPack).ok)
local bus = StrategicWorldNativeBus.create(world)
local production = Production.create(bus)
local activated = production:activate(Definitions)
assert(activated.ok and activated.cityAnchorBindingCount == 5)
local initial = bus:status()
assert(initial.fullyCapableProviderCount == 1)
assert(initial.bindingCountByKind["city-anchor"] == 5)
assert(initial.bindingCountByKind["unique-pal"] == 0)
assert(initial.bindingCountByKind["city-boss"] == 0)

local actor_key =
    "pwft.actor.pwft.unique.pinkcat.pal-player-instance-001"
local actor_class =
    "/Game/Pal/Blueprint/Character/Monster/PalActorBP/PinkCat/"
        .. "BP_PinkCat_BOSS.BP_PinkCat_BOSS_C"
local bound = production:bind_unique_pal_actor(
    "pwft.unique.pinkcat",
    actor_key,
    actor_class
)
assert(bound.ok)
local dynamic = bus:status().bindingCountByKind
assert(dynamic["unique-pal"] == 1)
assert(dynamic["city-boss"] == 1)
assert(production:bind_unique_pal_actor(
    "pwft.unique.pinkcat",
    actor_key,
    actor_class
).reason == "strategic-native-unique-pal-actor-already-bound")

local protected = production:ingest({
    eventKind = "boss-damage",
    eventId = "spec.production.boss.damage",
    operationId = "spec.production.boss.damage",
    bindingId = bound.cityBossBindingId,
    actorKey = actor_key,
    actorClassKey = actor_class,
    proposedHealth = 0,
    destructionActor = { kind = "player", id = "local-player" },
})
assert(protected.ok)
assert(protected.reason == "boss-one-hp-protection-applied")
assert(protected.appliedHealth == 1)

local unbound = production:unbind_unique_pal_actor(
    "pwft.unique.pinkcat"
)
assert(unbound.ok)
assert(bus:status().bindingCountByKind["unique-pal"] == 0)
assert(bus:status().bindingCountByKind["city-boss"] == 0)
assert(production:unbind_unique_pal_actor(
    "pwft.unique.pinkcat"
).reason == "strategic-native-unique-pal-actor-already-unbound")

local anchor = Definitions.cityAnchors[1]
local loaded = production:ingest({
    eventKind = "city-loaded",
    eventId = "spec.production.city.loaded",
    operationId = "spec.production.city.loaded",
    bindingId = anchor.bindingId,
    actorKey = anchor.actorKey,
    actorClassKey = anchor.actorClassKey,
})
assert(loaded.ok and loaded.reason == "city-native-state-ready")
assert(loaded.desiredState.loaded == true)

assert(bus:unbind_world().ok)
assert(bus:status().bindingCount == 0)
assert(production:activate(Definitions).ok)
assert(bus:status().bindingCountByKind["city-anchor"] == 5)
local status = production:status()
assert(status.exactIndividualBindingRequired == true)
assert(status.broadActorScan == false)
assert(status.PalworldSaveMutation == false)

print("PASS strategic native production registers all event capabilities, binds exact city anchors and live unique-Pal actors, gates Boss HP, and rebinds per world")
