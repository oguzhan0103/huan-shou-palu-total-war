local QuestObjectiveRouter = {}
local QuestObjectiveSchema = require("pwft.quest_objective_schema")

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"

local function copy(value)
    return QuestObjectiveSchema.copy(value)
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function validate_token(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    assert(
        string.match(value, "^[A-Za-z0-9_.:-]+$") ~= nil,
        label .. " must be a structured identifier"
    )
    return value
end

local function make_state()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        processedEvents = {},
        progressByQuest = {},
    }
end

local function validate_state(state)
    assert(type(state) == "table", "quest-objective router state must be a table")
    assert(
        state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported quest-objective router state schema"
    )
    assert(type(state.processedEvents) == "table", "quest-objective processed events are required")
    assert(type(state.progressByQuest) == "table", "quest-objective progress ledger is required")
end

local function ensure_state(progression)
    if type(progression.state.questObjectiveRouter) ~= "table" then
        progression.state.questObjectiveRouter = make_state()
    end
    validate_state(progression.state.questObjectiveRouter)
    return progression.state.questObjectiveRouter
end

local function count_keys(values)
    local count = 0
    for _, _ in pairs(values) do
        count = count + 1
    end
    return count
end

local function touch_progression(instance, event)
    local root = instance.progression.state
    root.revision = (root.revision or 0) + 1
    root.eventCount = (root.eventCount or 0) + 1
    event.revision = root.revision
    root.lastEvent = copy(event)
    if instance.onChange ~= nil then
        local ok, error_message = pcall(instance.onChange, nil, copy(event))
        if not ok then
            instance.lastNotificationError = tostring(error_message)
        end
    end
end

local function progress_record(working, candidate, rule)
    local quest = working[candidate.questInstanceId]
    if quest == nil then
        quest = {}
        working[candidate.questInstanceId] = quest
    end
    local stage = quest[candidate.currentStageId]
    if stage == nil then
        stage = {}
        quest[candidate.currentStageId] = stage
    end
    local record = stage[rule.objectiveId]
    if record == nil then
        record = {
            count = 0,
            completed = false,
            lastEventId = nil,
        }
        stage[rule.objectiveId] = record
    end
    return record
end

local function transition_event_id(event, candidate, rule)
    return table.concat({
        "objective",
        event.eventId,
        tostring(candidate.sequence),
        rule.objectiveId,
    }, ":")
end

local function apply_action(instance, event, candidate, rule, record)
    local event_id = transition_event_id(event, candidate, rule)
    local structured_result = {
        sourceId = "pwft.quest-objective-router.v1",
        objectiveId = rule.objectiveId,
        triggerEventId = event.eventId,
        triggerAuthority = event.authority,
        triggerSource = event.source,
        triggerKind = event.kind,
        progress = record.count,
        requiredCount = rule.requiredCount,
    }
    if rule.action.kind == "advance" then
        return instance.questRuntime:advance(
            candidate.questInstanceId,
            rule.action.targetStageId,
            event_id,
            structured_result
        )
    elseif rule.action.kind == "branch" then
        return instance.questRuntime:branch(
            candidate.questInstanceId,
            rule.action.branchId,
            event_id,
            structured_result
        )
    end
    return instance.questRuntime:complete(
        candidate.questInstanceId,
        event_id,
        structured_result
    )
end

function QuestObjectiveRouter.create(quest_runtime, progression, options)
    options = options or {}
    assert(
        type(quest_runtime) == "table"
            and type(quest_runtime.active_objective_stages) == "function"
            and type(quest_runtime.advance) == "function"
            and type(quest_runtime.branch) == "function"
            and type(quest_runtime.complete) == "function",
        "quest runtime with objective support is required"
    )
    assert(type(progression) == "table" and type(progression.state) == "table", "progression is required")
    assert(options.onChange == nil or type(options.onChange) == "function", "objective onChange must be a function")
    local schema_status = QuestObjectiveSchema.status()
    local instance = setmetatable({
        version = API_VERSION,
        questRuntime = quest_runtime,
        progression = progression,
        state = ensure_state(progression),
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            eventSchemaVersion = schema_status.eventSchemaVersion,
            ruleSchemaVersion = schema_status.ruleSchemaVersion,
            supportedSources = schema_status.sourceCount,
            supportedEventKinds = schema_status.eventKindCount,
            deterministicTransitions = true,
            idempotentEvents = true,
            inlineNarrativeAllowed = false,
            modelMayDispatch = false,
            modelMayMutateState = false,
            palworldSaveMutation = false,
        },
    }, { __index = QuestObjectiveRouter })
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.quest-objective-router.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function QuestObjectiveRouter:rebind_progression_state()
    local previous = self.state
    self.state = ensure_state(self.progression)
    return result(true, "progression-state-rebound", {
        stateChanged = previous ~= self.state,
    })
end

function QuestObjectiveRouter:dispatch(raw_event)
    local normalized_ok, event_or_error = pcall(
        QuestObjectiveSchema.normalize_event,
        raw_event
    )
    if not normalized_ok then
        return result(false, "invalid-quest-objective-event", {
            validationError = tostring(event_or_error),
        })
    end
    local event = event_or_error
    local signature = QuestObjectiveSchema.signature(event)
    local previous = self.state.processedEvents[event.eventId]
    if previous ~= nil then
        if previous.signature ~= signature then
            return result(false, "quest-objective-event-id-conflict", {
                eventId = event.eventId,
            })
        end
        local replay = copy(previous.response)
        replay.reason = "quest-objective-event-already-processed"
        replay.replayed = true
        return replay
    end

    local working = copy(self.state.progressByQuest)
    local matched = 0
    local progressed = 0
    local transitions = 0
    local outcomes = {}
    for _, candidate in ipairs(self.questRuntime:active_objective_stages()) do
        for _, rule in ipairs(candidate.objectiveRules) do
            local record = progress_record(working, candidate, rule)
            if record.completed ~= true
                and QuestObjectiveSchema.matches(rule, event) then
                matched = matched + 1
                local increment = QuestObjectiveSchema.increment(rule, event)
                local before = record.count
                record.count = math.min(
                    rule.requiredCount,
                    record.count + increment
                )
                record.lastEventId = event.eventId
                if record.count > before then
                    progressed = progressed + 1
                end
                local outcome = {
                    questInstanceId = candidate.questInstanceId,
                    stageId = candidate.currentStageId,
                    objectiveId = rule.objectiveId,
                    before = before,
                    after = record.count,
                    requiredCount = rule.requiredCount,
                    action = nil,
                }
                outcomes[#outcomes + 1] = outcome
                if record.count >= rule.requiredCount then
                    local transition = apply_action(
                        self,
                        event,
                        candidate,
                        rule,
                        record
                    )
                    if not transition.ok then
                        return result(false, "quest-objective-transition-failed", {
                            eventId = event.eventId,
                            questInstanceId = candidate.questInstanceId,
                            objectiveId = rule.objectiveId,
                            transitionReason = transition.reason,
                        })
                    end
                    record.completed = true
                    outcome.action = rule.action.kind
                    outcome.transitionReason = transition.reason
                    transitions = transitions + 1
                    -- The quest has left this stage. One authoritative event
                    -- may advance many quests, but never cascades through
                    -- multiple stages of the same quest.
                    break
                end
            end
        end
    end

    self.state.progressByQuest = working
    local response = result(
        true,
        matched > 0
                and "quest-objective-event-applied"
            or "quest-objective-event-ignored",
        {
            eventId = event.eventId,
            source = event.source,
            kind = event.kind,
            matchedObjectiveCount = matched,
            progressedObjectiveCount = progressed,
            transitionCount = transitions,
            outcomes = outcomes,
        }
    )
    self.state.processedEvents[event.eventId] = {
        signature = signature,
        response = copy(response),
    }
    touch_progression(self, {
        type = "quest-objective-event",
        eventId = event.eventId,
        source = event.source,
        kind = event.kind,
        matchedObjectiveCount = matched,
        transitionCount = transitions,
    })
    return response
end

function QuestObjectiveRouter:objective_status(quest_instance_id)
    validate_token(quest_instance_id, "quest instance ID")
    return copy(self.state.progressByQuest[quest_instance_id] or {})
end

function QuestObjectiveRouter:status()
    return {
        apiVersion = self.version,
        processedEventCount = count_keys(self.state.processedEvents),
        trackedQuestCount = count_keys(self.state.progressByQuest),
        snapshotOwnedByProgression =
            self.progression.state.questObjectiveRouter == self.state,
        supportedSources = self.capabilities.supportedSources,
        supportedEventKinds = self.capabilities.supportedEventKinds,
        inlineNarrativeAllowed = false,
        modelMayDispatch = false,
        modelMayMutateState = false,
        palworldSaveMutation = false,
        lastNotificationError = self.lastNotificationError,
    }
end

return QuestObjectiveRouter
