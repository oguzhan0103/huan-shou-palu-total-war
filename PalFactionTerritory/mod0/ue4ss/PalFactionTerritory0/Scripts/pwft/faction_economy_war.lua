local FactionEconomyWar = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"

local ALLOWED_TRANSITIONS = {
    stable = { trade_requested = true },
    trade_requested = { threat = true, ceasefire = true },
    threat = { war = true, ceasefire = true },
    war = { ceasefire = true },
    ceasefire = { stable = true, trade_requested = true },
}

local BAND_RANK = {
    absent = 1,
    scarce = 2,
    limited = 3,
    established = 4,
    strong = 5,
    abundant = 6,
    dominant = 7,
    exclusive = 8,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[copy(key)] = copy(child) end
    return result
end

local function result(ok, reason, extra)
    local response = extra or {}
    response.ok = ok
    response.reason = reason
    return response
end

local function non_empty(value)
    return type(value) == "string" and value ~= ""
end

local function non_negative_integer(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function positive_integer(value)
    return non_negative_integer(value) and value > 0
end

local function count_keys(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
end

local function sorted_keys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function conflict_key(faction_id, resource_id)
    return faction_id .. "|" .. resource_id
end

local function make_state(max_history)
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        eventCount = 0,
        historyDropped = 0,
        maxHistory = max_history,
        history = {},
        operationSignatures = {},
        conflicts = {},
    }
end

local function validate_dependencies(progression, resource_ledger)
    assert(type(progression) == "table" and type(progression.state) == "table",
        "progression state root is required")
    assert(type(resource_ledger) == "table"
            and type(resource_ledger.market_signal) == "function"
            and type(resource_ledger.resource_status) == "function",
        "faction resource ledger is required")
    assert(count_keys(resource_ledger.factions) == 7,
        "economy-war runtime requires seven human economy factions")
    assert(count_keys(resource_ledger.resources) == 8,
        "economy-war runtime requires eight resource channels")
end

local function ensure_state(instance)
    local root = instance.progression.state
    if type(root.factionEconomyWar) ~= "table" then
        root.factionEconomyWar = make_state(instance.maxHistory)
    end
    local state = root.factionEconomyWar
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported faction economy-war snapshot schema")
    state.revision = state.revision or 0
    state.eventCount = state.eventCount or 0
    state.historyDropped = state.historyDropped or 0
    state.maxHistory = state.maxHistory or instance.maxHistory
    state.history = state.history or {}
    state.operationSignatures = state.operationSignatures or {}
    state.conflicts = state.conflicts or {}
    for key, record in pairs(state.conflicts) do
        assert(type(record) == "table", "economy-war conflict record must be a table")
        assert(key == conflict_key(record.requesterFactionId, record.resourceId),
            "economy-war conflict key mismatch")
        assert(instance.resourceLedger.factions[record.requesterFactionId] ~= nil,
            "economy-war snapshot contains an unknown requester faction")
        assert(instance.resourceLedger.factions[record.supplierFactionId] ~= nil,
            "economy-war snapshot contains an unknown supplier faction")
        assert(instance.resourceLedger.resources[record.resourceId] ~= nil,
            "economy-war snapshot contains an unknown resource")
        assert(ALLOWED_TRANSITIONS[record.status] ~= nil,
            "economy-war snapshot contains an invalid status")
        assert(non_negative_integer(record.nextTransitionTick),
            "economy-war next transition tick must be a non-negative integer")
    end
    return state
end

local function append_bounded(state, event)
    state.history[#state.history + 1] = copy(event)
    if #state.history > state.maxHistory then
        table.remove(state.history, 1)
        state.historyDropped = state.historyDropped + 1
    end
end

local function operation_signature(faction_id, resource_id, logical_tick)
    return faction_id .. "|" .. resource_id .. "|" .. tostring(logical_tick)
end

local function duplicate_operation(instance, operation_id, signature)
    local previous = instance.state.operationSignatures[operation_id]
    if previous == nil then return nil end
    if previous.signature ~= signature then
        return result(false, "operation-id-conflict")
    end
    local response = copy(previous.response)
    response.ok = true
    response.reason = "duplicate-operation"
    response.duplicateOfReason = previous.response.reason
    return response
end

local function commit_transition(instance, operation_id, signature, response, event)
    local state = instance.state
    state.operationSignatures[operation_id] = {
        signature = signature,
        response = copy(response),
    }
    state.revision = state.revision + 1
    state.eventCount = state.eventCount + 1
    event.revision = state.revision
    append_bounded(state, event)
    if instance.onChange ~= nil then
        local called, message = pcall(instance.onChange, event.requesterFactionId, copy(event))
        if not called then instance.lastNotificationError = tostring(message) end
    end
    return response
end

local function select_supplier(instance, requester_faction_id, resource_id)
    local best = nil
    for _, faction_id in ipairs(sorted_keys(instance.resourceLedger.factions)) do
        if faction_id ~= requester_faction_id then
            local signal = instance.resourceLedger:market_signal(faction_id, resource_id)
            if signal ~= nil and signal.direction == "sell" then
                local candidate = {
                    factionId = faction_id,
                    supplyBand = signal.supplyBand,
                    quantity = signal.quantity,
                }
                if best == nil
                    or BAND_RANK[candidate.supplyBand] > BAND_RANK[best.supplyBand]
                    or (BAND_RANK[candidate.supplyBand] == BAND_RANK[best.supplyBand]
                        and candidate.quantity > best.quantity)
                    or (BAND_RANK[candidate.supplyBand] == BAND_RANK[best.supplyBand]
                        and candidate.quantity == best.quantity
                        and candidate.factionId < best.factionId) then
                    best = candidate
                end
            end
        end
    end
    return best
end

local function transition(instance, record, next_status, logical_tick)
    assert(ALLOWED_TRANSITIONS[record.status][next_status] == true,
        "invalid economy-war transition")
    local previous_status = record.status
    record.status = next_status
    record.lastTransitionTick = logical_tick
    record.nextTransitionTick = logical_tick + instance.cooldownTicks
    record.transitionCount = record.transitionCount + 1
    return previous_status
end

function FactionEconomyWar.create(progression, resource_ledger, options)
    options = options or {}
    validate_dependencies(progression, resource_ledger)
    local cooldown_ticks = options.cooldownTicks or 3
    local max_history = options.maxHistory or 128
    assert(positive_integer(cooldown_ticks),
        "economy-war cooldownTicks must be a positive integer")
    assert(positive_integer(max_history),
        "economy-war maxHistory must be a positive integer")
    assert(options.onChange == nil or type(options.onChange) == "function",
        "economy-war onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        resourceLedger = resource_ledger,
        cooldownTicks = cooldown_ticks,
        maxHistory = max_history,
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            shortageDrivenTransitions = true,
            deterministicSupplierSelection = true,
            tradeRequestState = true,
            threatState = true,
            warState = true,
            ceasefireState = true,
            logicalTickCooldown = true,
            idempotentOperations = true,
            boundedHistory = true,
            modOwnedProgressionSnapshot = true,
            automaticCombatMutation = false,
            automaticFactionRelationMutation = false,
            gameObjectMutation = false,
            currencyMutation = false,
            palworldSaveMutation = false,
        },
    }, { __index = FactionEconomyWar })
    instance.state = ensure_state(instance)
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.faction-economy-war.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function FactionEconomyWar:rebind_progression_state()
    local called, rebound = pcall(ensure_state, self)
    if not called then
        return result(false, "economy-war-snapshot-invalid", { error = tostring(rebound) })
    end
    self.state = rebound
    return result(true, "economy-war-state-rebound")
end

function FactionEconomyWar:advance_shortage(
    requester_faction_id,
    resource_id,
    operation_id,
    logical_tick
)
    if self.resourceLedger.factions[requester_faction_id] == nil then
        return result(false, "unknown-economy-faction")
    end
    if self.resourceLedger.resources[resource_id] == nil then
        return result(false, "unknown-economy-resource")
    end
    if not non_empty(operation_id) then return result(false, "operation-id-required") end
    if not non_negative_integer(logical_tick) then
        return result(false, "non-negative-logical-tick-required")
    end
    local signature = operation_signature(requester_faction_id, resource_id, logical_tick)
    local duplicate = duplicate_operation(self, operation_id, signature)
    if duplicate ~= nil then return duplicate end

    local key = conflict_key(requester_faction_id, resource_id)
    local record = self.state.conflicts[key]
    local signal = self.resourceLedger:market_signal(requester_faction_id, resource_id)
    local shortage = signal.direction == "procure"

    if record == nil then
        if not shortage then
            return result(false, "no-active-shortage", {
                factionId = requester_faction_id,
                resourceId = resource_id,
                supplyBand = signal.supplyBand,
            })
        end
        local supplier = select_supplier(self, requester_faction_id, resource_id)
        if supplier == nil then
            return result(false, "no-supplier-available", {
                factionId = requester_faction_id,
                resourceId = resource_id,
            })
        end
        record = {
            requesterFactionId = requester_faction_id,
            supplierFactionId = supplier.factionId,
            resourceId = resource_id,
            status = "stable",
            openedTick = logical_tick,
            lastTransitionTick = logical_tick,
            nextTransitionTick = logical_tick,
            transitionCount = 0,
            supplierSupplyBand = supplier.supplyBand,
        }
        self.state.conflicts[key] = record
    end

    if logical_tick < record.lastTransitionTick then
        return result(false, "logical-tick-regression", {
            lastTransitionTick = record.lastTransitionTick,
        })
    end

    local next_status = nil
    local transition_reason = nil
    if shortage then
        if record.status == "war" then
            return result(false, "war-already-active", {
                conflict = copy(record),
            })
        end
        if logical_tick < record.nextTransitionTick then
            return result(false, "transition-cooldown-active", {
                conflict = copy(record),
                remainingTicks = record.nextTransitionTick - logical_tick,
            })
        end
        if record.status == "stable" or record.status == "ceasefire" then
            next_status = "trade_requested"
            transition_reason = "resource-shortage-trade-requested"
        elseif record.status == "trade_requested" then
            next_status = "threat"
            transition_reason = "unresolved-shortage-threat-issued"
        elseif record.status == "threat" then
            next_status = "war"
            transition_reason = "unresolved-shortage-war-declared"
        end
    else
        if record.status == "stable" then
            return result(false, "no-active-shortage")
        elseif record.status == "ceasefire" then
            if logical_tick < record.nextTransitionTick then
                return result(false, "transition-cooldown-active", {
                    conflict = copy(record),
                    remainingTicks = record.nextTransitionTick - logical_tick,
                })
            end
            next_status = "stable"
            transition_reason = "ceasefire-stabilized"
        else
            next_status = "ceasefire"
            transition_reason = "shortage-resolved-ceasefire"
        end
    end

    local previous_status = transition(self, record, next_status, logical_tick)
    local response = result(true, transition_reason, {
        operationId = operation_id,
        requesterFactionId = requester_faction_id,
        supplierFactionId = record.supplierFactionId,
        resourceId = resource_id,
        beforeStatus = previous_status,
        status = record.status,
        supplyBand = signal.supplyBand,
        nextTransitionTick = record.nextTransitionTick,
        conflict = copy(record),
    })
    return commit_transition(self, operation_id, signature, response, {
        type = "economy-war-transition",
        operationId = operation_id,
        requesterFactionId = requester_faction_id,
        supplierFactionId = record.supplierFactionId,
        resourceId = resource_id,
        beforeStatus = previous_status,
        status = record.status,
        reason = transition_reason,
        logicalTick = logical_tick,
        nextTransitionTick = record.nextTransitionTick,
    })
end

function FactionEconomyWar:conflict_status(requester_faction_id, resource_id)
    return copy(self.state.conflicts[conflict_key(requester_faction_id, resource_id)])
end

function FactionEconomyWar:active_conflicts()
    local conflicts = {}
    for _, key in ipairs(sorted_keys(self.state.conflicts)) do
        local record = self.state.conflicts[key]
        if record.status ~= "stable" then conflicts[#conflicts + 1] = copy(record) end
    end
    return conflicts
end

function FactionEconomyWar:status()
    local counts = { stable = 0, trade_requested = 0, threat = 0, war = 0, ceasefire = 0 }
    for _, record in pairs(self.state.conflicts) do counts[record.status] = counts[record.status] + 1 end
    return {
        apiVersion = self.version,
        schemaVersion = self.state.schemaVersion,
        revision = self.state.revision,
        eventCount = self.state.eventCount,
        conflictCount = count_keys(self.state.conflicts),
        activeConflictCount = #self:active_conflicts(),
        counts = counts,
        cooldownTicks = self.cooldownTicks,
        historyCount = #self.state.history,
        historyDropped = self.state.historyDropped,
        operationSignatureCount = count_keys(self.state.operationSignatures),
        lastNotificationError = self.lastNotificationError,
    }
end

function FactionEconomyWar:export_snapshot()
    return copy(self.state)
end

return FactionEconomyWar
