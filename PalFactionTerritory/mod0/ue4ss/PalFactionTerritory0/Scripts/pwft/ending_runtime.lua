local EndingRuntime = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local PACK_SCHEMA = "pwft.ending-routes.pack.v1"

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[copy(key)] = copy(child) end
    return result
end

local function deep_equal(first, second)
    if type(first) ~= type(second) then return false end
    if type(first) ~= "table" then return first == second end
    for key, value in pairs(first) do
        if not deep_equal(value, second[key]) then return false end
    end
    for key in pairs(second) do
        if first[key] == nil then return false end
    end
    return true
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value, name)
    assert(type(value) == "string" and value ~= "", name .. " is required")
    return value
end

local function stable_id(value, name)
    non_empty(value, name)
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil, name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil, name .. " cannot contain empty namespace segments")
    return value
end

local function semver(value, name)
    non_empty(value, name)
    assert(string.match(value, "^%d+%.%d+%.%d+[%w.+-]*$") ~= nil, name .. " must use semantic version syntax")
    return value
end

local function localization_key(value, name)
    stable_id(value, name)
    assert(string.find(value, ".loc.", 1, true) ~= nil or string.find(value, ".text.", 1, true) ~= nil,
        name .. " must be a localization key")
    return value
end

local function scalar(value, name)
    local value_type = type(value)
    assert(value_type == "string" or value_type == "number" or value_type == "boolean",
        name .. " must be a scalar")
    return value
end

local function string_list(value, name, validator)
    assert(type(value) == "table" and #value > 0, name .. " must be a non-empty list")
    local seen = {}
    local normalized = {}
    for _, item in ipairs(value) do
        validator(item, name .. " item")
        assert(not seen[item], name .. " contains a duplicate: " .. item)
        seen[item] = true
        table.insert(normalized, item)
    end
    return normalized
end

local function known_rank(progression, rank_id)
    non_empty(rank_id, "rank ID")
    assert(progression.rankIndexes[rank_id] ~= nil, "unknown rank ID: " .. rank_id)
    return rank_id
end

local function validate_condition(condition, progression, strategic_world)
    assert(type(condition) == "table", "ending condition must be a table")
    local kind = non_empty(condition.kind, "ending condition kind")
    if kind == "all_human_rank" then
        return { kind = kind, rankId = known_rank(progression, condition.rankId) }
    elseif kind == "all_pal_relation" then
        local relation = non_empty(condition.relation, "Pal relation")
        assert(relation == "Friendly" or relation == "Hostile", "unsupported Pal relation")
        return { kind = kind, relation = relation }
    elseif kind == "progression_gate" then
        local gate = non_empty(condition.gate, "progression gate")
        assert(gate == "palReconciliation" or gate == "ending3", "unsupported progression gate")
        assert(type(condition.expected) == "boolean", "progression gate expected value must be boolean")
        return { kind = kind, gate = gate, expected = condition.expected }
    elseif kind == "city_status" then
        local city_ids = string_list(condition.cityIds, "city IDs", stable_id)
        for _, city_id in ipairs(city_ids) do
            assert(strategic_world:city_status(city_id) ~= nil, "ending condition references unknown city: " .. city_id)
        end
        local statuses = string_list(condition.allowedStatuses, "allowed city statuses", non_empty)
        for _, status in ipairs(statuses) do
            assert(status == "active" or status == "occupied" or status == "destroyed",
                "unsupported city status: " .. status)
        end
        return { kind = kind, cityIds = city_ids, allowedStatuses = statuses }
    elseif kind == "faction_survival" then
        local faction_ids = string_list(condition.factionIds, "faction IDs", stable_id)
        for _, faction_id in ipairs(faction_ids) do
            assert(progression.factionKinds[faction_id] ~= nil, "ending condition references unknown faction: " .. faction_id)
        end
        assert(type(condition.expected) == "boolean", "faction survival expected value must be boolean")
        return { kind = kind, factionIds = faction_ids, expected = condition.expected }
    elseif kind == "unique_pal_owner" then
        local pal_ids = string_list(condition.uniquePalIds, "unique Pal IDs", stable_id)
        for _, pal_id in ipairs(pal_ids) do
            assert(strategic_world:unique_pal_status(pal_id) ~= nil,
                "ending condition references unknown unique Pal: " .. pal_id)
        end
        local owner_kind = non_empty(condition.ownerKind, "unique Pal owner kind")
        assert(owner_kind == "player" or owner_kind == "faction" or owner_kind == "wild" or owner_kind == "unclaimed",
            "unsupported unique Pal owner kind")
        if owner_kind == "faction" then
            stable_id(condition.ownerId, "unique Pal owner faction ID")
            assert(progression.factionKinds[condition.ownerId] ~= nil, "unknown unique Pal owner faction")
        elseif owner_kind == "player" and condition.ownerId ~= nil then
            non_empty(condition.ownerId, "unique Pal owner player ID")
        else
            assert(condition.ownerId == nil, "owner ID is not allowed for this owner kind")
        end
        return {
            kind = kind,
            uniquePalIds = pal_ids,
            ownerKind = owner_kind,
            ownerId = condition.ownerId,
        }
    elseif kind == "flag_equals" then
        return {
            kind = kind,
            key = stable_id(condition.key, "ending flag key"),
            value = scalar(condition.value, "ending flag value"),
        }
    end
    error("unsupported ending condition kind: " .. kind)
end

local function validate_effect(effect, progression, strategic_world)
    assert(type(effect) == "table", "ending effect must be a table")
    local kind = non_empty(effect.kind, "ending effect kind")
    if kind == "set_title" then
        return { kind = kind, titleKey = localization_key(effect.titleKey, "ending title key") }
    elseif kind == "set_world_disposition" then
        local value = non_empty(effect.value, "world disposition")
        assert(value == "pacified" or value == "conditional" or value == "hostile",
            "unsupported world disposition")
        return { kind = kind, value = value }
    elseif kind == "set_flag" then
        return {
            kind = kind,
            key = stable_id(effect.key, "ending flag key"),
            value = scalar(effect.value, "ending flag value"),
        }
    elseif kind == "set_faction_disposition" then
        stable_id(effect.factionId, "ending faction ID")
        assert(progression.factionKinds[effect.factionId] ~= nil, "ending effect references unknown faction")
        local value = non_empty(effect.value, "ending faction disposition")
        assert(value == "non_hostile_until_attacked" or value == "friendly" or value == "hostile",
            "unsupported ending faction disposition")
        return { kind = kind, factionId = effect.factionId, value = value }
    elseif kind == "city_transition" then
        stable_id(effect.cityId, "ending city ID")
        assert(strategic_world:city_status(effect.cityId) ~= nil, "ending effect references unknown city")
        local status = non_empty(effect.status, "ending city status")
        assert(status == "active" or status == "occupied" or status == "destroyed",
            "unsupported ending city status")
        if effect.ownerFactionId ~= nil then
            stable_id(effect.ownerFactionId, "ending city owner faction ID")
            assert(progression.factionKinds[effect.ownerFactionId] == "Human",
                "ending city owner must be a known human faction")
        end
        return {
            kind = kind,
            cityId = effect.cityId,
            status = status,
            ownerFactionId = effect.ownerFactionId,
        }
    end
    error("unsupported ending effect kind: " .. kind)
end

local function normalize_pack(pack, progression, strategic_world)
    assert(type(pack) == "table", "ending routes pack is required")
    assert(pack.schemaVersion == PACK_SCHEMA, "unsupported ending routes pack schema")
    local normalized = {
        schemaVersion = PACK_SCHEMA,
        contentPackId = stable_id(pack.contentPackId, "content pack ID"),
        contentVersion = semver(pack.contentVersion, "content version"),
        routes = {},
    }
    assert(type(pack.routes) == "table" and #pack.routes > 0, "ending routes are required")
    local route_ids = {}
    for _, route in ipairs(pack.routes) do
        assert(type(route) == "table", "ending route must be a table")
        local id = stable_id(route.id, "ending route ID")
        assert(not route_ids[id], "duplicate ending route ID: " .. id)
        route_ids[id] = true
        assert(type(route.conditions) == "table" and #route.conditions > 0, "ending route conditions are required")
        assert(type(route.effects) == "table" and #route.effects > 0, "ending route effects are required")
        local normalized_route = {
            id = id,
            displayNameKey = localization_key(route.displayNameKey, "ending route display name key"),
            priority = tonumber(route.priority) or 0,
            conditions = {},
            effects = {},
        }
        for _, condition in ipairs(route.conditions) do
            table.insert(normalized_route.conditions, validate_condition(condition, progression, strategic_world))
        end
        for _, effect in ipairs(route.effects) do
            table.insert(normalized_route.effects, validate_effect(effect, progression, strategic_world))
        end
        table.insert(normalized.routes, normalized_route)
    end
    return normalized
end

local function make_state()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        eventCount = 0,
        lastEvent = nil,
        packs = {},
        processedOperationIds = {},
        flags = {},
        completedRouteId = nil,
        completedOperationId = nil,
        postEnding = {
            titleKey = nil,
            worldDisposition = "conditional",
            factionDispositionById = {},
        },
    }
end

local function ensure_state(progression)
    if type(progression.state.endings) ~= "table" then progression.state.endings = make_state() end
    local state = progression.state.endings
    assert(state.schemaVersion == STATE_SCHEMA_VERSION, "unsupported ending state schema")
    state.revision = state.revision or 0
    state.eventCount = state.eventCount or 0
    state.packs = state.packs or {}
    state.processedOperationIds = state.processedOperationIds or {}
    state.flags = state.flags or {}
    state.postEnding = state.postEnding or {}
    state.postEnding.worldDisposition = state.postEnding.worldDisposition or "conditional"
    state.postEnding.factionDispositionById = state.postEnding.factionDispositionById or {}
    return state
end

local function notify(instance, event)
    instance.state.revision = instance.state.revision + 1
    instance.state.eventCount = instance.state.eventCount + 1
    event.revision = instance.state.revision
    instance.state.lastEvent = copy(event)
    if instance.onChange ~= nil then
        local ok, error_message = pcall(instance.onChange, nil, copy(event))
        if not ok then instance.lastNotificationError = tostring(error_message) end
    end
end

local function rank_at_least(instance, faction_id, required_rank)
    local record = instance.progression:status(faction_id)
    local current = record and record.rankId and instance.progression.rankIndexes[record.rankId] or 0
    return current >= instance.progression.rankIndexes[required_rank]
end

local function condition_status(instance, condition)
    if condition.kind == "all_human_rank" then
        local missing = {}
        for _, faction_id in ipairs(instance.progression.contract.humanFactionIds) do
            if not rank_at_least(instance, faction_id, condition.rankId) then table.insert(missing, faction_id) end
        end
        return #missing == 0, { missingFactionIds = missing }
    elseif condition.kind == "all_pal_relation" then
        local missing = {}
        for _, faction_id in ipairs(instance.progression.contract.palFactionIds) do
            local status = instance.progression:status(faction_id)
            if status.relation ~= condition.relation then table.insert(missing, faction_id) end
        end
        return #missing == 0, { missingFactionIds = missing }
    elseif condition.kind == "progression_gate" then
        local gates = instance.progression:gate_status()
        local actual = condition.gate == "ending3" and gates.ending3Unlocked or gates.palReconciliationUnlocked
        return actual == condition.expected, { expected = condition.expected, actual = actual }
    elseif condition.kind == "city_status" then
        local allowed = {}
        for _, status in ipairs(condition.allowedStatuses) do allowed[status] = true end
        local failing = {}
        for _, city_id in ipairs(condition.cityIds) do
            local status = instance.strategicWorld:city_status(city_id)
            if not allowed[status.status] then table.insert(failing, city_id) end
        end
        return #failing == 0, { failingCityIds = failing }
    elseif condition.kind == "faction_survival" then
        local failing = {}
        for _, faction_id in ipairs(condition.factionIds) do
            local survives = instance.strategicWorld:faction_status(faction_id).survives
            if survives ~= condition.expected then table.insert(failing, faction_id) end
        end
        return #failing == 0, { failingFactionIds = failing }
    elseif condition.kind == "unique_pal_owner" then
        local failing = {}
        for _, pal_id in ipairs(condition.uniquePalIds) do
            local owner = instance.strategicWorld:unique_pal_status(pal_id).owner
            local owner_matches = owner.kind == condition.ownerKind
                and (condition.ownerId == nil or owner.id == condition.ownerId)
            if not owner_matches then table.insert(failing, pal_id) end
        end
        return #failing == 0, { failingUniquePalIds = failing }
    elseif condition.kind == "flag_equals" then
        local actual = instance.state.flags[condition.key]
        return actual == condition.value, { expected = condition.value, actual = actual }
    end
    return false, { error = "unsupported-condition" }
end

function EndingRuntime.create(progression, strategic_world, options)
    options = options or {}
    assert(type(strategic_world) == "table", "strategic-world service is required")
    assert(options.onChange == nil or type(options.onChange) == "function", "ending onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        strategicWorld = strategic_world,
        state = ensure_state(progression),
        onChange = options.onChange,
        contentPackRegistry = options.contentPackRegistry,
        routeDefinitions = {},
        packDefinitions = {},
        lastNotificationError = nil,
        capabilities = {
            contentDefinedRoutes = true,
            deterministicConditionEvaluation = true,
            oneCommittedEndingPerWorld = true,
            persistentPostEndingPolicy = true,
            cityWorldStateEffects = true,
            modelMayCommitEnding = false,
            storyContentIncluded = false,
        },
    }, { __index = EndingRuntime })
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.ending-runtime.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function EndingRuntime:rebind_progression_state()
    local previous_state = self.state
    self.state = ensure_state(self.progression)
    local initialized = 0
    for content_pack_id, normalized in pairs(self.packDefinitions) do
        local existing = self.state.packs[content_pack_id]
        if existing == nil then
            self.state.packs[content_pack_id] = {
                contentPackId = content_pack_id,
                contentVersion = normalized.contentVersion,
                definition = copy(normalized),
            }
            initialized = initialized + 1
        else
            assert(
                existing.contentVersion == normalized.contentVersion,
                "restored ending pack requires migration: "
                    .. content_pack_id
            )
            if existing.definition ~= nil then
                assert(
                    deep_equal(existing.definition, normalized),
                    "restored ending pack definition mismatch: "
                        .. content_pack_id
                )
            else
                existing.definition = copy(normalized)
            end
        end
    end
    return result(true, "progression-state-rebound", {
        stateChanged = previous_state ~= self.state,
        initializedPackCount = initialized,
    })
end

function EndingRuntime:register_pack(pack)
    local ok, normalized_or_error = pcall(normalize_pack, pack, self.progression, self.strategicWorld)
    if not ok then return result(false, "invalid-ending-pack", { error = tostring(normalized_or_error) }) end
    local normalized = normalized_or_error
    if self.contentPackRegistry ~= nil then
        local manifest = self.contentPackRegistry:manifest(normalized.contentPackId)
        if manifest == nil then
            return result(false, "content-pack-manifest-not-registered", {
                contentPackId = normalized.contentPackId,
            })
        end
        if not self.contentPackRegistry:has_capability(normalized.contentPackId, "pwft.world.endings") then
            return result(false, "content-pack-capability-missing", {
                contentPackId = normalized.contentPackId,
            })
        end
    end
    local existing = self.state.packs[normalized.contentPackId]
    if existing ~= nil and existing.contentVersion ~= normalized.contentVersion then
        return result(false, "ending-pack-migration-required", {
            currentVersion = existing.contentVersion,
            requestedVersion = normalized.contentVersion,
        })
    end
    if existing ~= nil and existing.definition ~= nil and not deep_equal(existing.definition, normalized) then
        return result(false, "ending-pack-version-content-mismatch", {
            contentPackId = normalized.contentPackId,
            contentVersion = normalized.contentVersion,
        })
    end
    for _, route in ipairs(normalized.routes) do
        local current = self.routeDefinitions[route.id]
        if current ~= nil and current.contentPackId ~= normalized.contentPackId then
            return result(false, "ending-route-id-conflict", { routeId = route.id })
        end
    end
    self.packDefinitions[normalized.contentPackId] = copy(normalized)
    for _, route in ipairs(normalized.routes) do
        local registered = copy(route)
        registered.contentPackId = normalized.contentPackId
        registered.contentVersion = normalized.contentVersion
        self.routeDefinitions[route.id] = registered
    end
    if existing ~= nil then
        return result(true, "ending-pack-already-registered", { contentPackId = normalized.contentPackId })
    end
    self.state.packs[normalized.contentPackId] = {
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        definition = copy(normalized),
    }
    notify(self, {
        type = "ending-pack-registered",
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
    })
    return result(true, "ending-pack-registered", {
        contentPackId = normalized.contentPackId,
        routeCount = #normalized.routes,
    })
end

function EndingRuntime:set_flag(key, value, operation_id)
    stable_id(key, "ending flag key")
    scalar(value, "ending flag value")
    non_empty(operation_id, "operation ID")
    if self.state.processedOperationIds[operation_id] ~= nil then
        return result(true, "duplicate-operation", copy(self.state.processedOperationIds[operation_id]))
    end
    self.state.flags[key] = value
    local response = result(true, "ending-flag-set", { key = key, value = value })
    self.state.processedOperationIds[operation_id] = copy(response)
    notify(self, { type = "ending-flag-set", key = key, value = value, operationId = operation_id })
    return response
end

function EndingRuntime:evaluate(route_id)
    local route = self.routeDefinitions[route_id]
    if route == nil then return result(false, "unknown-ending-route") end
    local checks = {}
    local ready = true
    for index, condition in ipairs(route.conditions) do
        local passed, details = condition_status(self, condition)
        table.insert(checks, {
            index = index,
            kind = condition.kind,
            passed = passed,
            details = details,
        })
        if not passed then ready = false end
    end
    return result(true, ready and "ending-route-ready" or "ending-route-locked", {
        routeId = route_id,
        ready = ready,
        checks = checks,
        alreadyCompletedRouteId = self.state.completedRouteId,
    })
end

function EndingRuntime:available_routes()
    local routes = {}
    for route_id, definition in pairs(self.routeDefinitions) do
        local evaluation = self:evaluate(route_id)
        table.insert(routes, {
            id = route_id,
            displayNameKey = definition.displayNameKey,
            priority = definition.priority,
            ready = evaluation.ready,
            reason = evaluation.reason,
        })
    end
    table.sort(routes, function(first, second)
        if first.priority == second.priority then return first.id < second.id end
        return first.priority > second.priority
    end)
    return routes
end

function EndingRuntime:commit(route_id, operation_id)
    non_empty(operation_id, "operation ID")
    local previous = self.state.processedOperationIds[operation_id]
    if previous ~= nil then
        local duplicate = copy(previous)
        duplicate.ok = true
        duplicate.reason = "duplicate-operation"
        return duplicate
    end
    if self.state.completedRouteId ~= nil then
        return result(false, "ending-already-committed", { completedRouteId = self.state.completedRouteId })
    end
    local evaluation = self:evaluate(route_id)
    if not evaluation.ok then return evaluation end
    if not evaluation.ready then return evaluation end
    local route = self.routeDefinitions[route_id]
    local applied_effects = {}
    for index, effect in ipairs(route.effects) do
        if effect.kind == "set_title" then
            self.state.postEnding.titleKey = effect.titleKey
        elseif effect.kind == "set_world_disposition" then
            self.state.postEnding.worldDisposition = effect.value
        elseif effect.kind == "set_flag" then
            self.state.flags[effect.key] = effect.value
        elseif effect.kind == "set_faction_disposition" then
            self.state.postEnding.factionDispositionById[effect.factionId] = effect.value
        elseif effect.kind == "city_transition" then
            local transition = self.strategicWorld:apply_ending_transition(
                effect.cityId,
                { status = effect.status, ownerFactionId = effect.ownerFactionId },
                operation_id .. ":city:" .. tostring(index),
                { authority = "pwft.ending-runtime.v1", routeId = route_id }
            )
            assert(transition.ok, "validated ending city transition failed: " .. tostring(transition.reason))
        end
        table.insert(applied_effects, copy(effect))
    end
    self.state.completedRouteId = route_id
    self.state.completedOperationId = operation_id
    local response = result(true, "ending-committed", {
        routeId = route_id,
        postEnding = copy(self.state.postEnding),
        effects = applied_effects,
    })
    self.state.processedOperationIds[operation_id] = copy(response)
    notify(self, { type = "ending-committed", routeId = route_id, operationId = operation_id })
    return response
end

function EndingRuntime:post_ending_policy()
    return {
        completedRouteId = self.state.completedRouteId,
        completed = self.state.completedRouteId ~= nil,
        titleKey = self.state.postEnding.titleKey,
        worldDisposition = self.state.postEnding.worldDisposition,
        factionDispositionById = copy(self.state.postEnding.factionDispositionById),
        ordinaryActorsNonHostileUntilAttacked = self.state.postEnding.worldDisposition == "pacified",
    }
end

function EndingRuntime:status()
    local pack_count = 0
    local route_count = 0
    for _ in pairs(self.state.packs) do pack_count = pack_count + 1 end
    for _ in pairs(self.routeDefinitions) do route_count = route_count + 1 end
    return {
        apiVersion = self.version,
        schemaVersion = self.state.schemaVersion,
        revision = self.state.revision,
        contentPackCount = pack_count,
        routeCount = route_count,
        completedRouteId = self.state.completedRouteId,
        storyContentIncluded = false,
        lastNotificationError = self.lastNotificationError,
    }
end

function EndingRuntime:export_snapshot()
    return copy(self.state)
end

return EndingRuntime
