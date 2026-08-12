local QuestObjectiveSchema = {}

local EVENT_SCHEMA_VERSION = "pwft.quest-objective-event.v1"
local RULE_SCHEMA_VERSION = "pwft.quest-objective-rule.v1"

local AUTHORITIES = {
    defense = "pwft.defense.v1",
    raid = "pwft.raid.v1",
    commerce = "pwft.commerce.v1",
    native = "pwft.native.v1",
    content = "pwft.content.v1",
}

local STRING_FIELDS = {
    factionId = true,
    territoryId = true,
    locationId = true,
    actorId = true,
    itemId = true,
    productId = true,
    signalId = true,
    outcome = true,
    direction = true,
}

local BOOLEAN_FIELDS = {
    playerParticipated = true,
    playerSideWon = true,
    leaderKillCredited = true,
    playerCredited = true,
    confirmed = true,
}

local NUMBER_FIELDS = {
    quantity = true,
    amount = true,
}

local EVENT_KINDS = {
    defense = {
        completed = {
            fields = {
                factionId = true,
                territoryId = true,
                outcome = true,
                playerParticipated = true,
            },
            required = { "outcome", "playerParticipated" },
            outcomes = {
                victory = true,
                defeat = true,
                cancelled = true,
                timed_out = true,
            },
        },
    },
    raid = {
        completed = {
            fields = {
                factionId = true,
                territoryId = true,
                outcome = true,
                playerParticipated = true,
                playerSideWon = true,
                leaderKillCredited = true,
            },
            required = {
                "outcome",
                "playerParticipated",
                "playerSideWon",
                "leaderKillCredited",
            },
            outcomes = {
                victory = true,
                defeat = true,
                cancelled = true,
                timed_out = true,
            },
        },
    },
    commerce = {
        transaction = {
            fields = {
                factionId = true,
                itemId = true,
                productId = true,
                direction = true,
                quantity = true,
                amount = true,
                confirmed = true,
            },
            required = { "direction", "quantity", "confirmed" },
            directions = { buy = true, sell = true },
        },
    },
    native = {
        actor_interacted = {
            fields = {
                factionId = true,
                territoryId = true,
                actorId = true,
            },
            required = { "actorId" },
        },
        actor_defeated = {
            fields = {
                factionId = true,
                territoryId = true,
                actorId = true,
                playerCredited = true,
            },
            required = { "actorId", "playerCredited" },
        },
        location_entered = {
            fields = {
                territoryId = true,
                locationId = true,
            },
            required = { "locationId" },
        },
        item_acquired = {
            fields = {
                itemId = true,
                quantity = true,
            },
            required = { "itemId", "quantity" },
        },
    },
    content = {
        signal = {
            fields = {
                factionId = true,
                territoryId = true,
                actorId = true,
                itemId = true,
                signalId = true,
                outcome = true,
                quantity = true,
            },
            required = { "signalId" },
        },
    },
}

local EVENT_FIELDS = {
    schemaVersion = true,
    eventId = true,
    authority = true,
    source = true,
    kind = true,
}
for field, _ in pairs(STRING_FIELDS) do
    EVENT_FIELDS[field] = true
end
for field, _ in pairs(BOOLEAN_FIELDS) do
    EVENT_FIELDS[field] = true
end
for field, _ in pairs(NUMBER_FIELDS) do
    EVENT_FIELDS[field] = true
end

local RULE_FIELDS = {
    schemaVersion = true,
    objectiveId = true,
    eventSource = true,
    eventKind = true,
    match = true,
    requiredCount = true,
    incrementBy = true,
    action = true,
}

local MATCH_FIELDS = {
    minimumQuantity = true,
    minimumAmount = true,
}
for field, _ in pairs(STRING_FIELDS) do
    MATCH_FIELDS[field] = true
end
for field, _ in pairs(BOOLEAN_FIELDS) do
    MATCH_FIELDS[field] = true
end

local ACTION_FIELDS = {
    kind = true,
    targetStageId = true,
    branchId = true,
}

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local copied = {}
    seen[value] = copied
    for key, item in pairs(value) do
        copied[copy(key, seen)] = copy(item, seen)
    end
    return copied
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
    assert(value_type == "table", "unsupported quest-objective value")
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
    for field, _ in pairs(value) do
        assert(
            type(field) == "string" and allowed[field] == true,
            label .. " contains unsupported field: " .. tostring(field)
        )
    end
end

local function validate_token(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    assert(#value <= 160, label .. " is too long")
    assert(
        string.match(value, "^[A-Za-z0-9_.:-]+$") ~= nil,
        label .. " must be a structured identifier"
    )
    return value
end

local function positive_integer(value, label)
    assert(
        type(value) == "number"
            and value == math.floor(value)
            and value >= 1
            and value <= 1000000000000,
        label .. " must be a bounded positive integer"
    )
    return value
end

local function non_negative_integer(value, label)
    assert(
        type(value) == "number"
            and value == math.floor(value)
            and value >= 0
            and value <= 1000000000000,
        label .. " must be a bounded non-negative integer"
    )
    return value
end

local function belongs_to_namespace(value, namespace)
    return value == namespace
        or string.sub(value, 1, #namespace + 1) == namespace .. "."
end

local function event_kind(source, kind)
    local source_kinds = EVENT_KINDS[source]
    assert(source_kinds ~= nil, "unsupported quest-objective event source")
    local definition = source_kinds[kind]
    assert(definition ~= nil, "unsupported quest-objective event kind")
    return definition
end

local function validate_event_field(field, value, label)
    if STRING_FIELDS[field] then
        validate_token(value, label)
    elseif BOOLEAN_FIELDS[field] then
        assert(type(value) == "boolean", label .. " must be boolean")
    elseif field == "quantity" then
        positive_integer(value, label)
    elseif field == "amount" then
        non_negative_integer(value, label)
    else
        error(label .. " is not a supported event field")
    end
end

function QuestObjectiveSchema.normalize_event(event)
    assert_only_fields(event, EVENT_FIELDS, "quest-objective event")
    assert(event.schemaVersion == EVENT_SCHEMA_VERSION, "unsupported quest-objective event schema")
    local source = validate_token(event.source, "quest-objective event source")
    local kind = validate_token(event.kind, "quest-objective event kind")
    local definition = event_kind(source, kind)
    assert(
        event.authority == AUTHORITIES[source],
        "quest-objective event authority mismatch"
    )

    local normalized = {
        schemaVersion = EVENT_SCHEMA_VERSION,
        eventId = validate_token(event.eventId, "quest-objective event ID"),
        authority = event.authority,
        source = source,
        kind = kind,
    }
    for field, value in pairs(event) do
        if EVENT_FIELDS[field]
            and field ~= "schemaVersion"
            and field ~= "eventId"
            and field ~= "authority"
            and field ~= "source"
            and field ~= "kind" then
            assert(
                definition.fields[field] == true,
                "quest-objective event field is not allowed for this kind: " .. field
            )
            validate_event_field(field, value, "quest-objective event " .. field)
            normalized[field] = value
        end
    end
    for _, field in ipairs(definition.required or {}) do
        assert(normalized[field] ~= nil, "quest-objective event requires field: " .. field)
    end
    if definition.outcomes ~= nil then
        assert(
            definition.outcomes[normalized.outcome] == true,
            "unsupported quest-objective event outcome"
        )
    end
    if definition.directions ~= nil then
        assert(
            definition.directions[normalized.direction] == true,
            "unsupported commerce direction"
        )
    end
    if source == "commerce" then
        assert(normalized.confirmed == true, "commerce objective events must be confirmed")
        assert(
            normalized.itemId ~= nil or normalized.productId ~= nil,
            "commerce objective event requires an item or product ID"
        )
    end
    return normalized
end

function QuestObjectiveSchema.normalize_rule(rule, namespace)
    assert_only_fields(rule, RULE_FIELDS, "quest objective rule")
    assert(rule.schemaVersion == RULE_SCHEMA_VERSION, "unsupported quest objective rule schema")
    validate_token(namespace, "quest objective namespace")
    local objective_id = validate_token(rule.objectiveId, "quest objective ID")
    assert(
        belongs_to_namespace(objective_id, namespace),
        "quest objective ID must belong to its content-pack namespace"
    )
    local source = validate_token(rule.eventSource, "quest objective event source")
    local kind = validate_token(rule.eventKind, "quest objective event kind")
    local definition = event_kind(source, kind)

    local match = rule.match or {}
    assert_only_fields(match, MATCH_FIELDS, "quest objective match")
    local normalized_match = {}
    for field, value in pairs(match) do
        if field == "minimumQuantity" then
            assert(definition.fields.quantity == true, "minimumQuantity is unavailable for this event kind")
            normalized_match[field] = positive_integer(value, "minimumQuantity")
        elseif field == "minimumAmount" then
            assert(definition.fields.amount == true, "minimumAmount is unavailable for this event kind")
            normalized_match[field] = non_negative_integer(value, "minimumAmount")
        else
            assert(
                definition.fields[field] == true,
                "quest objective match field is not available for this event kind: " .. field
            )
            validate_event_field(field, value, "quest objective match " .. field)
            normalized_match[field] = value
        end
    end

    local increment_by = rule.incrementBy or "event"
    assert(
        increment_by == "event"
            or increment_by == "quantity"
            or increment_by == "amount",
        "unsupported quest objective increment mode"
    )
    if increment_by ~= "event" then
        assert(
            definition.fields[increment_by] == true,
            "quest objective increment field is unavailable for this event kind"
        )
    end

    assert_only_fields(rule.action, ACTION_FIELDS, "quest objective action")
    local action_kind = validate_token(rule.action.kind, "quest objective action kind")
    assert(
        action_kind == "advance"
            or action_kind == "branch"
            or action_kind == "complete",
        "unsupported quest objective action"
    )
    local action = { kind = action_kind }
    if action_kind == "advance" then
        action.targetStageId = validate_token(
            rule.action.targetStageId,
            "quest objective target stage ID"
        )
        assert(rule.action.branchId == nil, "advance action cannot declare a branch ID")
    elseif action_kind == "branch" then
        action.branchId = validate_token(
            rule.action.branchId,
            "quest objective branch ID"
        )
        assert(rule.action.targetStageId == nil, "branch action cannot declare a target stage ID")
    else
        assert(
            rule.action.targetStageId == nil and rule.action.branchId == nil,
            "complete action cannot declare a transition target"
        )
    end

    return {
        schemaVersion = RULE_SCHEMA_VERSION,
        objectiveId = objective_id,
        eventSource = source,
        eventKind = kind,
        match = normalized_match,
        requiredCount = positive_integer(rule.requiredCount or 1, "quest objective required count"),
        incrementBy = increment_by,
        action = action,
    }
end

function QuestObjectiveSchema.validate_action(rule, stage)
    if rule.action.kind == "advance" then
        assert(
            stage.nextStageSet[rule.action.targetStageId] == true,
            "quest objective advance target is not allowed by the stage"
        )
    elseif rule.action.kind == "branch" then
        assert(
            stage.branchById[rule.action.branchId] ~= nil,
            "quest objective branch is not declared by the stage"
        )
    else
        assert(
            stage.completionAllowed == true,
            "quest objective cannot complete a non-completable stage"
        )
    end
end

function QuestObjectiveSchema.matches(rule, event)
    if rule.eventSource ~= event.source or rule.eventKind ~= event.kind then
        return false
    end
    for field, expected in pairs(rule.match) do
        if field == "minimumQuantity" then
            if event.quantity == nil or event.quantity < expected then
                return false
            end
        elseif field == "minimumAmount" then
            if event.amount == nil or event.amount < expected then
                return false
            end
        elseif event[field] ~= expected then
            return false
        end
    end
    return true
end

function QuestObjectiveSchema.increment(rule, event)
    if rule.incrementBy == "event" then
        return 1
    end
    return event[rule.incrementBy]
end

function QuestObjectiveSchema.signature(value)
    return stable_encode(value)
end

function QuestObjectiveSchema.copy(value)
    return copy(value)
end

function QuestObjectiveSchema.status()
    local source_count = 0
    local kind_count = 0
    for _, kinds in pairs(EVENT_KINDS) do
        source_count = source_count + 1
        for _, _ in pairs(kinds) do
            kind_count = kind_count + 1
        end
    end
    return {
        eventSchemaVersion = EVENT_SCHEMA_VERSION,
        ruleSchemaVersion = RULE_SCHEMA_VERSION,
        sourceCount = source_count,
        eventKindCount = kind_count,
        authorities = copy(AUTHORITIES),
        inlineNarrativeAllowed = false,
        modelAuthorityAvailable = false,
    }
end

return QuestObjectiveSchema
