local FactionEconomy = {}

local API_VERSION = "1.1.0"

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

local function require_non_empty_string(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function count_keys(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count
end

local function round_to_step(value, step)
    return math.floor((value + step / 2) / step) * step
end

local function clamp_integer(value, minimum, maximum)
    local integer = math.floor(value)
    if integer < minimum then
        return minimum
    end
    if integer > maximum then
        return maximum
    end
    return integer
end

local function validate_contract(contract)
    assert(type(contract) == "table", "faction economy contract is required")
    assert(
        contract.schemaVersion == "1.0.0",
        "unsupported faction economy contract schema"
    )
    assert(
        contract.baselineStatus
            == "user_confirmed_trade_direction_resource_and_recipe_baseline_complete_balance_pending_2026-07-29",
        "faction economy baseline is not active"
    )
    assert(
        contract.designPolicy.merchantOrganisationFactionId == nil,
        "Merchant Guild must remain independent"
    )
    assert(
        contract.designPolicy.sellsProcessedGoodsFromLocalResources == true,
        "economy must derive processed goods from local resources"
    )
    assert(
        contract.designPolicy.procuresGoodsMissingFromLocalSupply == true,
        "economy must procure missing goods"
    )
    assert(
        contract.designPolicy.sellingUnrequestedGoodsGrantsCommerceReputation
            == false,
        "unrequested goods cannot grant faction reputation"
    )
    assert(#contract.factions == 7, "expected seven human economy factions")
    assert(#contract.resources == 8, "expected eight mineral channels")
    assert(
        #contract.auditedProducts == 9,
        "expected nine audited processed-goods candidates"
    )

    local band_order = {}
    for index, band in ipairs(
        contract.supplyBands.orderedLowToHigh
    ) do
        require_non_empty_string(band, "supply band")
        assert(band_order[band] == nil, "duplicate supply band")
        band_order[band] = index
    end
    assert(band_order.absent ~= nil, "absent supply band is required")
    assert(band_order.scarce ~= nil, "scarce supply band is required")
    assert(band_order.limited ~= nil, "limited supply band is required")

    local balance_profile = contract.marketRules.balanceProfile
    assert(
        balance_profile.status
            == "offline_first_pass_complete_user_confirmation_and_live_calibration_pending",
        "economy balance profile status drifted"
    )
    assert(
        balance_profile.runtimeAuthority == false,
        "offline economy balance cannot mutate runtime shops"
    )
    assert(
        balance_profile.supplyIndexMode
            == "audited_supply_band_only_no_numeric_vein_weight",
        "economy cannot assume a numeric vein production weight"
    )
    assert(
        type(balance_profile.priceRoundingStep) == "number"
            and balance_profile.priceRoundingStep > 0,
        "price rounding step must be positive"
    )
    assert(
        type(balance_profile.merchantInputCostFloorMultiplier) == "number"
            and balance_profile.merchantInputCostFloorMultiplier >= 1,
        "merchant input cost floor multiplier must be at least one"
    )
    assert(
        type(balance_profile.minimumUnitsPerActiveLine) == "number"
            and balance_profile.minimumUnitsPerActiveLine >= 1,
        "minimum active-line units must be positive"
    )
    assert(
        type(balance_profile.maximumUnitsPerActiveLine) == "number"
            and balance_profile.maximumUnitsPerActiveLine
                >= balance_profile.minimumUnitsPerActiveLine,
        "maximum active-line units must not be below the minimum"
    )
    local previous_sell_multiplier = nil
    local previous_stock_budget = nil
    for _, band in ipairs(contract.supplyBands.orderedLowToHigh) do
        local parameters = balance_profile.bands[band]
        assert(parameters ~= nil, "missing balance parameters for supply band")
        if band_order[band] <= band_order.scarce then
            assert(
                parameters.direction == "procure",
                "absent and scarce supply bands must procure"
            )
            assert(
                type(parameters.procurementPriceMultiplier) == "number"
                    and parameters.procurementPriceMultiplier > 1,
                "procurement price multiplier must be above native price"
            )
            assert(
                type(parameters.procurementValueBudget) == "number"
                    and parameters.procurementValueBudget > 0,
                "procurement value budget must be positive"
            )
        else
            assert(
                parameters.direction == "sell",
                "limited-or-better supply bands must sell"
            )
            assert(
                type(parameters.sellPriceMultiplier) == "number"
                    and parameters.sellPriceMultiplier > 0,
                "sell price multiplier must be positive"
            )
            assert(
                type(parameters.stockValueBudget) == "number"
                    and parameters.stockValueBudget > 0,
                "stock value budget must be positive"
            )
            if previous_sell_multiplier ~= nil then
                assert(
                    parameters.sellPriceMultiplier
                        <= previous_sell_multiplier,
                    "sell prices must not rise with supply"
                )
                assert(
                    parameters.stockValueBudget
                        >= previous_stock_budget,
                    "stock value budgets must not fall with supply"
                )
            end
            previous_sell_multiplier = parameters.sellPriceMultiplier
            previous_stock_budget = parameters.stockValueBudget
        end
    end
    assert(
        balance_profile.bands.absent.procurementPriceMultiplier
            >= balance_profile.bands.scarce.procurementPriceMultiplier,
        "absent procurement price must not be below scarce procurement price"
    )
    assert(
        balance_profile.bands.absent.procurementValueBudget
            >= balance_profile.bands.scarce.procurementValueBudget,
        "absent procurement budget must not be below scarce procurement budget"
    )

    local merchant_inputs = {}
    local merchant_input_policy = contract.merchantInputPolicy
    assert(
        merchant_input_policy.regionalEndowmentAuditRequired == false,
        "existing merchant inputs cannot require regional audits"
    )
    assert(
        merchant_input_policy.countsTowardEffectiveSupplyBand == false,
        "existing merchant inputs cannot reduce territorial supply"
    )
    assert(
        merchant_input_policy.countsTowardProductCostFloor == true,
        "existing merchant inputs must contribute to product cost"
    )
    for _, input in ipairs(merchant_input_policy.inputs) do
        require_non_empty_string(input.itemId, "merchant input item ID")
        assert(
            type(input.nativeBasePrice) == "number"
                and input.nativeBasePrice > 0,
            "merchant input native price must be positive"
        )
        assert(
            merchant_inputs[input.itemId] == nil,
            "duplicate existing merchant input"
        )
        merchant_inputs[input.itemId] = copy(input)
    end

    local resources = {}
    local resource_by_item = {}
    for _, resource in ipairs(contract.resources) do
        require_non_empty_string(resource.resourceId, "resource ID")
        require_non_empty_string(resource.nativeItemId, "resource item ID")
        assert(
            type(resource.nativeBasePrice) == "number"
                and resource.nativeBasePrice > 0,
            "territorial resource native price must be positive"
        )
        assert(resources[resource.resourceId] == nil, "duplicate resource ID")
        assert(
            resource_by_item[resource.nativeItemId] == nil,
            "duplicate native resource item ID"
        )
        resources[resource.resourceId] = copy(resource)
        resource_by_item[resource.nativeItemId] = resources[resource.resourceId]
    end

    local factions = {}
    for _, faction in ipairs(contract.factions) do
        require_non_empty_string(faction.factionId, "economy faction ID")
        require_non_empty_string(faction.territoryId, "economy territory ID")
        assert(factions[faction.factionId] == nil, "duplicate economy faction")
        for resource_id, observation in pairs(
            faction.resourceBaseline
        ) do
            assert(resources[resource_id] ~= nil, "unknown economy resource")
            assert(
                band_order[observation.supplyBand] ~= nil,
                "unknown faction resource supply band"
            )
        end
        assert(
            count_keys(faction.resourceBaseline) == #contract.resources,
            "faction resource baseline is incomplete"
        )
        factions[faction.factionId] = copy(faction)
    end

    local products = {}
    for _, product in ipairs(contract.auditedProducts) do
        require_non_empty_string(product.productItemId, "product item ID")
        assert(
            products[product.productItemId] == nil,
            "duplicate audited product"
        )
        assert(
            type(product.materials) == "table"
                and #product.materials > 0,
            "audited product materials are required"
        )
        assert(
            type(product.nativeBasePrice) == "number"
                and product.nativeBasePrice > 0,
            "audited product native price must be positive"
        )
        for _, material in ipairs(product.materials) do
            require_non_empty_string(material.itemId, "material item ID")
            assert(
                type(material.count) == "number"
                    and material.count > 0,
                "material count must be positive"
            )
            assert(
                resource_by_item[material.itemId] ~= nil
                    or merchant_inputs[material.itemId] ~= nil,
                "product input is neither territorial nor merchant supplied"
            )
        end
        products[product.productItemId] = copy(product)
    end

    local activation = contract.runtimeActivation
    assert(
        activation.nativeMerchantSpawnEnabled == false,
        "economy cannot spawn merchants before live validation"
    )
    assert(
        activation.customProductRowsEnabled == false,
        "economy custom product rows must remain disabled"
    )
    assert(
        activation.dynamicPriceRuntimeEnabled == false,
        "dynamic price runtime must remain disabled"
    )
    assert(
        activation.requestedSaleReputationSettlementEnabled == false,
        "requested-sale settlement must remain disabled"
    )

    return {
        bandOrder = band_order,
        balanceProfile = copy(balance_profile),
        resources = resources,
        resourceByItem = resource_by_item,
        merchantInputs = merchant_inputs,
        factions = factions,
        products = products,
    }
end

function FactionEconomy.create(contract)
    local indexes = validate_contract(contract)
    return setmetatable({
        version = API_VERSION,
        contract = copy(contract),
        bandOrder = indexes.bandOrder,
        balanceProfile = indexes.balanceProfile,
        resources = indexes.resources,
        resourceByItem = indexes.resourceByItem,
        merchantInputs = indexes.merchantInputs,
        factions = indexes.factions,
        products = indexes.products,
        capabilities = {
            territorialResourceEndowment = true,
            processedGoodsSignals = true,
            missingGoodsProcurementSignals = true,
            multiInputBottleneck = true,
            existingMerchantInputSupply = true,
            nativeBasePrices = true,
            offlineBalanceProfile = true,
            exactPriceMultipliers = true,
            exactStockCounts = true,
            exactProcurementPrices = true,
            exactProcurementQuotas = true,
            runtimeMerchantMutation = false,
            runtimeReputationSettlement = false,
        },
    }, { __index = FactionEconomy })
end

function FactionEconomy:commodity_signal(faction_id, product_id)
    local faction = self.factions[
        require_non_empty_string(faction_id, "faction ID")
    ]
    if faction == nil then
        return nil, "unknown-economy-faction"
    end
    local product = self.products[
        require_non_empty_string(product_id, "product item ID")
    ]
    if product == nil then
        return nil, "unknown-economy-product"
    end

    local inputs = {}
    local merchant_supplied_inputs = {}
    local merchant_input_native_cost = 0
    local limiting_band = nil
    local limiting_ordinal = nil
    for _, material in ipairs(product.materials) do
        local resource = self.resourceByItem[material.itemId]
        if resource == nil then
            local merchant_input = assert(
                self.merchantInputs[material.itemId],
                "unregistered merchant-supplied input"
            )
            table.insert(merchant_supplied_inputs, {
                itemId = material.itemId,
                count = material.count,
                displayNameZhHans = merchant_input.displayNameZhHans,
                nativeBasePrice = merchant_input.nativeBasePrice,
                nativeCost = merchant_input.nativeBasePrice
                    * material.count,
                role = merchant_input.role,
            })
            merchant_input_native_cost = merchant_input_native_cost
                + merchant_input.nativeBasePrice * material.count
        else
            local observation =
                faction.resourceBaseline[resource.resourceId]
            local ordinal = self.bandOrder[
                observation.supplyBand
            ]
            table.insert(inputs, {
                itemId = material.itemId,
                resourceId = resource.resourceId,
                count = material.count,
                ordinaryNodes = observation.ordinaryNodes,
                veins = observation.veins,
                supplyBand = observation.supplyBand,
            })
            if limiting_ordinal == nil
                or ordinal < limiting_ordinal then
                limiting_ordinal = ordinal
                limiting_band = observation.supplyBand
            end
        end
    end

    local balance_profile = self.balanceProfile
    local merchant_input_cost_floor = round_to_step(
        merchant_input_native_cost
            * balance_profile.merchantInputCostFloorMultiplier,
        balance_profile.priceRoundingStep
    )
    local signal = {
        factionId = faction_id,
        territoryId = faction.territoryId,
        productItemId = product_id,
        displayNameZhHans = product.displayNameZhHans,
        nativeBasePrice = product.nativeBasePrice,
        inputs = inputs,
        merchantSuppliedInputs = merchant_supplied_inputs,
        merchantInputNativeCost = merchant_input_native_cost,
        merchantInputCostFloor = merchant_input_cost_floor,
        supplyMode = #merchant_supplied_inputs == 0
            and "territorial-only"
            or "territorial-bottleneck-plus-existing-merchant-inputs",
        effectiveSupplyBand = limiting_band,
        direction = "unresolved",
        reason = "no-territorial-resource-input",
        balanceProfileId = balance_profile.profileId,
        balanceProfileStatus = balance_profile.status,
        exactPriceMultiplier = nil,
        exactSellPrice = nil,
        exactStockCount = nil,
        stockValueBudget = nil,
        exactProcurementPriceMultiplier = nil,
        exactProcurementPrice = nil,
        exactProcurementQuota = nil,
        procurementValueBudget = nil,
    }
    if limiting_ordinal == nil then
        return signal
    end

    local parameters = assert(
        balance_profile.bands[limiting_band],
        "missing balance parameters for effective supply band"
    )
    if parameters.direction == "procure" then
        signal.direction = "procure"
        signal.reason = "local-effective-supply-shortfall"
        signal.exactPriceMultiplier =
            parameters.procurementPriceMultiplier
        signal.exactProcurementPriceMultiplier =
            parameters.procurementPriceMultiplier
        signal.exactProcurementPrice = round_to_step(
            product.nativeBasePrice
                * parameters.procurementPriceMultiplier,
            balance_profile.priceRoundingStep
        )
        signal.procurementValueBudget =
            parameters.procurementValueBudget
        signal.exactProcurementQuota = clamp_integer(
            parameters.procurementValueBudget
                / signal.exactProcurementPrice,
            balance_profile.minimumUnitsPerActiveLine,
            balance_profile.maximumUnitsPerActiveLine
        )
    else
        signal.direction = "sell"
        signal.reason = "local-effective-supply-supports-production"
        signal.exactPriceMultiplier = parameters.sellPriceMultiplier
        signal.exactSellPrice = math.max(
            round_to_step(
                product.nativeBasePrice
                    * parameters.sellPriceMultiplier,
                balance_profile.priceRoundingStep
            ),
            merchant_input_cost_floor
        )
        signal.stockValueBudget = parameters.stockValueBudget
        signal.exactStockCount = clamp_integer(
            parameters.stockValueBudget / signal.exactSellPrice,
            balance_profile.minimumUnitsPerActiveLine,
            balance_profile.maximumUnitsPerActiveLine
        )
    end
    return signal
end

function FactionEconomy:faction_market(faction_id)
    if self.factions[
        require_non_empty_string(faction_id, "faction ID")
    ] == nil then
        return nil, "unknown-economy-faction"
    end
    local market = {
        factionId = faction_id,
        sell = {},
        procure = {},
        unresolved = {},
    }
    for _, product in ipairs(self.contract.auditedProducts) do
        local signal = self:commodity_signal(
            faction_id,
            product.productItemId
        )
        table.insert(market[signal.direction], signal)
    end
    return market
end

function FactionEconomy:is_requested_item(faction_id, product_id)
    local signal = self:commodity_signal(faction_id, product_id)
    return signal ~= nil and signal.direction == "procure"
end

function FactionEconomy:status()
    local closed_loop_products = 0
    local merchant_supplied_input_products = 0
    local unresolved_products = 0
    local sample_faction_id = self.contract.factions[1].factionId
    for _, product in ipairs(self.contract.auditedProducts) do
        local signal = self:commodity_signal(
            sample_faction_id,
            product.productItemId
        )
        if signal.direction == "unresolved" then
            unresolved_products = unresolved_products + 1
        elseif #signal.merchantSuppliedInputs == 0 then
            closed_loop_products = closed_loop_products + 1
        else
            merchant_supplied_input_products =
                merchant_supplied_input_products + 1
        end
    end
    return {
        version = self.version,
        factionCount = count_keys(self.factions),
        resourceCount = count_keys(self.resources),
        auditedProductCount = count_keys(self.products),
        closedLoopProductCount = closed_loop_products,
        merchantSuppliedInputProductCount =
            merchant_supplied_input_products,
        unresolvedProductCount = unresolved_products,
        merchantOrganisationId =
            self.contract.designPolicy.merchantOrganisationId,
        merchantOrganisationDisplayNameZhHans =
            self.contract.designPolicy
                .merchantOrganisationDisplayNameZhHans,
        customProductRowsEnabled =
            self.contract.runtimeActivation.customProductRowsEnabled,
        dynamicPriceRuntimeEnabled =
            self.contract.runtimeActivation.dynamicPriceRuntimeEnabled,
        requestedSaleReputationSettlementEnabled =
            self.contract.runtimeActivation
                .requestedSaleReputationSettlementEnabled,
        balanceProfileId = self.balanceProfile.profileId,
        balanceRuntimeAuthority = self.balanceProfile.runtimeAuthority,
        balanceStatus = self.contract.marketRules.balanceStatus,
    }
end

return FactionEconomy
