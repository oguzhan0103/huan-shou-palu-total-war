local UniquePalRansomShopBridge = {}

local API_VERSION = "1.0.0"
local SETTLEMENT_KIND = "unique-pal-ransom"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function positive_integer(value, name)
    assert(type(value) == "number" and value > 0
            and value == math.floor(value),
        name .. " must be a positive integer")
    return value
end

local function native_key(shop_id, product_id)
    return require_text(shop_id, "native ransom shop ID")
        .. "\31" .. require_text(product_id, "native ransom product ID")
end

local function offer_signature(offer)
    return table.concat({
        offer.offerId,
        offer.deliveryId,
        offer.uniquePalId,
        offer.playerId,
        offer.holderFactionId,
        offer.targetKey,
        offer.providerId,
        offer.authoritySource,
        offer.bindingId,
        tostring(offer.worldGeneration),
        offer.nativeOfferId,
        offer.shopId,
        offer.productId,
        offer.merchantFactionId,
        offer.currency,
        tostring(offer.amount),
        tostring(offer.buyQuantity),
        offer.ransomPaymentKey,
    }, "|")
end

local function log(instance, message)
    if instance.logger ~= nil then
        pcall(instance.logger, "[UniquePalRansomShop] " .. message)
    end
end

function UniquePalRansomShopBridge.create(world_effect_bus, options)
    assert(type(world_effect_bus) == "table"
            and type(world_effect_bus.status) == "function"
            and type(world_effect_bus.provider_status) == "function"
            and type(world_effect_bus.ransom_offer_status) == "function"
            and type(world_effect_bus.confirm_ransom_payment) == "function",
        "unique-Pal world-effect bus with ransom callback API is required")
    options = options or {}
    return setmetatable({
        version = API_VERSION,
        worldEffectBus = world_effect_bus,
        logger = options.logger,
        offersById = {},
        offersByNativeKey = {},
        processedTransactions = {},
        acceptedOfferCount = 0,
        confirmedPaymentCount = 0,
        rejectedPaymentCount = 0,
        ignoredCommerceEventCount = 0,
        worldUnbindCount = 0,
        lastError = nil,
    }, { __index = UniquePalRansomShopBridge })
end

function UniquePalRansomShopBridge:accept_offer(
    payload,
    context,
    native_offer
)
    local called, normalized = pcall(function()
        assert(type(payload) == "table"
                and payload.deliveryKind == "ransom-offer",
            "ransom-offer delivery payload is required")
        assert(type(context) == "table",
            "ransom-offer provider context is required")
        assert(type(native_offer) == "table",
            "native ransom shop binding is required")
        local bus_status = self.worldEffectBus:status()
        local provider_id = require_text(context.providerId,
            "ransom provider ID")
        local provider = self.worldEffectBus:provider_status(provider_id)
        assert(provider ~= nil and provider.enabled == true
                and provider.deliveryKinds["ransom-offer"] == true,
            "active ransom-offer provider is required")
        assert(context.worldGeneration == bus_status.worldGeneration
                and payload.worldGeneration == bus_status.worldGeneration,
            "ransom offer world generation is stale")
        assert(type(payload.nativeRoutes) == "table",
            "ransom native routes are required")
        assert(payload.currency == "Gold",
            "native ransom shop bridge only accepts Gold quotes")
        local amount = positive_integer(payload.amount,
            "Core ransom amount")
        local quantity = positive_integer(native_offer.buyQuantity,
            "native ransom purchase quantity")
        assert(quantity == 1 and native_offer.singlePurchaseStock == true,
            "native ransom product must be a single-purchase stock-one offer")
        assert(native_offer.serverAuthoritativePrice == true
                and native_offer.serverAuthoritativePaymentResult == true,
            "native ransom offer requires server-authoritative price and result")
        assert(native_offer.unitPrice == amount,
            "native ransom price must equal the Core quote")
        assert(native_offer.currency == payload.currency,
            "native ransom currency must equal the Core quote")
        assert(native_offer.merchantFactionId
                == payload.previousHolderFactionId,
            "ransom merchant must be the current NPC holder faction")
        assert(native_offer.ransomPaymentKey
                == payload.nativeRoutes.ransomPaymentKey,
            "native ransom payment route does not match the target binding")
        local offer = {
            offerId = require_text(payload.offerId,
                "Core ransom offer ID"),
            deliveryId = require_text(payload.deliveryId,
                "ransom delivery ID"),
            uniquePalId = require_text(payload.uniquePalId,
                "unique Pal ID"),
            playerId = require_text(payload.playerId,
                "ransom player ID"),
            holderFactionId = require_text(payload.previousHolderFactionId,
                "ransom holder faction ID"),
            targetKey = require_text(payload.targetKey,
                "ransom target key"),
            providerId = provider_id,
            authoritySource = require_text(provider.authoritySource,
                "ransom provider authority"),
            bindingId = require_text(context.bindingId,
                "ransom target binding ID"),
            worldGeneration = bus_status.worldGeneration,
            nativeOfferId = require_text(native_offer.nativeOfferId,
                "native ransom offer ID"),
            shopId = require_text(native_offer.shopId,
                "native ransom shop ID"),
            productId = require_text(native_offer.productId,
                "native ransom product ID"),
            merchantFactionId = require_text(
                native_offer.merchantFactionId,
                "native ransom merchant faction ID"),
            currency = payload.currency,
            amount = amount,
            buyQuantity = quantity,
            ransomPaymentKey = native_offer.ransomPaymentKey,
            status = "open",
        }
        offer.signature = offer_signature(offer)
        return offer
    end)
    if not called then
        self.lastError = tostring(normalized)
        return result(false, "invalid-native-ransom-shop-offer", {
            deliveryId = type(payload) == "table" and payload.deliveryId or nil,
            validationError = self.lastError,
        })
    end

    local existing = self.offersById[normalized.offerId]
    if existing ~= nil then
        if existing.signature ~= normalized.signature then
            self.lastError = "ransom-offer-id-conflict"
            return result(false, "native-ransom-shop-offer-id-conflict", {
                deliveryId = normalized.deliveryId,
            })
        end
        return result(true, "native-ransom-shop-offer-already-accepted", {
            deliveryId = normalized.deliveryId,
            accepted = true,
            nativeOfferId = existing.nativeOfferId,
            idempotent = true,
        })
    end
    local key = native_key(normalized.shopId, normalized.productId)
    local conflicting_offer_id = self.offersByNativeKey[key]
    if conflicting_offer_id ~= nil
        and conflicting_offer_id ~= normalized.offerId then
        self.lastError = "native-ransom-shop-product-conflict"
        return result(false, "native-ransom-shop-product-conflict", {
            deliveryId = normalized.deliveryId,
        })
    end
    self.offersById[normalized.offerId] = normalized
    self.offersByNativeKey[key] = normalized.offerId
    self.acceptedOfferCount = self.acceptedOfferCount + 1
    self.lastError = nil
    log(self, string.format(
        "OFFER_ACCEPTED offer=%s pal=%s faction=%s price=%d stock=1 generation=%d reputation=0",
        normalized.offerId,
        normalized.uniquePalId,
        normalized.merchantFactionId,
        normalized.amount,
        normalized.worldGeneration
    ))
    return result(true, "native-ransom-shop-offer-accepted", {
        deliveryId = normalized.deliveryId,
        accepted = true,
        nativeOfferId = normalized.nativeOfferId,
    })
end

function UniquePalRansomShopBridge:resolve_price(
    shop_id,
    product_id,
    quantity
)
    local offer_id = self.offersByNativeKey[
        native_key(shop_id, product_id)
    ]
    local offer = offer_id and self.offersById[offer_id] or nil
    if offer == nil or offer.status ~= "open"
        or quantity ~= offer.buyQuantity then
        return nil
    end
    return offer.amount
end

function UniquePalRansomShopBridge:buy_policy(pending)
    assert(type(pending) == "table", "pending native buy is required")
    local offer_id = self.offersByNativeKey[
        native_key(pending.shopId, pending.productId)
    ]
    if offer_id == nil then return nil end
    local offer = self.offersById[offer_id]
    local eligible = offer ~= nil
        and offer.status == "open"
        and pending.factionId == offer.merchantFactionId
        and pending.buyNum == offer.buyQuantity
        and pending.totalGold == offer.amount
    return {
        settlementKind = SETTLEMENT_KIND,
        settlementReferenceId = offer_id,
        settlementEligible = eligible,
        skipCommerceReputation = true,
    }
end

function UniquePalRansomShopBridge:handle_commerce_event(event)
    assert(type(event) == "table", "commerce event is required")
    if event.type ~= "commerce-buy-result"
        or event.settlementKind ~= SETTLEMENT_KIND then
        self.ignoredCommerceEventCount = self.ignoredCommerceEventCount + 1
        return result(true, "commerce-event-not-unique-pal-ransom", {
            ignored = true,
        })
    end
    local offer = self.offersById[event.settlementReferenceId]
    if offer == nil then
        self.rejectedPaymentCount = self.rejectedPaymentCount + 1
        return result(false, "native-ransom-shop-offer-unavailable")
    end
    local transaction_id = require_text(event.transactionId,
        "native ransom transaction ID")
    local signature = table.concat({
        transaction_id,
        tostring(event.ok),
        tostring(event.factionId),
        tostring(event.shopId),
        tostring(event.productId),
        tostring(event.buyNum),
        tostring(event.totalGold),
        tostring(event.commerceReputationSuppressed),
        tostring(event.settlementEligible),
    }, "|")
    local previous = self.processedTransactions[transaction_id]
    if previous ~= nil then
        if previous.signature ~= signature then
            self.rejectedPaymentCount = self.rejectedPaymentCount + 1
            return result(false, "native-ransom-transaction-id-conflict")
        end
        local replay = copy(previous.response)
        replay.idempotent = true
        replay.duplicateOfReason = replay.reason
        replay.reason = "duplicate-native-ransom-shop-transaction"
        return replay
    end
    if event.ok ~= true then
        return result(false, "native-ransom-shop-payment-not-confirmed", {
            retryable = offer.status == "open",
        })
    end
    local current_generation = self.worldEffectBus:status().worldGeneration
    local current_offer = self.worldEffectBus:ransom_offer_status(
        offer.offerId
    )
    local exact = event.settlementEligible == true
        and event.commerceReputationSuppressed == true
        and event.factionId == offer.merchantFactionId
        and event.shopId == offer.shopId
        and event.productId == offer.productId
        and event.buyNum == offer.buyQuantity
        and event.totalGold == offer.amount
        and current_generation == offer.worldGeneration
        and current_offer ~= nil
        and current_offer.status == "open"
        and current_offer.nativeOfferId == offer.nativeOfferId
    if not exact then
        self.rejectedPaymentCount = self.rejectedPaymentCount + 1
        self.lastError = "native-ransom-shop-payment-mismatch"
        return result(false, "native-ransom-shop-payment-mismatch")
    end
    local callback = {
        callbackId = "pwft.ransom-shop." .. transaction_id,
        providerId = offer.providerId,
        authoritySource = offer.authoritySource,
        bindingId = offer.bindingId,
        worldGeneration = offer.worldGeneration,
        offerId = offer.offerId,
        nativeOfferId = offer.nativeOfferId,
        ransomPaymentKey = offer.ransomPaymentKey,
        uniquePalId = offer.uniquePalId,
        playerId = offer.playerId,
        currency = offer.currency,
        amount = offer.amount,
        paid = true,
    }
    local response = self.worldEffectBus:confirm_ransom_payment(callback)
    if response.ok then
        self.processedTransactions[transaction_id] = {
            signature = signature,
            response = copy(response),
        }
        offer.status = "settled"
        offer.transactionId = transaction_id
        self.confirmedPaymentCount = self.confirmedPaymentCount + 1
        self.lastError = nil
        log(self, string.format(
            "PAYMENT_CONFIRMED offer=%s transaction=%s price=%d reputation=0",
            offer.offerId,
            transaction_id,
            offer.amount
        ))
    else
        -- Native payment has already succeeded, so the same authoritative
        -- event must remain replayable when the world-effect callback fails
        -- transiently.  Never require a second purchase for a callback retry.
        self.rejectedPaymentCount = self.rejectedPaymentCount + 1
        self.lastError = response.reason
    end
    return response
end

function UniquePalRansomShopBridge:unbind_world(reason)
    local count = 0
    for _ in pairs(self.offersById) do count = count + 1 end
    self.offersById = {}
    self.offersByNativeKey = {}
    self.processedTransactions = {}
    self.worldUnbindCount = self.worldUnbindCount + 1
    self.lastError = reason or "world-unloading"
    return result(true, "native-ransom-shop-world-unbound", {
        clearedOfferCount = count,
    })
end

function UniquePalRansomShopBridge:status()
    local open, settled = 0, 0
    for _, offer in pairs(self.offersById) do
        if offer.status == "open" then open = open + 1
        elseif offer.status == "settled" then settled = settled + 1 end
    end
    return {
        apiVersion = self.version,
        openOfferCount = open,
        settledOfferCount = settled,
        acceptedOfferCount = self.acceptedOfferCount,
        confirmedPaymentCount = self.confirmedPaymentCount,
        rejectedPaymentCount = self.rejectedPaymentCount,
        ignoredCommerceEventCount = self.ignoredCommerceEventCount,
        worldUnbindCount = self.worldUnbindCount,
        lastError = self.lastError,
        paymentRoute = "native-server-authoritative-shop-buy-result",
        commerceReputationAward = 0,
        directCurrencyMutation = false,
        PalworldSaveMutation = false,
        palDeliveryIncluded = false,
        exactShopProductFactionPriceAndGeneration = true,
    }
end

return UniquePalRansomShopBridge
