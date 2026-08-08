package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local FactionApi = require("pwft.faction_api")

local notifications = {}
local progression = Progression.create(Registry.progression)
local api = FactionApi.create(progression, function(faction_id, outcome, status)
    table.insert(notifications, {
        factionId = faction_id,
        reason = outcome.reason,
        reputation = status.reputation,
        relation = status.relation,
    })
end)

assert(api.version == "1.0.0")
assert(api.capabilities.multipleHumanMemberships == true)
assert(api.capabilities.humanFactionRelationMatrix == true)
assert(api.capabilities.affiliationDiplomacyRecovery == true)
assert(api.capabilities.automaticCommerceDiplomacyRecovery == true)
assert(api.capabilities.reputationDecrease == false)
assert(api.capabilities.PalMembership == false)
assert(api.capabilities.PalworldSaveMutation == false)

local rayne_id = "pwft.faction.rayne_syndicate"
assert(api:can_join(rayne_id) == true)
local joined = api:join_human(rayne_id, "sample.recruitment.rayne")
assert(joined.ok == true)
assert(joined.reason == "joined")
assert(#notifications == 1)
assert(notifications[1].relation == "Player")
local free_pal_id = "pwft.faction.free_pal_alliance"
assert(api:faction_relation(rayne_id, free_pal_id) == "Hostile")
assert(api:faction_status(free_pal_id).relation == "Hostile")
assert(api:can_join(free_pal_id) == false)
local recovered = api:clear_affiliation_hostility(
    free_pal_id,
    rayne_id,
    "sample.trade.free-pal.recovery.001"
)
assert(recovered.ok == true)
assert(recovered.reason == "diplomacy-hostility-cleared")
assert(api:faction_status(free_pal_id).relation == "Friendly")
assert(api:can_join(free_pal_id) == true)
assert(#notifications == 2)

local task = api:award_task(rayne_id, 250, "sample.task.rayne.001")
assert(task.ok == true)
assert(task.applied == 250)
assert(#notifications == 3)
local duplicate_task = api:award_task(rayne_id, 250, "sample.task.rayne.001")
assert(duplicate_task.ok == true)
assert(duplicate_task.reason == "duplicate-event")
assert(duplicate_task.applied == 0)
assert(#notifications == 3)

local commerce = api:award_commerce(
    rayne_id,
    100,
    "sample.trade.rayne.001",
    "sample.window.day-001"
)
assert(commerce.applied == 20)
assert(commerce.reason == "award-capped")
local duplicate_commerce = api:award_commerce(
    rayne_id,
    100,
    "sample.trade.rayne.001",
    "sample.window.day-001"
)
assert(duplicate_commerce.reason == "duplicate-event")
assert(duplicate_commerce.applied == 0)

local defense = api:award_defense(
    rayne_id,
    400,
    "sample.defense.small-settlement.001"
)
assert(defense.applied == 300)
assert(defense.reason == "award-capped")
assert(api:faction_status(rayne_id).reputation == 570)
assert(api:faction_status(rayne_id).rankId == "CoreMember")
assert(api:has_guard_access(rayne_id) == false)

assert(api:reconcile_pal(
    "pwft.faction.dark_nocturnal_pal_tribe",
    "sample.pal-reconciliation.dark.001"
).reason == "pal-discourse-service-required")

assert(pcall(function()
    api:award_task(rayne_id, 100, "")
end) == false)
assert(pcall(function()
    api:award_commerce(rayne_id, 1, "tx-without-window", "")
end) == false)

local snapshot = api:export_snapshot()
assert(snapshot.schemaVersion == "1.0.0")
assert(snapshot.factions[rayne_id].reputation == 570)
assert(snapshot.processedEventIds["task:sample.task.rayne.001"] == true)
assert(snapshot.processedEventIds["commerce:sample.trade.rayne.001"] == true)
assert(snapshot.processedEventIds["defense:sample.defense.small-settlement.001"] == true)

print("PASS Lua faction API (content hooks, idempotency, caps, notifications)")
