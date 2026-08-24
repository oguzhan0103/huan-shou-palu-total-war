local FactionDynamicEconomy = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do
        result[copy(key)] = copy(child)
    end
    return result
end

local function non_empty(value)
    return type(value) == "string" and value ~= ""
end

local function round_to_step(value, step)
    return math.floor((value + step / 2) / step) * step
end

local function clamp_integer(value, minimum, maximum)
    local integer = math.floor(value)
    if integer < minimum then return minimum end
    if integer > maximum then return maximum end
    return integer
end

local function count_keys(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
end

local function validate(base_economy, resource_ledger)
    assert(type(base_economy) == "table"
            and type(base_economy.commodity_signal) == "function"
            and type(base_economy.faction_market) == "function",
        "validated faction economy is required")
    assert(type(resource_ledger) == "table"
            and type(resource_ledger.resource_status) == "function"
            and type(resource_ledger.status) == "function",
        "faction resource ledger is required")
    assert(count_keys(base_economy.factions) == 7,
        "dynamic economy requires seven human factions")
    assert(count_keys(resource_ledger.resources) == 8,
        "dynamic economy requires eight resource channels")
end

function FactionDynamicEconomy.create(base_economy, resource_ledger)
    validate(base_economy, resource_ledger)
    return setmetatable({
        version = API_VERSION,
        baseEconomy = base_economy,
        resourceLedger = resource_ledger,
        contract = base_economy.contract,
        bandOrder = base_economy.bandOrder,
        balanceProfile = base_economy.balanceProfile,
        resources = base_economy.resources,
        resourceByItem = base_economy.resourceByItem,
        merchantInputs = base_economy.merchantInputs,
        factions = base_economy.factions,
        products = base_economy.products,
        capabilities = {
            resourceLedgerAuthority = true,
            liveSupplyBandProjection = true,
            dynamicSellPrices = true,
            dynamicStockCounts = true,
            dynamicProcurementRequests = true,
            multiInputBottleneck = true,
            merchantInputCostFloor = true,
            deterministicProjection = true,
            gameObjectMutation = false,
            currencyMutation = false,
            palworldSaveMutation = false,
        },
    }, { __index = FactionDynamicEconomy })
end

function FactionDynamicEconomy:commodity_signal(faction_id, product_id)
    if not non_empty(faction_id) then
        error("faction ID must be a non-empty string")
    end
    if not non_empty(product_id) then
        error("product item ID must be a non-empty string")
    end
    local baseline, reason = self.baseEconomy:commodity_signal(
        faction_id,
        product_id
    )
    if baseline == nil then return nil, reason end

    local signal = copy(baseline)
    local limiting_band = nil
    local limiting_ordinal = nil
    local available_units = nil
    local quantities = {}
    for _, input in ipairs(signal.inputs) do
        local status = self.resourceLedger:resource_status(
            faction_id,
            input.resourceId
        )
        if status == nil then
            return nil, "resource-ledger-status-unavailable"
        end
        input.supplyBand = status.supplyBand
        input.quantity = status.quantity
        quantities[input.resourceId] = status.quantity
        local ordinal = self.bandOrder[status.supplyBand]
        if limiting_ordinal == nil or ordinal < limiting_ordinal then
            limiting_ordinal = ordinal
            limiting_band = status.supplyBand
        end
        local units = math.floor(status.quantity / input.count)
        if available_units == nil or units < available_units then
            available_units = units
        end
    end

    signal.effectiveSupplyBand = limiting_band
    signal.resourceQuantities = quantities
    signal.availableProductionUnits = available_units
    signal.resourceLedgerRevision = self.resourceLedger:status().revision
    signal.projectionAuthority = "pwft.faction-resource-ledger.v1"
    signal.direction = "unresolved"
    signal.reason = "no-territorial-resource-input"
    signal.exactPriceMultiplier = nil
    signal.exactSellPrice = nil
    signal.exactStockCount = nil
    signal.stockValueBudget = nil
    signal.exactProcurementPriceMultiplier = nil
    signal.exactProcurementPrice = nil
    signal.exactProcurementQuota = nil
    signal.procurementValueBudget = nil
    if limiting_ordinal == nil then return signal end

    local profile = self.balanceProfile
    local parameters = assert(profile.bands[limiting_band],
        "missing dynamic balance parameters")
    if parameters.direction == "procure" then
        signal.direction = "procure"
        signal.reason = "live-resource-shortage-requests-procurement"
        signal.exactPriceMultiplier =
            parameters.procurementPriceMultiplier
        signal.exactProcurementPriceMultiplier =
            parameters.procurementPriceMultiplier
        signal.exactProcurementPrice = round_to_step(
            signal.nativeBasePrice
                * parameters.procurementPriceMultiplier,
            profile.priceRoundingStep
        )
        signal.procurementValueBudget =
            parameters.procurementValueBudget
        signal.exactProcurementQuota = clamp_integer(
            parameters.procurementValueBudget
                / signal.exactProcurementPrice,
            profile.minimumUnitsPerActiveLine,
            profile.maximumUnitsPerActiveLine
        )
    else
        signal.direction = "sell"
        signal.reason = "live-resource-stock-supports-production"
        signal.exactPriceMultiplier = parameters.sellPriceMultiplier
        signal.exactSellPrice = math.max(
            round_to_step(
                signal.nativeBasePrice
                    * parameters.sellPriceMultiplier,
                profile.priceRoundingStep
            ),
            signal.merchantInputCostFloor
        )
        signal.stockValueBudget = parameters.stockValueBudget
        local budget_stock = clamp_integer(
            parameters.stockValueBudget / signal.exactSellPrice,
            profile.minimumUnitsPerActiveLine,
            profile.maximumUnitsPerActiveLine
        )
        signal.exactStockCount = math.max(
            1,
            math.min(budget_stock, available_units or budget_stock)
        )
    end
    return signal
end

function FactionDynamicEconomy:faction_market(faction_id)
    if self.factions[faction_id] == nil then
        return nil, "unknown-economy-faction"
    end
    local market = {
        factionId = faction_id,
        sell = {},
        procure = {},
        unresolved = {},
        resourceLedgerRevision = self.resourceLedger:status().revision,
    }
    for _, product in ipairs(self.contract.auditedProducts) do
        local signal, reason = self:commodity_signal(
            faction_id,
            product.productItemId
        )
        if signal == nil then return nil, reason end
        table.insert(market[signal.direction], signal)
    end
    return market
end

function FactionDynamicEconomy:is_requested_item(faction_id, product_id)
    local signal = self:commodity_signal(faction_id, product_id)
    return signal ~= nil and signal.direction == "procure"
end

function FactionDynamicEconomy:status()
    local product_count = 0
    local procurement_count = 0
    local unresolved_count = 0
    for faction_id in pairs(self.factions) do
        local market = assert(self:faction_market(faction_id))
        product_count = product_count + #market.sell
        procurement_count = procurement_count + #market.procure
        unresolved_count = unresolved_count + #market.unresolved
    end
    local status = copy(self.baseEconomy:status())
    status.version = self.version
    status.apiVersion = self.version
    status.resourceLedgerRevision = self.resourceLedger:status().revision
    status.marketSignalCount = product_count + procurement_count
        + unresolved_count
    status.productCount = product_count
    status.procurementCount = procurement_count
    status.unresolvedCount = unresolved_count
    status.dynamicSellPrices = true
    status.dynamicStockCounts = true
    status.dynamicProcurementRequests = true
    status.dynamicPriceRuntimeEnabled = true
    status.balanceRuntimeAuthority = true
    status.projectionAuthority = "pwft.faction-resource-ledger.v1"
    return status
end

return FactionDynamicEconomy
