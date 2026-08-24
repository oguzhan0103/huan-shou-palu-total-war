package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Config = require("pwft.config")
local WorldBalance = require("pwft.world_balance")
local Mask = WorldBalance.islandMask

assert(Config.worldBalance.enabled == true)
assert(Config.worldBalance.targetLevel == 80)
assert(Config.worldBalance.levelOverride.enabled == false)
assert(Config.worldBalance.liveAudit.enabled == false)
assert(Config.worldBalance.liveAudit.bossProbe.enabled == false)
assert(Config.worldBalance.liveAudit.bossProbe.characterId == "Boss_Anubis")
assert(Config.worldBalance.liveAudit.bossProbe.saveWrites == false)
assert(Config.worldBalance.palFactionRage.enabled == false)
assert(Config.worldBalance.palFactionRage.makeUncapturable == true)
assert(Config.worldBalance.palFactionRage.hpMultiplier == 2.0)
assert(Config.worldBalance.palFactionRage.damageMultiplier == 2.0)
assert(Config.worldBalance.palFactionRage.liveAudit.enabled == false)
assert(Config.worldBalance.palFactionRage.liveAudit.probe.enabled == false)
assert(Config.worldBalance.palFactionRage.liveAudit.probe.key == "F7")
assert(Config.worldBalance.palFactionRage.liveAudit.probe.characterId == "PinkCat")
assert(Config.worldBalance.palFactionRage.liveAudit.probe.spawnLevel == 80)
assert(#Config.worldBalance.palFactionRage.liveAudit.probe.observeDelaysMs == 2)
assert(Config.worldBalance.palFactionRage.liveAudit.probe.saveWrites == false)
assert(Config.worldBalance.loadedActorReconcile.enabled == false)
assert(#Config.worldBalance.loadedActorReconcile.delaysMs == 2)
assert(WorldBalance.has_enabled_feature(Config.worldBalance) == false)

local level_only = {
    enabled = true,
    targetLevel = 80,
    levelOverride = { enabled = true },
    palFactionRage = {
        enabled = false,
        makeUncapturable = true,
        hpMultiplier = 2.0,
        damageMultiplier = 2.0,
    },
    loadedActorReconcile = { enabled = false, delaysMs = { 5000, 15000 } },
}
assert(WorldBalance.has_enabled_feature(level_only) == true)
level_only.levelOverride.enabled = false
level_only.palFactionRage.enabled = true
assert(WorldBalance.has_enabled_feature(level_only) == true)

local rage = Config.worldBalance.palFactionRage
local target_state = {
    island = "pwft.island.desert",
    isPal = true,
    isPredator = true,
    hpRate = 2.0,
    damageRate = 2.0,
    spawnedType = 8,
    uncapturable = true,
}
assert(WorldBalance.rage_state_is_verified(target_state, rage) == true)
target_state.uncapturable = false
assert(WorldBalance.rage_state_is_verified(target_state, rage) == false)
target_state.uncapturable = true
target_state.spawnedType = 0
assert(WorldBalance.rage_state_is_verified(target_state, rage) == false)

local control_state = {
    island = nil,
    isPal = true,
    isPredator = false,
    hpRate = 1.0,
    damageRate = 1.0,
    spawnedType = 0,
    uncapturable = false,
}
assert(WorldBalance.rage_probe_control_is_unchanged(control_state) == true)
control_state.isPredator = true
assert(WorldBalance.rage_probe_control_is_unchanged(control_state) == false)
control_state.isPredator = false
control_state.hpRate = 2.0
assert(WorldBalance.rage_probe_control_is_unchanged(control_state) == false)

-- B1 level management is deliberately broader than B2 rage targeting:
-- ordinary wild Pals are group 0 during native initialization, while groups
-- 3/4 remain protected player-guild representations.
assert(WorldBalance.level_group_is_world_managed(0) == true)
assert(WorldBalance.level_group_is_world_managed(1) == true)
assert(WorldBalance.level_group_is_world_managed(2) == true)
assert(WorldBalance.level_group_is_world_managed(5) == true)
assert(WorldBalance.level_group_is_world_managed(6) == true)
assert(WorldBalance.level_group_is_world_managed(3) == false)
assert(WorldBalance.level_group_is_world_managed(4) == false)
assert(WorldBalance.level_group_is_world_managed(nil) == false)

local empty_owner = { A = 0, B = 0, C = 0, D = 0 }
local assigned_owner = { A = 0, B = 0, C = 7, D = 0 }
assert(WorldBalance.guid_has_nonzero_parts(empty_owner) == false)
assert(WorldBalance.guid_has_nonzero_parts(assigned_owner) == true)
assert(WorldBalance.guid_has_nonzero_parts({ A = 0, B = 0 }) == nil)
assert(WorldBalance.guid_has_nonzero_parts(nil) == nil)

local eligible, reason =
    WorldBalance.rage_group_is_world_enemy(0, false)
assert(eligible == true)
assert(reason == "world-ungrouped-owner-empty")
eligible, reason = WorldBalance.rage_group_is_world_enemy(0, true)
assert(eligible == false)
assert(reason == "save-owner-assigned")
eligible, reason = WorldBalance.rage_group_is_world_enemy(0, nil)
assert(eligible == false)
assert(reason == "owner-state-unavailable")
assert(WorldBalance.rage_group_is_world_enemy(1, false) == true)
assert(WorldBalance.rage_group_is_world_enemy(5, nil) == true)
assert(WorldBalance.rage_group_is_world_enemy(6, nil) == true)
assert(WorldBalance.rage_group_is_world_enemy(3, false) == false)
assert(WorldBalance.rage_group_is_world_enemy(4, false) == false)

assert(Mask.textureSize == 1024)
assert(#Mask.islands == 5)

local expected_pixels = {
    ["pwft.island.central_southeast_archipelago"] = 19317,
    ["pwft.island.desert"] = 37958,
    ["pwft.island.snow"] = 28779,
    ["pwft.island.volcano"] = 32788,
    ["pwft.island.feybreak"] = 57830,
}

local total_pixels = 0
for _, island in ipairs(Mask.islands) do
    assert(expected_pixels[island.id] == island.pixelCount)
    assert(Mask.classify_pixel(island.sampleX, island.sampleY) == island.id)
    total_pixels = total_pixels + island.pixelCount
end
assert(total_pixels == 176672)
assert(Mask.classify_pixel(487, 592) == nil)

local sample = Mask.islands[1]
local projection = Mask.projection
local world_y = projection.minY
    + ((sample.sampleX + 0.5) / Mask.textureSize)
        * (projection.maxY - projection.minY)
local world_x = projection.minX
    + (1.0 - ((sample.sampleY + 0.5) / Mask.textureSize))
        * (projection.maxX - projection.minX)
assert(WorldBalance.classify_world(world_x, world_y) == sample.id)

print("PASS world balance contract (independent level/rage/reconcile gates, 5 Pal islands)")
