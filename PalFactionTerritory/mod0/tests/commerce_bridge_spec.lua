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
local wrapped_slot_array = {
    get = function()
        error("TArray.get requires an index")
    end,
    ForEach = function(_, callback)
        callback(0, {
            ItemId = { StaticId = pal_oil_name },
            StackCount = 40,
        })
    end,
}
local wrapped_started, wrapped_attempt =
    bridge:on_item_sell_ui_request(
        item_shop_ui,
        wrapped_slot_array
    )
assert(wrapped_started)
assert(#wrapped_attempt.items == 1)
assert(wrapped_attempt.items[1].itemId == "PalOil")
assert(wrapped_attempt.items[1].count == 40)
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
assert(bridge:status().itemSellUiRequestCount == 2)
assert(bridge:status().itemSellUiAcceptedCount == 1)
assert(bridge:status().extractedSaleItemCount == 3)
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

-- The native ItemShop can submit a transient presentation slot which does
-- not change when the authoritative player inventory removes a full stack.
-- An unrelated real inventory OnRep must wake the aggregate inventory probe,
-- while settlement still requires the exact total item-count decrease.
local aggregate_inventory_count = 1
local aggregate_bridge = CommerceBridge.create(commerce, {
    windowIdProvider = function()
        return "world-day-aggregate-21"
    end,
    nativeSaleReplicationProbeEnabled = true,
    nativeSaleReputationSettlementEnabled = true,
    inventorySnapshotResolver = function(item_id, sold_count)
        assert(item_id == "Coal")
        assert(sold_count == 1)
        return {
            initialCount = aggregate_inventory_count,
            readCurrentCount = function()
                return aggregate_inventory_count
            end,
        }
    end,
})
local aggregate_actor = {
    GetFullName = function()
        return "BP_NPC_Trader_C /Game/Test/AggregateVendor"
    end,
}
local aggregate_component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/AggregatePlayer"
    end,
}
local presentation_slot = {
    ItemId = { StaticId = coal_name },
    StackCount = 1,
    GetFullName = function()
        return "PalItemSlot /Engine/Transient/PresentationSale"
    end,
}
assert(aggregate_bridge:register_vendor_actor(
    "pwft.faction.rayne_syndicate",
    aggregate_actor,
    { mode = "fixed-market", commercialTruce = true }
))
assert(aggregate_bridge:on_shop_setup(
    aggregate_component,
    aggregate_actor
))
assert(aggregate_bridge:on_item_sell_ui_request(
    item_shop_ui,
    { presentation_slot }
))
assert(aggregate_bridge:on_sell_request(
    aggregate_component,
    { A = 21, B = 22, C = 23, D = 24 },
    {}
))
aggregate_inventory_count = 0
local aggregate_confirmed, aggregate_outcome =
    aggregate_bridge:on_item_slot_replicated(
        {
            GetFullName = function()
                return "PalItemSlot /Game/Test/RealInventorySlot"
            end,
        },
        "test-OnRep_ItemId"
    )
assert(aggregate_confirmed)
assert(aggregate_outcome.ok)
assert(aggregate_outcome.applied == 0)
assert(aggregate_outcome.reason == "no-requested-items")
assert(presentation_slot.StackCount == 1)
assert(aggregate_bridge:status().confirmedSellCount == 1)

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

local context_bridge = CommerceBridge.create(commerce, {
    nativeSaleReplicationProbeEnabled = true,
    nativeSaleReputationSettlementEnabled = true,
})
local context_rayne_actor = {
    GetFullName = function()
        return "BP_NPC_Trader_C /Game/Test/ContextRayne"
    end,
}
local context_genetics_actor = {
    GetFullName = function()
        return "BP_NPC_Trader_C /Game/Test/ContextGenetics"
    end,
}
local shared_component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/SharedPlayer"
    end,
}
assert(context_bridge:register_vendor_actor(
    "pwft.faction.rayne_syndicate",
    context_rayne_actor,
    { mode = "fixed-market", representedFactionId = "rayne" }
))
assert(context_bridge:on_shop_setup(
    shared_component,
    context_rayne_actor
))
assert(context_bridge:register_vendor_actor(
    "pwft.faction.pal_genetic_research_unit",
    context_genetics_actor,
    { mode = "fixed-market", representedFactionId = "genetics" }
))
assert(context_bridge:on_shop_setup(
    shared_component,
    context_genetics_actor
))
assert(context_bridge:begin_vendor_interaction(
    "pwft.faction.rayne_syndicate",
    context_rayne_actor
))
assert(context_bridge:on_item_sell_ui_request(
    item_shop_ui,
    {
        {
            ItemId = { StaticId = pal_oil_name },
            StackCount = 40,
        },
    }
))
local context_requested, context_pending =
    context_bridge:on_sell_request(
        shared_component,
        { A = 21, B = 22, C = 23, D = 24 },
        {}
    )
assert(context_requested)
assert(context_pending.factionId
    == "pwft.faction.rayne_syndicate")

local delayed_callbacks = {}
local previous_execute_with_delay = ExecuteWithDelay
local previous_execute_in_game_thread = ExecuteInGameThread
ExecuteWithDelay = function(_, callback)
    table.insert(delayed_callbacks, callback)
end
ExecuteInGameThread = function(callback)
    callback()
end
local polled_bridge = CommerceBridge.create(commerce, {
    nativeSaleReplicationProbeEnabled = true,
    nativeSaleReputationSettlementEnabled = false,
})
local polled_actor = {
    GetFullName = function()
        return "BP_NPC_Trader_C /Game/Test/PolledVendor"
    end,
}
local polled_component = {
    GetFullName = function()
        return "PalNetworkShopComponent /Game/Test/PolledPlayer"
    end,
}
local polled_slot = {
    ItemId = { StaticId = pal_oil_name },
    StackCount = 10,
    GetFullName = function()
        return "PalItemSlot /Game/Test/PolledSale"
    end,
}
assert(polled_bridge:register_vendor_actor(
    "pwft.faction.rayne_syndicate",
    polled_actor,
    { mode = "fixed-market", commercialTruce = true }
))
assert(polled_bridge:on_shop_setup(polled_component, polled_actor))
assert(polled_bridge:on_item_sell_ui_request(
    item_shop_ui,
    { polled_slot }
))
assert(polled_bridge:on_sell_request(
    polled_component,
    { A = 17, B = 18, C = 19, D = 20 },
    {}
))
assert(#delayed_callbacks == 1)
polled_slot.StackCount = 0
delayed_callbacks[1]()
assert(polled_bridge:status().nativeSellReplicationConfirmedCount == 1)
assert(polled_bridge:status().nativeSellReplicationProbeOnlyCount == 1)
assert(polled_bridge:status().confirmedSellCount == 0)
ExecuteWithDelay = previous_execute_with_delay
ExecuteInGameThread = previous_execute_in_game_thread

print("PASS native commerce buy bridge and confirmed-sale adapter")
