package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local FactionApi = require("pwft.faction_api")
local FactionProgression = require("pwft.faction_progression")
local HostileCommerceLiveTest =
    require("pwft.hostile_commerce_live_test")
local Registry = require("pwft.registry")

local notifications = {}
local progression = FactionProgression.create(Registry.progression)
local api = FactionApi.create(progression, function(
    faction_id,
    outcome,
    status
)
    table.insert(notifications, {
        factionId = faction_id,
        reason = outcome.reason,
        relation = status.relation,
    })
end)
local qa = HostileCommerceLiveTest.create({
    enabled = true,
    key = "F2",
    joinFactionId = "pwft.faction.free_pal_alliance",
    targetFactionId = "pwft.faction.rayne_syndicate",
    contentId = "pwft.qa.hostile-commerce-live-test",
}, api)

local before = qa:status()
assert(before.targetRelation == "Friendly")
assert(before.targetReputation == 0)
assert(before.directReputationWrites == false)
assert(before.nativeTransactionsRequired == true)

local activated = qa:activate()
assert(activated.ok == true)
assert(activated.reason == "hostile-commerce-live-test-ready")
assert(activated.joinOutcome.reason == "joined")
assert(activated.beforeRelation == "Friendly")
assert(activated.afterRelation == "Hostile")
assert(activated.targetReputation == 0)
assert(activated.directReputationWrites == false)
assert(activated.nativeTransactionsRequired == true)
assert(#notifications == 1)
assert(notifications[1].factionId
    == "pwft.faction.free_pal_alliance")

local repeated = qa:activate()
assert(repeated.ok == true)
assert(repeated.joinOutcome.reason == "already-joined")
assert(repeated.afterRelation == "Hostile")
assert(#notifications == 1)
assert(qa:status().activationCount == 2)

local invalid = pcall(function()
    HostileCommerceLiveTest.create({
        enabled = false,
        key = "F2",
        joinFactionId = "pwft.faction.free_pal_alliance",
        targetFactionId = "pwft.faction.rayne_syndicate",
        contentId = "pwft.qa.hostile-commerce-live-test",
    }, api)
end)
assert(invalid == false)

print("PASS hostile commerce live-test uses real faction join and native-only recovery")
