package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionCommerce = require("pwft.faction_commerce")
local FactionEconomy = require("pwft.faction_economy")
local FactionEconomyShopCatalog =
    require("pwft.faction_economy_shop_catalog")
local FactionProgression = require("pwft.faction_progression")

local awards = {}
local faction_api = {
    award_commerce = function(
        _,
        faction_id,
        amount,
        transaction_id,
        window_id
    )
        table.insert(awards, {
            factionId = faction_id,
            amount = amount,
            transactionId = transaction_id,
            windowId = window_id,
        })
        return {
            ok = true,
            reason = "awarded",
            applied = amount,
        }
    end,
}

local commerce = FactionCommerce.create(Registry.commerce, faction_api)
assert(commerce.version == "1.0.0")
assert(commerce:status().factionCount == 7)
assert(commerce.capabilities.automaticAffiliationRecovery == true)
assert(commerce.capabilities.oneHostilitySourceAtATime == true)
assert(commerce.capabilities.economyDrivenRequestedItems == false)
assert(commerce:status().requestedItemSource
    == "faction-commerce-static-fallback")
assert(
    commerce:merchant_status("pwft.faction.rayne_syndicate").salesChannel
        == "PalShop"
)
assert(
    commerce:is_requested_item(
        "pwft.faction.free_pal_alliance",
        "Leather"
    )
)
assert(
    not commerce:is_requested_item(
        "pwft.faction.free_pal_alliance",
        "Coal"
    )
)

assert(
    commerce:register_shop(
        "shop-rayne",
        "pwft.faction.rayne_syndicate"
    ).ok
)
assert(commerce:calculate_buy_award(0) == 1)
assert(commerce:calculate_buy_award(25000) == 5)
assert(commerce:calculate_buy_award(999999) == 5)

local buy = commerce:confirm_buy(
    "shop-rayne",
    "native-buy-001",
    15000,
    "world-day-10"
)
assert(buy.ok)
assert(buy.applied == 3)
assert(buy.direction == "buy")
assert(#awards == 1)
assert(awards[1].factionId == "pwft.faction.rayne_syndicate")
assert(awards[1].transactionId == "buy:shop-rayne:native-buy-001")

local duplicate = commerce:confirm_buy(
    "shop-rayne",
    "native-buy-001",
    15000,
    "world-day-10"
)
assert(duplicate.reason == "duplicate-transaction")
assert(#awards == 1)

commerce:register_shop(
    "shop-fpa",
    "pwft.faction.free_pal_alliance"
)
local no_request = commerce:confirm_requested_sale(
    "shop-fpa",
    "sale-001",
    {
        { itemId = "Coal", count = 100 },
    },
    "world-day-10"
)
assert(no_request.reason == "no-requested-items")
assert(#awards == 1)

local requested = commerce:confirm_requested_sale(
    "shop-fpa",
    "sale-002",
    {
        { itemId = "Leather", count = 45 },
        { itemId = "Coal", count = 999 },
    },
    "world-day-10"
)
assert(requested.ok)
assert(requested.requestedItemCount == 45)
assert(requested.requestedAward == 2)
assert(requested.applied == 2)
assert(#awards == 2)

-- The foundation runtime must settle shortages from the economy contract,
-- not the older static requestedItemIds compatibility list. Rayne requests
-- IronIngot in the economy model while PalSphere_Master is static-only.
local economy = FactionEconomy.create(Registry.economy)
local economy_shops = FactionEconomyShopCatalog.create(
    Registry.economyShops,
    economy
)
local resolved_awards = {}
local resolved_commerce = FactionCommerce.create(
    Registry.commerce,
    {
        award_commerce = function(_, faction_id, amount)
            table.insert(resolved_awards, {
                factionId = faction_id,
                amount = amount,
            })
            return {
                ok = true,
                reason = "awarded",
                applied = amount,
            }
        end,
    },
    {
        requestedItemResolver = function(faction_id, item_id)
            return economy_shops:is_requested_item(
                faction_id,
                item_id
            )
        end,
        requestedItemSource =
            "faction-economy-commodity-signals-v1",
    }
)
assert(resolved_commerce.capabilities.economyDrivenRequestedItems
    == true)
assert(resolved_commerce:is_requested_item(
    "pwft.faction.rayne_syndicate",
    "IronIngot"
) == true)
assert(resolved_commerce:is_requested_item(
    "pwft.faction.rayne_syndicate",
    "PalSphere_Master"
) == false)
assert(resolved_commerce:register_shop(
    "shop-rayne-economy-resolved",
    "pwft.faction.rayne_syndicate",
    {
        mode = "fixed-market",
        commercialTruce = true,
    }
).ok)
local economy_resolved_sale =
    resolved_commerce:confirm_requested_sale(
        "shop-rayne-economy-resolved",
        "sale-economy-resolved-001",
        {
            { itemId = "IronIngot", count = 40 },
            { itemId = "PalSphere_Master", count = 999 },
        },
        "world-day-economy-resolved"
    )
assert(economy_resolved_sale.ok)
assert(economy_resolved_sale.requestedItemCount == 40)
assert(economy_resolved_sale.requestedAward == 2)
assert(#economy_resolved_sale.requestedItems == 1)
assert(economy_resolved_sale.requestedItems[1].itemId
    == "IronIngot")
assert(economy_resolved_sale.requestedItemSource
    == "faction-economy-commodity-signals-v1")
assert(#resolved_awards == 1)

local retry_attempts = 0
local retry_commerce = FactionCommerce.create(Registry.commerce, {
    award_commerce = function()
        retry_attempts = retry_attempts + 1
        if retry_attempts == 1 then
            return {
                ok = false,
                reason = "temporary-settlement-rejection",
                applied = 0,
            }
        end
        return {
            ok = true,
            reason = "awarded-after-retry",
            applied = 1,
        }
    end,
})
assert(
    retry_commerce:register_shop(
        "shop-retry",
        "pwft.faction.pidf"
    ).ok
)
local rejected = retry_commerce:confirm_buy(
    "shop-retry",
    "native-buy-retry-001",
    5000,
    "world-day-10"
)
assert(not rejected.ok)
assert(rejected.reason == "temporary-settlement-rejection")
assert(retry_commerce:status().transactionCount == 0)
local retried = retry_commerce:confirm_buy(
    "shop-retry",
    "native-buy-retry-001",
    5000,
    "world-day-10"
)
assert(retried.ok)
assert(retried.reason == "awarded-after-retry")
assert(retry_commerce:status().transactionCount == 1)
assert(retry_attempts == 2)

-- Successful fixed-market purchases feed the real progression API. Four
-- maximum-value purchases per window reach the 20-point window cap; three
-- windows clear exactly one 60-point affiliation-hostility source.
local recovery_progression =
    FactionProgression.create(Registry.progression)
local recovery_api = FactionApi.create(recovery_progression)
local recovery_commerce =
    FactionCommerce.create(Registry.commerce, recovery_api)
local rayne_id = "pwft.faction.rayne_syndicate"
local free_pal_id = "pwft.faction.free_pal_alliance"
assert(recovery_api:join_human(
    rayne_id,
    "commerce-recovery-join-rayne"
).ok)
assert(recovery_api:faction_status(free_pal_id).relation
    == "Hostile")
assert(recovery_commerce:register_shop(
    "shop-fpa-fixed-recovery",
    free_pal_id,
    {
        mode = "fixed-market",
        commercialTruce = true,
    }
).ok)
local last_recovery = nil
for window = 1, 3 do
    for transaction = 1, 4 do
        local transaction_id = string.format(
            "native-buy-recovery-%d-%d",
            window,
            transaction
        )
        last_recovery = recovery_commerce:confirm_buy(
            "shop-fpa-fixed-recovery",
            transaction_id,
            25000,
            "world-day-recovery-" .. window
        )
        assert(last_recovery.ok)
        assert(last_recovery.applied == 5)
    end
end
assert(
    last_recovery.commerceDiplomacyRecovery.reason
        == "diplomacy-hostility-cleared-by-commerce"
)
assert(last_recovery.commerceDiplomacyRecovery.cleared == true)
assert(recovery_api:faction_status(free_pal_id).reputation
    == 60)
assert(recovery_api:faction_status(free_pal_id).relation
    == "Friendly")
assert(recovery_api:can_join(free_pal_id) == true)
assert(
    recovery_commerce:confirm_buy(
        "shop-fpa-fixed-recovery",
        "native-buy-recovery-3-4",
        25000,
        "world-day-recovery-3"
    ).reason
        == "duplicate-transaction"
)

print("PASS seven-faction commerce registry and settlement engine")
