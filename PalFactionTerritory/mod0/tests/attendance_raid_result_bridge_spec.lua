package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalRaidResultAdapter = require("pwft.pal_raid_result_adapter")
local AttendanceRaidResultBridge =
    require("pwft.attendance_raid_result_bridge")

local progression = Progression.create(Registry.progression)
local reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression,
    {
        randomIndex = function()
            return 1
        end,
    }
)
local faction_id = "pwft.faction.dark_nocturnal_pal_tribe"
assert(reconciliation:register_content(faction_id, {
    contentPackId = "test.attendance.raid",
    contentVersion = "1.0.0",
    tokenQuota = 3,
    maximumAffinityPerDiscourse = 10,
}).ok)

local adapter = PalRaidResultAdapter.create(
    reconciliation,
    {
        normalizedRaidAdapterEnabled = true,
        nativeRaidResultBindingEnabled = true,
        attendanceRaidResultBindingEnabled = true,
        leaderDesignation = "first-spawn-of-final-wave",
    }
)
local logs = {}
local observed_results = {}
local observed_starts = {}
local observed_cancellations = {}
local bridge = AttendanceRaidResultBridge.create(
    adapter,
    {
        palFactionId = faction_id,
        nativeGroupName = "Invader_Group_Monster_Grade5_Basic",
        settlementId = "pwft.settlement.small_settlement",
        expectedAttackerCount = 4,
    },
    {
        actorKey = function(actor)
            return actor and actor.key or nil
        end,
        attributionResolver = function(attacker)
            if attacker and attacker.kind == "player" then
                return {
                    attackerKind = "local-player",
                    attackerMatchesLocalPlayer = true,
                    attributionAuthority =
                        "pal-player-controller-uid-v1",
                }
            end
            if attacker and attacker.kind == "owned-pal" then
                return {
                    attackerKind = "pal",
                    attackerIsPlayersOtomo = true,
                    trainerMatchesLocalPlayer = true,
                    attributionAuthority =
                        "pal-character-trainer-v1",
                }
            end
            return {
                attackerKind = "unresolved",
                attributionAuthority = "unresolved",
            }
        end,
        logger = function(message)
            table.insert(logs, message)
        end,
        resultObserver = function(value)
            observed_results[#observed_results + 1] = value
            return true, "observed"
        end,
        startObserver = function(value)
            observed_starts[#observed_starts + 1] = value
            return true, "opened"
        end,
        cancelObserver = function(value)
            observed_cancellations[#observed_cancellations + 1] = value
            return true, "cancelled"
        end,
    }
)

local actors = {
    { key = "attendance:leader" },
    { key = "attendance:member-2" },
    { key = "attendance:member-3" },
    { key = "attendance:member-4" },
}
local player = { key = "actor:local-player", kind = "player" }
local npc = { key = "actor:resident", kind = "resident" }

assert(bridge:begin(7, actors).ok)
assert(#observed_starts == 1)
assert(observed_starts[1].settlementId
    == "pwft.settlement.small_settlement")
local active = bridge:status()
assert(active.active and active.memberCount == 4)
assert(active.leaderActorKey == "attendance:leader")
local event = adapter:event_status(active.eventId)
assert(event.lifecycleKind == "attendance-native-actors")
assert(event.leaderActorKey == "attendance:leader")

-- Killing ordinary attackers establishes the victory state but cannot replace
-- the designated-leader participation requirement.
assert(bridge:record_death(actors[2], npc).ok)
assert(bridge:record_death(actors[3], player).ok)
assert(bridge:record_death(actors[4], npc).ok)
local settled = bridge:record_death(actors[1], player)
assert(settled.ok and settled.reason == "raid-event-settled")
assert(settled.event.allWavesCleared == true)
assert(settled.event.leaderKillCredited == true)
assert(settled.settlement.tokenAwarded == true)
assert(reconciliation:status(faction_id).tokensAwarded == 1)
assert(bridge:status().settlements == 1)
assert(settled.resultObserverOk == true)
assert(#observed_results == 1)
assert(observed_results[1].raidEventId == settled.event.raidEventId)
assert(observed_results[1].playerParticipated == true)
assert(observed_results[1].playerSideWon == true)
assert(observed_results[1].palTokenAwarded == true)

-- A resident killing the leader still lets the town win, but yields no token.
assert(bridge:begin(8, actors).ok)
assert(bridge:record_death(actors[1], npc).ok)
assert(bridge:record_death(actors[2], player).ok)
assert(bridge:record_death(actors[3], player).ok)
local no_credit = bridge:record_death(actors[4], player)
assert(no_credit.ok)
assert(no_credit.settlement.tokenAwarded == false)
assert(no_credit.settlement.reason
    == "raid-leader-kill-credit-required")
assert(reconciliation:status(faction_id).tokensAwarded == 1)
assert(#observed_results == 2)
assert(observed_results[2].playerParticipated == false)
assert(observed_results[2].palTokenAwarded == false)

-- Timer/world cleanup cancels an incomplete event and can never settle it.
assert(bridge:begin(9, actors).ok)
assert(bridge:record_death(actors[1], player).ok)
local cancelled = bridge:cancel("attendance-event-timeout")
assert(cancelled.ok and cancelled.reason == "raid-event-cancelled")
assert(cancelled.event.cancelled == true)
assert(cancelled.event.resolved == false)
assert(cancelled.cancelObserverOk == true)
assert(#observed_cancellations == 1)
assert(reconciliation:status(faction_id).tokensAwarded == 1)
assert(bridge:status().timerCleanupMaySettleRaid == false)

local too_few = bridge:begin(10, { actors[1], actors[2] })
assert(not too_few.ok)
assert(too_few.reason == "attendance-attacker-count-mismatch")

local saw_started, saw_settled, saw_cancelled = false, false, false
for _, message in ipairs(logs) do
    saw_started = saw_started
        or string.find(message, "ATTENDANCE_RAID_RESULT_STARTED", 1, true)
            ~= nil
    saw_settled = saw_settled
        or string.find(message, "ATTENDANCE_RAID_RESULT_SETTLED", 1, true)
            ~= nil
    saw_cancelled = saw_cancelled
        or string.find(message, "ATTENDANCE_RAID_RESULT_CANCELLED", 1, true)
            ~= nil
end
assert(saw_started and saw_settled and saw_cancelled)

print("PASS attendance raid result bridge: four native members, deterministic leader, credited victory token, no-credit victory, and timer cancellation")
