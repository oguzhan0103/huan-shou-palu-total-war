local PalRaidResultAdapter = {}

local API_VERSION = "1.0.0"
local PLAYER_UID_AUTHORITY = "pal-player-controller-uid-v1"
local OWNED_PAL_AUTHORITY = "pal-character-trainer-v1"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function is_non_empty_string(value)
    return type(value) == "string" and value ~= ""
end

local function is_positive_integer(value)
    return type(value) == "number"
        and value > 0
        and value == math.floor(value)
end

local function validate_policy(contract, config)
    assert(type(contract) == "table", "Pal reconciliation contract is required")
    local policy = contract.raidResultAdapterPolicy
    assert(type(policy) == "table", "Pal raid-result adapter policy is required")
    assert(policy.normalizedAdapterEnabled == true, "normalized Pal raid adapter must be enabled")
    assert(policy.nativeBindingEnabled == true, "native Pal raid binding contract must be enabled")
    assert(policy.leaderDesignation == "first-spawn-of-final-wave", "unsupported Pal raid leader designation")
    assert(policy.timerCleanupMaySettleRaid == false, "timer cleanup cannot settle a Pal raid")
    assert(policy.conflictingEvidenceBehavior == "block-event-fail-closed", "conflicting Pal raid evidence must fail closed")
    assert(type(config) == "table", "Pal raid-result adapter configuration is required")
    assert(config.normalizedRaidAdapterEnabled == true, "normalized Pal raid adapter is disabled")
    assert(config.nativeRaidResultBindingEnabled == true, "native Pal raid binding is disabled")
    assert(config.leaderDesignation == policy.leaderDesignation, "Pal raid leader designation drifted")
    return policy
end

local function public_event(event)
    if event == nil then
        return nil
    end
    return {
        raidEventId = event.raidEventId,
        palFactionId = event.palFactionId,
        nativeGroupGuid = event.nativeGroupGuid,
        waveMax = event.waveMax,
        active = event.active,
        blocked = event.blocked,
        blockReason = event.blockReason,
        resolved = event.resolved,
        memberCount = event.memberCount,
        deathCount = event.deathCount,
        leaderActorKey = event.leaderActorKey,
        leaderWaveIndex = event.leaderWaveIndex,
        leaderDead = event.leaderDead,
        leaderKillCredited = event.leaderKillCredited,
        leaderAttributionKind = event.leaderAttributionKind,
        playerSideWon = event.playerSideWon,
        allWavesCleared = event.allWavesCleared,
        settlement = copy(event.settlement),
    }
end

local function block_event(event, reason)
    event.blocked = true
    event.blockReason = reason
    return result(false, reason, public_event(event))
end

local function same_member(member, observation)
    return member.waveIndex == observation.waveIndex
        and member.spawnAuthority == observation.spawnAuthority
end

local function same_death(death, observation)
    return death.lastAttackerActorKey == observation.lastAttackerActorKey
        and death.attackerKind == observation.attackerKind
        and death.attributionAuthority == observation.attributionAuthority
        and death.attackerMatchesLocalPlayer
            == (observation.attackerMatchesLocalPlayer == true)
        and death.attackerIsPlayersOtomo
            == (observation.attackerIsPlayersOtomo == true)
        and death.trainerMatchesLocalPlayer
            == (observation.trainerMatchesLocalPlayer == true)
end

function PalRaidResultAdapter.create(pal_reconciliation, config)
    assert(type(pal_reconciliation) == "table", "Pal reconciliation service is required")
    assert(type(pal_reconciliation.record_raid_result) == "function", "Pal reconciliation service lacks raid settlement")
    local policy = validate_policy(pal_reconciliation.contract, config)
    return setmetatable({
        version = API_VERSION,
        service = pal_reconciliation,
        policy = policy,
        events = {},
        resolvedEvents = {},
        capabilities = {
            normalizedEventAggregation = true,
            deterministicFinalWaveLeader = true,
            directLocalPlayerCredit = true,
            localOwnedPalCredit = true,
            remotePlayerCredit = false,
            timerSettlement = false,
            PalworldSaveMutation = false,
        },
    }, { __index = PalRaidResultAdapter })
end

function PalRaidResultAdapter:begin_event(observation)
    if type(observation) ~= "table" then
        return result(false, "raid-event-observation-required")
    end
    local raid_event_id = observation.raidEventId
    if not is_non_empty_string(raid_event_id) then
        return result(false, "raid-event-id-required")
    end
    if observation.sourceAuthority ~= self.policy.eventAuthority then
        return result(false, "unauthorized-raid-event-source")
    end
    if not is_non_empty_string(observation.palFactionId) then
        return result(false, "pal-faction-id-required")
    end
    if not is_non_empty_string(observation.nativeGroupGuid) then
        return result(false, "native-group-guid-required")
    end
    if not is_positive_integer(observation.waveMax) then
        return result(false, "positive-wave-max-required")
    end
    local resolved = self.resolvedEvents[raid_event_id]
    if resolved ~= nil then
        return result(true, "raid-event-already-resolved", copy(resolved))
    end
    local existing = self.events[raid_event_id]
    if existing ~= nil then
        if existing.palFactionId == observation.palFactionId
            and existing.nativeGroupGuid == observation.nativeGroupGuid
            and existing.waveMax == observation.waveMax then
            return result(true, "raid-event-already-active", public_event(existing))
        end
        return block_event(existing, "raid-event-observation-conflict")
    end
    local event = {
        raidEventId = raid_event_id,
        palFactionId = observation.palFactionId,
        nativeGroupGuid = observation.nativeGroupGuid,
        waveMax = observation.waveMax,
        sourceAuthority = observation.sourceAuthority,
        active = true,
        blocked = false,
        blockReason = nil,
        resolved = false,
        memberCount = 0,
        deathCount = 0,
        members = {},
        deaths = {},
        leaderActorKey = nil,
        leaderWaveIndex = nil,
        leaderDead = false,
        leaderKillCredited = false,
        leaderAttributionKind = nil,
    }
    self.events[raid_event_id] = event
    return result(true, "raid-event-started", public_event(event))
end

function PalRaidResultAdapter:register_member(raid_event_id, observation)
    if not is_non_empty_string(raid_event_id) then
        return result(false, "raid-event-id-required")
    end
    local event = self.events[raid_event_id]
    if event == nil then
        return result(false, "unknown-active-raid-event")
    end
    if event.blocked then
        return result(false, event.blockReason, public_event(event))
    end
    if type(observation) ~= "table" then
        return result(false, "raid-member-observation-required")
    end
    if observation.spawnAuthority ~= self.policy.spawnAuthority then
        return result(false, "unauthorized-raid-member-source")
    end
    if not is_non_empty_string(observation.actorKey) then
        return result(false, "raid-member-actor-key-required")
    end
    if not is_positive_integer(observation.waveIndex)
        or observation.waveIndex > event.waveMax then
        return result(false, "raid-member-wave-index-invalid")
    end
    local existing = event.members[observation.actorKey]
    if existing ~= nil then
        if same_member(existing, observation) then
            return result(true, "raid-member-already-registered", {
                event = public_event(event),
                member = copy(existing),
            })
        end
        return block_event(event, "raid-member-observation-conflict")
    end
    event.memberCount = event.memberCount + 1
    local member = {
        actorKey = observation.actorKey,
        waveIndex = observation.waveIndex,
        spawnOrdinal = event.memberCount,
        spawnAuthority = observation.spawnAuthority,
        isDesignatedLeader = false,
    }
    if observation.waveIndex == event.waveMax
        and event.leaderActorKey == nil then
        event.leaderActorKey = observation.actorKey
        event.leaderWaveIndex = observation.waveIndex
        member.isDesignatedLeader = true
    end
    event.members[observation.actorKey] = member
    return result(true,
        member.isDesignatedLeader and "raid-leader-designated" or "raid-member-registered",
        {
            event = public_event(event),
            member = copy(member),
        }
    )
end

function PalRaidResultAdapter:record_death(raid_event_id, observation)
    if not is_non_empty_string(raid_event_id) then
        return result(false, "raid-event-id-required")
    end
    local event = self.events[raid_event_id]
    if event == nil then
        return result(false, "unknown-active-raid-event")
    end
    if event.blocked then
        return result(false, event.blockReason, public_event(event))
    end
    if type(observation) ~= "table" then
        return result(false, "raid-death-observation-required")
    end
    if observation.deathAuthority ~= self.policy.deathAuthority then
        return result(false, "unauthorized-raid-death-source")
    end
    if not is_non_empty_string(observation.victimActorKey) then
        return result(false, "raid-death-victim-key-required")
    end
    local member = event.members[observation.victimActorKey]
    if member == nil then
        return result(false, "unregistered-raid-victim")
    end
    local existing = event.deaths[observation.victimActorKey]
    if existing ~= nil then
        if same_death(existing, observation) then
            return result(true, "raid-death-already-recorded", {
                event = public_event(event),
                death = copy(existing),
            })
        end
        return block_event(event, "raid-death-observation-conflict")
    end

    local attribution_kind = "unresolved"
    local credited = false
    if observation.attackerKind == "local-player"
        and observation.attackerMatchesLocalPlayer == true
        and observation.attributionAuthority == PLAYER_UID_AUTHORITY then
        attribution_kind = "direct-local-player"
        credited = true
    elseif observation.attackerKind == "pal"
        and observation.attackerIsPlayersOtomo == true
        and observation.trainerMatchesLocalPlayer == true
        and observation.attributionAuthority == OWNED_PAL_AUTHORITY then
        attribution_kind = "local-player-owned-pal"
        credited = true
    end
    local death = {
        victimActorKey = observation.victimActorKey,
        lastAttackerActorKey = observation.lastAttackerActorKey,
        attackerKind = observation.attackerKind,
        attributionAuthority = observation.attributionAuthority,
        attackerMatchesLocalPlayer = observation.attackerMatchesLocalPlayer == true,
        attackerIsPlayersOtomo = observation.attackerIsPlayersOtomo == true,
        trainerMatchesLocalPlayer = observation.trainerMatchesLocalPlayer == true,
        attributionKind = attribution_kind,
        playerCredited = credited,
    }
    event.deaths[observation.victimActorKey] = death
    event.deathCount = event.deathCount + 1
    if observation.victimActorKey == event.leaderActorKey then
        event.leaderDead = true
        event.leaderKillCredited = credited
        event.leaderAttributionKind = attribution_kind
    end
    return result(true,
        credited and "raid-death-player-credited" or "raid-death-not-player-credited",
        {
            event = public_event(event),
            death = copy(death),
        }
    )
end

function PalRaidResultAdapter:finish_event(raid_event_id, observation)
    if not is_non_empty_string(raid_event_id) then
        return result(false, "raid-event-id-required")
    end
    local resolved = self.resolvedEvents[raid_event_id]
    if resolved ~= nil then
        return result(true, "raid-event-already-resolved", copy(resolved))
    end
    local event = self.events[raid_event_id]
    if event == nil then
        return result(false, "unknown-active-raid-event")
    end
    if event.blocked then
        return result(false, event.blockReason, public_event(event))
    end
    if type(observation) ~= "table" then
        return result(false, "raid-outcome-observation-required")
    end
    if observation.outcomeAuthority ~= self.policy.outcomeAuthority then
        return result(false, "unauthorized-raid-outcome-source")
    end
    if observation.nativeEnded ~= true then
        return result(false, "authoritative-native-end-required", public_event(event))
    end
    if type(observation.playerSideWon) ~= "boolean"
        or type(observation.allWavesCleared) ~= "boolean" then
        return result(false, "complete-native-outcome-required", public_event(event))
    end

    event.active = false
    event.resolved = true
    event.playerSideWon = observation.playerSideWon == true
        and observation.allWavesCleared == true
    event.allWavesCleared = observation.allWavesCleared == true
    local service_result = self.service:record_raid_result(
        event.palFactionId,
        {
            raidEventId = event.raidEventId,
            playerSideWon = event.playerSideWon,
            playerCreditedLeaderKill = event.leaderDead == true
                and event.leaderKillCredited == true,
        }
    )
    event.settlement = copy(service_result)
    local completed = public_event(event)
    self.resolvedEvents[raid_event_id] = completed
    self.events[raid_event_id] = nil
    return result(true, "raid-event-settled", {
        event = copy(completed),
        settlement = copy(service_result),
    })
end

function PalRaidResultAdapter:event_status(raid_event_id)
    if not is_non_empty_string(raid_event_id) then
        return nil
    end
    return public_event(self.events[raid_event_id])
        or copy(self.resolvedEvents[raid_event_id])
end

function PalRaidResultAdapter:status()
    local active_count = 0
    local blocked_count = 0
    for _, event in pairs(self.events) do
        active_count = active_count + 1
        if event.blocked then
            blocked_count = blocked_count + 1
        end
    end
    local resolved_count = 0
    for _, _ in pairs(self.resolvedEvents) do
        resolved_count = resolved_count + 1
    end
    return {
        apiVersion = self.version,
        normalizedRaidAdapterEnabled = true,
        nativeRaidResultBindingEnabled = true,
        leaderDesignation = self.policy.leaderDesignation,
        activeEventCount = active_count,
        blockedEventCount = blocked_count,
        resolvedEventCount = resolved_count,
        remoteOrUnresolvedAttributionAwardsToken = false,
        timerCleanupMaySettleRaid = false,
    }
end

return PalRaidResultAdapter
