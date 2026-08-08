package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Policy = require("pwft.policy")

assert(Registry.counts.factions == 12)
assert(Registry.counts.regions == 22)
assert(Registry.counts.islands == 7)
assert(Registry.counts.nativeWatchtowers == 24)
assert(Registry.counts.mappedNativePlaceNames == 82)

local latest = Policy.latest_relations({
    { factionId = "pwft.faction.rayne_syndicate", state = "Hostile", revision = 1 },
    { factionId = "pwft.faction.rayne_syndicate", state = "Friendly", revision = 2 },
    { factionId = "pwft.faction.rayne_syndicate", state = "Hostile", revision = 1 },
    { factionId = "pwft.faction.dark_nocturnal_pal_tribe", state = "Hostile", revision = 1 },
})

local rayne = Registry.islands["pwft.island.central_southeast_archipelago"]
assert(Policy.resolve_relation(rayne, latest, false) == "Friendly")

-- The native place-name index resolves to the same presentation object used
-- by the territory map.  These two checks cover a real extracted row key and
-- an isolated synthetic key used only by this policy unit test.
local extracted_place_presentation = Policy.resolve_region_name_presentation(
    Registry,
    "Grass_001",
    latest,
    false
)
assert(extracted_place_presentation.islandId == rayne.id)
assert(extracted_place_presentation.color == "#4D86D9")
Registry.regionNameIdToIsland["PWFT_TestRegion"] = rayne.id
local place_presentation = Policy.resolve_region_name_presentation(
    Registry,
    "PWFT_TestRegion",
    latest,
    false
)
assert(place_presentation.islandId == rayne.id)
assert(place_presentation.relation == "Friendly")
assert(place_presentation.color == "#4D86D9")
assert(Policy.resolve_region_name_presentation(Registry, "PWFT_Unmapped", latest, false) == nil)

local original = Policy.resolve_overlay(Registry, rayne, "Original", true, latest, false)
assert(original.visible == false)
assert(original.preserveNativeFog == true)

latest["pwft.faction.rayne_syndicate"] = {
    factionId = "pwft.faction.rayne_syndicate",
    state = "Hostile",
    revision = 3,
}
local hostile = Policy.resolve_overlay(Registry, rayne, "Human", true, latest, false)
assert(hostile.visible == true)
assert(hostile.relation == "Hostile")
assert(hostile.color == "#D34A4A")

local pal_hostile = Policy.resolve_overlay(Registry, rayne, "Pal", true, latest, false)
assert(pal_hostile.visible == true)
assert(pal_hostile.relation == "Hostile")

local sakurajima = Registry.islands["pwft.island.sakurajima"]
local unowned_pal_layer = Policy.resolve_overlay(Registry, sakurajima, "Pal", true, latest, false)
assert(unowned_pal_layer.visible == false)

local locked = Policy.resolve_overlay(Registry, rayne, "Human", false, latest, false)
assert(locked.visible == false)
assert(locked.color == "#6B7078")

local hostile_travel = Policy.can_use_public_fast_travel(rayne, true, latest, false)
assert(hostile_travel.allowed == false)
assert(hostile_travel.reasonCode == "hostile_territory")

latest["pwft.faction.rayne_syndicate"] = {
    factionId = "pwft.faction.rayne_syndicate",
    state = "Player",
    revision = 4,
}
local player_owned = Policy.resolve_overlay(Registry, rayne, "Human", true, latest, false)
assert(player_owned.visible == true)
assert(player_owned.relation == "Player")
assert(player_owned.color == "#4FAF68")

print("PASS Lua policy (island layers, colors, fog, fast travel)")
