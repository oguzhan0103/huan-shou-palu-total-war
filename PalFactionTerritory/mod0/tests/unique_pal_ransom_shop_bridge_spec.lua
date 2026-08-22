package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionCommerce = require("pwft.faction_commerce")
local CommerceBridge = require("pwft.commerce_bridge")
local UniquePalRansomShopBridge =
    require("pwft.unique_pal_ransom_shop_bridge")

local world_generation = 7
local confirmed_callbacks = {}
local callback_failures_remaining = 1
local core_offer = {
    offerId = "spec.ransom.offer.1",
    status = "open",
    nativeOfferId = nil,
}
local world_effect_bus = {}
function world_effect_bus:status()
    return { worldGeneration = world_generation }
end
function world_effect_bus:provider_status(provider_id)
    if provider_id ~= "spec.provider.unique-pal-world" then return nil end
    return {
        providerId = provider_id,
        authoritySource = "spec.authority.unique-pal-world",
        enabled = true,
        deliveryKinds = { ["ransom-offer"] = true },
    }
end
function world_effect_bus:ransom_offer_status(offer_id)
    if offer_id ~= core_offer.offerId then return nil end
    local result = {}
    for key, value in pairs(core_offer) do result[key] = value end
    return result
end
function world_effect_bus:confirm_ransom_payment(callback)
    table.insert(confirmed_callbacks, callback)
    assert(callback.providerId == "spec.provider.unique-pal-world")
    assert(callback.authoritySource == "spec.authority.unique-pal-world")
    assert(callback.bindingId == "spec.binding.pidf")
    assert(callback.worldGeneration == world_generation)
    assert(callback.offerId == core_offer.offerId)
    assert(callback.nativeOfferId == core_offer.nativeOfferId)
    assert(callback.ransomPaymentKey == "PFT_Ransom_Payment_PIDF")
    assert(callback.uniquePalId == "pwft.unique.anubis")
    assert(callback.playerId == "local-player")
    assert(callback.currency == "Gold")
    assert(callback.amount == 99999999)
    assert(callback.paid == true)
    if callback_failures_remaining > 0 then
        callback_failures_remaining = callback_failures_remaining - 1
        return {
            ok = false,
            reason = "spec-transient-world-effect-failure",
            retryable = true,
        }
    end
    core_offer.status = "settled"
    return {
        ok = true,
        reason = "unique-pal-ransom-settled",
        transactionId = callback.callbackId,
        commerceReputationAward = 0,
    }
end

local ransom_bridge = UniquePalRansomShopBridge.create(
    world_effect_bus
)
local shop_id = "00000001-00000002-00000003-00000004"
local product_id = "00000005-00000006-00000007-00000008"
local payload = {
    deliveryId = "unique-pal-world.spec.ransom.offer.1.ransom-offer",
    deliveryKind = "ransom-offer",
    offerId = core_offer.offerId,
    uniquePalId = "pwft.unique.anubis",
    playerId = "local-player",
    targetKey = "faction:pwft.faction.pidf",
    previousHolderFactionId = "pwft.faction.pidf",
    currency = "Gold",
    amount = 99999999,
    worldGeneration = world_generation,
    nativeRoutes = {
        ransomPaymentKey = "PFT_Ransom_Payment_PIDF",
    },
}
local context = {
    providerId = "spec.provider.unique-pal-world",
    bindingId = "spec.binding.pidf",
    worldGeneration = world_generation,
}
local native_offer = {
    nativeOfferId = "spec.native.ransom.offer.1",
    shopId = shop_id,
    productId = product_id,
    merchantFactionId = "pwft.faction.pidf",
    currency = "Gold",
    unitPrice = 99999999,
    buyQuantity = 1,
    singlePurchaseStock = true,
    serverAuthoritativePrice = true,
    serverAuthoritativePaymentResult = true,
    ransomPaymentKey = "PFT_Ransom_Payment_PIDF",
}
local accepted = ransom_bridge:accept_offer(
    payload,
    context,
    native_offer
)
assert(accepted.ok and accepted.accepted)
assert(accepted.nativeOfferId == native_offer.nativeOfferId)
core_offer.nativeOfferId = accepted.nativeOfferId
local duplicate_offer = ransom_bridge:accept_offer(
    payload,
    context,
    native_offer
)
assert(duplicate_offer.ok and duplicate_offer.idempotent)

local invalid_offer = {}
for key, value in pairs(native_offer) do invalid_offer[key] = value end
invalid_offer.nativeOfferId = "spec.native.ransom.offer.invalid"
invalid_offer.shopId = "invalid-shop"
invalid_offer.productId = "invalid-product"
invalid_offer.unitPrice = 1
local invalid_payload = {}
for key, value in pairs(payload) do invalid_payload[key] = value end
invalid_payload.offerId = "spec.ransom.offer.invalid"
invalid_payload.deliveryId = "spec.ransom.offer.invalid.delivery"
assert(not ransom_bridge:accept_offer(
    invalid_payload,
    context,
    invalid_offer
).ok)

local awards = {}
local faction_api = {
    award_commerce = function(_, faction_id, amount, transaction_id)
        table.insert(awards, {
            factionId = faction_id,
            amount = amount,
            transactionId = transaction_id,
        })
        return { ok = true, reason = "awarded", applied = amount }
    end,
}
local commerce = FactionCommerce.create(Registry.commerce, faction_api)
local commerce_events = {}
local ransom_results = {}
local transaction_sequence = 0
local commerce_bridge = CommerceBridge.create(commerce, {
    windowIdProvider = function() return "spec-commerce-window" end,
    transactionIdFactory = function()
        transaction_sequence = transaction_sequence + 1
        return "spec-native-buy-" .. tostring(transaction_sequence)
    end,
    priceResolver = function(request_shop_id, request_product_id, quantity)
        return ransom_bridge:resolve_price(
            request_shop_id,
            request_product_id,
            quantity
        )
    end,
    buyPolicyResolver = function(pending)
        return ransom_bridge:buy_policy(pending)
    end,
    eventSink = function(event)
        table.insert(commerce_events, event)
        table.insert(ransom_results,
            ransom_bridge:handle_commerce_event(event))
    end,
})
local actor = {
    GetFullName = function()
        return "BP_PIDF_Ransom_Merchant_C /Game/Test/Ransom"
    end,
}
local component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/Ransom"
    end,
}
local shop_guid = { A = 1, B = 2, C = 3, D = 4 }
local product_guid = { A = 5, B = 6, C = 7, D = 8 }
assert(commerce_bridge:register_vendor_actor(
    "pwft.faction.pidf",
    actor,
    { mode = "fixed-market", commercialTruce = true }
))
assert(commerce_bridge:on_shop_setup(component, actor))
local requested, pending = commerce_bridge:on_buy_request(
    component,
    shop_guid,
    product_guid,
    1
)
assert(requested)
assert(pending.totalGold == 99999999)
assert(pending.buyPolicy.settlementKind == "unique-pal-ransom")
assert(pending.buyPolicy.skipCommerceReputation == true)
assert(pending.buyPolicy.settlementEligible == true)
local handled, buy_outcome = commerce_bridge:on_buy_result(
    component,
    "EPalShopBuyResultType::Successed"
)
assert(handled and buy_outcome.ok)
assert(buy_outcome.requestedAward == 0)
assert(#awards == 0)
assert(#confirmed_callbacks == 1)
assert(not ransom_results[#ransom_results].ok)
assert(ransom_results[#ransom_results].retryable == true)
local ransom_event = commerce_events[#commerce_events]
assert(ransom_event.totalGold == 99999999)
assert(ransom_event.commerceReputationSuppressed == true)
assert(ransom_event.settlementEligible == true)
assert(ransom_bridge:status().confirmedPaymentCount == 0)

-- The player has already paid.  A transient callback failure must allow the
-- exact same native buy-result event to be replayed without another purchase.
local retry_payment = ransom_bridge:handle_commerce_event(ransom_event)
assert(retry_payment.ok)
assert(#confirmed_callbacks == 2)
assert(ransom_bridge:status().confirmedPaymentCount == 1)
assert(commerce_bridge:status().noCommerceAwardBuyCount == 1)

local duplicate_payment = ransom_bridge:handle_commerce_event(ransom_event)
assert(duplicate_payment.ok and duplicate_payment.idempotent)
assert(#confirmed_callbacks == 2)

-- A different native product is ordinary commerce and must keep the existing
-- reputation path.  The ransom bridge ignores it rather than taking payment
-- authority over the rest of the merchant guild catalog.
local ordinary_product = { A = 9, B = 10, C = 11, D = 12 }
assert(commerce_bridge:on_buy_request(
    component,
    shop_guid,
    ordinary_product,
    1
))
assert(commerce_bridge:on_buy_result(
    component,
    "EPalShopBuyResultType::Successed"
))
assert(#awards == 1)
assert(ransom_results[#ransom_results].ignored == true)

local unbound = ransom_bridge:unbind_world("spec-world-unload")
assert(unbound.ok and unbound.clearedOfferCount == 1)
assert(ransom_bridge:resolve_price(shop_id, product_id, 1) == nil)
assert(ransom_bridge:status().openOfferCount == 0)
assert(ransom_bridge:status().directCurrencyMutation == false)
assert(ransom_bridge:status().palDeliveryIncluded == false)

print("PASS unique-Pal ransom shop bridge uses exact native shop/product/faction/price/generation, keeps failed settlement callbacks replayable, confirms only server buy success, awards zero commerce reputation, and clears on world unload")
