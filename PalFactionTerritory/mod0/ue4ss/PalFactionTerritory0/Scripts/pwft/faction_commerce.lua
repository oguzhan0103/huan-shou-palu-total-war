local FactionCommerce = {}

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
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function require_non_negative_number(value, name)
    assert(type(value) == "number" and value >= 0, name .. " must be non-negative")
    return value
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function validate_contract(contract)
    assert(type(contract) == "table", "faction commerce contract is required")
    assert(contract.schemaVersion == "1.0.0", "unsupported faction commerce contract schema")
    assert(
        contract.baselineStatus == "mechanics_complete_balance_provisional_2026-07-28",
        "faction commerce baseline is not active"
    )
    assert(contract.designPolicy.storyContentIncluded == false, "commerce core cannot include story content")
    assert(contract.designPolicy.humanFactionsOnly == true, "commerce membership must remain human-only")
    assert(contract.designPolicy.nativeSuccessfulTransactionsOnly == true, "commerce awards require native success")
    assert(
        contract.designPolicy.requestedItemAuthority
            == "faction_economy.v1.json commodity signals",
        "commerce requested items must follow the economy contract"
    )
    assert(
        contract.designPolicy.requestedItemIdsCompatibilityFallbackOnly
            == true,
        "static commerce requested item IDs must remain fallback-only"
    )
    assert(
        contract.designPolicy.merchantGuildEconomyCountersOwnedBy
            == "faction_economy_shops.v1.json",
        "Merchant Guild counters must be owned by the economy-shop contract"
    )
    assert(contract.designPolicy.palworldSaveMutationAllowed == false, "commerce cannot mutate Palworld saves")
    assert(#contract.factions == 7, "expected seven human commerce factions")

    local by_faction = {}
    local by_merchant = {}
    for _, merchant in ipairs(contract.factions) do
        require_non_empty_string(merchant.factionId, "commerce faction ID")
        require_non_empty_string(merchant.merchantId, "commerce merchant ID")
        require_non_empty_string(merchant.clothingColour, "commerce clothing colour")
        assert(
            string.find(merchant.clothingColour, "^#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") ~= nil,
            "invalid commerce clothing colour"
        )
        assert(by_faction[merchant.factionId] == nil, "duplicate commerce faction")
        assert(by_merchant[merchant.merchantId] == nil, "duplicate commerce merchant")
        by_faction[merchant.factionId] = copy(merchant)
        by_merchant[merchant.merchantId] = by_faction[merchant.factionId]
        local requested = {}
        assert(
            type(merchant.guardCharacterClassPaths) == "table",
            "commerce guard class paths are required"
        )
        assert(
            #merchant.guardCharacterIds
                == #merchant.guardCharacterClassPaths,
            "commerce guard ID/class path count mismatch"
        )
        for index, character_id in ipairs(
            merchant.guardCharacterIds
        ) do
            require_non_empty_string(
                character_id,
                "commerce guard character ID"
            )
            require_non_empty_string(
                merchant.guardCharacterClassPaths[index],
                "commerce guard character class path"
            )
        end
        for _, item_id in ipairs(merchant.requestedItemIds or {}) do
            require_non_empty_string(item_id, "requested item ID")
            assert(requested[item_id] == nil, "duplicate requested item ID")
            requested[item_id] = true
        end
        by_faction[merchant.factionId].requestedItemSet = requested
    end

    local buy = contract.transactionPolicy.buyAward
    local sale = contract.transactionPolicy.requestedSaleAward
    assert(buy.goldPerReputation > 0, "buy reputation divisor must be positive")
    assert(buy.minimumPerSuccessfulTransaction > 0, "successful buys must award at least one")
    assert(buy.maximumPerSuccessfulTransaction >= buy.minimumPerSuccessfulTransaction, "invalid buy award range")
    assert(sale.itemsPerReputation > 0, "sale reputation divisor must be positive")
    assert(sale.unrequestedItemAward == 0, "unrequested items cannot award reputation")
    return by_faction, by_merchant
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function FactionCommerce.create(contract, faction_api, options)
    assert(type(faction_api) == "table", "faction API is required")
    assert(type(faction_api.award_commerce) == "function", "faction API lacks commerce awards")
    options = options or {}
    assert(
        options.requestedItemResolver == nil
            or type(options.requestedItemResolver) == "function",
        "requested item resolver must be a function"
    )
    local by_faction, by_merchant = validate_contract(contract)
    return setmetatable({
        version = API_VERSION,
        contract = copy(contract),
        factionApi = faction_api,
        factions = by_faction,
        merchants = by_merchant,
        shops = {},
        processedTransactions = {},
        transactionCount = 0,
        awardedTransactionCount = 0,
        requestedItemResolver = options.requestedItemResolver,
        requestedItemSource = options.requestedItemSource
            or (
                options.requestedItemResolver ~= nil
                    and "external-procurement-resolver"
                or "faction-commerce-static-fallback"
            ),
        capabilities = {
            fixedFactionBuyers = true,
            visitingFactionCaravans = true,
            factionClothingColours = true,
            nativeBuyConfirmation = true,
            requestedItemSales = true,
            economyDrivenRequestedItems =
                options.requestedItemResolver ~= nil,
            unrequestedSaleAwards = false,
            globalProgressionCaps = true,
            automaticAffiliationRecovery = true,
            oneHostilitySourceAtATime = true,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionCommerce })
end

function FactionCommerce:merchant_status(faction_id)
    local merchant = self.factions[
        require_non_empty_string(faction_id, "faction ID")
    ]
    if merchant == nil then
        return nil
    end
    local view = copy(merchant)
    view.requestedItemSet = nil
    return view
end

function FactionCommerce:register_shop(shop_id, faction_id, metadata)
    require_non_empty_string(shop_id, "shop ID")
    require_non_empty_string(faction_id, "faction ID")
    local merchant = self.factions[faction_id]
    if merchant == nil then
        return result(false, "unknown-commerce-faction")
    end
    local existing = self.shops[shop_id]
    if existing ~= nil and existing.factionId ~= faction_id then
        return result(false, "shop-already-bound-to-other-faction")
    end
    self.shops[shop_id] = {
        shopId = shop_id,
        factionId = faction_id,
        merchantId = merchant.merchantId,
        metadata = copy(metadata or {}),
    }
    return result(true, existing and "already-registered" or "registered", {
        shopId = shop_id,
        factionId = faction_id,
    })
end

function FactionCommerce:shop_status(shop_id)
    local shop = self.shops[
        require_non_empty_string(shop_id, "shop ID")
    ]
    return shop and copy(shop) or nil
end

function FactionCommerce:is_requested_item(faction_id, item_id)
    local merchant = self.factions[
        require_non_empty_string(faction_id, "faction ID")
    ]
    if merchant == nil then
        return false, "unknown-commerce-faction"
    end
    item_id = require_non_empty_string(item_id, "item ID")
    if self.requestedItemResolver ~= nil then
        local ok, requested, detail = pcall(
            self.requestedItemResolver,
            faction_id,
            item_id
        )
        if not ok then
            return false, "requested-item-resolver-failed:"
                .. tostring(requested)
        end
        return requested == true, detail
    end
    return merchant.requestedItemSet[item_id] == true,
        "static-commerce-fallback"
end

function FactionCommerce:calculate_buy_award(total_gold)
    require_non_negative_number(total_gold, "transaction gold value")
    local policy = self.contract.transactionPolicy.buyAward
    return clamp(
        math.floor(total_gold / policy.goldPerReputation),
        policy.minimumPerSuccessfulTransaction,
        policy.maximumPerSuccessfulTransaction
    )
end

function FactionCommerce:calculate_requested_sale_award(faction_id, items)
    require_non_empty_string(faction_id, "faction ID")
    assert(type(items) == "table", "sold items must be a table")
    local merchant = self.factions[faction_id]
    if merchant == nil then
        return 0, 0
    end
    local requested_count = 0
    local requested_items = {}
    for _, item in ipairs(items) do
        assert(type(item) == "table", "sold item entry must be a table")
        local item_id = require_non_empty_string(item.itemId, "sold item ID")
        local count = require_non_negative_number(item.count, "sold item count")
        local is_requested = self:is_requested_item(
            faction_id,
            item_id
        )
        if is_requested then
            local integer_count = math.floor(count)
            requested_count = requested_count + integer_count
            table.insert(requested_items, {
                itemId = item_id,
                count = integer_count,
            })
        end
    end
    if requested_count == 0 then
        return 0, 0, requested_items
    end
    local policy = self.contract.transactionPolicy.requestedSaleAward
    return clamp(
        math.floor(requested_count / policy.itemsPerReputation),
        policy.minimumPerSuccessfulTransaction,
        policy.maximumPerSuccessfulTransaction
    ), requested_count, requested_items
end

function FactionCommerce:confirm_buy(
    shop_id,
    transaction_id,
    total_gold,
    commerce_window_id
)
    require_non_empty_string(shop_id, "shop ID")
    require_non_empty_string(transaction_id, "transaction ID")
    require_non_negative_number(total_gold, "transaction gold value")
    require_non_empty_string(commerce_window_id, "commerce window ID")
    local shop = self.shops[shop_id]
    if shop == nil then
        return result(false, "unregistered-shop")
    end
    local event_id = "buy:" .. shop_id .. ":" .. transaction_id
    if self.processedTransactions[event_id] then
        return result(true, "duplicate-transaction", {
            factionId = shop.factionId,
            transactionId = transaction_id,
            applied = 0,
        })
    end
    local requested_award = self:calculate_buy_award(total_gold)
    local recovery_eligible =
        shop.metadata.mode == "fixed-market"
        and shop.metadata.commercialTruce == true
    local award = self.factionApi:award_commerce(
        shop.factionId,
        requested_award,
        event_id,
        commerce_window_id,
        {
            diplomacyRecoveryEligible = recovery_eligible,
            venueMode = shop.metadata.mode,
        }
    )
    if not award.ok then
        return award
    end
    self.processedTransactions[event_id] = true
    self.transactionCount = self.transactionCount + 1
    if award.ok and (award.applied or 0) > 0 then
        self.awardedTransactionCount = self.awardedTransactionCount + 1
    end
    award.direction = "buy"
    award.shopId = shop_id
    award.factionId = shop.factionId
    award.requestedAward = requested_award
    award.transactionId = transaction_id
    return award
end

function FactionCommerce:confirm_requested_sale(
    shop_id,
    transaction_id,
    items,
    commerce_window_id
)
    require_non_empty_string(shop_id, "shop ID")
    require_non_empty_string(transaction_id, "transaction ID")
    require_non_empty_string(commerce_window_id, "commerce window ID")
    local shop = self.shops[shop_id]
    if shop == nil then
        return result(false, "unregistered-shop")
    end
    local event_id = "sell:" .. shop_id .. ":" .. transaction_id
    if self.processedTransactions[event_id] then
        return result(true, "duplicate-transaction", {
            factionId = shop.factionId,
            transactionId = transaction_id,
            applied = 0,
        })
    end
    local requested_award, requested_count, requested_items =
        self:calculate_requested_sale_award(shop.factionId, items)
    if requested_award == 0 then
        return result(true, "no-requested-items", {
            factionId = shop.factionId,
            transactionId = transaction_id,
            applied = 0,
            requestedItemCount = 0,
            requestedItems = {},
            requestedItemSource = self.requestedItemSource,
        })
    end
    local award = self.factionApi:award_commerce(
        shop.factionId,
        requested_award,
        event_id,
        commerce_window_id,
        {
            diplomacyRecoveryEligible =
                shop.metadata.mode == "fixed-market"
                    and shop.metadata.commercialTruce
                        == true,
            venueMode = shop.metadata.mode,
        }
    )
    if not award.ok then
        return award
    end
    self.processedTransactions[event_id] = true
    self.transactionCount = self.transactionCount + 1
    if award.ok and (award.applied or 0) > 0 then
        self.awardedTransactionCount = self.awardedTransactionCount + 1
    end
    award.direction = "sell"
    award.shopId = shop_id
    award.factionId = shop.factionId
    award.requestedAward = requested_award
    award.requestedItemCount = requested_count
    award.requestedItems = requested_items
    award.requestedItemSource = self.requestedItemSource
    award.transactionId = transaction_id
    return award
end

function FactionCommerce:status()
    local registered_count = 0
    for _, _ in pairs(self.shops) do
        registered_count = registered_count + 1
    end
    return {
        version = self.version,
        factionCount = #self.contract.factions,
        registeredShopCount = registered_count,
        transactionCount = self.transactionCount,
        awardedTransactionCount = self.awardedTransactionCount,
        requestedItemSource = self.requestedItemSource,
        economyDrivenRequestedItems =
            self.capabilities.economyDrivenRequestedItems,
        merchantIslandPlacementStatus =
            self.contract.merchantIsland.placementStatus,
        sellSettlementStatus =
            self.contract.nativeAdapter.sellSettlementStatus,
    }
end

return FactionCommerce
