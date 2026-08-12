local ContentActionRuntime = {}

local API_VERSION = "1.0.0"
local PACK_SCHEMA = "pwft.content-actions.pack.v1"
local STATE_SCHEMA = "1.0.0"

local ACTION_FIELDS = {
    actionId = true,
    kind = true,
    parameters = true,
    requiresPlayerConfirmation = true,
}

local PARAMETER_FIELDS = {
    award_task_reputation = { factionId = true, amount = true },
    join_human_faction = { factionId = true },
    clear_affiliation_hostility = {
        targetFactionId = true,
        sourceFactionId = true,
    },
    transfer_unique_pal = {
        uniquePalId = true,
        expectedOwner = true,
        newOwner = true,
    },
    preserve_city = { cityId = true },
    occupy_city = { cityId = true, ownerFactionId = true },
    destroy_city = { cityId = true, actor = true },
    restore_city = { cityId = true, ownerFactionId = true },
    issue_ultimatum = {
        ultimatumId = true,
        issuerFactionId = true,
        targetId = true,
        demand = true,
    },
    resolve_ultimatum = { ultimatumId = true, accepted = true },
    set_ending_flag = { key = true, value = true },
    commit_ending_route = { routeId = true },
}

local REQUIRED_CAPABILITY = {
    award_task_reputation = "pwft.quest.templates",
    join_human_faction = "pwft.quest.templates",
    clear_affiliation_hostility = "pwft.quest.templates",
    transfer_unique_pal = "pwft.world.unique-pals",
    preserve_city = "pwft.world.city-states",
    occupy_city = "pwft.world.city-states",
    destroy_city = "pwft.world.city-states",
    restore_city = "pwft.world.city-states",
    issue_ultimatum = "pwft.world.city-states",
    resolve_ultimatum = "pwft.world.city-states",
    set_ending_flag = "pwft.world.endings",
    commit_ending_route = "pwft.world.endings",
}

local CONFIRMATION_REQUIRED = {
    join_human_faction = true,
    transfer_unique_pal = true,
    occupy_city = true,
    destroy_city = true,
    restore_city = true,
    issue_ultimatum = true,
    resolve_ultimatum = true,
    commit_ending_route = true,
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do
        result[copy(key, seen)] = copy(child, seen)
    end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    assert(not string.find(value, "%s"), label .. " cannot contain whitespace")
    return value
end

local function stable_id(value, label)
    non_empty(value, label)
    assert(string.match(value, "^[A-Za-z0-9_.:-]+$") ~= nil,
        label .. " must be a structured identifier")
    return value
end

local function belongs_to_namespace(value, namespace)
    return value == namespace
        or string.sub(value, 1, #namespace + 1) == namespace .. "."
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then return left < right end
        return type(left) < type(right)
    end)
    return keys
end

local function stable_encode(value)
    local kind = type(value)
    if kind == "nil" then return "n" end
    if kind == "boolean" then return value and "b1" or "b0" end
    if kind == "number" then return "d" .. tostring(value) end
    if kind == "string" then return "s" .. #value .. ":" .. value end
    assert(kind == "table", "content action contains unsupported value")
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
    for key in pairs(value) do
        assert(type(key) == "string" and allowed[key] == true,
            label .. " contains unsupported field: " .. tostring(key))
    end
end

local function scalar(value, label)
    local kind = type(value)
    assert(kind == "string" or kind == "number" or kind == "boolean",
        label .. " must be a scalar")
    if kind == "string" then stable_id(value, label) end
    return value
end

local function normalize_owner(owner, faction_kinds, label)
    assert(type(owner) == "table", label .. " is required")
    assert_only_fields(owner, { kind = true, id = true }, label)
    local kind = non_empty(owner.kind, label .. " kind")
    assert(kind == "wild" or kind == "unclaimed"
        or kind == "player" or kind == "faction",
        label .. " kind is unsupported")
    if kind == "faction" then
        stable_id(owner.id, label .. " faction ID")
        assert(faction_kinds[owner.id] ~= nil,
            label .. " references an unknown faction")
        return { kind = kind, id = owner.id }
    end
    assert(owner.id == nil, label .. " ID is not allowed for " .. kind)
    return { kind = kind }
end

local function require_human_faction(instance, faction_id, label)
    stable_id(faction_id, label)
    assert(instance.factionApi.progression.factionKinds[faction_id] == "Human",
        label .. " must reference a human faction")
    return faction_id
end

local function require_known_faction(instance, faction_id, label)
    stable_id(faction_id, label)
    assert(instance.factionApi.progression.factionKinds[faction_id] ~= nil,
        label .. " references an unknown faction")
    return faction_id
end

local function normalize_parameters(instance, pack_id, kind, parameters)
    local allowed = PARAMETER_FIELDS[kind]
    assert(allowed ~= nil, "unsupported content action kind")
    assert_only_fields(parameters, allowed, "content action parameters")
    local value = copy(parameters)
    if kind == "award_task_reputation" then
        require_human_faction(instance, value.factionId, "task faction ID")
        assert(type(value.amount) == "number" and value.amount > 0,
            "task reputation amount must be positive")
    elseif kind == "join_human_faction" then
        require_human_faction(instance, value.factionId, "join faction ID")
    elseif kind == "clear_affiliation_hostility" then
        require_human_faction(instance, value.targetFactionId,
            "hostility target faction ID")
        require_human_faction(instance, value.sourceFactionId,
            "hostility source faction ID")
    elseif kind == "transfer_unique_pal" then
        stable_id(value.uniquePalId, "unique Pal ID")
        assert(instance.strategicWorld.uniquePalDefinitions[value.uniquePalId] ~= nil,
            "content action references an unknown unique Pal")
        value.expectedOwner = normalize_owner(
            value.expectedOwner,
            instance.factionApi.progression.factionKinds,
            "expected unique Pal owner"
        )
        value.newOwner = normalize_owner(
            value.newOwner,
            instance.factionApi.progression.factionKinds,
            "new unique Pal owner"
        )
    elseif kind == "preserve_city" or kind == "destroy_city" then
        stable_id(value.cityId, "city ID")
        assert(instance.strategicWorld.cityDefinitions[value.cityId] ~= nil,
            "content action references an unknown city")
        if kind == "destroy_city" then
            value.actor = normalize_owner(
                value.actor,
                instance.factionApi.progression.factionKinds,
                "city destruction actor"
            )
            assert(value.actor.kind == "player" or value.actor.kind == "faction",
                "city destruction actor must be player or faction")
        end
    elseif kind == "occupy_city" or kind == "restore_city" then
        stable_id(value.cityId, "city ID")
        assert(instance.strategicWorld.cityDefinitions[value.cityId] ~= nil,
            "content action references an unknown city")
        require_human_faction(instance, value.ownerFactionId,
            "city owner faction ID")
    elseif kind == "issue_ultimatum" then
        stable_id(value.ultimatumId, "ultimatum ID")
        assert(belongs_to_namespace(value.ultimatumId,
            instance.contentPackRegistry:manifest(pack_id).namespace),
            "ultimatum ID must belong to the content-pack namespace")
        require_human_faction(instance, value.issuerFactionId,
            "ultimatum issuer faction ID")
        stable_id(value.targetId, "ultimatum target ID")
        assert(type(value.demand) == "table", "ultimatum demand is required")
        assert_only_fields(value.demand, {
            kind = true,
            resourceId = true,
            amount = true,
            resultTag = true,
        }, "ultimatum demand")
        local demand_kind = non_empty(value.demand.kind, "ultimatum demand kind")
        assert(demand_kind == "tribute" or demand_kind == "submission"
            or demand_kind == "resource" or demand_kind == "ceasefire"
            or demand_kind == "custom", "unsupported ultimatum demand kind")
        if value.demand.resourceId ~= nil then
            stable_id(value.demand.resourceId, "ultimatum resource ID")
        end
        if value.demand.amount ~= nil then
            assert(type(value.demand.amount) == "number"
                and value.demand.amount > 0,
                "ultimatum demand amount must be positive")
        end
        if value.demand.resultTag ~= nil then
            stable_id(value.demand.resultTag, "ultimatum result tag")
        end
    elseif kind == "resolve_ultimatum" then
        stable_id(value.ultimatumId, "ultimatum ID")
        assert(type(value.accepted) == "boolean",
            "ultimatum acceptance must be boolean")
    elseif kind == "set_ending_flag" then
        stable_id(value.key, "ending flag key")
        assert(belongs_to_namespace(value.key,
            instance.contentPackRegistry:manifest(pack_id).namespace),
            "ending flag must belong to the content-pack namespace")
        scalar(value.value, "ending flag value")
    elseif kind == "commit_ending_route" then
        stable_id(value.routeId, "ending route ID")
        assert(instance.endingRuntime.routeDefinitions[value.routeId] ~= nil,
            "content action references an unknown ending route")
    end
    return value
end

local function make_state(progression)
    if type(progression.state.contentActions) ~= "table" then
        progression.state.contentActions = {
            schemaVersion = STATE_SCHEMA,
            processedEventIds = {},
        }
    end
    local state = progression.state.contentActions
    assert(state.schemaVersion == STATE_SCHEMA,
        "unsupported content-action state schema")
    state.processedEventIds = state.processedEventIds or {}
    return state
end

function ContentActionRuntime.create(
    faction_api,
    strategic_world,
    ending_runtime,
    content_pack_registry
)
    assert(type(faction_api) == "table", "faction API is required")
    assert(type(strategic_world) == "table", "strategic world is required")
    assert(type(ending_runtime) == "table", "ending runtime is required")
    assert(type(content_pack_registry) == "table",
        "content-pack registry is required")
    local instance = setmetatable({
        version = API_VERSION,
        factionApi = faction_api,
        strategicWorld = strategic_world,
        endingRuntime = ending_runtime,
        contentPackRegistry = content_pack_registry,
        state = make_state(faction_api.progression),
        packDefinitions = {},
        actions = {},
        capabilities = {
            registeredActionsOnly = true,
            playerConfirmationForIrreversibleActions = true,
            idempotentDispatch = true,
            directCommerceAwards = false,
            directDefenseAwards = false,
            directPalReconciliation = false,
            languageModelAuthority = false,
            PalworldSaveMutation = false,
        },
    }, { __index = ContentActionRuntime })
    if type(faction_api.progression.register_restore_listener) == "function" then
        local registered = faction_api.progression:register_restore_listener(
            "content-action-runtime",
            function()
                return instance:rebind_progression(faction_api.progression)
            end
        )
        assert(registered.ok, "content-action restore listener registration failed")
    end
    return instance
end

local function normalize_pack(instance, pack)
    assert(type(pack) == "table", "content-action pack is required")
    assert_only_fields(pack, {
        schemaVersion = true,
        contentPackId = true,
        contentVersion = true,
        actions = true,
    }, "content-action pack")
    assert(pack.schemaVersion == PACK_SCHEMA,
        "unsupported content-action pack schema")
    local pack_id = stable_id(pack.contentPackId, "content pack ID")
    local manifest = instance.contentPackRegistry:manifest(pack_id)
    assert(manifest ~= nil, "content-action pack manifest is not registered")
    assert(pack.contentVersion == manifest.contentVersion,
        "content-action pack version does not match its manifest")
    assert(type(pack.actions) == "table", "content actions must be an array")
    local normalized = {
        schemaVersion = PACK_SCHEMA,
        contentPackId = pack_id,
        contentVersion = pack.contentVersion,
        actions = {},
    }
    local seen = {}
    for index, action in ipairs(pack.actions) do
        assert(type(index) == "number", "content actions must be an array")
        assert_only_fields(action, ACTION_FIELDS, "content action")
        local action_id = stable_id(action.actionId, "content action ID")
        assert(belongs_to_namespace(action_id, manifest.namespace),
            "content action ID must belong to the content-pack namespace")
        assert(seen[action_id] == nil, "duplicate content action ID")
        seen[action_id] = true
        local kind = non_empty(action.kind, "content action kind")
        local capability = REQUIRED_CAPABILITY[kind]
        assert(capability ~= nil, "unsupported content action kind")
        assert(instance.contentPackRegistry:has_capability(pack_id, capability),
            "content pack lacks capability for action kind: " .. capability)
        local requires_confirmation = action.requiresPlayerConfirmation == true
        assert(type(action.requiresPlayerConfirmation) == "boolean",
            "content action confirmation policy must be explicit")
        if CONFIRMATION_REQUIRED[kind] then
            assert(requires_confirmation,
                "irreversible content action must require player confirmation")
        end
        normalized.actions[#normalized.actions + 1] = {
            actionId = action_id,
            kind = kind,
            parameters = normalize_parameters(
                instance,
                pack_id,
                kind,
                action.parameters
            ),
            requiresPlayerConfirmation = requires_confirmation,
            contentPackId = pack_id,
            contentVersion = pack.contentVersion,
        }
    end
    assert(#normalized.actions > 0, "content-action pack cannot be empty")
    return normalized
end

function ContentActionRuntime:register_pack(pack)
    local ok, normalized_or_error = pcall(normalize_pack, self, pack)
    if not ok then
        return result(false, "invalid-content-action-pack", {
            validationError = tostring(normalized_or_error),
        })
    end
    local normalized = normalized_or_error
    local fingerprint = stable_encode(normalized)
    local existing = self.packDefinitions[normalized.contentPackId]
    if existing ~= nil then
        if existing.fingerprint == fingerprint then
            return result(true, "content-action-pack-already-registered", {
                contentPackId = normalized.contentPackId,
                actionCount = #normalized.actions,
            })
        end
        return result(false, "content-action-pack-migration-required")
    end
    for _, action in ipairs(normalized.actions) do
        if self.actions[action.actionId] ~= nil then
            return result(false, "content-action-id-conflict", {
                actionId = action.actionId,
            })
        end
    end
    self.packDefinitions[normalized.contentPackId] = {
        fingerprint = fingerprint,
        definition = copy(normalized),
    }
    for _, action in ipairs(normalized.actions) do
        self.actions[action.actionId] = copy(action)
    end
    return result(true, "content-action-pack-registered", {
        contentPackId = normalized.contentPackId,
        actionCount = #normalized.actions,
    })
end

local function materialize_owner(owner, context)
    local value = copy(owner)
    if value.kind == "player" then
        value.id = stable_id(context.playerId,
            "player ID for content action")
    end
    return value
end

local function execute(instance, action, event_id, context)
    local p = action.parameters
    if action.kind == "award_task_reputation" then
        return instance.factionApi:award_task(
            p.factionId,
            p.amount,
            event_id
        )
    elseif action.kind == "join_human_faction" then
        return instance.factionApi:join_human(p.factionId, event_id)
    elseif action.kind == "clear_affiliation_hostility" then
        return instance.factionApi:clear_affiliation_hostility(
            p.targetFactionId,
            p.sourceFactionId,
            event_id
        )
    elseif action.kind == "transfer_unique_pal" then
        return instance.strategicWorld:transfer_unique_pal(
            p.uniquePalId,
            materialize_owner(p.expectedOwner, context),
            materialize_owner(p.newOwner, context),
            event_id,
            { reason = action.actionId }
        )
    elseif action.kind == "preserve_city" then
        return instance.strategicWorld:preserve_city(
            p.cityId,
            event_id,
            { sourceId = context.sourceId }
        )
    elseif action.kind == "occupy_city" then
        return instance.strategicWorld:occupy_city(
            p.cityId,
            p.ownerFactionId,
            event_id,
            { sourceId = context.sourceId }
        )
    elseif action.kind == "destroy_city" then
        return instance.strategicWorld:destroy_city(
            p.cityId,
            materialize_owner(p.actor, context),
            event_id,
            { sourceId = context.sourceId }
        )
    elseif action.kind == "restore_city" then
        return instance.strategicWorld:restore_city(
            p.cityId,
            p.ownerFactionId,
            event_id,
            { sourceId = context.sourceId }
        )
    elseif action.kind == "issue_ultimatum" then
        return instance.strategicWorld:issue_ultimatum(
            p.ultimatumId,
            p.issuerFactionId,
            p.targetId,
            p.demand,
            event_id
        )
    elseif action.kind == "resolve_ultimatum" then
        return instance.strategicWorld:resolve_ultimatum(
            p.ultimatumId,
            p.accepted,
            event_id,
            { sourceId = context.sourceId }
        )
    elseif action.kind == "set_ending_flag" then
        return instance.endingRuntime:set_flag(p.key, p.value, event_id)
    elseif action.kind == "commit_ending_route" then
        return instance.endingRuntime:commit(p.routeId, event_id)
    end
    return result(false, "unsupported-content-action-kind")
end

function ContentActionRuntime:dispatch(action_id, event_id, context)
    stable_id(action_id, "content action ID")
    stable_id(event_id, "content action event ID")
    assert(type(context) == "table", "content action context is required")
    assert_only_fields(context, {
        sourceKind = true,
        sourceId = true,
        playerConfirmed = true,
        playerId = true,
    }, "content action context")
    local source_kind = non_empty(context.sourceKind,
        "content action source kind")
    assert(source_kind == "quest-completion"
        or source_kind == "player-confirmed-choice"
        or source_kind == "native-event",
        "unsupported content action source kind")
    stable_id(context.sourceId, "content action source ID")
    assert(type(context.playerConfirmed) == "boolean",
        "content action player-confirmed flag must be explicit")
    local action = self.actions[action_id]
    if action == nil then return result(false, "unknown-content-action") end
    if action.requiresPlayerConfirmation and not context.playerConfirmed then
        return result(false, "player-confirmation-required", {
            actionId = action_id,
        })
    end
    local signature = stable_encode({
        actionId = action_id,
        sourceKind = context.sourceKind,
        sourceId = context.sourceId,
        playerId = context.playerId,
    })
    local previous = self.state.processedEventIds[event_id]
    if previous ~= nil then
        if previous.signature ~= signature then
            return result(false, "content-action-event-id-conflict")
        end
        local replay = copy(previous.response)
        replay.ok = true
        replay.reason = "content-action-already-dispatched"
        replay.duplicateOfReason = previous.response.reason
        return replay
    end
    local ok, outcome_or_error = pcall(
        execute,
        self,
        action,
        event_id,
        context
    )
    if not ok then
        return result(false, "content-action-execution-failed", {
            actionId = action_id,
            executionError = tostring(outcome_or_error),
        })
    end
    if type(outcome_or_error) ~= "table" or outcome_or_error.ok ~= true then
        return outcome_or_error
    end
    local response = copy(outcome_or_error)
    response.actionId = action_id
    response.contentPackId = action.contentPackId
    response.sourceKind = context.sourceKind
    response.sourceId = context.sourceId
    self.state.processedEventIds[event_id] = {
        signature = signature,
        response = copy(response),
    }
    return response
end

function ContentActionRuntime:action_status(action_id)
    local action = self.actions[action_id]
    return action and copy(action) or nil
end

function ContentActionRuntime:export_registered_packs()
    local packs = {}
    for pack_id, record in pairs(self.packDefinitions) do
        packs[pack_id] = copy(record.definition)
    end
    return packs
end

function ContentActionRuntime:status()
    local pack_count = 0
    local action_count = 0
    local event_count = 0
    for _ in pairs(self.packDefinitions) do pack_count = pack_count + 1 end
    for _ in pairs(self.actions) do action_count = action_count + 1 end
    for _ in pairs(self.state.processedEventIds) do event_count = event_count + 1 end
    return {
        apiVersion = self.version,
        packCount = pack_count,
        actionCount = action_count,
        processedEventCount = event_count,
        registeredActionsOnly = true,
        questStructuredResultBinding = true,
        playerConfirmationForIrreversibleActions = true,
        modelMayDispatch = false,
        PalworldSaveMutation = false,
    }
end

function ContentActionRuntime:dispatch_structured_result(
    structured_result,
    event_id_prefix,
    context
)
    assert(type(structured_result) == "table",
        "quest structured result is required")
    stable_id(event_id_prefix, "content action event prefix")
    assert(type(context) == "table", "content action context is required")
    local action_ids = structured_result.contentActionIds
    if action_ids == nil and structured_result.contentActionId ~= nil then
        action_ids = { structured_result.contentActionId }
    end
    if type(action_ids) ~= "table" or #action_ids == 0 then
        return result(false, "content-actions-not-declared", {
            dispatchedCount = 0,
        })
    end
    local seen = {}
    local outcomes = {}
    for index, action_id in ipairs(action_ids) do
        stable_id(action_id, "content action ID")
        if seen[action_id] then
            return result(false, "duplicate-content-action-id", {
                actionId = action_id,
                dispatchedCount = #outcomes,
            })
        end
        seen[action_id] = true
        local outcome = self:dispatch(
            action_id,
            event_id_prefix .. ":" .. tostring(index),
            context
        )
        outcomes[#outcomes + 1] = copy(outcome)
        if not outcome.ok then
            return result(false, "content-action-batch-stopped", {
                actionId = action_id,
                actionReason = outcome.reason,
                dispatchedCount = index - 1,
                outcomes = outcomes,
            })
        end
    end
    return result(true, "content-actions-dispatched", {
        dispatchedCount = #outcomes,
        outcomes = outcomes,
    })
end

function ContentActionRuntime:rebind_progression(progression)
    assert(type(progression) == "table" and type(progression.state) == "table",
        "progression instance is required")
    self.factionApi.progression = progression
    self.state = make_state(progression)
    return result(true, "content-action-progression-rebound")
end

return ContentActionRuntime
