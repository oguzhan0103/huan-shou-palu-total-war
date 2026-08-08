package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalRaidResultAdapter = require("pwft.pal_raid_result_adapter")

local policy = Registry.palReconciliation.raidResultAdapterPolicy
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
    contentPackId = "fan.story.dark.v1",
    contentVersion = "1.0.0",
    tokenQuota = 6,
    maximumAffinityPerDiscourse = 20,
}).ok)

local adapter = PalRaidResultAdapter.create(
    reconciliation,
    {
        normalizedRaidAdapterEnabled = true,
        nativeRaidResultBindingEnabled = false,
        leaderDesignation = "first-spawn-of-final-wave",
    }
)

local function begin(event_id, wave_max)
    return adapter:begin_event({
        raidEventId = event_id,
        palFactionId = faction_id,
        nativeGroupGuid = "group:" .. event_id,
        waveMax = wave_max or 3,
        sourceAuthority = policy.eventAuthority,
    })
end

local function member(event_id, actor_key, wave_index)
    return adapter:register_member(event_id, {
        actorKey = actor_key,
        waveIndex = wave_index,
        spawnAuthority = policy.spawnAuthority,
    })
end

local function direct_player_death(event_id, actor_key)
    return adapter:record_death(event_id, {
        victimActorKey = actor_key,
        lastAttackerActorKey = "actor:local-player",
        attackerKind = "local-player",
        attackerMatchesLocalPlayer = true,
        attributionAuthority = "pal-player-controller-uid-v1",
        deathAuthority = policy.deathAuthority,
    })
end

local function finish(event_id, won, cleared, native_ended)
    return adapter:finish_event(event_id, {
        nativeEnded = native_ended ~= false,
        playerSideWon = won,
        allWavesCleared = cleared,
        outcomeAuthority = policy.outcomeAuthority,
    })
end

assert(adapter.version == "1.0.0")
assert(adapter.capabilities.normalizedEventAggregation)
assert(adapter.capabilities.deterministicFinalWaveLeader)
assert(adapter.capabilities.timerSettlement == false)
assert(adapter:status().nativeRaidResultBindingEnabled == false)

assert(adapter:begin_event({
    raidEventId = "unauthorized",
    palFactionId = faction_id,
    nativeGroupGuid = "group:unauthorized",
    waveMax = 3,
    sourceAuthority = "timer-cleanup",
}).reason == "unauthorized-raid-event-source")
assert(adapter:event_status("unauthorized") == nil)

-- The first observed spawn in the final wave is the one deterministic Mod
-- leader. Later final-wave members remain ordinary members.
assert(begin("direct-win").reason == "raid-event-started")
assert(member("direct-win", "direct:wave-1", 1).reason == "raid-member-registered")
assert(member("direct-win", "direct:leader", 3).reason == "raid-leader-designated")
assert(member("direct-win", "direct:final-2", 3).reason == "raid-member-registered")
assert(adapter:event_status("direct-win").leaderActorKey == "direct:leader")
assert(direct_player_death("direct-win", "direct:leader").reason == "raid-death-player-credited")

-- Timer cleanup or an incomplete native callback cannot settle the event.
local timer_attempt = finish("direct-win", true, true, false)
assert(not timer_attempt.ok)
assert(timer_attempt.reason == "authoritative-native-end-required")
assert(adapter:event_status("direct-win").active == true)

local direct = finish("direct-win", true, true)
assert(direct.ok and direct.reason == "raid-event-settled")
assert(direct.settlement.tokenAwarded == true)
assert(reconciliation:status(faction_id).tokensAwarded == 1)
local duplicate = finish("direct-win", true, true)
assert(duplicate.ok and duplicate.reason == "raid-event-already-resolved")
assert(reconciliation:status(faction_id).tokensAwarded == 1)

-- A Pal only counts when both native ownership predicates and its Trainer
-- relationship resolve to the local player.
assert(begin("owned-pal-win").ok)
assert(member("owned-pal-win", "owned:leader", 3).reason == "raid-leader-designated")
local owned = adapter:record_death("owned-pal-win", {
    victimActorKey = "owned:leader",
    lastAttackerActorKey = "actor:owned-pal",
    attackerKind = "pal",
    attackerIsPlayersOtomo = true,
    trainerMatchesLocalPlayer = true,
    attributionAuthority = "pal-character-trainer-v1",
    deathAuthority = policy.deathAuthority,
})
assert(owned.ok and owned.reason == "raid-death-player-credited")
assert(owned.death.attributionKind == "local-player-owned-pal")
assert(finish("owned-pal-win", true, true).settlement.tokenAwarded == true)
assert(reconciliation:status(faction_id).tokensAwarded == 2)

-- Remote or unresolved attackers fail closed even if the player side wins.
assert(begin("remote-no-credit").ok)
assert(member("remote-no-credit", "remote:leader", 3).reason == "raid-leader-designated")
local remote = adapter:record_death("remote-no-credit", {
    victimActorKey = "remote:leader",
    lastAttackerActorKey = "actor:remote-player",
    attackerKind = "remote-player",
    attackerMatchesLocalPlayer = false,
    attributionAuthority = "remote-player-unresolved",
    deathAuthority = policy.deathAuthority,
})
assert(remote.ok and remote.reason == "raid-death-not-player-credited")
local remote_finish = finish("remote-no-credit", true, true)
assert(remote_finish.ok)
assert(remote_finish.settlement.reason == "raid-leader-kill-credit-required")
assert(remote_finish.settlement.tokenAwarded == false)

-- Killing an ordinary invader does not substitute for killing the designated
-- leader, and no final-wave spawn means no leader can be credited.
assert(begin("ordinary-only").ok)
assert(member("ordinary-only", "ordinary:member", 1).ok)
assert(direct_player_death("ordinary-only", "ordinary:member").ok)
assert(finish("ordinary-only", true, true).settlement.tokenAwarded == false)
assert(adapter:event_status("ordinary-only").leaderActorKey == nil)

-- A credited leader kill still awards nothing when the player side loses or
-- when native wave clear is false.
assert(begin("lost-after-kill").ok)
assert(member("lost-after-kill", "lost:leader", 3).reason == "raid-leader-designated")
assert(direct_player_death("lost-after-kill", "lost:leader").ok)
local lost = finish("lost-after-kill", false, false)
assert(lost.settlement.reason == "player-side-did-not-win")
assert(lost.settlement.tokenAwarded == false)

-- Conflicting authoritative observations permanently block that transient
-- event and never reach the token service.
assert(begin("member-conflict").ok)
assert(member("member-conflict", "conflict:actor", 1).ok)
local conflict = member("member-conflict", "conflict:actor", 2)
assert(not conflict.ok and conflict.reason == "raid-member-observation-conflict")
assert(adapter:event_status("member-conflict").blocked == true)
assert(finish("member-conflict", true, true).reason == "raid-member-observation-conflict")

assert(begin("begin-conflict", 3).ok)
local begin_conflict = adapter:begin_event({
    raidEventId = "begin-conflict",
    palFactionId = faction_id,
    nativeGroupGuid = "group:begin-conflict",
    waveMax = 4,
    sourceAuthority = policy.eventAuthority,
})
assert(not begin_conflict.ok and begin_conflict.reason == "raid-event-observation-conflict")

local status = adapter:status()
assert(status.activeEventCount == 2)
assert(status.blockedEventCount == 2)
assert(status.resolvedEventCount == 5)
assert(status.remoteOrUnresolvedAttributionAwardsToken == false)
assert(status.timerCleanupMaySettleRaid == false)
assert(reconciliation:status(faction_id).tokensAwarded == 2)

print("PASS authoritative Pal raid aggregation, deterministic leader credit, native-end settlement, idempotency, and fail-closed conflicts")
