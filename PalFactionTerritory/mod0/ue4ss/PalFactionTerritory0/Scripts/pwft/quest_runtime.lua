local QuestRuntime = {}
local QuestObjectiveSchema = require("pwft.quest_objective_schema")

local API_VERSION = "1.1.0"
local TEMPLATE_SCHEMA_VERSION = "1.1.0"
local LEGACY_TEMPLATE_SCHEMA_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local QUEST_CAPABILITY = "pwft.quest.templates"

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[copy(key, seen)] = copy(item, seen)
    end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_non_empty_string(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    assert(not string.find(value, "%s"), label .. " cannot contain whitespace")
    return value
end

local function sorted_keys(values)
    local keys = {}
    for key, _ in pairs(values) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return left < right
        end
        return type(left) < type(right)
    end)
    return keys
end

local function stable_encode(value)
    local value_type = type(value)
    if value_type == "nil" then
        return "n"
    elseif value_type == "boolean" then
        return value and "b1" or "b0"
    elseif value_type == "number" then
        return "d" .. tostring(value)
    elseif value_type == "string" then
        return "s" .. #value .. ":" .. value
    end
    assert(value_type == "table", "unsupported quest value")
    local parts = { "t{" }
    for _, key in ipairs(sorted_keys(value)) do
        parts[#parts + 1] = stable_encode(key)
        parts[#parts + 1] = stable_encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function assert_only_fields(value, allowed, label)
    assert(type(value) == "table", label .. " must be a table")
    for key, _ in pairs(value) do
        assert(type(key) == "string" and allowed[key] == true, label .. " contains unsupported field: " .. tostring(key))
    end
end

local function id_belongs_to_namespace(value, namespace)
    return value == namespace
        or string.sub(value, 1, #namespace + 1) == namespace .. "."
end

local function validate_token(value, label)
    require_non_empty_string(value, label)
    assert(
        string.match(value, "^[A-Za-z0-9_.:-]+$") ~= nil,
        label .. " must be a structured identifier"
    )
    return value
end

local INLINE_TEXT_FIELDS = {
    text = true,
    label = true,
    displayName = true,
    description = true,
    title = true,
    body = true,
    dialogue = true,
    prompt = true,
    name = true,
}

local function validate_structured(value, label, depth, seen, item_counter)
    depth = depth or 0
    seen = seen or {}
    item_counter = item_counter or { count = 0 }
    assert(depth <= 8, label .. " exceeds maximum depth")
    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean" or value_type == "number" then
        return
    end
    if value_type == "string" then
        validate_token(value, label)
        assert(#value <= 160, label .. " token is too long")
        return
    end
    assert(value_type == "table", label .. " contains an unsupported value type")
    assert(seen[value] == nil, label .. " cannot contain cycles")
    seen[value] = true
    for key, item in pairs(value) do
        item_counter.count = item_counter.count + 1
        assert(item_counter.count <= 256, label .. " contains too many values")
        if type(key) == "string" then
            validate_token(key, label .. " key")
            assert(INLINE_TEXT_FIELDS[key] ~= true, label .. " cannot contain inline narrative field: " .. key)
        else
            assert(type(key) == "number" and key >= 1 and key == math.floor(key), label .. " contains an invalid key")
        end
        validate_structured(item, label, depth + 1, seen, item_counter)
    end
    seen[value] = nil
end

local TEMPLATE_FIELDS = {
    schemaVersion = true,
    contentPackId = true,
    contentVersion = true,
    templateId = true,
    titleKey = true,
    summaryKey = true,
    startStageId = true,
    accessPolicy = true,
    stages = true,
}

local ACCESS_POLICY_FIELDS = {
    factionId = true,
    requiresJoined = true,
    minimumRankId = true,
    minimumReputation = true,
    onAccessLoss = true,
}

local STAGE_FIELDS = {
    stageId = true,
    objectiveKey = true,
    objectiveRules = true,
    nextStageIds = true,
    branches = true,
    completionAllowed = true,
    abortAllowed = true,
}

local BRANCH_FIELDS = {
    branchId = true,
    choiceKey = true,
    nextStageId = true,
}

local function public_stage(stage)
    if stage == nil then
        return nil
    end
    return {
        stageId = stage.stageId,
        objectiveKey = stage.objectiveKey,
        objectiveRules = copy(stage.objectiveRules),
        nextStageIds = copy(stage.nextStageIds),
        branches = copy(stage.branches),
        completionAllowed = stage.completionAllowed,
        abortAllowed = stage.abortAllowed,
    }
end

local function public_instance(instance, template)
    local value = copy(instance)
    value.stage = template and public_stage(template.stages[instance.currentStageId]) or nil
    return value
end

local function normalize_access_policy(progression, access_policy)
    if access_policy == nil then
        return nil
    end
    assert_only_fields(
        access_policy,
        ACCESS_POLICY_FIELDS,
        "quest access policy"
    )
    local faction_id = validate_token(
        access_policy.factionId,
        "quest access faction ID"
    )
    local faction = progression:status(faction_id)
    assert(
        faction ~= nil and faction.kind == "Human",
        "quest access policy requires a human faction"
    )
    assert(
        access_policy.requiresJoined == nil
            or type(access_policy.requiresJoined) == "boolean",
        "quest access requiresJoined must be boolean"
    )
    assert(
        access_policy.minimumReputation == nil
            or type(access_policy.minimumReputation) == "number",
        "quest access minimumReputation must be numeric"
    )
    local minimum_rank_id = access_policy.minimumRankId
    if minimum_rank_id ~= nil then
        validate_token(minimum_rank_id, "quest access minimum rank ID")
        assert(
            progression.rankIndexes[minimum_rank_id] ~= nil,
            "quest access minimum rank is unknown"
        )
    end
    assert(
        access_policy.onAccessLoss == "suspend",
        "quest access loss must suspend rather than delete progress"
    )
    assert(
        access_policy.requiresJoined == true
            or minimum_rank_id ~= nil
            or access_policy.minimumReputation ~= nil,
        "quest access policy must declare a requirement"
    )
    return {
        factionId = faction_id,
        requiresJoined = access_policy.requiresJoined == true,
        minimumRankId = minimum_rank_id,
        minimumReputation = access_policy.minimumReputation,
        onAccessLoss = "suspend",
    }
end

local function normalize_template(
    progression,
    content_registry,
    template
)
    assert_only_fields(template, TEMPLATE_FIELDS, "quest template")
    assert(
        template.schemaVersion == TEMPLATE_SCHEMA_VERSION
            or template.schemaVersion == LEGACY_TEMPLATE_SCHEMA_VERSION,
        "unsupported quest-template schema"
    )
    assert(
        template.schemaVersion == TEMPLATE_SCHEMA_VERSION
            or template.accessPolicy == nil,
        "quest access policy requires quest-template schema 1.1.0"
    )
    local pack_id = require_non_empty_string(template.contentPackId, "quest content-pack ID")
    local manifest = content_registry:manifest(pack_id)
    assert(manifest ~= nil, "quest content pack is not registered")
    assert(content_registry:has_capability(pack_id, QUEST_CAPABILITY), "quest content pack lacks quest-template capability")
    assert(template.contentVersion == manifest.contentVersion, "quest template content version does not match its pack")
    local template_id = validate_token(template.templateId, "quest template ID")
    assert(id_belongs_to_namespace(template_id, manifest.namespace), "quest template ID must belong to its content-pack namespace")

    local function localization_key(value, label)
        require_non_empty_string(value, label)
        assert(content_registry:owns_localization_key(pack_id, value), label .. " is not declared by the content pack")
        return value
    end

    local stages = {}
    local stage_order = {}
    local objective_ids = {}
    local objective_rule_count = 0
    assert(type(template.stages) == "table" and #template.stages > 0, "quest template stages are required")
    for _, stage in ipairs(template.stages) do
        assert_only_fields(stage, STAGE_FIELDS, "quest stage")
        local stage_id = validate_token(stage.stageId, "quest stage ID")
        assert(stages[stage_id] == nil, "duplicate quest stage ID: " .. stage_id)
        assert(type(stage.completionAllowed) == "boolean", "quest stage completionAllowed must be boolean")
        assert(stage.abortAllowed == nil or type(stage.abortAllowed) == "boolean", "quest stage abortAllowed must be boolean")
        local next_stage_ids = {}
        local next_stage_set = {}
        assert(stage.nextStageIds == nil or type(stage.nextStageIds) == "table", "quest nextStageIds must be an array")
        for _, next_stage_id in ipairs(stage.nextStageIds or {}) do
            validate_token(next_stage_id, "quest next-stage ID")
            assert(next_stage_set[next_stage_id] == nil, "duplicate quest next-stage ID")
            next_stage_set[next_stage_id] = true
            next_stage_ids[#next_stage_ids + 1] = next_stage_id
        end
        local branches = {}
        local branch_by_id = {}
        assert(stage.branches == nil or type(stage.branches) == "table", "quest branches must be an array")
        for _, branch in ipairs(stage.branches or {}) do
            assert_only_fields(branch, BRANCH_FIELDS, "quest branch")
            local branch_id = validate_token(branch.branchId, "quest branch ID")
            assert(branch_by_id[branch_id] == nil, "duplicate quest branch ID")
            local normalized_branch = {
                branchId = branch_id,
                choiceKey = localization_key(branch.choiceKey, "quest branch choice key"),
                nextStageId = validate_token(branch.nextStageId, "quest branch target stage ID"),
            }
            branches[#branches + 1] = normalized_branch
            branch_by_id[branch_id] = normalized_branch
        end
        local objective_rules = {}
        assert(
            stage.objectiveRules == nil or type(stage.objectiveRules) == "table",
            "quest objectiveRules must be an array"
        )
        for _, objective_rule in ipairs(stage.objectiveRules or {}) do
            local normalized_rule = QuestObjectiveSchema.normalize_rule(
                objective_rule,
                manifest.namespace
            )
            assert(
                objective_ids[normalized_rule.objectiveId] == nil,
                "duplicate quest objective ID: " .. normalized_rule.objectiveId
            )
            objective_ids[normalized_rule.objectiveId] = stage_id
            objective_rules[#objective_rules + 1] = normalized_rule
            objective_rule_count = objective_rule_count + 1
        end
        stages[stage_id] = {
            stageId = stage_id,
            objectiveKey = localization_key(stage.objectiveKey, "quest objective key"),
            objectiveRules = objective_rules,
            nextStageIds = next_stage_ids,
            nextStageSet = next_stage_set,
            branches = branches,
            branchById = branch_by_id,
            completionAllowed = stage.completionAllowed,
            abortAllowed = stage.abortAllowed ~= false,
        }
        stage_order[#stage_order + 1] = stage_id
    end

    local start_stage_id = validate_token(template.startStageId, "quest start-stage ID")
    assert(stages[start_stage_id] ~= nil, "quest start stage does not exist")
    for stage_id, stage in pairs(stages) do
        for _, next_stage_id in ipairs(stage.nextStageIds) do
            assert(stages[next_stage_id] ~= nil, "quest stage references an unknown next stage: " .. stage_id)
        end
        for _, branch in ipairs(stage.branches) do
            assert(stages[branch.nextStageId] ~= nil, "quest branch references an unknown next stage: " .. stage_id)
        end
        for _, objective_rule in ipairs(stage.objectiveRules) do
            QuestObjectiveSchema.validate_action(objective_rule, stage)
        end
    end

    local reachable = {}
    local queue = { start_stage_id }
    while #queue > 0 do
        local stage_id = table.remove(queue, 1)
        if reachable[stage_id] == nil then
            reachable[stage_id] = true
            local stage = stages[stage_id]
            for _, next_stage_id in ipairs(stage.nextStageIds) do
                queue[#queue + 1] = next_stage_id
            end
            for _, branch in ipairs(stage.branches) do
                queue[#queue + 1] = branch.nextStageId
            end
        end
    end
    for stage_id, _ in pairs(stages) do
        assert(reachable[stage_id] == true, "quest template contains unreachable stage: " .. stage_id)
    end

    local can_complete = {}
    local changed = true
    while changed do
        changed = false
        for stage_id, stage in pairs(stages) do
            if can_complete[stage_id] == nil then
                local possible = stage.completionAllowed
                for _, next_stage_id in ipairs(stage.nextStageIds) do
                    possible = possible or can_complete[next_stage_id] == true
                end
                for _, branch in ipairs(stage.branches) do
                    possible = possible or can_complete[branch.nextStageId] == true
                end
                if possible then
                    can_complete[stage_id] = true
                    changed = true
                end
            end
        end
    end
    for stage_id, _ in pairs(stages) do
        assert(can_complete[stage_id] == true, "quest stage has no path to completion: " .. stage_id)
    end

    local normalized = {
        schemaVersion = template.schemaVersion,
        contentPackId = pack_id,
        contentVersion = manifest.contentVersion,
        templateId = template_id,
        titleKey = localization_key(template.titleKey, "quest title key"),
        summaryKey = localization_key(template.summaryKey, "quest summary key"),
        startStageId = start_stage_id,
        accessPolicy = normalize_access_policy(
            progression,
            template.accessPolicy
        ),
        stages = stages,
        stageOrder = stage_order,
        objectiveRuleCount = objective_rule_count,
    }
    normalized.fingerprint = stable_encode({
        schemaVersion = normalized.schemaVersion,
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        templateId = normalized.templateId,
        titleKey = normalized.titleKey,
        summaryKey = normalized.summaryKey,
        startStageId = normalized.startStageId,
        accessPolicy = normalized.accessPolicy,
        stages = template.stages,
    })
    return normalized
end

local function validate_saved_state(state)
    assert(type(state) == "table", "quest runtime snapshot must be a table")
    assert(state.schemaVersion == STATE_SCHEMA_VERSION, "unsupported quest runtime snapshot schema")
    assert(type(state.instances) == "table", "quest runtime instances are required")
    assert(type(state.processedEventIds) == "table", "quest runtime processed events are required")
    assert(type(state.sequence) == "number" and state.sequence >= 0, "quest runtime sequence is invalid")
end

local function ensure_state(progression)
    if progression.state.contentQuests == nil then
        progression.state.contentQuests = {
            schemaVersion = STATE_SCHEMA_VERSION,
            sequence = 0,
            instances = {},
            processedEventIds = {},
        }
    else
        validate_saved_state(progression.state.contentQuests)
    end
    return progression.state.contentQuests
end

local function quest_access_status(instance, template)
    local policy = template and template.accessPolicy or nil
    if policy == nil then
        return {
            eligible = true,
            reason = "quest-access-unrestricted",
        }
    end
    local faction = instance.progression:status(policy.factionId)
    if faction == nil or faction.kind ~= "Human" then
        return {
            eligible = false,
            reason = "quest-access-faction-unavailable",
            factionId = policy.factionId,
        }
    end
    if policy.requiresJoined and not faction.joined then
        return {
            eligible = false,
            reason = "quest-access-membership-required",
            factionId = policy.factionId,
            rankId = faction.rankId,
            reputation = faction.reputation,
        }
    end
    if policy.minimumRankId ~= nil then
        local current_rank = instance.progression.rankIndexes[
            faction.rankId
        ] or 0
        local required_rank = instance.progression.rankIndexes[
            policy.minimumRankId
        ]
        if current_rank < required_rank then
            return {
                eligible = false,
                reason = "quest-access-rank-too-low",
                factionId = policy.factionId,
                requiredRankId = policy.minimumRankId,
                rankId = faction.rankId,
                reputation = faction.reputation,
            }
        end
    end
    if policy.minimumReputation ~= nil
        and faction.reputation < policy.minimumReputation then
        return {
            eligible = false,
            reason = "quest-access-reputation-too-low",
            factionId = policy.factionId,
            requiredReputation = policy.minimumReputation,
            reputation = faction.reputation,
            rankId = faction.rankId,
        }
    end
    return {
        eligible = true,
        reason = "quest-access-granted",
        factionId = policy.factionId,
        rankId = faction.rankId,
        reputation = faction.reputation,
    }
end

local function touch_progression(instance, event)
    local state = instance.progression.state
    state.revision = (state.revision or 0) + 1
    state.eventCount = (state.eventCount or 0) + 1
    event.revision = state.revision
    state.lastEvent = copy(event)
    if instance.onChange ~= nil then
        local ok, error_message = pcall(instance.onChange, nil, copy(event))
        if not ok then
            instance.lastNotificationError = tostring(error_message)
        end
    end
end

function QuestRuntime.create(progression, content_pack_registry, options)
    options = options or {}
    assert(type(progression) == "table" and type(progression.state) == "table", "progression instance is required")
    assert(
        type(content_pack_registry) == "table"
            and type(content_pack_registry.manifest) == "function"
            and type(content_pack_registry.has_capability) == "function"
            and type(content_pack_registry.owns_localization_key) == "function",
        "content-pack registry is required"
    )
    assert(options.onChange == nil or type(options.onChange) == "function", "quest onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        contentPackRegistry = content_pack_registry,
        templates = {},
        state = ensure_state(progression),
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            localizationKeysOnly = true,
            deterministicBranches = true,
            structuredResults = true,
            idempotentEvents = true,
            objectiveRules = true,
            factionAccessPolicies = true,
            accessLossSuspension = true,
            accessRecovery = true,
            snapshotOwnedByProgression = true,
            authoredStoryContent = false,
            PalworldSaveMutation = false,
        },
    }, { __index = QuestRuntime })
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.quest-runtime.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function QuestRuntime:rebind_progression_state()
    local previous_state = self.state
    self.state = ensure_state(self.progression)
    local reconciliation = self:reconcile_access(nil)
    return result(true, "progression-state-rebound", {
        stateChanged = previous_state ~= self.state,
        accessReconciliation = reconciliation,
    })
end

function QuestRuntime:reconcile_access(faction_id)
    local checked = 0
    local suspended = 0
    local resumed = 0
    local outcomes = {}
    for _, quest in pairs(self.state.instances) do
        local template = self.templates[quest.templateId]
        local policy = template and template.accessPolicy or nil
        if quest.state == "active"
            and policy ~= nil
            and (faction_id == nil or policy.factionId == faction_id) then
            checked = checked + 1
            local access = quest_access_status(self, template)
            local was_suspended = quest.accessSuspended == true
            quest.accessSuspended = not access.eligible
            quest.accessReason = access.reason
            if quest.accessSuspended and not was_suspended then
                suspended = suspended + 1
            elseif not quest.accessSuspended and was_suspended then
                resumed = resumed + 1
            end
            outcomes[#outcomes + 1] = {
                questInstanceId = quest.questInstanceId,
                suspended = quest.accessSuspended,
                access = copy(access),
            }
        end
    end
    return result(true, "quest-access-reconciled", {
        factionId = faction_id,
        checkedCount = checked,
        suspendedCount = suspended,
        resumedCount = resumed,
        outcomes = outcomes,
    })
end

function QuestRuntime:register_template(template)
    local ok, normalized_or_error = pcall(
        normalize_template,
        self.progression,
        self.contentPackRegistry,
        template
    )
    if not ok then
        return result(false, "invalid-quest-template", {
            validationError = tostring(normalized_or_error),
        })
    end
    local normalized = normalized_or_error
    local existing = self.templates[normalized.templateId]
    if existing ~= nil then
        if existing.fingerprint == normalized.fingerprint then
            return result(true, "quest-template-already-registered", {
                templateId = normalized.templateId,
            })
        end
        return result(false, "quest-template-migration-required", {
            templateId = normalized.templateId,
            currentContentVersion = existing.contentVersion,
            requestedContentVersion = normalized.contentVersion,
        })
    end
    for _, quest in pairs(self.state.instances) do
        if quest.templateId == normalized.templateId
            and quest.contentVersion ~= normalized.contentVersion then
            return result(false, "quest-instance-migration-required", {
                templateId = normalized.templateId,
                questInstanceId = quest.questInstanceId,
            })
        end
    end
    self.templates[normalized.templateId] = normalized
    return result(true, "quest-template-registered", {
        templateId = normalized.templateId,
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        stageCount = #normalized.stageOrder,
        objectiveRuleCount = normalized.objectiveRuleCount,
    })
end

function QuestRuntime:active_objective_stages()
    self:reconcile_access(nil)
    local active = {}
    for _, quest in pairs(self.state.instances) do
        if quest.state == "active"
            and quest.accessSuspended ~= true then
            local template = self.templates[quest.templateId]
            if template ~= nil
                and template.contentVersion == quest.contentVersion then
                local stage = template.stages[quest.currentStageId]
                active[#active + 1] = {
                    questInstanceId = quest.questInstanceId,
                    templateId = quest.templateId,
                    contentPackId = quest.contentPackId,
                    contentVersion = quest.contentVersion,
                    currentStageId = quest.currentStageId,
                    sequence = quest.sequence,
                    objectiveRules = copy(stage.objectiveRules),
                }
            end
        end
    end
    table.sort(active, function(left, right)
        if left.sequence == right.sequence then
            return left.questInstanceId < right.questInstanceId
        end
        return left.sequence < right.sequence
    end)
    return active
end

function QuestRuntime:_replay(event_id, signature, replay_reason)
    local previous = self.state.processedEventIds[event_id]
    if previous == nil then
        return nil
    end
    if previous.signature ~= signature then
        return result(false, "quest-event-id-conflict", {
            eventId = event_id,
            previousOperation = previous.operation,
        })
    end
    local response = copy(previous.response)
    response.reason = replay_reason
    response.replayed = true
    return response
end

function QuestRuntime:_record(event_id, operation, signature, response)
    self.state.processedEventIds[event_id] = {
        operation = operation,
        signature = signature,
        response = copy(response),
    }
end

function QuestRuntime:start(template_id, quest_instance_id, event_id, context)
    validate_token(template_id, "quest template ID")
    validate_token(quest_instance_id, "quest instance ID")
    validate_token(event_id, "quest event ID")
    validate_structured(context, "quest start context")
    local signature = stable_encode({ "start", template_id, quest_instance_id, context })
    local replay = self:_replay(event_id, signature, "quest-start-already-processed")
    if replay ~= nil then
        return replay
    end
    local template = self.templates[template_id]
    if template == nil then
        return result(false, "unknown-quest-template")
    end
    local access = quest_access_status(self, template)
    if not access.eligible then
        return result(false, "quest-access-denied", {
            access = access,
        })
    end
    if self.state.instances[quest_instance_id] ~= nil then
        return result(false, "quest-instance-already-exists")
    end
    self.state.sequence = self.state.sequence + 1
    local quest = {
        questInstanceId = quest_instance_id,
        templateId = template_id,
        contentPackId = template.contentPackId,
        contentVersion = template.contentVersion,
        state = "active",
        currentStageId = template.startStageId,
        sequence = self.state.sequence,
        transitionCount = 0,
        history = {},
        startContext = copy(context),
        resolution = nil,
        accessSuspended = false,
        accessReason = access.reason,
    }
    self.state.instances[quest_instance_id] = quest
    local response = result(true, "quest-started", {
        quest = public_instance(quest, template),
    })
    self:_record(event_id, "start", signature, response)
    touch_progression(self, {
        type = "quest-start",
        eventId = event_id,
        questInstanceId = quest_instance_id,
        templateId = template_id,
    })
    return response
end

function QuestRuntime:_transition(operation, quest_instance_id, selector, event_id, structured_result)
    validate_token(quest_instance_id, "quest instance ID")
    validate_token(selector, operation == "branch" and "quest branch ID" or "quest next-stage ID")
    validate_token(event_id, "quest event ID")
    validate_structured(structured_result, "quest structured result")
    local signature = stable_encode({ operation, quest_instance_id, selector, structured_result })
    local replay = self:_replay(event_id, signature, "quest-" .. operation .. "-already-processed")
    if replay ~= nil then
        return replay
    end
    local quest = self.state.instances[quest_instance_id]
    if quest == nil then
        return result(false, "unknown-quest-instance")
    end
    if quest.state ~= "active" then
        return result(false, "quest-not-active", { quest = copy(quest) })
    end
    local template = self.templates[quest.templateId]
    if template == nil or template.contentVersion ~= quest.contentVersion then
        return result(false, "quest-template-unavailable")
    end
    local access = quest_access_status(self, template)
    quest.accessSuspended = not access.eligible
    quest.accessReason = access.reason
    if quest.accessSuspended then
        return result(false, "quest-access-suspended", {
            quest = public_instance(quest, template),
            access = access,
        })
    end
    local stage = template.stages[quest.currentStageId]
    local next_stage_id = selector
    local branch_id = nil
    if operation == "advance" then
        if stage.nextStageSet[selector] ~= true then
            return result(false, "quest-transition-not-allowed")
        end
    else
        local branch = stage.branchById[selector]
        if branch == nil then
            return result(false, "unknown-quest-branch")
        end
        branch_id = selector
        next_stage_id = branch.nextStageId
    end
    local from_stage_id = quest.currentStageId
    quest.currentStageId = next_stage_id
    quest.transitionCount = quest.transitionCount + 1
    quest.history[#quest.history + 1] = {
        eventId = event_id,
        operation = operation,
        fromStageId = from_stage_id,
        toStageId = next_stage_id,
        branchId = branch_id,
        structuredResult = copy(structured_result),
    }
    local response = result(true, operation == "advance" and "quest-advanced" or "quest-branched", {
        quest = public_instance(quest, template),
        structuredResult = copy(structured_result),
    })
    self:_record(event_id, operation, signature, response)
    touch_progression(self, {
        type = "quest-" .. operation,
        eventId = event_id,
        questInstanceId = quest_instance_id,
        fromStageId = from_stage_id,
        toStageId = next_stage_id,
        branchId = branch_id,
    })
    return response
end

function QuestRuntime:advance(quest_instance_id, next_stage_id, event_id, structured_result)
    return self:_transition("advance", quest_instance_id, next_stage_id, event_id, structured_result)
end

function QuestRuntime:branch(quest_instance_id, branch_id, event_id, structured_result)
    return self:_transition("branch", quest_instance_id, branch_id, event_id, structured_result)
end

function QuestRuntime:_resolve(operation, quest_instance_id, event_id, structured_result)
    validate_token(quest_instance_id, "quest instance ID")
    validate_token(event_id, "quest event ID")
    validate_structured(structured_result, "quest structured result")
    local signature = stable_encode({ operation, quest_instance_id, structured_result })
    local replay = self:_replay(event_id, signature, "quest-" .. operation .. "-already-processed")
    if replay ~= nil then
        return replay
    end
    local quest = self.state.instances[quest_instance_id]
    if quest == nil then
        return result(false, "unknown-quest-instance")
    end
    if quest.state ~= "active" then
        return result(false, "quest-not-active", { quest = copy(quest) })
    end
    local template = self.templates[quest.templateId]
    if template == nil or template.contentVersion ~= quest.contentVersion then
        return result(false, "quest-template-unavailable")
    end
    local access = quest_access_status(self, template)
    quest.accessSuspended = not access.eligible
    quest.accessReason = access.reason
    if quest.accessSuspended then
        return result(false, "quest-access-suspended", {
            quest = public_instance(quest, template),
            access = access,
        })
    end
    local stage = template.stages[quest.currentStageId]
    if operation == "complete" and not stage.completionAllowed then
        return result(false, "quest-completion-not-allowed")
    elseif operation == "abort" and not stage.abortAllowed then
        return result(false, "quest-abort-not-allowed")
    end
    quest.state = operation == "complete" and "completed" or "aborted"
    quest.resolution = {
        eventId = event_id,
        outcome = quest.state,
        stageId = quest.currentStageId,
        structuredResult = copy(structured_result),
    }
    local response = result(true, operation == "complete" and "quest-completed" or "quest-aborted", {
        quest = public_instance(quest, template),
        resolution = copy(quest.resolution),
    })
    self:_record(event_id, operation, signature, response)
    touch_progression(self, {
        type = "quest-" .. operation,
        eventId = event_id,
        questInstanceId = quest_instance_id,
        templateId = quest.templateId,
        stageId = quest.currentStageId,
    })
    return response
end

function QuestRuntime:complete(quest_instance_id, event_id, structured_result)
    return self:_resolve("complete", quest_instance_id, event_id, structured_result)
end

function QuestRuntime:abort(quest_instance_id, event_id, structured_result)
    return self:_resolve("abort", quest_instance_id, event_id, structured_result)
end

function QuestRuntime:quest_status(quest_instance_id)
    validate_token(quest_instance_id, "quest instance ID")
    local quest = self.state.instances[quest_instance_id]
    if quest == nil then
        return nil
    end
    return public_instance(quest, self.templates[quest.templateId])
end

function QuestRuntime:template_status(template_id)
    validate_token(template_id, "quest template ID")
    local template = self.templates[template_id]
    if template == nil then
        return nil
    end
    return {
        templateId = template.templateId,
        contentPackId = template.contentPackId,
        contentVersion = template.contentVersion,
        titleKey = template.titleKey,
        summaryKey = template.summaryKey,
        startStageId = template.startStageId,
        accessPolicy = copy(template.accessPolicy),
        stageCount = #template.stageOrder,
        objectiveRuleCount = template.objectiveRuleCount,
    }
end

function QuestRuntime:status()
    local active = 0
    local completed = 0
    local aborted = 0
    local suspended = 0
    for _, quest in pairs(self.state.instances) do
        if quest.state == "active" then
            active = active + 1
            if quest.accessSuspended == true then
                suspended = suspended + 1
            end
        elseif quest.state == "completed" then
            completed = completed + 1
        elseif quest.state == "aborted" then
            aborted = aborted + 1
        end
    end
    return {
        apiVersion = self.version,
        templateCount = #sorted_keys(self.templates),
        questInstanceCount = active + completed + aborted,
        activeQuestCount = active,
        completedQuestCount = completed,
        abortedQuestCount = aborted,
        suspendedQuestCount = suspended,
        processedEventCount = #sorted_keys(self.state.processedEventIds),
        localizationKeysOnly = true,
        structuredResultsOnly = true,
        objectiveRulesEnabled = true,
        factionAccessPoliciesEnabled = true,
        snapshotOwnedByProgression = self.progression.state.contentQuests == self.state,
        authoredStoryContent = false,
        lastNotificationError = self.lastNotificationError,
    }
end

return QuestRuntime
