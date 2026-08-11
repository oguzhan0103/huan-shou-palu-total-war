local AttendanceRaidResultBridge = {}

local API_VERSION = "1.0.0"
local PREFIX = "[PalFactionTerritory0][AttendanceRaidResultBridge]"
local EVENT_AUTHORITY = "pwft-attendance-event-v1"
local SPAWN_AUTHORITY = "pwft-npc-manager-spawn-v1"
local DEATH_AUTHORITY = "pal-character-on-dead-character-v1"
local OUTCOME_AUTHORITY = "pwft-attendance-all-members-dead-v1"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value)
    return type(value) == "string" and value ~= ""
end

local function default_actor_key(actor)
    if actor == nil then
        return nil
    end
    if type(actor) == "string" then
        return actor
    end
    local valid, is_valid = pcall(function()
        return actor:IsValid()
    end)
    if not valid or is_valid ~= true then
        return nil
    end
    local named, name = pcall(function()
        return actor:GetFullName()
    end)
    return named and tostring(name) or tostring(actor)
end

local function unresolved_attribution()
    return {
        attackerKind = "unresolved",
        attackerMatchesLocalPlayer = false,
        attackerIsPlayersOtomo = false,
        trainerMatchesLocalPlayer = false,
        attributionAuthority =
            "remote-or-unresolved-attendance-attacker",
    }
end

function AttendanceRaidResultBridge.create(adapter, config, dependencies)
    assert(type(adapter) == "table", "Pal raid-result adapter is required")
    assert(type(adapter.begin_event) == "function", "Pal raid-result adapter lacks begin_event")
    assert(type(adapter.register_member) == "function", "Pal raid-result adapter lacks register_member")
    assert(type(adapter.record_death) == "function", "Pal raid-result adapter lacks record_death")
    assert(type(adapter.finish_event) == "function", "Pal raid-result adapter lacks finish_event")
    assert(type(adapter.cancel_event) == "function", "Pal raid-result adapter lacks cancel_event")
    assert(type(config) == "table", "attendance raid-result bridge configuration is required")
    assert(non_empty(config.palFactionId), "attendance Pal faction ID is required")
    assert(non_empty(config.nativeGroupName), "attendance native group name is required")
    assert(non_empty(config.settlementId), "attendance settlement ID is required")
    assert(type(config.expectedAttackerCount) == "number"
        and config.expectedAttackerCount > 0
        and config.expectedAttackerCount
            == math.floor(config.expectedAttackerCount),
        "attendance attacker count must be a positive integer")
    dependencies = dependencies or {}
    return setmetatable({
        version = API_VERSION,
        adapter = adapter,
        config = config,
        dependencies = dependencies,
        active = nil,
        serial = 0,
        settlements = 0,
        cancellations = 0,
        failures = 0,
    }, { __index = AttendanceRaidResultBridge })
end

function AttendanceRaidResultBridge:_log(message)
    local logger = self.dependencies.logger
    if type(logger) == "function" then
        logger(PREFIX .. " " .. tostring(message))
    end
end

function AttendanceRaidResultBridge:_actor_key(actor)
    local provider = self.dependencies.actorKey or default_actor_key
    local ok, key = pcall(provider, actor)
    if not ok or not non_empty(key) then
        return nil
    end
    return key
end

function AttendanceRaidResultBridge:_attribution(attacker)
    local provider = self.dependencies.attributionResolver
    if type(provider) ~= "function" then
        return unresolved_attribution()
    end
    local ok, attribution = pcall(provider, attacker)
    if not ok or type(attribution) ~= "table" then
        return unresolved_attribution()
    end
    return attribution
end

function AttendanceRaidResultBridge:begin(generation, actors)
    if type(actors) ~= "table"
        or #actors ~= self.config.expectedAttackerCount then
        self.failures = self.failures + 1
        return result(false, "attendance-attacker-count-mismatch", {
            expected = self.config.expectedAttackerCount,
            actual = type(actors) == "table" and #actors or 0,
        })
    end
    if self.active ~= nil then
        self:cancel("superseded-by-new-attendance-raid")
    end

    self.serial = self.serial + 1
    local event_id = string.format(
        "attendance-pal-raid:%s:%d:%d",
        self.config.settlementId,
        tonumber(generation) or 0,
        self.serial
    )
    local group_guid = string.format(
        "attendance:%s:%d:%d",
        self.config.nativeGroupName,
        tonumber(generation) or 0,
        self.serial
    )
    local begun = self.adapter:begin_event({
        raidEventId = event_id,
        palFactionId = self.config.palFactionId,
        nativeGroupGuid = group_guid,
        waveMax = 1,
        sourceAuthority = EVENT_AUTHORITY,
    })
    if not begun.ok then
        self.failures = self.failures + 1
        return begun
    end

    local active = {
        eventId = event_id,
        groupGuid = group_guid,
        generation = generation,
        memberKeys = {},
        deathKeys = {},
        memberCount = 0,
        deathCount = 0,
        leaderActorKey = nil,
    }
    self.active = active
    for index, actor in ipairs(actors) do
        local actor_key = self:_actor_key(actor)
        if actor_key == nil or active.memberKeys[actor_key] == true then
            self.failures = self.failures + 1
            self:cancel("attendance-member-key-invalid-or-duplicate")
            return result(false, "attendance-member-key-invalid-or-duplicate", {
                index = index,
            })
        end
        local registered = self.adapter:register_member(event_id, {
            actorKey = actor_key,
            waveIndex = 1,
            spawnAuthority = SPAWN_AUTHORITY,
        })
        if not registered.ok then
            self.failures = self.failures + 1
            self:cancel("attendance-member-registration-failed")
            return registered
        end
        active.memberKeys[actor_key] = true
        active.memberCount = active.memberCount + 1
        if index == 1 then
            active.leaderActorKey = actor_key
        end
        self:_log(string.format(
            "ATTENDANCE_RAID_RESULT_MEMBER event=%s actor=%s index=%d/%d leader=%s authority=%s",
            event_id,
            actor_key,
            index,
            self.config.expectedAttackerCount,
            tostring(index == 1),
            SPAWN_AUTHORITY
        ))
    end
    self:_log(string.format(
        "ATTENDANCE_RAID_RESULT_STARTED event=%s group=%s faction=%s settlement=%s members=%d leader=%s authority=%s",
        event_id,
        self.config.nativeGroupName,
        self.config.palFactionId,
        self.config.settlementId,
        active.memberCount,
        active.leaderActorKey,
        EVENT_AUTHORITY
    ))
    return result(true, "attendance-raid-result-started", {
        raidEventId = event_id,
        leaderActorKey = active.leaderActorKey,
        memberCount = active.memberCount,
    })
end

function AttendanceRaidResultBridge:record_death(victim, attacker)
    local active = self.active
    if active == nil then
        return result(false, "attendance-raid-result-not-active")
    end
    local victim_key = self:_actor_key(victim)
    if victim_key == nil or active.memberKeys[victim_key] ~= true then
        return result(false, "death-not-from-active-attendance-raid")
    end
    if active.deathKeys[victim_key] == true then
        return result(true, "attendance-death-already-recorded", {
            raidEventId = active.eventId,
            victimActorKey = victim_key,
        })
    end

    local attribution = self:_attribution(attacker)
    local attacker_key = self:_actor_key(attacker)
        or "<unresolved-attacker>"
    local recorded = self.adapter:record_death(active.eventId, {
        victimActorKey = victim_key,
        lastAttackerActorKey = attacker_key,
        attackerKind = attribution.attackerKind or "unresolved",
        attackerMatchesLocalPlayer =
            attribution.attackerMatchesLocalPlayer == true,
        attackerIsPlayersOtomo =
            attribution.attackerIsPlayersOtomo == true,
        trainerMatchesLocalPlayer =
            attribution.trainerMatchesLocalPlayer == true,
        attributionAuthority = attribution.attributionAuthority
            or "remote-or-unresolved-attendance-attacker",
        deathAuthority = DEATH_AUTHORITY,
    })
    if not recorded.ok then
        self.failures = self.failures + 1
        return recorded
    end
    active.deathKeys[victim_key] = true
    active.deathCount = active.deathCount + 1
    local leader = victim_key == active.leaderActorKey
    self:_log(string.format(
        "ATTENDANCE_RAID_RESULT_DEATH event=%s victim=%s attacker=%s leader=%s kind=%s credited=%s deaths=%d/%d authority=%s",
        active.eventId,
        victim_key,
        attacker_key,
        tostring(leader),
        tostring(attribution.attackerKind or "unresolved"),
        tostring(recorded.death and recorded.death.playerCredited == true),
        active.deathCount,
        active.memberCount,
        DEATH_AUTHORITY
    ))
    if active.deathCount < active.memberCount then
        return recorded
    end

    local settled = self.adapter:finish_event(active.eventId, {
        attendanceEnded = true,
        playerSideWon = true,
        allWavesCleared = true,
        outcomeAuthority = OUTCOME_AUTHORITY,
    })
    local token_awarded = settled.settlement
        and settled.settlement.tokenAwarded == true
    self:_log(string.format(
        "ATTENDANCE_RAID_RESULT_SETTLED event=%s allMembersDead=true playerSideWon=true leader=%s leaderKillCredited=%s ok=%s reason=%s tokenAwarded=%s authority=%s",
        active.eventId,
        active.leaderActorKey,
        tostring(settled.event
            and settled.event.leaderKillCredited == true),
        tostring(settled.ok),
        tostring(settled.reason),
        tostring(token_awarded == true),
        OUTCOME_AUTHORITY
    ))
    self.active = nil
    if settled.ok then
        self.settlements = self.settlements + 1
    else
        self.failures = self.failures + 1
    end
    return settled
end

function AttendanceRaidResultBridge:cancel(reason)
    local active = self.active
    if active == nil then
        return result(true, "attendance-raid-result-already-idle")
    end
    local cancelled = self.adapter:cancel_event(active.eventId, {
        outcomeAuthority = OUTCOME_AUTHORITY,
        reason = reason or "attendance-raid-result-cancelled",
    })
    self:_log(string.format(
        "ATTENDANCE_RAID_RESULT_CANCELLED event=%s deaths=%d/%d ok=%s reason=%s timerSettlement=false authority=%s",
        active.eventId,
        active.deathCount,
        active.memberCount,
        tostring(cancelled.ok),
        tostring(reason),
        OUTCOME_AUTHORITY
    ))
    self.active = nil
    self.cancellations = self.cancellations + 1
    if not cancelled.ok then
        self.failures = self.failures + 1
    end
    return cancelled
end

function AttendanceRaidResultBridge:status()
    return {
        apiVersion = self.version,
        active = self.active ~= nil,
        eventId = self.active and self.active.eventId or nil,
        memberCount = self.active and self.active.memberCount or 0,
        deathCount = self.active and self.active.deathCount or 0,
        leaderActorKey = self.active
            and self.active.leaderActorKey or nil,
        settlements = self.settlements,
        cancellations = self.cancellations,
        failures = self.failures,
        eventAuthority = EVENT_AUTHORITY,
        spawnAuthority = SPAWN_AUTHORITY,
        deathAuthority = DEATH_AUTHORITY,
        outcomeAuthority = OUTCOME_AUTHORITY,
        timerCleanupMaySettleRaid = false,
    }
end

return AttendanceRaidResultBridge
