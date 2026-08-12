package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionDefense = require("pwft.faction_defense")
local FactionProgression = require("pwft.faction_progression")
local HumanDefenseResultBridge =
    require("pwft.human_defense_result_bridge")

local rayne = "pwft.faction.rayne_syndicate"
local pal_faction = "pwft.faction.desert_pal_tribe"
local snapshot = FactionProgression.create(
    Registry.progression
):export_snapshot()
snapshot.factions[rayne].reputation = -20
local progression = FactionProgression.create(
    Registry.progression,
    snapshot
)
local api = FactionApi.create(progression)
local defense = FactionDefense.create(api)
local bridge = HumanDefenseResultBridge.create(defense, {
    authoritySource = "spec.authoritative-human-defense.v1",
    reputationAward = 50,
})

local function envelope(event_id, resolution_id, participated, won)
    return {
        schemaVersion = "1.0.0",
        routeKind = "human-settlement-defense",
        authoritative = true,
        authoritySource = "spec.authoritative-human-defense.v1",
        eventId = event_id,
        resolutionId = resolution_id,
        factionId = rayne,
        settlementId = "pwft.settlement.small_settlement",
        playerParticipated = participated,
        playerSideWon = won,
    }
end

local open = bridge:open(envelope(
    "human-defense.event.hostile",
    "unused-open-resolution",
    true,
    true
))
assert(open.ok and open.reason == "human-defense-event-opened")
assert(open.hostileAtStart == true)
assert(open.temporaryTruce == true)
assert(bridge:open(envelope(
    "human-defense.event.hostile",
    "another-unused-resolution",
    true,
    true
)).reason == "human-defense-event-already-open")

local settled_input = envelope(
    "human-defense.event.hostile",
    "human-defense.result.hostile",
    true,
    true
)
local settled = bridge:settle(settled_input)
assert(settled.ok)
assert(settled.reason == "human-defense-reputation-awarded")
assert(settled.applied == 50)
assert(settled.credited == true)
assert(settled.temporaryTruceEnded == true)
assert(settled.palTokenAwarded == false)
assert(api:faction_status(rayne).reputation == 30)
assert(api:faction_status(rayne).relation == "Friendly")

local duplicate = bridge:settle(settled_input)
assert(duplicate.ok)
assert(duplicate.reason == "duplicate-human-defense-result")
assert(duplicate.duplicateOfReason
    == "human-defense-reputation-awarded")
assert(duplicate.applied == 0)
assert(api:faction_status(rayne).reputation == 30)

local absence_before = api:faction_status(rayne).reputation
local absence = bridge:settle(envelope(
    "human-defense.event.absent",
    "human-defense.result.absent",
    false,
    true
))
assert(absence.ok)
assert(absence.reason == "human-defense-no-player-participation")
assert(absence.applied == 0 and absence.credited == false)
assert(api:faction_status(rayne).reputation == absence_before)

local failure = bridge:settle(envelope(
    "human-defense.event.failed",
    "human-defense.result.failed",
    true,
    false
))
assert(failure.ok)
assert(failure.reason == "human-defense-failed-no-award")
assert(failure.applied == 0 and failure.credited == false)
assert(api:faction_status(rayne).reputation == absence_before)

local unauthorized = envelope(
    "human-defense.event.unauthorized",
    "human-defense.result.unauthorized",
    true,
    true
)
unauthorized.authoritative = false
local unauthorized_result = bridge:settle(unauthorized)
assert(unauthorized_result.ok == false)
assert(unauthorized_result.reason == "invalid-human-defense-result")
assert(unauthorized_result.applied == 0)

local pal_route = envelope(
    "human-defense.event.pal",
    "human-defense.result.pal",
    true,
    true
)
pal_route.factionId = pal_faction
local pal_result = bridge:settle(pal_route)
assert(pal_result.ok == false)
assert(pal_result.reason == "human-defense-only")
assert(pal_result.applied == 0)
assert(pal_result.palTokenAwarded == false)

local token_request = envelope(
    "human-defense.event.token",
    "human-defense.result.token",
    true,
    true
)
token_request.palTokenAwardRequested = true
local token_result = bridge:settle(token_request)
assert(token_result.ok == false)
assert(token_result.reason == "invalid-human-defense-result")
assert(token_result.palTokenAwarded == false)

local conflict = envelope(
    "human-defense.event.absent",
    "human-defense.result.conflict",
    false,
    true
)
local conflict_result = bridge:settle(conflict)
assert(conflict_result.ok == false)
assert(conflict_result.reason == "human-defense-event-result-conflict")

-- A new bridge instance has lost its in-memory result cache, but the
-- progression event ID remains authoritative and prevents a second award.
local replay_bridge = HumanDefenseResultBridge.create(
    FactionDefense.create(api),
    {
        authoritySource = "spec.authoritative-human-defense.v1",
        reputationAward = 50,
    }
)
local replay = replay_bridge:settle(settled_input)
assert(replay.ok)
assert(replay.reason == "persisted-human-defense-result-already-applied")
assert(replay.defenseReason == "duplicate-event")
assert(replay.applied == 0 and replay.idempotent == true)
assert(api:faction_status(rayne).reputation == absence_before)

local pal_after = api:faction_status(pal_faction)
assert(pal_after.reputation == snapshot.factions[pal_faction].reputation)
local status = bridge:status()
assert(status.awardedCount == 1)
assert(status.zeroAwardCount == 2)
assert(status.duplicateCount == 1)
assert(status.PalTokenAuthority == false)
assert(status.PalworldSaveMutation == false)

print("PASS authoritative human defense results award only participated victories, remain idempotent, and never mint Pal tokens")
