package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Presence = require("pwft.faction_economy_merchant_presence")

local active = 0
local pending = 0
local activations = 0
local deactivations = 0
local last_root = nil
local last_rotation = nil
local runtime = {
    status = function()
        return { activeCount = active, pendingCount = pending }
    end,
    activate_market = function(_, root, rotation)
        activations = activations + 1
        last_root = root
        last_rotation = rotation
        pending = 7
        return { ok = true, reason = "economy-market-activation-queued" }
    end,
    deactivate_market = function(_, reason)
        deactivations = deactivations + 1
        active = 0
        pending = 0
        return {
            ok = true,
            reason = "economy-market-deactivated",
            sourceReason = reason,
        }
    end,
}

local contract = {
    merchantIsland = {
        rootLocation = { X = 1000, Y = 2000, Z = 3000 },
        rootRotation = { Pitch = 0, Yaw = 235.46, Roll = 0 },
    },
}
local presence = Presence.create(runtime, contract, {
    enabled = true,
    activationRadius = 10000,
    deactivationRadius = 14000,
    pollIntervalMs = 2000,
})

local world = presence:on_world_loaded("spec")
assert(world.ok == true)
assert(world.generation == 1)
assert(deactivations == 1)

local rebased = presence:set_live_root(
    { X = 5000, Y = 6000, Z = 7000 },
    { Pitch = 0, Yaw = 90, Roll = 0 },
    "FTPoint90"
)
assert(rebased.ok == true)
assert(presence:status().liveRootSource == "FTPoint90")

local far = presence:tick({ X = 30000, Y = 6000, Z = 7000 })
assert(far.reason == "merchant-market-out-of-range")
assert(activations == 0)

local entered = presence:tick({ X = 5500, Y = 6000, Z = 7000 })
assert(entered.ok == true)
assert(entered.transitioned == true)
assert(activations == 1)
assert(last_root.X == 5000 and last_root.Y == 6000 and last_root.Z == 7000)
assert(last_rotation.Yaw == 90)

local duplicate = presence:tick({ X = 5500, Y = 6000, Z = 7000 })
assert(duplicate.reason == "merchant-market-already-present")
assert(duplicate.transitioned == false)
assert(activations == 1)

pending = 0
active = 7
local hysteresis = presence:tick({ X = 17500, Y = 6000, Z = 7000 })
assert(hysteresis.reason == "merchant-market-retained")
assert(deactivations == 1)

local departed = presence:tick({ X = 20000, Y = 6000, Z = 7000 })
assert(departed.ok == true)
assert(departed.transitioned == true)
assert(deactivations == 2)

active = 7
local reload = presence:on_world_loaded("second-world")
assert(reload.generation == 2)
assert(deactivations == 3)
assert(presence:status().liveRootSource == nil)
assert(presence.rootLocation.X == 1000)
assert(presence.rootLocation.Y == 2000)
assert(presence.rootLocation.Z == 3000)
assert(presence.rootRotation.Yaw == 235.46)
assert(presence:status().activeCount == 0)
assert(presence:status().activationAttemptCount == 1)
assert(presence:status().deactivationAttemptCount == 3)
assert(presence:status().tickCount == 5)

active = 7
local unloading = presence:on_world_unloading("third-world")
assert(unloading.ok == true)
assert(unloading.generation == 3)
assert(deactivations == 4)
assert(presence:status().lastReason == "world-unloading")
assert(presence:status().deactivationAttemptCount == 4)

print("faction_economy_merchant_presence_spec: ok")
