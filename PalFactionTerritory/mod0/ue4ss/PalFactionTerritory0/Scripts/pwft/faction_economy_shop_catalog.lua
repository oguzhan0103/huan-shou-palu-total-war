local FactionEconomyShopCatalog = {}

local API_VERSION = "1.0.0"

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

local function validate_contract(contract, economy)
    assert(type(contract) == "table", "economy shop contract is required")
    assert(type(economy) == "table", "faction economy service is required")
    assert(
        contract.schemaVersion == "1.0.0",
        "unsupported economy shop contract schema"
    )
    assert(
        contract.baselineStatus
            == "offline_shop_asset_and_catalog_ready_runtime_disabled_2026-07-29",
        "economy shop asset baseline is not active"
    )
    assert(
        contract.designPolicy.fixedCountersAreMerchantGuildEmployees == true,
        "fixed counters must remain Merchant Guild employees"
    )
    assert(
        contract.designPolicy.fixedCountersAreFactionMembers == false,
        "fixed counters cannot become faction members"
    )
    assert(
        contract.designPolicy.allCountersUseItemShop == true,
        "economy representatives must use ordinary ItemShop"
    )
    assert(
        contract.designPolicy.raynePalMerchantIsExcludedSpecialCase == true,
        "Rayne Pal merchant special case must remain excluded"
    )
    assert(
        contract.procurementAdapter.nativeItemShopRequestedItemFilterAvailable
            == false,
        "native ItemShop cannot claim a requested-item filter"
    )
    assert(
        contract.procurementAdapter
            .nativeItemShopProcurementPriceOverrideAvailable
            == false,
        "native ItemShop cannot claim a procurement-price override"
    )
    assert(
        contract.procurementAdapter.targetPriceSettlementMode
            == "native_sale_plus_mod_bonus_after_confirmed_server_success",
        "procurement settlement mode drifted"
    )
    assert(
        contract.procurementAdapter.serverSuccessSignalStatus
            == "replication_probe_ready_settlement_disabled_live_acceptance_pending",
        "server sale replication must remain settlement-disabled pending live acceptance"
    )
    assert(
        contract.procurementAdapter.moneyBonusMutationEnabled == false,
        "procurement money mutation must remain disabled"
    )
    assert(
        contract.procurementAdapter
            .commerceReputationSettlementEnabled
            == false,
        "procurement reputation mutation must remain disabled"
    )

    local activation = contract.runtimeActivation
    assert(
        activation.customProductRowsReady == true,
        "custom product rows must be built before catalog registration"
    )
    for _, key in ipairs({
        "customProductRowsEnabled",
        "nativeMerchantSpawnEnabled",
        "nativeShopBindingEnabled",
        "dynamicRestockEnabled",
        "procurementMoneyBonusEnabled",
        "procurementCommerceReputationEnabled",
    }) do
        assert(
            type(activation[key]) == "boolean",
            key .. " activation flag must be boolean"
        )
    end

    local representatives = {}
    local representative_order = {}
    local character_ids = {}
    local lottery_rows = {}
    local product_rows = {}
    local slot_indexes = {}
    for _, representative in ipairs(contract.representatives) do
        local faction_id = require_non_empty_string(
            representative.representedFactionId,
            "represented faction ID"
        )
        assert(
            economy.factions[faction_id] ~= nil,
            "shop representative references unknown economy faction"
        )
        assert(
            representatives[faction_id] == nil,
            "duplicate economy shop representative"
        )
        assert(
            type(representative.slotIndex) == "number"
                and representative.slotIndex >= 0,
            "representative slot index must be non-negative"
        )
        assert(
            slot_indexes[representative.slotIndex] == nil,
            "duplicate economy shop slot"
        )
        local character_id = require_non_empty_string(
            representative.nativeCharacterId,
            "native merchant character ID"
        )
        assert(
            string.find(character_id, "NPC_Male_Trader01_v", 1, true) == 1,
            "economy shop representative must use an ordinary ItemShop trader"
        )
        assert(
            character_ids[character_id] == nil,
            "duplicate economy shop character"
        )
        local lottery_row = require_non_empty_string(
            representative.lotteryRowName,
            "lottery row name"
        )
        local product_row = require_non_empty_string(
            representative.productGroupRowName,
            "product-group row name"
        )
        assert(
            lottery_rows[lottery_row] == nil,
            "duplicate economy shop lottery row"
        )
        assert(
            product_rows[product_row] == nil,
            "duplicate economy shop product row"
        )

        representatives[faction_id] = copy(representative)
        table.insert(representative_order, faction_id)
        character_ids[character_id] = true
        lottery_rows[lottery_row] = true
        product_rows[product_row] = true
        slot_indexes[representative.slotIndex] = true
    end
    assert(
        #representative_order == 7,
        "expected seven economy shop representatives"
    )
    for expected_slot = 0, 6 do
        assert(
            slot_indexes[expected_slot] == true,
            "economy shop slots must cover zero through six"
        )
    end
    for faction_id in pairs(economy.factions) do
        assert(
            representatives[faction_id] ~= nil,
            "economy shop representatives must cover every human economy faction"
        )
    end

    return representatives, representative_order
end

function FactionEconomyShopCatalog.create(contract, economy)
    local representatives, representative_order =
        validate_contract(contract, economy)
    local instance = setmetatable({
        version = API_VERSION,
        contract = copy(contract),
        economy = economy,
        representatives = representatives,
        representativeOrder = representative_order,
        capabilities = {
            readOnlyCatalog = true,
            nativeItemShopProductRows = true,
            nativeItemShopLotteryRows = true,
            exactSellPrices = true,
            exactStockCounts = true,
            requestedItemCatalog = true,
            exactProcurementTargetPrices = true,
            exactProcurementQuotas = true,
            runtimeMerchantSpawn =
                contract.runtimeActivation
                    .nativeMerchantSpawnEnabled,
            runtimeShopBinding =
                contract.runtimeActivation
                    .nativeShopBindingEnabled,
            runtimeRestockMutation =
                contract.runtimeActivation
                    .dynamicRestockEnabled,
            runtimeMoneyMutation =
                contract.runtimeActivation
                    .procurementMoneyBonusEnabled,
            runtimeReputationMutation =
                contract.runtimeActivation
                    .procurementCommerceReputationEnabled,
        },
    }, { __index = FactionEconomyShopCatalog })

    local product_count = 0
    local procurement_count = 0
    local signal_count = 0
    for _, faction_id in ipairs(representative_order) do
        local market = assert(instance.economy:faction_market(faction_id))
        product_count = product_count + #market.sell
        procurement_count = procurement_count + #market.procure
        signal_count = signal_count
            + #market.sell
            + #market.procure
            + #market.unresolved
    end
    instance.productCount = product_count
    instance.procurementCount = procurement_count
    instance.signalCount = signal_count
    return instance
end

function FactionEconomyShopCatalog:representative(faction_id)
    local representative = self.representatives[
        require_non_empty_string(faction_id, "faction ID")
    ]
    if representative == nil then
        return nil, "unknown-economy-shop-faction"
    end
    return copy(representative)
end

function FactionEconomyShopCatalog:shop_catalog(faction_id)
    local representative, reason = self:representative(faction_id)
    if representative == nil then
        return nil, reason
    end
    local market = assert(self.economy:faction_market(faction_id))
    local products = {}
    for _, signal in ipairs(market.sell) do
        table.insert(products, {
            itemId = signal.productItemId,
            displayNameZhHans = signal.displayNameZhHans,
            price = signal.exactSellPrice,
            stock = signal.exactStockCount,
            supplyBand = signal.effectiveSupplyBand,
            nativeBasePrice = signal.nativeBasePrice,
            priceMultiplier = signal.exactPriceMultiplier,
            productType =
                self.contract.nativeItemShopAssets.productType,
            productNum =
                self.contract.nativeItemShopAssets.productNum,
        })
    end
    return {
        factionId = faction_id,
        merchantOrganisationId =
            self.contract.designPolicy.merchantOrganisationId,
        slotIndex = representative.slotIndex,
        clothingColour = representative.clothingColour,
        nativeCharacterId = representative.nativeCharacterId,
        nativeCharacterClassPath =
            representative.nativeCharacterClassPath,
        sourceNativeShopRowName =
            representative.sourceNativeShopRowName,
        lotteryRowName = representative.lotteryRowName,
        productGroupRowName =
            representative.productGroupRowName,
        products = products,
        rowsReady =
            self.contract.runtimeActivation.customProductRowsReady,
        rowsEnabled =
            self.contract.runtimeActivation.customProductRowsEnabled,
        nativeShopBindingEnabled =
            self.contract.runtimeActivation.nativeShopBindingEnabled,
    }
end

function FactionEconomyShopCatalog:procurement_catalog(faction_id)
    local representative, reason = self:representative(faction_id)
    if representative == nil then
        return nil, reason
    end
    local market = assert(self.economy:faction_market(faction_id))
    local requested = {}
    for _, signal in ipairs(market.procure) do
        table.insert(requested, {
            itemId = signal.productItemId,
            displayNameZhHans = signal.displayNameZhHans,
            targetPrice = signal.exactProcurementPrice,
            quota = signal.exactProcurementQuota,
            supplyBand = signal.effectiveSupplyBand,
            nativeBasePrice = signal.nativeBasePrice,
            priceMultiplier =
                signal.exactProcurementPriceMultiplier,
        })
    end
    return {
        factionId = faction_id,
        lotteryRowName = representative.lotteryRowName,
        requested = requested,
        nativeRequestedItemFilterAvailable =
            self.contract.procurementAdapter
                .nativeItemShopRequestedItemFilterAvailable,
        nativePriceOverrideAvailable =
            self.contract.procurementAdapter
                .nativeItemShopProcurementPriceOverrideAvailable,
        targetPriceSettlementMode =
            self.contract.procurementAdapter
                .targetPriceSettlementMode,
        serverSuccessSignalStatus =
            self.contract.procurementAdapter
                .serverSuccessSignalStatus,
        moneyBonusEnabled =
            self.contract.runtimeActivation
                .procurementMoneyBonusEnabled,
        commerceReputationEnabled =
            self.contract.runtimeActivation
                .procurementCommerceReputationEnabled,
    }
end

function FactionEconomyShopCatalog:is_requested_item(
    faction_id,
    item_id
)
    local signal, reason =
        self.economy:commodity_signal(faction_id, item_id)
    if signal == nil then
        return false, reason
    end
    return signal.direction == "procure", signal.direction
end

function FactionEconomyShopCatalog:quote_procurement(
    faction_id,
    item_id,
    quantity,
    native_unit_price
)
    require_non_empty_string(faction_id, "faction ID")
    require_non_empty_string(item_id, "item ID")
    if type(quantity) ~= "number"
        or quantity < 1
        or quantity ~= math.floor(quantity) then
        return nil, "invalid-positive-integer-quantity"
    end
    if native_unit_price ~= nil
        and (
            type(native_unit_price) ~= "number"
            or native_unit_price < 0
        ) then
        return nil, "invalid-native-unit-price"
    end
    local signal, reason =
        self.economy:commodity_signal(faction_id, item_id)
    if signal == nil then
        return nil, reason
    end
    if signal.direction ~= "procure" then
        return nil, "item-not-requested"
    end

    local eligible_quantity = math.min(
        quantity,
        signal.exactProcurementQuota
    )
    local native_price = native_unit_price
        or signal.nativeBasePrice
    local target_gross =
        signal.exactProcurementPrice * eligible_quantity
    local native_gross = native_price * eligible_quantity
    return {
        factionId = faction_id,
        itemId = item_id,
        requestedQuantity = quantity,
        eligibleQuantity = eligible_quantity,
        quota = signal.exactProcurementQuota,
        overQuota = quantity > signal.exactProcurementQuota,
        targetUnitPrice = signal.exactProcurementPrice,
        nativeUnitPrice = native_price,
        targetGross = target_gross,
        nativeGross = native_gross,
        maximumMoneyBonus =
            math.max(0, target_gross - native_gross),
        settlementReady = false,
        moneyMutationEnabled =
            self.contract.runtimeActivation
                .procurementMoneyBonusEnabled,
        commerceReputationMutationEnabled =
            self.contract.runtimeActivation
                .procurementCommerceReputationEnabled,
        serverSuccessSignalStatus =
            self.contract.procurementAdapter
                .serverSuccessSignalStatus,
    }
end

function FactionEconomyShopCatalog:status()
    local activation = self.contract.runtimeActivation
    return {
        version = self.version,
        representativeCount = #self.representativeOrder,
        productRowCount = self.productCount,
        requestedItemCount = self.procurementCount,
        marketSignalCount = self.signalCount,
        customProductRowsReady =
            activation.customProductRowsReady,
        customProductRowsEnabled =
            activation.customProductRowsEnabled,
        nativeMerchantSpawnEnabled =
            activation.nativeMerchantSpawnEnabled,
        nativeShopBindingEnabled =
            activation.nativeShopBindingEnabled,
        dynamicRestockEnabled =
            activation.dynamicRestockEnabled,
        procurementMoneyBonusEnabled =
            activation.procurementMoneyBonusEnabled,
        procurementCommerceReputationEnabled =
            activation.procurementCommerceReputationEnabled,
        merchantIslandPlacementStatus =
            self.contract.merchantIslandBinding
                .liveGroundValidationRequired
                and "pending-live-ground-validation"
                or "ready",
        serverSuccessSignalStatus =
            self.contract.procurementAdapter
                .serverSuccessSignalStatus,
    }
end

return FactionEconomyShopCatalog
