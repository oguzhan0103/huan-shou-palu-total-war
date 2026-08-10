package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionCommerce = require("pwft.faction_commerce")
local CommerceBridge = require("pwft.commerce_bridge")

local awards = {}
local faction_api = {
    award_commerce = function(
        _,
        faction_id,
        amount,
        transaction_id,
        window_id,
        commerce_context
    )
        table.insert(awards, {
            factionId = faction_id,
            amount = amount,
            transactionId = transaction_id,
            windowId = window_id,
            diplomacyRecoveryEligible =
                commerce_context
                    and commerce_context
                        .diplomacyRecoveryEligible
                or false,
            venueMode =
                commerce_context
                    and commerce_context.venueMode
                or nil,
        })
        return {
            ok = true,
            reason = "awarded",
            applied = amount,
        }
    end,
}
local commerce = FactionCommerce.create(Registry.commerce, faction_api)
local events = {}
local bridge = CommerceBridge.create(commerce, {
    eventSink = function(event)
        table.insert(events, event)
    end,
    windowIdProvider = function()
        return "world-day-20"
    end,
    transactionIdFactory = function()
        return "native-transaction-001"
    end,
    priceResolver = function(_, _, quantity)
        return quantity * 12000
    end,
    nativeSaleReplicationProbeEnabled = true,
    nativeSaleReputationSettlementEnabled = false,
})

local actor = {
    GetFullName = function()
        return "BP_NPC_DarkTrader_C /Game/Test/Rayne"
    end,
}
local component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/Player"
    end,
}
local shop_guid = { A = 1, B = 2, C = 3, D = 4 }
local product_guid = { A = 5, B = 6, C = 7, D = 8 }

assert(bridge:register_vendor_actor(
    "pwft.faction.rayne_syndicate",
    actor,
    {
        mode = "fixed-market",
        commercialTruce = true,
    }
))
assert(bridge:on_shop_setup(component, actor))
local requested, pending = bridge:on_buy_request(
    component,
    shop_guid,
    product_guid,
    2
)
assert(requested)
assert(pending.totalGold == 24000)
assert(#awards == 0)

local failed, failed_outcome = bridge:on_buy_result(component, 2)
assert(failed)
assert(failed_outcome.reason == "native-buy-failed")
assert(#awards == 0)

bridge:on_buy_request(component, shop_guid, product_guid, 2)
local succeeded, buy_outcome = bridge:on_buy_result(
    component,
    "EPalShopBuyResultType::Successed"
)
assert(succeeded)
assert(buy_outcome.ok)
assert(buy_outcome.requestedAward == 4)
assert(#awards == 1)
assert(awards[1].diplomacyRecoveryEligible == true)
assert(awards[1].venueMode == "fixed-market")
assert(events[#events].type == "commerce-buy-result")
assert(events[#events].ok == true)

local item_shop_ui = {
    GetFullName = function()
        return "PalUIItemShopBase /Game/Test/ItemShop"
    end,
}
local pal_oil_name = {
    ToString = function()
        return "PalOil"
    end,
}
local coal_name = {
    ToString = function()
        return "Coal"
    end,
}
local ui_started, ui_attempt =
    bridge:on_item_sell_ui_request(
        item_shop_ui,
        {
            {
                ItemId = { StaticId = pal_oil_name },
                StackCount = 40,
            },
            {
                ItemId = { StaticId = coal_name },
                StackCount = 999,
            },
        }
    )
assert(ui_started)
assert(#ui_attempt.items == 2)
assert(bridge:on_sell_request(component, shop_guid, {}))
assert(bridge:on_item_sell_ui_result(
    item_shop_ui,
    true
))
assert(#awards == 1)
local sale_confirmed, sale_outcome = bridge:confirm_item_sale(
    component,
    nil,
    "native-sale-confirmation-001",
    "world-day-20"
)
assert(sale_confirmed)
assert(sale_outcome.requestedAward == 2)
assert(#awards == 2)
assert(awards[2].diplomacyRecoveryEligible == true)
assert(awards[2].venueMode == "fixed-market")
assert(bridge:status().sellRequestCount == 1)
assert(bridge:status().itemSellUiRequestCount == 1)
assert(bridge:status().itemSellUiAcceptedCount == 1)
assert(bridge:status().extractedSaleItemCount == 2)
assert(bridge:status().confirmedSellCount == 1)

assert(bridge:on_item_sell_ui_request(
    item_shop_ui,
    {
        {
            ItemId = { StaticId = coal_name },
            StackCount = 10,
        },
    }
))
assert(bridge:on_sell_request(component, shop_guid, {}))
assert(bridge:on_item_sell_ui_result(
    item_shop_ui,
    false
))
local rejected_sale, rejected_reason =
    bridge:confirm_item_sale(
        component,
        nil,
        "must-not-settle",
        "world-day-20"
    )
assert(not rejected_sale)
assert(rejected_reason == "no-pending-sale")
assert(#awards == 2)

local replicated_slot = {
    ItemId = { StaticId = pal_oil_name },
    StackCount = 20,
    GetFullName = function()
        return "PalItemSlot /Game/Test/ReplicatedSale"
    end,
}
assert(bridge:on_item_sell_ui_request(
    item_shop_ui,
    { replicated_slot }
))
assert(bridge:on_sell_request(component, shop_guid, {}))
assert(bridge:on_item_sell_ui_result(
    item_shop_ui,
    true
))
assert(#awards == 2)
replicated_slot.StackCount = 0
local replication_confirmed, replication_outcome =
    bridge:on_item_slot_replicated(
        replicated_slot,
        "test-OnRep_StackCount"
    )
assert(replication_confirmed)
assert(
    replication_outcome.reason
        == "native-sale-replication-confirmed-probe-only"
)
assert(#awards == 2)
assert(
    bridge:status().nativeSellReplicationConfirmedCount
        == 1
)
assert(
    bridge:status().nativeSellReplicationProbeOnlyCount
        == 1
)
assert(
    bridge:status().sellNativeSuccessSignal
        == "server-inventory-replication-probe-ready-settlement-disabled"
)
assert(events[#events].type == "commerce-sale-confirmed")
assert(events[#events].settlementEnabled == false)
assert(events[#events].items[1].itemId == "PalOil")

local settling_bridge = CommerceBridge.create(commerce, {
    windowIdProvider = function()
        return "world-day-21"
    end,
    nativeSaleReplicationProbeEnabled = true,
    nativeSaleReputationSettlementEnabled = true,
})
local settling_actor = {
    GetFullName = function()
        return "BP_NPC_Trader_C /Game/Test/SettlingVendor"
    end,
}
local settling_component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/SettlingPlayer"
    end,
}
assert(settling_bridge:register_vendor_actor(
    "pwft.faction.rayne_syndicate",
    settling_actor,
    {
        mode = "fixed-market",
        commercialTruce = true,
    }
))
assert(settling_bridge:on_shop_setup(
    settling_component,
    settling_actor
))
local settling_slot = {
    ItemId = { StaticId = pal_oil_name },
    StackCount = 40,
    GetFullName = function()
        return "PalItemSlot /Game/Test/SettlingSale"
    end,
}
assert(settling_bridge:on_item_sell_ui_request(
    item_shop_ui,
    { settling_slot }
))
assert(settling_bridge:on_sell_request(
    settling_component,
    { A = 9, B = 10, C = 11, D = 12 },
    {}
))
assert(settling_bridge:on_item_sell_ui_result(
    item_shop_ui,
    true
))
settling_slot.StackCount = 0
local settled, settled_outcome =
    settling_bridge:on_item_slot_replicated(
        settling_slot,
        "test-authoritative-replication"
    )
assert(settled)
assert(settled_outcome.ok)
assert(settled_outcome.requestedAward == 2)
assert(#awards == 3)

-- A temporary sidecar/progression rejection after authoritative inventory
-- replication must not lose the sale. The same confirmation and commerce
-- window are retried, so the eventual success is awarded exactly once.
local retry_attempts = 0
local retry_confirmations = {}
local retry_windows = {}
local retry_commerce = {
    registeredShops = {},
}
function retry_commerce:merchant_status()
    return { factionId = "pwft.faction.rayne_syndicate" }
end
function retry_commerce:register_shop(shop_id, faction_id, metadata)
    self.registeredShops[shop_id] = {
        factionId = faction_id,
        metadata = metadata,
    }
    return { ok = true, reason = "registered" }
end
function retry_commerce:confirm_requested_sale(
    shop_id,
    confirmation_id,
    items,
    commerce_window_id
)
    retry_attempts = retry_attempts + 1
    retry_confirmations[retry_attempts] = confirmation_id
    retry_windows[retry_attempts] = commerce_window_id
    if retry_attempts == 1 then
        return {
            ok = false,
            reason = "temporary-progression-sidecar-unavailable",
            applied = 0,
        }
    end
    return {
        ok = true,
        reason = "commerce-reputation-awarded-after-retry",
        applied = 1,
        requestedAward = 1,
        shopId = shop_id,
        requestedItemCount = items[1].count,
    }
end
local retry_bridge = CommerceBridge.create(retry_commerce, {
    windowIdProvider = function()
        return "world-day-retry-22"
    end,
    nativeSaleReplicationProbeEnabled = true,
    nativeSaleReputationSettlementEnabled = true,
})
local retry_actor = {
    GetFullName = function()
        return "BP_NPC_Trader_C /Game/Test/RetryVendor"
    end,
}
local retry_component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/RetryPlayer"
    end,
}
local retry_slot = {
    ItemId = { StaticId = pal_oil_name },
    StackCount = 20,
    GetFullName = function()
        return "PalItemSlot /Game/Test/RetrySale"
    end,
}
assert(retry_bridge:register_vendor_actor(
    "pwft.faction.rayne_syndicate",
    retry_actor,
    { mode = "fixed-market", commercialTruce = true }
))
assert(retry_bridge:on_shop_setup(retry_component, retry_actor))
assert(retry_bridge:on_item_sell_ui_request(
    item_shop_ui,
    { retry_slot }
))
assert(retry_bridge:on_sell_request(
    retry_component,
    { A = 13, B = 14, C = 15, D = 16 },
    {}
))
assert(retry_bridge:on_item_sell_ui_result(item_shop_ui, true))
retry_slot.StackCount = 0
local retry_failed, retry_failure =
    retry_bridge:on_item_slot_replicated(
        retry_slot,
        "test-authoritative-replication-first"
    )
assert(not retry_failed)
assert(retry_failure.reason
    == "temporary-progression-sidecar-unavailable")
assert(retry_bridge:status().confirmedSellCount == 0)
local retry_succeeded, retry_outcome =
    retry_bridge:on_item_slot_replicated(
        retry_slot,
        "test-authoritative-replication-retry"
    )
assert(retry_succeeded)
assert(retry_outcome.reason
    == "commerce-reputation-awarded-after-retry")
assert(retry_outcome.applied == 1)
assert(retry_attempts == 2)
assert(retry_confirmations[1] == retry_confirmations[2])
assert(retry_windows[1] == retry_windows[2])
assert(retry_windows[1] == "world-day-retry-22")
assert(retry_bridge:status().confirmedSellCount == 1)
assert(retry_bridge:status().nativeSellSettlementAttemptCount == 2)
assert(retry_bridge:status().nativeSellSettlementRetryCount == 1)
assert(retry_bridge:status().nativeSellSettlementFailureCount == 1)
local no_duplicate, no_duplicate_reason =
    retry_bridge:on_item_slot_replicated(
        retry_slot,
        "test-authoritative-replication-after-success"
    )
assert(not no_duplicate)
assert(no_duplicate_reason == "replicated-slot-not-pending-sale")
assert(retry_attempts == 2)

print("PASS native commerce buy bridge and confirmed-sale adapter")
