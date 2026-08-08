package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")

local rayne = "pwft.faction.rayne_syndicate"
local pidf = "pwft.faction.pidf"
local player = { kind = "player", id = "test-player" }
local rayne_owner = { kind = "faction", id = rayne }

local pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "sample.strategic.foundation",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "sample.unique.wild_dragon",
            speciesId = "SampleWildDragon",
            displayNameKey = "sample.loc.unique.wild_dragon.name",
            initialOwner = { kind = "wild" },
        },
        {
            id = "sample.unique.guardian",
            speciesId = "SampleGuardian",
            displayNameKey = "sample.text.unique.guardian.name",
            initialOwner = rayne_owner,
        },
    },
    cities = {
        {
            id = "sample.city.rayne",
            factionId = rayne,
            displayNameKey = "sample.loc.city.rayne.name",
            requiredUniquePalId = "sample.unique.wild_dragon",
            restorable = true,
        },
        {
            id = "sample.city.pidf",
            factionId = pidf,
            displayNameKey = "sample.text.city.pidf.name",
            requiredUniquePalId = "sample.unique.guardian",
        },
    },
}

local progression = Progression.create(Registry.progression)
local notifications = {}
local world = StrategicWorld.create(progression, {
    onChange = function(_, event)
        table.insert(notifications, event.type)
    end,
})

assert(world.version == "1.0.0")
assert(world.capabilities.singleOwnerUniquePals)
assert(world.capabilities.bossOneHpProtection)
assert(world:status().contentPackCount == 0)

-- Invalid text and conflicting definitions fail before any state is committed.
local invalid = {
    schemaVersion = pack.schemaVersion,
    contentPackId = "sample.invalid",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "sample.unique.invalid",
            speciesId = "Invalid",
            displayNameKey = "这是内联剧情文本",
            initialOwner = { kind = "wild" },
        },
    },
    cities = {},
}
local invalid_result = world:register_pack(invalid)
assert(not invalid_result.ok and invalid_result.reason == "invalid-content-pack")
assert(world:status().contentPackCount == 0)

local registered = world:register_pack(pack)
assert(registered.ok and registered.reason == "content-pack-registered")
assert(registered.uniquePalCount == 2 and registered.cityCount == 2)
assert(world:status().contentPackCount == 1)
assert(world:status().storyContentIncluded == false)
assert(world:register_pack(pack).reason == "content-pack-already-registered")
local silent_edit = {}
for key, value in pairs(pack) do silent_edit[key] = value end
silent_edit.uniquePals = {
    pack.uniquePals[1],
    {
        id = pack.uniquePals[2].id,
        speciesId = "ChangedWithoutVersionBump",
        displayNameKey = pack.uniquePals[2].displayNameKey,
        initialOwner = pack.uniquePals[2].initialOwner,
    },
}
assert(world:register_pack(silent_edit).reason == "content-pack-version-content-mismatch")

local changed_version = {}
for key, value in pairs(pack) do changed_version[key] = value end
changed_version.contentVersion = "1.1.0"
assert(world:register_pack(changed_version).reason == "content-pack-migration-required")

-- A lethal hit is clamped to one health until the actor controls the mapped
-- unique Pal. Merely owning a different strategic Pal is insufficient.
local protected = world:boss_health_gate("sample.city.rayne", player, 0)
assert(protected.ok and protected.reason == "boss-one-hp-protection-applied")
assert(protected.appliedHealth == 1 and protected.destructionAuthorized == false)
assert(world:destroy_city("sample.city.rayne", player, "destroy-before-pal").reason
    == "required-unique-pal-not-controlled")

local transfer = world:transfer_unique_pal(
    "sample.unique.wild_dragon",
    { kind = "wild" },
    player,
    "claim-wild-dragon",
    { reason = "sample-diplomacy-resolution" }
)
assert(transfer.ok and transfer.reason == "unique-pal-transferred")
assert(world:transfer_unique_pal(
    "sample.unique.wild_dragon",
    { kind = "wild" },
    rayne_owner,
    "stale-owner-transfer"
).reason == "unique-pal-owner-conflict")
local duplicate_transfer = world:transfer_unique_pal(
    "sample.unique.wild_dragon",
    { kind = "wild" },
    player,
    "claim-wild-dragon"
)
assert(duplicate_transfer.ok and duplicate_transfer.reason == "duplicate-operation")

local lethal = world:boss_health_gate("sample.city.rayne", player, 0)
assert(lethal.appliedHealth == 0 and lethal.destructionAuthorized == true)
local destroyed = world:destroy_city(
    "sample.city.rayne",
    player,
    "destroy-rayne",
    { sourceId = "sample.quest.final-assault" }
)
assert(destroyed.ok and destroyed.reason == "city-destroyed")
assert(world:city_status("sample.city.rayne").status == "destroyed")
assert(world:faction_status(rayne).destroyed == 1)
assert(world:occupy_city("sample.city.rayne", pidf, "occupy-destroyed").reason == "city-already-destroyed")

local restored = world:restore_city(
    "sample.city.rayne",
    rayne,
    "restore-rayne",
    { sourceId = "sample.ending.restoration" }
)
assert(restored.ok and restored.reason == "city-restored")
assert(world:city_status("sample.city.rayne").status == "active")
assert(world:preserve_city("sample.city.rayne", "preserve-rayne").ok)
assert(world:city_status("sample.city.rayne").preservationCount == 1)

local occupied = world:occupy_city("sample.city.rayne", pidf, "occupy-rayne")
assert(occupied.ok and occupied.reason == "city-occupied")
assert(world:city_status("sample.city.rayne").ownerFactionId == pidf)
assert(world:faction_status(rayne).occupied == 1)
assert(world:restore_city("sample.city.pidf", pidf, "restore-non-restorable").reason == "city-restoration-not-allowed-by-content")

local issued = world:issue_ultimatum(
    "sample.ultimatum.tribute-1",
    rayne,
    "player:test-player",
    { kind = "tribute", resourceId = "Gold", amount = 1000 },
    "issue-ultimatum-1"
)
assert(issued.ok and issued.reason == "ultimatum-issued")
local rejected = world:resolve_ultimatum(
    "sample.ultimatum.tribute-1",
    false,
    "resolve-ultimatum-1",
    { nextEventKey = "sample.event.war-threat" }
)
assert(rejected.ok and rejected.reason == "ultimatum-rejected")
assert(world:resolve_ultimatum(
    "sample.ultimatum.tribute-1",
    true,
    "resolve-ultimatum-2"
).reason == "ultimatum-already-resolved")

-- The world slice lives under the progression snapshot. A new runtime can
-- attach the same content definitions without resetting ownership or cities.
local snapshot = progression:export_snapshot()
local restored_progression = Progression.create(Registry.progression, snapshot)
local restored_world = StrategicWorld.create(restored_progression)
assert(restored_world:register_pack(pack).reason == "content-pack-already-registered")
assert(restored_world:unique_pal_status("sample.unique.wild_dragon").owner.kind == "player")
assert(restored_world:city_status("sample.city.rayne").status == "occupied")
assert(restored_world:status().ultimatumCount == 1)
assert(#notifications >= 7)

print("PWFT strategic world specification: PASS")
