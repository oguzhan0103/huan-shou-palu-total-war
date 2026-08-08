package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")

local rayne = "pwft.faction.rayne_syndicate"
local pidf = "pwft.faction.pidf"
local player = { kind = "player", id = "ending-test-player" }

local strategic_pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "sample.ending.world",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "sample.unique.crown",
            speciesId = "SampleCrownPal",
            displayNameKey = "sample.loc.unique.crown.name",
            initialOwner = { kind = "wild" },
        },
    },
    cities = {
        {
            id = "sample.city.capital",
            factionId = rayne,
            displayNameKey = "sample.loc.city.capital.name",
            requiredUniquePalId = "sample.unique.crown",
            restorable = true,
        },
    },
}

local ending_pack = {
    schemaVersion = "pwft.ending-routes.pack.v1",
    contentPackId = "sample.ending.routes",
    contentVersion = "1.0.0",
    routes = {
        {
            id = "pwft.ending.destroyer",
            displayNameKey = "sample.loc.ending.destroyer.name",
            priority = 10,
            conditions = {
                { kind = "flag_equals", key = "sample.flag.destroyer-ready", value = true },
            },
            effects = {
                { kind = "set_title", titleKey = "sample.loc.title.destroyer" },
                { kind = "set_world_disposition", value = "hostile" },
                { kind = "city_transition", cityId = "sample.city.capital", status = "destroyed" },
            },
        },
        {
            id = "pwft.ending.invader",
            displayNameKey = "sample.loc.ending.invader.name",
            priority = 20,
            conditions = {
                { kind = "flag_equals", key = "sample.flag.invader-ready", value = true },
            },
            effects = {
                { kind = "set_title", titleKey = "sample.loc.title.invader" },
                { kind = "set_world_disposition", value = "conditional" },
                {
                    kind = "city_transition",
                    cityId = "sample.city.capital",
                    status = "occupied",
                    ownerFactionId = pidf,
                },
            },
        },
        {
            id = "pwft.ending.conqueror",
            displayNameKey = "sample.loc.ending.conqueror.name",
            priority = 100,
            conditions = {
                {
                    kind = "city_status",
                    cityIds = { "sample.city.capital" },
                    allowedStatuses = { "active", "occupied" },
                },
                {
                    kind = "faction_survival",
                    factionIds = { rayne },
                    expected = true,
                },
                {
                    kind = "unique_pal_owner",
                    uniquePalIds = { "sample.unique.crown" },
                    ownerKind = "player",
                    ownerId = "ending-test-player",
                },
                { kind = "flag_equals", key = "sample.flag.final-challenge-won", value = true },
            },
            effects = {
                { kind = "set_title", titleKey = "sample.loc.title.conqueror" },
                { kind = "set_world_disposition", value = "pacified" },
                { kind = "set_flag", key = "sample.flag.postgame-open", value = true },
                {
                    kind = "set_faction_disposition",
                    factionId = rayne,
                    value = "non_hostile_until_attacked",
                },
                {
                    kind = "city_transition",
                    cityId = "sample.city.capital",
                    status = "active",
                    ownerFactionId = rayne,
                },
            },
        },
    },
}

local progression = Progression.create(Registry.progression)
local world = StrategicWorld.create(progression)
assert(world:register_pack(strategic_pack).ok)
local endings = EndingRuntime.create(progression, world)
assert(endings.version == "1.0.0")
assert(endings.capabilities.modelMayCommitEnding == false)

local invalid_pack = {
    schemaVersion = ending_pack.schemaVersion,
    contentPackId = "sample.ending.invalid",
    contentVersion = "1.0.0",
    routes = {
        {
            id = "sample.ending.invalid",
            displayNameKey = "这不是本地化键",
            conditions = { { kind = "flag_equals", key = "sample.flag.x", value = true } },
            effects = { { kind = "set_world_disposition", value = "pacified" } },
        },
    },
}
assert(endings:register_pack(invalid_pack).reason == "invalid-ending-pack")
assert(endings:status().contentPackCount == 0)

local registered = endings:register_pack(ending_pack)
assert(registered.ok and registered.routeCount == 3)
assert(endings:register_pack(ending_pack).reason == "ending-pack-already-registered")
local silent_ending_edit = {}
for key, value in pairs(ending_pack) do silent_ending_edit[key] = value end
silent_ending_edit.routes = {
    ending_pack.routes[1],
    ending_pack.routes[2],
    {
        id = ending_pack.routes[3].id,
        displayNameKey = ending_pack.routes[3].displayNameKey,
        priority = 999,
        conditions = ending_pack.routes[3].conditions,
        effects = ending_pack.routes[3].effects,
    },
}
assert(endings:register_pack(silent_ending_edit).reason == "ending-pack-version-content-mismatch")
assert(endings:status().routeCount == 3)
local available = endings:available_routes()
assert(available[1].id == "pwft.ending.conqueror" and available[1].priority == 100)

local locked = endings:evaluate("pwft.ending.conqueror")
assert(locked.ok and not locked.ready and locked.reason == "ending-route-locked")
assert(#locked.checks == 4)

assert(world:transfer_unique_pal(
    "sample.unique.crown",
    { kind = "wild" },
    player,
    "ending-claim-crown"
).ok)
assert(endings:set_flag(
    "sample.flag.final-challenge-won",
    true,
    "ending-final-challenge"
).ok)
assert(endings:set_flag(
    "sample.flag.final-challenge-won",
    true,
    "ending-final-challenge"
).reason == "duplicate-operation")

local ready = endings:evaluate("pwft.ending.conqueror")
assert(ready.ready and ready.reason == "ending-route-ready")

-- No external content or model can bypass the ending authority boundary.
local unauthorized = pcall(function()
    world:apply_ending_transition(
        "sample.city.capital",
        { status = "destroyed" },
        "unauthorized-ending-transition",
        { authority = "model-output", routeId = "fake" }
    )
end)
assert(not unauthorized)

local completed = endings:commit("pwft.ending.conqueror", "ending-commit-conqueror")
assert(completed.ok and completed.reason == "ending-committed")
assert(#completed.effects == 5)
assert(world:city_status("sample.city.capital").status == "active")
local post = endings:post_ending_policy()
assert(post.completed and post.completedRouteId == "pwft.ending.conqueror")
assert(post.titleKey == "sample.loc.title.conqueror")
assert(post.worldDisposition == "pacified")
assert(post.ordinaryActorsNonHostileUntilAttacked == true)
assert(post.factionDispositionById[rayne] == "non_hostile_until_attacked")
assert(endings.state.flags["sample.flag.postgame-open"] == true)
assert(endings:commit("pwft.ending.conqueror", "ending-commit-conqueror").reason == "duplicate-operation")
assert(endings:commit("pwft.ending.destroyer", "ending-commit-destroyer").reason == "ending-already-committed")

-- All world/ending state is part of the same Mod-owned progression snapshot.
local snapshot = progression:export_snapshot()
local progression_restored = Progression.create(Registry.progression, snapshot)
local world_restored = StrategicWorld.create(progression_restored)
assert(world_restored:register_pack(strategic_pack).ok)
local endings_restored = EndingRuntime.create(progression_restored, world_restored)
assert(endings_restored:register_pack(ending_pack).ok)
assert(endings_restored:post_ending_policy().completedRouteId == "pwft.ending.conqueror")
assert(endings_restored:status().storyContentIncluded == false)

print("PWFT ending runtime specification: PASS")
