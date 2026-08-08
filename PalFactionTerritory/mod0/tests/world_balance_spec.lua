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
assert(Config.worldBalance.palFactionRage.enabled == false)
assert(Config.worldBalance.palFactionRage.makeUncapturable == true)
assert(Config.worldBalance.palFactionRage.hpMultiplier == 2.0)
assert(Config.worldBalance.palFactionRage.damageMultiplier == 2.0)
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
