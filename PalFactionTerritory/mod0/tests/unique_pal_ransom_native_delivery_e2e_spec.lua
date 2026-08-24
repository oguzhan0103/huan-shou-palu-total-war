package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local UniquePalCampaign = require("pwft.unique_pal_campaign")
local WorldEffectBus = require("pwft.unique_pal_world_effect_bus")
local NativeDeliveryBridge =
    require("pwft.unique_pal_native_delivery_bridge")
local NativeDeliveryProduction =
    require("pwft.unique_pal_native_delivery_production")
local RansomShopBridge = require("pwft.unique_pal_ransom_shop_bridge")
local FactionCommerce = require("pwft.faction_commerce")
local CommerceBridge = require("pwft.commerce_bridge")

local rayne = "pwft.faction.rayne_syndicate"
local pidf = "pwft.faction.pidf"
local player_id = "local-player"
local unique_pal_id = "pwft.unique.anubis"
local price = 99999999

local progression = Progression.create(Registry.progression)
local world = StrategicWorld.create(progression)
assert(world:register_pack({
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "spec.ransom-delivery.world",
    contentVersion = "1.0.0",
    uniquePals = {{
        id = unique_pal_id,
        speciesId = "Anubis",
        displayNameKey = "spec.loc.unique.anubis.name",
        initialOwner = { kind = "faction", id = pidf },
    }},
    cities = {},
}).ok)

local world_effect_bus
local campaign = UniquePalCampaign.create(
    progression,
    world,
    {
        playerId = player_id,
        onChange = function(event)
            if world_effect_bus ~= nil then
                world_effect_bus:handle_campaign_event(event)
            end
        end,
    }
)
assert(campaign:register_pack({
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = "spec.ransom-delivery.campaign",
    contentVersion = "1.0.0",
    uniquePals = {{
        id = unique_pal_id,
        target = {
            kind = "faction",
            id = rayne,
            affectedFactionIds = { rayne },
        },
        boss = {
            speciesId = "Anubis",
            nativeBossAvailable = true,
            bindingStatus = "bound",
            strengthProfile = "raid-slab",
        },
        schedule = {
            minimumIntervalTicks = 1,
            maximumIntervalTicks = 1,
            noticeTicks = 1,
            openTicks = 1,
        },
        ransomPrice = price,
        candidateFactionIds = { pidf },
    }},
}).ok)
world_effect_bus = WorldEffectBus.create(campaign)

local scheduled = {}
local native_bridge = NativeDeliveryBridge.create(world_effect_bus, {
    maxAutomaticAttempts = 3,
    schedule = function(_, callback)
        scheduled[#scheduled + 1] = callback
        return true
    end,
})
local ransom_bridge = RansomShopBridge.create(world_effect_bus)

local adapter_bind_count = 0
local create_count = 0
local capture_count = 0
local storage_read_count = 0
local adapter = {}
function adapter:status()
    return {
        buildId = "24575825",
        objectDumpSha256 =
            "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78",
        allowMutatingDelivery = true,
        capabilities = {
            currentBuildSignatureBound = true,
            capacityPreflight = true,
            serverAuthoritativeSpawn = true,
            stableIndividualIdentity = true,
            serverAuthoritativeCapture = true,
            exactStorageReadback = true,
            directContainerMutation = false,
            PalworldSaveMutation = false,
        },
    }
end
function adapter:bind_world(generation)
    assert(generation == world_effect_bus:status().worldGeneration)
    adapter_bind_count = adapter_bind_count + 1
    return { ok = true, reason = "spec-adapter-world-bound" }
end
function adapter:preflight(request)
    assert(request.uniquePalId == unique_pal_id)
    assert(request.speciesId == "Anubis")
    return { ok = true, capacityAvailable = true }
end
function adapter:create_individual(request)
    create_count = create_count + 1
    return {
        ok = true,
        nativeDeliveryId = request.deliveryId .. ":native",
        individualKey = "pal-local-player-spec-anubis-001",
    }
end
function adapter:commit_capture(_, native_delivery_id, individual_key)
    assert(string.find(native_delivery_id, ":native", 1, true) ~= nil)
    assert(individual_key == "pal-local-player-spec-anubis-001")
    capture_count = capture_count + 1
    return { ok = true, accepted = true }
end
function adapter:verify_storage(_, _, individual_key)
    storage_read_count = storage_read_count + 1
    return {
        ok = true,
        delivered = true,
        individualKey = individual_key,
    }
end
function adapter:rollback()
    return { ok = true, rolledBack = true }
end

local production = NativeDeliveryProduction.create(
    native_bridge,
    adapter,
    world_effect_bus,
    {
        enabled = true,
        buildId = "24575825",
        objectDumpSha256 =
            "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78",
        deliveryLevel = 80,
        approvedSpeciesByUniquePalId = {
            [unique_pal_id] = "Anubis",
            ["pwft.unique.pinkcat"] = "PinkCat",
            ["pwft.unique.weasel_dragon"] = "WeaselDragon",
            ["pwft.unique.black_metal_dragon"] = "BlackMetalDragon",
            ["pwft.unique.ronin"] = "Ronin",
        },
    }
)

local provider_id = "pwft.provider.spec.ransom-delivery"
local target_binding_id = "pwft.binding.spec.rayne-world-effects"
local pal_delivery_key = "PFT_Pal_Delivery_Rayne"
local shop_id = "00000001-00000002-00000003-00000004"
local product_id = "00000005-00000006-00000007-00000008"
local offer_sequence = 0
local function provider_handler(payload, context)
    if payload.deliveryKind == "ransom-offer" then
        offer_sequence = offer_sequence + 1
        return ransom_bridge:accept_offer(payload, context, {
            nativeOfferId = "pwft.native.ransom.offer."
                .. tostring(offer_sequence),
            shopId = shop_id,
            productId = product_id,
            merchantFactionId = pidf,
            currency = "Gold",
            unitPrice = price,
            buyQuantity = 1,
            singlePurchaseStock = true,
            serverAuthoritativePrice = true,
            serverAuthoritativePaymentResult = true,
            ransomPaymentKey = "PFT_Ransom_Payment_Rayne",
        })
    end
    if payload.deliveryKind == "pal-delivery" then
        return production:handle_delivery(payload, context)
    end
    return {
        ok = true,
        applied = true,
        deliveryId = payload.deliveryId,
        reason = "spec-text-notice-applied",
    }
end
assert(world_effect_bus:register_provider({
    providerId = provider_id,
    authoritySource = "pwft.authority.spec.ransom-delivery",
    deliveryKinds = { "war-notice", "ransom-offer", "pal-delivery" },
    idempotentDeliveryIds = true,
    generationFencedCallbacks = true,
}, provider_handler).ok)
assert(world_effect_bus:bind_target({
    bindingId = target_binding_id,
    providerId = provider_id,
    targetKind = "faction",
    targetId = rayne,
    buildId = "24575825",
    nativeRoutes = {
        textPresenterKey = "PFT_Text_Rayne",
        defenseRaidKey = "PFT_Defense_Rayne",
        backgroundWarResolverKey = "PFT_Background_War_Rayne",
        ransomPaymentKey = "PFT_Ransom_Payment_Rayne",
        palDeliveryKey = pal_delivery_key,
    },
    spawnBindings = {{
        spawnKind = "faction-patrol",
        spawnerKey = "PFT_Spawner_Rayne_Patrol",
        actorClassKeys = { "BP_PFT_Rayne_Patrol_C" },
    }},
    cleanupActorBindings = {},
    cityBindings = {},
    merchantCounterFactionIds = {},
    verification = {
        currentBuild = true,
        spawners = true,
        actorClasses = true,
        nativeRoutes = true,
    },
}).ok)
local generation = world_effect_bus:status().worldGeneration
assert(production:register({
    bindingId = "pwft.binding.spec.native-delivery.rayne",
    targetBindingId = target_binding_id,
    providerId = provider_id,
    palDeliveryKey = pal_delivery_key,
    worldGeneration = generation,
    speciesByUniquePalId = { [unique_pal_id] = "Anubis" },
}).ok)
assert(adapter_bind_count == 1)
assert(progression:join(rayne).ok)

local offered = world_effect_bus:offer_ransom(
    unique_pal_id,
    player_id,
    "pwft.offer.spec.anubis-ransom-001"
)
assert(offered.ok and offered.offer.amount == price)
assert(offered.offer.nativeOfferId == "pwft.native.ransom.offer.1")
assert(ransom_bridge:status().openOfferCount == 1)

local commerce_awards = 0
local commerce = FactionCommerce.create(Registry.commerce, {
    award_commerce = function()
        commerce_awards = commerce_awards + 1
        return { ok = true, reason = "awarded", applied = 1 }
    end,
})
local settlement_results = {}
local commerce_bridge = CommerceBridge.create(commerce, {
    transactionIdFactory = function()
        return "pwft.native.transaction.anubis-ransom-001"
    end,
    windowIdProvider = function() return "spec-window" end,
    priceResolver = function(
        request_shop,
        request_product,
        quantity,
        request_faction
    )
        return ransom_bridge:resolve_price(
            request_shop,
            request_product,
            quantity,
            request_faction
        )
    end,
    buyPolicyResolver = function(pending)
        return ransom_bridge:buy_policy(pending)
    end,
    eventSink = function(event)
        settlement_results[#settlement_results + 1] =
            ransom_bridge:handle_commerce_event(event)
    end,
})
local actor = {
    GetFullName = function()
        return "BP_PIDF_Ransom_Merchant_C /Game/Spec/Ransom"
    end,
}
local component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Spec/Ransom"
    end,
}
assert(commerce_bridge:register_vendor_actor(
    pidf,
    actor,
    { mode = "merchant-guild-ransom", commercialTruce = true }
))
assert(commerce_bridge:on_shop_setup(component, actor))
local requested, pending = commerce_bridge:on_buy_request(
    component,
    { A = 9, B = 10, C = 11, D = 12 },
    { A = 13, B = 14, C = 15, D = 16 },
    1
)
assert(requested and pending.totalGold == price)
assert(pending.shopId == "00000009-0000000a-0000000b-0000000c")
assert(pending.productId == "0000000d-0000000e-0000000f-00000010")
assert(pending.buyPolicy.settlementKind == "unique-pal-ransom")
assert(pending.buyPolicy.settlementEligible == true)
assert(pending.buyPolicy.skipCommerceReputation == true)
assert(commerce_bridge:on_buy_result(
    component,
    "EPalShopBuyResultType::Successed"
))
assert(settlement_results[1].ok)
assert(commerce_awards == 0)
assert(world:unique_pal_status(unique_pal_id).owner.kind == "player")
assert(world:unique_pal_status(unique_pal_id).owner.id == player_id)
assert(#scheduled == 1)

-- The Core has recorded the paid transfer and is waiting for this exact
-- server-created individual.  Drain the retained scheduler once to commit the
-- native capture and verify the same identity in storage.
scheduled[1]()
local delivery_id = "unique-pal-world.pwft.ransom-shop."
    .. "pwft.native.transaction.anubis-ransom-001.pal-delivery"
local delivery = world_effect_bus:delivery_status(delivery_id)
assert(delivery.status == "applied")
assert(create_count == 1)
assert(capture_count == 1)
assert(storage_read_count == 1)
assert(native_bridge:status().confirmedDeliveryCount == 1)
assert(native_bridge:status().pendingDeliveryCount == 0)
assert(ransom_bridge:status().confirmedPaymentCount == 1)
assert(ransom_bridge:status().runtimeIdentityBindCount == 1)
assert(ransom_bridge:status().palDeliveryIncluded == false)

local event = {
    type = "commerce-buy-result",
    ok = true,
    reason = "native-buy-confirmed-commerce-award-suppressed",
    transactionId = "pwft.native.transaction.anubis-ransom-001",
    factionId = pidf,
    shopId = pending.shopId,
    productId = pending.productId,
    buyNum = 1,
    totalGold = price,
    settlementKind = "unique-pal-ransom",
    settlementReferenceId = offered.offer.offerId,
    commerceReputationSuppressed = true,
    settlementEligible = true,
}
local duplicate_payment = ransom_bridge:handle_commerce_event(event)
assert(duplicate_payment.ok and duplicate_payment.idempotent)
assert(create_count == 1 and capture_count == 1 and storage_read_count == 1)

print("PASS one stock-one native ItemShop success confirms the exact ransom quote with zero commerce reputation, transfers one logical unique-Pal owner, creates/captures one approved Build-24575825 individual, reads back that same identity, and remains idempotent without a second payment or entity")
