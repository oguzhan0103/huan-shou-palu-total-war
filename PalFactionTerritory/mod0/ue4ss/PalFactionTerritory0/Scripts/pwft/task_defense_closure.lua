local TaskDefenseClosure = {}

local API_VERSION = "1.0.0"
local OBJECTIVE_EVENT_SCHEMA = "pwft.quest-objective-event.v1"
local OBJECTIVE_AUTHORITY = "pwft.defense.v1"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do
        output[copy(key)] = copy(child)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function required_text(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    return value
end

local function notify(instance, event)
    if instance.onChange == nil then return end
    local ok, error_message = pcall(instance.onChange, copy(event))
    if not ok then
        instance.lastNotificationError = tostring(error_message)
    end
end

function TaskDefenseClosure.create(
    human_defense_result_bridge,
    quest_objective_router,
    options
)
    assert(type(human_defense_result_bridge) == "table"
        and type(human_defense_result_bridge.open) == "function"
        and type(human_defense_result_bridge.settle) == "function",
        "human defense-result bridge is required")
    assert(type(quest_objective_router) == "table"
        and type(quest_objective_router.dispatch) == "function",
        "quest-objective router is required")
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "task-defense closure onChange must be a function")
    return setmetatable({
        version = API_VERSION,
        humanDefenseResultBridge = human_defense_result_bridge,
        questObjectiveRouter = quest_objective_router,
        onChange = options.onChange,
        openCount = 0,
        settlementCount = 0,
        objectiveDispatchCount = 0,
        objectiveTransitionCount = 0,
        objectiveFailureCount = 0,
        lastNotificationError = nil,
        capabilities = {
            authoritativeHumanDefenseOnly = true,
            objectiveEventAuthority = OBJECTIVE_AUTHORITY,
            combinedIdempotency = true,
            absenceOrDefeatAwardsZero = true,
            storyContentIncluded = false,
            palTokenAuthority = false,
            PalworldSaveMutation = false,
        },
    }, { __index = TaskDefenseClosure })
end

function TaskDefenseClosure:open(input)
    local opened = self.humanDefenseResultBridge:open(input)
    if opened.ok then self.openCount = self.openCount + 1 end
    notify(self, {
        type = "task-defense-open",
        eventId = input and input.eventId,
        factionId = input and input.factionId,
        settlementId = input and input.settlementId,
        ok = opened.ok == true,
        reason = opened.reason,
        temporaryTruce = opened.temporaryTruce == true,
    })
    return opened
end

function TaskDefenseClosure:settle(input)
    if type(input) ~= "table" then
        return result(false, "task-defense-input-required", {
            applied = 0,
            palTokenAwarded = false,
        })
    end
    local territory_id = input.territoryId
    local valid_territory, territory_or_error = pcall(
        required_text,
        territory_id,
        "task-defense territory ID"
    )
    if not valid_territory then
        return result(false, "task-defense-territory-required", {
            applied = 0,
            validationError = tostring(territory_or_error),
            palTokenAwarded = false,
        })
    end

    local defense = self.humanDefenseResultBridge:settle(input)
    if not defense.ok then
        notify(self, {
            type = "task-defense-settlement",
            eventId = input.eventId,
            factionId = input.factionId,
            territoryId = territory_id,
            ok = false,
            reason = defense.reason,
            defenseApplied = 0,
            questDispatched = false,
        })
        return result(false, "task-defense-result-rejected", {
            defense = copy(defense),
            applied = 0,
            palTokenAwarded = false,
        })
    end

    self.settlementCount = self.settlementCount + 1
    local objective = self.questObjectiveRouter:dispatch({
        schemaVersion = OBJECTIVE_EVENT_SCHEMA,
        eventId = required_text(input.eventId, "task-defense event ID")
            .. ":quest-defense",
        authority = OBJECTIVE_AUTHORITY,
        source = "defense",
        kind = "completed",
        factionId = required_text(input.factionId, "task-defense faction ID"),
        territoryId = territory_id,
        outcome = input.playerSideWon == true and "victory" or "defeat",
        playerParticipated = input.playerParticipated == true,
    })
    self.objectiveDispatchCount = self.objectiveDispatchCount + 1
    local original_transitions = tonumber(objective.transitionCount) or 0
    -- Router replays intentionally return the original response for audit.
    -- Count only newly applied transitions in this combined settlement.
    local transitions = objective.replayed == true and 0
        or original_transitions
    self.objectiveTransitionCount = self.objectiveTransitionCount + transitions
    if not objective.ok then
        self.objectiveFailureCount = self.objectiveFailureCount + 1
    end

    local combined_ok = objective.ok == true
    local combined_reason = combined_ok
            and "task-defense-closed"
        or "task-defense-quest-dispatch-failed"
    local outcome = result(combined_ok, combined_reason, {
        eventId = input.eventId,
        resolutionId = input.resolutionId,
        factionId = input.factionId,
        settlementId = input.settlementId,
        territoryId = territory_id,
        playerParticipated = input.playerParticipated == true,
        playerSideWon = input.playerSideWon == true,
        credited = defense.credited == true,
        applied = tonumber(defense.applied) or 0,
        defenseReason = defense.reason,
        defense = copy(defense),
        quest = copy(objective),
        questTransitionCount = transitions,
        questOriginalTransitionCount = original_transitions,
        questReplayed = objective.replayed == true,
        palTokenAwarded = false,
        idempotent = defense.idempotent == true
            or objective.replayed == true,
    })
    notify(self, {
        type = "task-defense-settlement",
        eventId = outcome.eventId,
        resolutionId = outcome.resolutionId,
        factionId = outcome.factionId,
        settlementId = outcome.settlementId,
        territoryId = outcome.territoryId,
        playerParticipated = outcome.playerParticipated,
        playerSideWon = outcome.playerSideWon,
        credited = outcome.credited,
        defenseApplied = outcome.applied,
        defenseReason = outcome.defenseReason,
        questDispatched = true,
        questOk = objective.ok == true,
        questReason = objective.reason,
        questTransitionCount = transitions,
        questReplayed = outcome.questReplayed,
        ok = outcome.ok,
        reason = outcome.reason,
    })
    return outcome
end

function TaskDefenseClosure:status()
    return {
        apiVersion = self.version,
        openCount = self.openCount,
        settlementCount = self.settlementCount,
        objectiveDispatchCount = self.objectiveDispatchCount,
        objectiveTransitionCount = self.objectiveTransitionCount,
        objectiveFailureCount = self.objectiveFailureCount,
        lastNotificationError = self.lastNotificationError,
        objectiveEventAuthority = OBJECTIVE_AUTHORITY,
        combinedIdempotency = true,
        storyContentIncluded = false,
        palTokenAuthority = false,
        PalworldSaveMutation = false,
    }
end

return TaskDefenseClosure
