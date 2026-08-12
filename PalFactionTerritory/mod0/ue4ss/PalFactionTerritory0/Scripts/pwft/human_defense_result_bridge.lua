local HumanDefenseResultBridge = {}

local API_VERSION = "1.0.0"
local SCHEMA_VERSION = "1.0.0"
local ROUTE_KIND = "human-settlement-defense"

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

local function require_text(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function normalize_common(instance, input)
    assert(type(input) == "table", "human defense input is required")
    assert(
        input.schemaVersion == SCHEMA_VERSION,
        "unsupported human defense input schema"
    )
    assert(
        input.routeKind == ROUTE_KIND,
        "human defense route kind is required"
    )
    assert(
        input.authoritative == true,
        "human defense result must be authoritative"
    )
    assert(
        input.authoritySource == instance.authoritySource,
        "human defense authority source is not trusted"
    )
    assert(
        input.palTokenAwardRequested ~= true
            and input.palTokenAwarded ~= true,
        "human defense route cannot request Pal token authority"
    )
    return {
        schemaVersion = SCHEMA_VERSION,
        routeKind = ROUTE_KIND,
        authoritySource = input.authoritySource,
        authoritative = true,
        eventId = require_text(input.eventId, "human defense event ID"),
        factionId = require_text(
            input.factionId,
            "human defense faction ID"
        ),
        settlementId = require_text(
            input.settlementId,
            "human defense settlement ID"
        ),
    }
end

local function normalize_open(instance, input)
    local normalized = normalize_common(instance, input)
    assert(
        input.playerPresent == nil or type(input.playerPresent) == "boolean",
        "human defense player presence must be boolean"
    )
    normalized.playerPresent = input.playerPresent == true
    return normalized
end

local function normalize_settlement(instance, input)
    local normalized = normalize_common(instance, input)
    normalized.resolutionId = require_text(
        input.resolutionId,
        "human defense resolution ID"
    )
    assert(
        type(input.playerParticipated) == "boolean",
        "human defense player participation must be explicit"
    )
    assert(
        type(input.playerSideWon) == "boolean",
        "human defense victory must be explicit"
    )
    normalized.playerParticipated = input.playerParticipated
    normalized.playerSideWon = input.playerSideWon
    return normalized
end

local function normalized_or_failure(instance, input, normalizer)
    local ok, normalized = pcall(normalizer, instance, input)
    if not ok then
        return nil, result(false, "invalid-human-defense-result", {
            applied = 0,
            validationError = tostring(normalized),
            palTokenAwarded = false,
        })
    end
    return normalized, nil
end

local function same_event(first, second)
    return first.eventId == second.eventId
        and first.factionId == second.factionId
        and first.settlementId == second.settlementId
        and first.authoritySource == second.authoritySource
        and first.routeKind == second.routeKind
end

local function same_result(first, second)
    return same_event(first, second)
        and first.resolutionId == second.resolutionId
        and first.playerParticipated == second.playerParticipated
        and first.playerSideWon == second.playerSideWon
end

function HumanDefenseResultBridge.create(faction_defense, options)
    assert(type(faction_defense) == "table", "faction defense service is required")
    for _, method_name in ipairs({ "begin", "participate", "resolve", "status" }) do
        assert(
            type(faction_defense[method_name]) == "function",
            "faction defense service lacks " .. method_name
        )
    end
    options = options or {}
    local reputation_award = options.reputationAward or 50
    assert(
        type(reputation_award) == "number" and reputation_award > 0,
        "human defense reputation award must be positive"
    )
    return setmetatable({
        version = API_VERSION,
        factionDefense = faction_defense,
        authoritySource = options.authoritySource
            or "pwft.native-human-defense-result.v1",
        reputationAward = reputation_award,
        participantId = options.participantId or "local-player",
        events = {},
        resultsByEventId = {},
        resultsByResolutionId = {},
        openCount = 0,
        settledCount = 0,
        awardedCount = 0,
        zeroAwardCount = 0,
        duplicateCount = 0,
        rejectedCount = 0,
        capabilities = {
            authoritativeInputOnly = true,
            humanFactionOnly = true,
            hostileTemporaryParticipation = true,
            explicitPlayerParticipation = true,
            explicitPlayerVictory = true,
            eventAndResultIdempotency = true,
            persistedAwardIdempotency = true,
            failureOrAbsenceAwardsZero = true,
            PalTokenAuthority = false,
            PalworldSaveMutation = false,
        },
    }, { __index = HumanDefenseResultBridge })
end

function HumanDefenseResultBridge:open(input)
    local normalized, failure = normalized_or_failure(
        self,
        input,
        normalize_open
    )
    if normalized == nil then
        self.rejectedCount = self.rejectedCount + 1
        return failure
    end
    local existing = self.events[normalized.eventId]
    if existing ~= nil then
        if not same_event(existing, normalized) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "human-defense-event-id-conflict", {
                eventId = normalized.eventId,
                applied = 0,
                palTokenAwarded = false,
            })
        end
        return result(true, "human-defense-event-already-open", {
            eventId = normalized.eventId,
            factionId = normalized.factionId,
            settlementId = normalized.settlementId,
            temporaryTruce = existing.temporaryTruce,
            applied = 0,
            palTokenAwarded = false,
        })
    end
    if self.resultsByEventId[normalized.eventId] ~= nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "human-defense-event-already-settled", {
            eventId = normalized.eventId,
            applied = 0,
            palTokenAwarded = false,
        })
    end
    local begun = self.factionDefense:begin(
        normalized.eventId,
        normalized.factionId,
        {
            settlementId = normalized.settlementId,
            allowHostileParticipation = true,
        }
    )
    if not begun.ok then
        self.rejectedCount = self.rejectedCount + 1
        begun.applied = 0
        begun.palTokenAwarded = false
        return begun
    end
    normalized.temporaryTruce = begun.temporaryTruce == true
    normalized.playerPresent = normalized.playerPresent == true
    if normalized.playerPresent then
        local participation = self.factionDefense:participate(
            normalized.eventId,
            self.participantId
        )
        if not participation.ok then
            self.factionDefense:resolve(
                normalized.eventId,
                false,
                self.reputationAward,
                normalized.eventId .. ":open-rollback",
                self.participantId
            )
            self.rejectedCount = self.rejectedCount + 1
            participation.applied = 0
            participation.palTokenAwarded = false
            return participation
        end
    end
    self.events[normalized.eventId] = normalized
    self.openCount = self.openCount + 1
    return result(true, "human-defense-event-opened", {
        eventId = normalized.eventId,
        factionId = normalized.factionId,
        settlementId = normalized.settlementId,
        hostileAtStart = begun.hostileAtStart == true,
        temporaryTruce = normalized.temporaryTruce,
        playerPresent = normalized.playerPresent,
        participating = normalized.playerPresent,
        applied = 0,
        palTokenAwarded = false,
    })
end

function HumanDefenseResultBridge:settle(input)
    local normalized, failure = normalized_or_failure(
        self,
        input,
        normalize_settlement
    )
    if normalized == nil then
        self.rejectedCount = self.rejectedCount + 1
        return failure
    end

    local previous_resolution =
        self.resultsByResolutionId[normalized.resolutionId]
    if previous_resolution ~= nil then
        if not same_result(previous_resolution.input, normalized) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "human-defense-resolution-id-conflict", {
                resolutionId = normalized.resolutionId,
                applied = 0,
                palTokenAwarded = false,
            })
        end
        self.duplicateCount = self.duplicateCount + 1
        local duplicate = copy(previous_resolution.outcome)
        duplicate.duplicateOfReason = duplicate.reason
        duplicate.reason = "duplicate-human-defense-result"
        duplicate.applied = 0
        duplicate.idempotent = true
        return duplicate
    end
    if self.resultsByEventId[normalized.eventId] ~= nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "human-defense-event-result-conflict", {
            eventId = normalized.eventId,
            resolutionId = normalized.resolutionId,
            applied = 0,
            palTokenAwarded = false,
        })
    end

    local event = self.events[normalized.eventId]
    if event == nil then
        local opened = self:open(normalized)
        if not opened.ok then
            return opened
        end
        event = self.events[normalized.eventId]
    elseif not same_event(event, normalized) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "human-defense-event-id-conflict", {
            eventId = normalized.eventId,
            applied = 0,
            palTokenAwarded = false,
        })
    end

    if normalized.playerParticipated then
        local participation = self.factionDefense:participate(
            normalized.eventId,
            self.participantId
        )
        if not participation.ok then
            self.rejectedCount = self.rejectedCount + 1
            participation.applied = 0
            participation.palTokenAwarded = false
            return participation
        end
    end

    local qualified_victory = normalized.playerSideWon
        and normalized.playerParticipated
    local defense_outcome = self.factionDefense:resolve(
        normalized.eventId,
        qualified_victory,
        self.reputationAward,
        normalized.resolutionId,
        self.participantId
    )
    if not defense_outcome.ok then
        self.rejectedCount = self.rejectedCount + 1
        defense_outcome.applied = 0
        defense_outcome.palTokenAwarded = false
        return defense_outcome
    end

    local applied = tonumber(defense_outcome.applied) or 0
    local outcome_reason = "human-defense-failed-no-award"
    if normalized.playerSideWon and normalized.playerParticipated then
        if defense_outcome.reason == "duplicate-event" then
            outcome_reason = "persisted-human-defense-result-already-applied"
        else
            outcome_reason = "human-defense-reputation-awarded"
        end
    elseif normalized.playerSideWon then
        outcome_reason = "human-defense-no-player-participation"
    end
    local outcome = result(true, outcome_reason, {
        eventId = normalized.eventId,
        resolutionId = normalized.resolutionId,
        factionId = normalized.factionId,
        settlementId = normalized.settlementId,
        playerParticipated = normalized.playerParticipated,
        playerSideWon = normalized.playerSideWon,
        credited = normalized.playerParticipated
            and normalized.playerSideWon,
        requested = normalized.playerParticipated
                and normalized.playerSideWon
                and self.reputationAward
            or 0,
        applied = applied,
        defenseReason = defense_outcome.reason,
        temporaryTruceEnded =
            defense_outcome.temporaryTruceEnded == true,
        authoritySource = normalized.authoritySource,
        palTokenAwarded = false,
        idempotent = defense_outcome.reason == "duplicate-event",
    })
    self.events[normalized.eventId] = nil
    self.resultsByEventId[normalized.eventId] = {
        input = copy(normalized),
        outcome = copy(outcome),
    }
    self.resultsByResolutionId[normalized.resolutionId] =
        self.resultsByEventId[normalized.eventId]
    self.settledCount = self.settledCount + 1
    if applied > 0 then
        self.awardedCount = self.awardedCount + 1
    else
        self.zeroAwardCount = self.zeroAwardCount + 1
    end
    return outcome
end

function HumanDefenseResultBridge:status()
    local active = 0
    for _ in pairs(self.events) do
        active = active + 1
    end
    return {
        apiVersion = self.version,
        schemaVersion = SCHEMA_VERSION,
        routeKind = ROUTE_KIND,
        authoritySource = self.authoritySource,
        reputationAward = self.reputationAward,
        participantId = self.participantId,
        activeEventCount = active,
        openCount = self.openCount,
        settledCount = self.settledCount,
        awardedCount = self.awardedCount,
        zeroAwardCount = self.zeroAwardCount,
        duplicateCount = self.duplicateCount,
        rejectedCount = self.rejectedCount,
        PalTokenAuthority = false,
        PalworldSaveMutation = false,
    }
end

return HumanDefenseResultBridge
