local FactionResourceLedger = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"

local EVENT_TYPES = {
    production = true,
    consumption = true,
    trade = true,
    import = true,
    loss = true,
}

local COMMON_EVENT_FIELDS = {
    operationId = true,
    type = true,
    factionId = true,
    resourceId = true,
    amount = true,
    direction = true,
}

local BAND_RULES = {
    { id = "absent", minimum = 0, maximum = 0, baseline = 0 },
    { id = "scarce", minimum = 1, maximum = 49, baseline = 25 },
    { id = "limited", minimum = 50, maximum = 99, baseline = 75 },
    { id = "established", minimum = 100, maximum = 249, baseline = 150 },
    { id = "strong", minimum = 250, maximum = 399, baseline = 300 },
    { id = "abundant", minimum = 400, maximum = 599, baseline = 500 },
    { id = "dominant", minimum = 600, maximum = 799, baseline = 700 },
    { id = "exclusive", minimum = 800, maximum = nil, baseline = 1000 },
}

local SIGNAL_RULES = {
    absent = {
        direction = "procure",
        priceMultiplier = 1.40,
        valueBudget = 30000,
    },
    scarce = {
        direction = "procure",
        priceMultiplier = 1.20,
        valueBudget = 18000,
    },
    limited = {
        direction = "sell",
        priceMultiplier = 1.15,
        valueBudget = 8000,
    },
    established = {
        direction = "sell",
        priceMultiplier = 1.00,
        valueBudget = 16000,
    },
    strong = {
        direction = "sell",
        priceMultiplier = 0.90,
        valueBudget = 28000,
    },
    abundant = {
        direction = "sell",
        priceMultiplier = 0.82,
        valueBudget = 40000,
    },
    dominant = {
        direction = "sell",
        priceMultiplier = 0.75,
        valueBudget = 60000,
    },
    exclusive = {
        direction = "sell",
        priceMultiplier = 0.70,
        valueBudget = 80000,
    },
}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[copy(key)] = copy(child)
    end
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

local function positive_integer(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function count_keys(values)
    local count = 0
    for _ in pairs(values or {}) do
        count = count + 1
    end
    return count
end

local function clamp_integer(value, minimum, maximum)
    local integer = math.floor(value)
    if integer < minimum then return minimum end
    if integer > maximum then return maximum end
    return integer
end

local function round_to_step(value, step)
    return math.floor((value + step / 2) / step) * step
end

local function band_for_quantity(quantity)
    for _, rule in ipairs(BAND_RULES) do
        if quantity >= rule.minimum
            and (rule.maximum == nil or quantity <= rule.maximum) then
            return rule.id
        end
    end
    error("resource quantity did not map to a supply band")
end

local function baseline_quantity(band)
    for _, rule in ipairs(BAND_RULES) do
        if rule.id == band then return rule.baseline end
    end
    error("unsupported baseline supply band: " .. tostring(band))
end

local function build_indexes(progression, economy_contract)
    assert(type(progression) == "table" and type(progression.state) == "table",
        "progression state root is required")
    assert(type(economy_contract) == "table", "faction economy contract is required")
    assert(economy_contract.schemaVersion == "1.0.0", "unsupported faction economy contract schema")
    assert(type(economy_contract.factions) == "table" and #economy_contract.factions == 7,
        "resource ledger requires seven economy factions")
    assert(type(economy_contract.resources) == "table" and #economy_contract.resources == 8,
        "resource ledger requires eight resource channels")

    local resources = {}
    for _, definition in ipairs(economy_contract.resources) do
        assert(non_empty(definition.resourceId), "resource ID is required")
        assert(non_empty(definition.nativeItemId), "resource item ID is required")
        assert(type(definition.nativeBasePrice) == "number" and definition.nativeBasePrice > 0,
            "resource native base price must be positive")
        assert(resources[definition.resourceId] == nil,
            "duplicate resource definition: " .. definition.resourceId)
        resources[definition.resourceId] = copy(definition)
    end

    local factions = {}
    for _, definition in ipairs(economy_contract.factions) do
        local faction_id = definition.factionId
        assert(non_empty(faction_id), "economy faction ID is required")
        assert(progression.factionKinds[faction_id] == "Human",
            "resource ledger faction must be a known human faction")
        assert(factions[faction_id] == nil, "duplicate economy faction: " .. faction_id)
        assert(type(definition.resourceBaseline) == "table"
                and count_keys(definition.resourceBaseline) == 8,
            "faction resource baseline must contain eight channels")
        for resource_id, observation in pairs(definition.resourceBaseline) do
            assert(resources[resource_id] ~= nil, "unknown resource in faction baseline")
            baseline_quantity(observation.supplyBand)
        end
        factions[faction_id] = copy(definition)
    end
    return factions, resources
end

local function make_state(factions, resources, max_history)
    local state = {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        eventCount = 0,
        historyDropped = 0,
        maxHistory = max_history,
        history = {},
        operationSignatures = {},
        factions = {},
    }
    for faction_id, faction in pairs(factions) do
        local record = {
            factionId = faction_id,
            territoryId = faction.territoryId,
            resources = {},
        }
        for resource_id in pairs(resources) do
            local initial_band = faction.resourceBaseline[resource_id].supplyBand
            record.resources[resource_id] = {
                resourceId = resource_id,
                quantity = baseline_quantity(initial_band),
                initialSupplyBand = initial_band,
                production = 0,
                consumption = 0,
                tradeInbound = 0,
                tradeOutbound = 0,
                imports = 0,
                losses = 0,
            }
        end
        state.factions[faction_id] = record
    end
    return state
end

local function ensure_state(instance)
    local root = instance.progression.state
    if type(root.factionResourceLedger) ~= "table" then
        root.factionResourceLedger = make_state(
            instance.factions,
            instance.resources,
            instance.maxHistory
        )
    end
    local state = root.factionResourceLedger
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported faction resource ledger snapshot schema")
    assert(type(state.factions) == "table", "resource ledger factions are required")
    for faction_id in pairs(instance.factions) do
        local faction = state.factions[faction_id]
        assert(type(faction) == "table" and type(faction.resources) == "table",
            "resource ledger snapshot is missing faction: " .. faction_id)
        for resource_id in pairs(instance.resources) do
            local resource = faction.resources[resource_id]
            assert(type(resource) == "table" and resource.resourceId == resource_id,
                "resource ledger snapshot is missing resource: " .. faction_id .. "/" .. resource_id)
            assert(type(resource.quantity) == "number" and resource.quantity >= 0
                    and resource.quantity == math.floor(resource.quantity),
                "resource ledger quantity must be a non-negative integer")
        end
    end
    state.history = state.history or {}
    state.operationSignatures = state.operationSignatures or {}
    state.historyDropped = state.historyDropped or 0
    state.eventCount = state.eventCount or 0
    state.revision = state.revision or 0
    state.maxHistory = state.maxHistory or instance.maxHistory
    return state
end

local function event_signature(event)
    return table.concat({
        event.type,
        event.factionId,
        event.resourceId,
        tostring(event.amount),
        event.direction or "-",
    }, "|")
end

local function validate_event(instance, event)
    if type(event) ~= "table" then return false, "event-table-required" end
    for key in pairs(event) do
        if COMMON_EVENT_FIELDS[key] ~= true then
            return false, "event-field-not-allowed"
        end
    end
    if not non_empty(event.operationId) then return false, "operation-id-required" end
    if EVENT_TYPES[event.type] ~= true then return false, "unsupported-resource-event" end
    if instance.factions[event.factionId] == nil then return false, "unknown-economy-faction" end
    if instance.resources[event.resourceId] == nil then return false, "unknown-economy-resource" end
    if not positive_integer(event.amount) then return false, "positive-integer-amount-required" end
    if event.type == "trade" then
        if event.direction ~= "inbound" and event.direction ~= "outbound" then
            return false, "trade-direction-required"
        end
    elseif event.direction ~= nil then
        return false, "direction-only-allowed-for-trade"
    end
    return true, nil
end

local function append_bounded(values, value, maximum)
    values[#values + 1] = value
    if #values > maximum then
        table.remove(values, 1)
        return true
    end
    return false
end

local function commit_operation(instance, operation_id, signature, response, event)
    local state = instance.state
    state.operationSignatures[operation_id] = {
        signature = signature,
        response = copy(response),
    }
    state.revision = state.revision + 1
    state.eventCount = state.eventCount + 1
    event.revision = state.revision
    if append_bounded(state.history, copy(event), state.maxHistory) then
        state.historyDropped = state.historyDropped + 1
    end
    if instance.onChange ~= nil then
        local called, message = pcall(instance.onChange, event.factionId, copy(event))
        if not called then instance.lastNotificationError = tostring(message) end
    end
    return response
end

function FactionResourceLedger.create(progression, economy_contract, options)
    options = options or {}
    local factions, resources = build_indexes(progression, economy_contract)
    local max_history = options.maxHistory or 128
    assert(positive_integer(max_history), "resource ledger maxHistory must be a positive integer")
    assert(options.onChange == nil or type(options.onChange) == "function",
        "resource ledger onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        factions = factions,
        resources = resources,
        maxHistory = max_history,
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            modOwnedProgressionSnapshot = true,
            sevenFactionBaseline = true,
            eightResourceBaseline = true,
            strictEventWhitelist = true,
            idempotentOperations = true,
            deterministicMarketSignals = true,
            boundedHistory = true,
            gameObjectMutation = false,
            currencyMutation = false,
            palworldSaveMutation = false,
        },
    }, { __index = FactionResourceLedger })
    instance.state = ensure_state(instance)
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.faction-resource-ledger.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function FactionResourceLedger:rebind_progression_state()
    local called, rebound = pcall(ensure_state, self)
    if not called then
        return result(false, "resource-ledger-snapshot-invalid", {
            error = tostring(rebound),
        })
    end
    self.state = rebound
    return result(true, "resource-ledger-state-rebound")
end

function FactionResourceLedger:apply_event(event)
    local valid, reason = validate_event(self, event)
    if not valid then return result(false, reason) end
    local signature = event_signature(event)
    local previous = self.state.operationSignatures[event.operationId]
    if previous ~= nil then
        if previous.signature ~= signature then
            return result(false, "operation-id-conflict")
        end
        local response = copy(previous.response)
        response.ok = true
        response.reason = "duplicate-operation"
        response.duplicateOfReason = previous.response.reason
        return response
    end

    local record = self.state.factions[event.factionId].resources[event.resourceId]
    local delta = event.amount
    if event.type == "consumption" or event.type == "loss"
        or (event.type == "trade" and event.direction == "outbound") then
        delta = -event.amount
    end
    if record.quantity + delta < 0 then
        return result(false, "insufficient-resource-stock", {
            available = record.quantity,
            requested = event.amount,
        })
    end

    local before = record.quantity
    record.quantity = record.quantity + delta
    if event.type == "production" then
        record.production = record.production + event.amount
    elseif event.type == "consumption" then
        record.consumption = record.consumption + event.amount
    elseif event.type == "import" then
        record.imports = record.imports + event.amount
    elseif event.type == "loss" then
        record.losses = record.losses + event.amount
    elseif event.direction == "inbound" then
        record.tradeInbound = record.tradeInbound + event.amount
    else
        record.tradeOutbound = record.tradeOutbound + event.amount
    end
    local before_band = band_for_quantity(before)
    local after_band = band_for_quantity(record.quantity)
    local response = result(true, "resource-event-applied", {
        operationId = event.operationId,
        factionId = event.factionId,
        resourceId = event.resourceId,
        eventType = event.type,
        direction = event.direction,
        amount = event.amount,
        before = before,
        after = record.quantity,
        beforeSupplyBand = before_band,
        supplyBand = after_band,
    })
    return commit_operation(self, event.operationId, signature, response, {
        type = "resource-event-applied",
        operationId = event.operationId,
        factionId = event.factionId,
        resourceId = event.resourceId,
        resourceEventType = event.type,
        direction = event.direction,
        amount = event.amount,
        before = before,
        after = record.quantity,
        beforeSupplyBand = before_band,
        supplyBand = after_band,
    })
end

function FactionResourceLedger:resource_status(faction_id, resource_id)
    local faction = self.state.factions[faction_id]
    if faction == nil or self.resources[resource_id] == nil then return nil end
    local status = copy(faction.resources[resource_id])
    status.factionId = faction_id
    status.supplyBand = band_for_quantity(status.quantity)
    status.definition = copy(self.resources[resource_id])
    return status
end

function FactionResourceLedger:market_signal(faction_id, resource_id)
    local status = self:resource_status(faction_id, resource_id)
    if status == nil then return nil, "unknown-faction-or-resource" end
    local rule = SIGNAL_RULES[status.supplyBand]
    local unit_price = round_to_step(
        status.definition.nativeBasePrice * rule.priceMultiplier,
        10
    )
    local signal = {
        factionId = faction_id,
        resourceId = resource_id,
        nativeItemId = status.definition.nativeItemId,
        quantity = status.quantity,
        supplyBand = status.supplyBand,
        direction = rule.direction,
        priceMultiplier = rule.priceMultiplier,
        unitPrice = unit_price,
        valueBudget = rule.valueBudget,
        exactStockCount = nil,
        exactProcurementQuota = nil,
    }
    if rule.direction == "sell" then
        signal.exactStockCount = math.min(
            status.quantity,
            clamp_integer(rule.valueBudget / unit_price, 1, 99)
        )
        signal.reason = "resource-stock-supports-sale"
    else
        local missing_to_limited = math.max(1, 50 - status.quantity)
        signal.exactProcurementQuota = math.min(
            missing_to_limited,
            clamp_integer(rule.valueBudget / unit_price, 1, 99)
        )
        signal.reason = "resource-shortage-requests-procurement"
    end
    return signal
end

function FactionResourceLedger:faction_status(faction_id)
    if self.state.factions[faction_id] == nil then return nil end
    local value = {
        factionId = faction_id,
        territoryId = self.state.factions[faction_id].territoryId,
        resources = {},
    }
    for resource_id in pairs(self.resources) do
        value.resources[resource_id] = self:resource_status(faction_id, resource_id)
    end
    return value
end

function FactionResourceLedger:status()
    return {
        apiVersion = self.version,
        schemaVersion = self.state.schemaVersion,
        revision = self.state.revision,
        eventCount = self.state.eventCount,
        factionCount = count_keys(self.state.factions),
        resourceCount = count_keys(self.resources),
        historyCount = #self.state.history,
        historyDropped = self.state.historyDropped,
        operationSignatureCount = count_keys(self.state.operationSignatures),
        lastNotificationError = self.lastNotificationError,
    }
end

function FactionResourceLedger:export_snapshot()
    return copy(self.state)
end

return FactionResourceLedger
