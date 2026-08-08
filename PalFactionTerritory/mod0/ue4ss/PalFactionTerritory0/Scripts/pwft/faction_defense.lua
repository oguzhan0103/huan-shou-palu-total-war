local FactionDefense = {}

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

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

function FactionDefense.create(faction_api)
    assert(type(faction_api) == "table", "faction API is required")
    assert(type(faction_api.award_defense) == "function", "faction API lacks defense awards")
    return setmetatable({
        version = "1.0.0",
        factionApi = faction_api,
        events = {},
        resolvedEventIds = {},
        capabilities = {
            hostileParticipation = true,
            temporaryTruce = true,
            reputationDecrease = false,
            successAwards = true,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionDefense })
end

function FactionDefense:begin(event_id, faction_id, options)
    require_non_empty_string(event_id, "defense event ID")
    require_non_empty_string(faction_id, "defense faction ID")
    if self.events[event_id] ~= nil then
        return result(true, "already-active", copy(self.events[event_id]))
    end
    if self.resolvedEventIds[event_id] then
        return result(false, "already-resolved")
    end
    local faction = self.factionApi:faction_status(faction_id)
    if faction == nil then
        return result(false, "unknown-faction")
    end
    if faction.kind ~= "Human" then
        return result(false, "human-defense-only")
    end
    options = options or {}
    local hostile = faction.relation == "Hostile"
    if hostile and options.allowHostileParticipation == false then
        return result(false, "hostile-participation-disabled")
    end
    local event = {
        eventId = event_id,
        factionId = faction_id,
        settlementId = options.settlementId,
        active = true,
        relationAtStart = faction.relation,
        hostileAtStart = hostile,
        temporaryTruce = hostile,
        participantIds = {},
        participantCount = 0,
    }
    self.events[event_id] = event
    return result(true, hostile and "hostile-temporary-truce" or "defense-started", copy(event))
end

function FactionDefense:participate(event_id, participant_id)
    require_non_empty_string(event_id, "defense event ID")
    require_non_empty_string(participant_id, "defense participant ID")
    local event = self.events[event_id]
    if event == nil or not event.active then
        return result(false, "defense-not-active")
    end
    if event.participantIds[participant_id] then
        return result(true, "already-participating", {
            eventId = event_id,
            participantId = participant_id,
            temporaryTruce = event.temporaryTruce,
        })
    end
    event.participantIds[participant_id] = true
    event.participantCount = event.participantCount + 1
    return result(true, "participating", {
        eventId = event_id,
        participantId = participant_id,
        temporaryTruce = event.temporaryTruce,
    })
end

function FactionDefense:effective_relation(faction_id, participant_id)
    require_non_empty_string(faction_id, "defense faction ID")
    require_non_empty_string(participant_id, "defense participant ID")
    for _, event in pairs(self.events) do
        if event.active
            and event.factionId == faction_id
            and event.temporaryTruce
            and event.participantIds[participant_id] then
            return "Friendly", "temporary-defense-truce", event.eventId
        end
    end
    local faction = self.factionApi:faction_status(faction_id)
    if faction == nil then
        return nil, "unknown-faction"
    end
    return faction.relation, "progression-relation"
end

function FactionDefense:resolve(
    event_id,
    succeeded,
    reputation_award,
    resolution_id,
    participant_id
)
    require_non_empty_string(event_id, "defense event ID")
    require_non_empty_string(resolution_id, "defense resolution ID")
    participant_id = participant_id or "local-player"
    require_non_empty_string(participant_id, "defense participant ID")
    local event = self.events[event_id]
    if event == nil or not event.active then
        return result(false, "defense-not-active")
    end
    event.active = false
    event.succeeded = succeeded == true
    event.resolutionId = resolution_id
    self.events[event_id] = nil
    self.resolvedEventIds[event_id] = true

    if not event.succeeded then
        return result(true, "defense-failed-no-reputation-decrease", {
            eventId = event_id,
            factionId = event.factionId,
            applied = 0,
            temporaryTruceEnded = event.temporaryTruce,
        })
    end
    if event.participantIds[participant_id] ~= true then
        return result(true, "success-without-player-participation", {
            eventId = event_id,
            factionId = event.factionId,
            applied = 0,
            temporaryTruceEnded = event.temporaryTruce,
        })
    end
    assert(
        type(reputation_award) == "number" and reputation_award > 0,
        "successful defense reputation award must be positive"
    )
    local award = self.factionApi:award_defense(
        event.factionId,
        reputation_award,
        event_id .. ":" .. resolution_id
    )
    award.eventId = event_id
    award.temporaryTruceEnded = event.temporaryTruce
    return award
end

function FactionDefense:status(event_id)
    if event_id ~= nil then
        local event = self.events[event_id]
        return event and copy(event) or nil
    end
    local active_count = 0
    for _, _ in pairs(self.events) do
        active_count = active_count + 1
    end
    local resolved_count = 0
    for _, _ in pairs(self.resolvedEventIds) do
        resolved_count = resolved_count + 1
    end
    return {
        version = self.version,
        activeEventCount = active_count,
        resolvedEventCount = resolved_count,
    }
end

return FactionDefense
