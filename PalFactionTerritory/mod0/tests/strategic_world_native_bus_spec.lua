package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "examples/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local StrategicWorldNativeBus =
    require("pwft.strategic_world_native_bus")
local Example = require("minimal-content-pack.pack")

local progression = Progression.create(Registry.progression)
local world = StrategicWorld.create(progression)
assert(world:register_pack(Example.strategicWorld).ok)
local bus = StrategicWorldNativeBus.create(world)

local provider = {
    providerId = "spec.native-strategic-provider.v1",
    authoritySource = "spec.native-strategic-authority.v1",
    allowedEventKinds = {
        "unique-pal-captured",
        "city-captured",
        "boss-damage",
        "boss-death",
        "city-loaded",
    },
}
assert(bus:register_provider(provider).ok)
assert(bus:register_provider(provider).reason
    == "native-strategic-provider-already-registered")

local unique_pal_id = Example.strategicWorld.uniquePals[1].id
local city_id = Example.strategicWorld.cities[1].id
local provider_id = provider.providerId
local authority_source = provider.authoritySource

local bindings = {
    {
        bindingId = "spec.binding.unique-pal",
        providerId = provider_id,
        bindingKind = "unique-pal",
        strategicId = unique_pal_id,
        actorKey = "PalIndividualCharacterHandle:spec-unique-pal-001",
        actorClassKey = "BP_ExampleUniquePal_C",
    },
    {
        bindingId = "spec.binding.city",
        providerId = provider_id,
        bindingKind = "city-anchor",
        strategicId = city_id,
        actorKey = "CityAnchor:spec-city-001",
    },
    {
        bindingId = "spec.binding.boss",
        providerId = provider_id,
        bindingKind = "city-boss",
        strategicId = city_id,
        actorKey = "PalIndividualCharacterHandle:spec-city-boss-001",
        actorClassKey = "BP_ExampleCityBoss_C",
    },
}
for _, binding in ipairs(bindings) do
    assert(bus:bind_actor(binding).ok)
end

local function event(kind, id, operation, binding, extra)
    local value = {
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = provider_id,
        authoritySource = authority_source,
        eventKind = kind,
        eventId = id,
        operationId = operation,
        bindingId = binding.bindingId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end

local player = { kind = "player", id = "spec-player" }
local boss_binding = bindings[3]
local protected = bus:ingest(event(
    "boss-damage",
    "spec.event.damage.protected",
    "spec.operation.damage.protected",
    boss_binding,
    { proposedHealth = 0, destructionActor = player }
))
assert(protected.ok)
assert(protected.reason == "boss-one-hp-protection-applied")
assert(protected.appliedHealth == 1)
assert(protected.stateChanged == false)

local blocked_death = bus:ingest(event(
    "boss-death",
    "spec.event.death.protected",
    "spec.operation.death.protected",
    boss_binding,
    { destructionActor = player }
))
assert(blocked_death.ok)
assert(blocked_death.reason == "boss-death-denied-one-hp-protection")
assert(blocked_death.appliedHealth == 1)
assert(blocked_death.cityDestroyed == false)
assert(world:city_status(city_id).status ~= "destroyed")

local pal_binding = bindings[1]
local transferred = bus:ingest(event(
    "unique-pal-captured",
    "spec.event.capture.unique-pal",
    "spec.operation.capture.unique-pal",
    pal_binding,
    { expectedOwner = { kind = "wild" }, newOwner = player }
))
assert(transferred.ok and transferred.reason == "unique-pal-transferred")
assert(transferred.stateChanged == true)

local accepted_damage = bus:ingest(event(
    "boss-damage",
    "spec.event.damage.authorized",
    "spec.operation.damage.authorized",
    boss_binding,
    { proposedHealth = 0, destructionActor = player }
))
assert(accepted_damage.ok)
assert(accepted_damage.reason == "boss-health-accepted")
assert(accepted_damage.appliedHealth == 0)

local destroyed = bus:ingest(event(
    "boss-death",
    "spec.event.death.authorized",
    "spec.operation.death.authorized",
    boss_binding,
    { destructionActor = player }
))
assert(destroyed.ok and destroyed.reason == "city-destroyed")
assert(destroyed.stateChanged == true)
assert(world:city_status(city_id).status == "destroyed")

local duplicate = bus:ingest(event(
    "boss-death",
    "spec.event.death.authorized",
    "spec.operation.death.authorized",
    boss_binding,
    { destructionActor = player }
))
assert(duplicate.ok)
assert(duplicate.reason == "duplicate-native-strategic-event")
assert(duplicate.duplicateOfReason == "city-destroyed")
assert(duplicate.stateChanged == false)

local wrong_actor = event(
    "city-loaded",
    "spec.event.city.wrong-actor",
    "spec.operation.city.wrong-actor",
    bindings[2]
)
wrong_actor.actorKey = "CityAnchor:some-other-city"
local wrong_actor_result = bus:ingest(wrong_actor)
assert(wrong_actor_result.ok == false)
assert(wrong_actor_result.reason == "invalid-native-strategic-event")

local forged = event(
    "city-loaded",
    "spec.event.city.forged",
    "spec.operation.city.forged",
    bindings[2]
)
forged.authoritySource = "forged-authority"
assert(bus:ingest(forged).reason == "invalid-native-strategic-event")

local conflict = event(
    "boss-damage",
    "spec.event.damage.operation-conflict",
    "spec.operation.capture.unique-pal",
    boss_binding,
    { proposedHealth = 1, destructionActor = player }
)
assert(bus:ingest(conflict).reason
    == "native-strategic-operation-id-conflict")

local loaded = bus:ingest(event(
    "city-loaded",
    "spec.event.city.loaded",
    "spec.operation.city.loaded",
    bindings[2]
))
assert(loaded.ok and loaded.reason == "city-native-state-ready")
assert(loaded.desiredState.destroyed == true)
assert(loaded.stateChanged == false)

local snapshot = bus:export_snapshot()
assert(snapshot.bindings == nil)
local restored = StrategicWorldNativeBus.create(world, {
    snapshot = snapshot,
})
assert(restored:status().providerCount == 1)
assert(restored:status().bindingCount == 0)
assert(restored:status().bindingsPersisted == false)
local before_rebind = restored:ingest(event(
    "city-loaded",
    "spec.event.city.after-restore",
    "spec.operation.city.after-restore",
    bindings[2]
))
assert(before_rebind.ok == false)
assert(before_rebind.reason == "invalid-native-strategic-event")
for _, binding in ipairs(bindings) do
    assert(restored:bind_actor(binding).ok)
end
local replay = restored:ingest(event(
    "unique-pal-captured",
    "spec.event.capture.unique-pal",
    "spec.operation.capture.unique-pal",
    pal_binding,
    { expectedOwner = { kind = "wild" }, newOwner = player }
))
assert(replay.ok)
assert(replay.reason == "duplicate-native-strategic-event")
assert(replay.stateChanged == false)

local unbound = restored:unbind_world()
assert(unbound.ok and unbound.removedBindingCount == 3)
assert(restored:status().bindingCount == 0)
assert(restored:status().serializableStateOnly == true)
assert(restored:status().PalworldSaveMutation == false)

print("PASS strategic native provider bus exact-binds actors, gates boss death at 1 HP, emits state changes, restores without UObjects, and fails closed")
