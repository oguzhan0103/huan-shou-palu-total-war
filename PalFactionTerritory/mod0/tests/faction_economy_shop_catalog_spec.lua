package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionEconomy = require("pwft.faction_economy")
local FactionEconomyShopCatalog =
    require("pwft.faction_economy_shop_catalog")

local economy = FactionEconomy.create(Registry.economy)
local shops = FactionEconomyShopCatalog.create(
    Registry.economyShops,
    economy
)

local status = shops:status()
assert(shops.version == "1.0.0")
assert(status.representativeCount == 7)
assert(status.productRowCount == 26)
assert(status.requestedItemCount == 37)
assert(status.marketSignalCount == 63)
assert(status.customProductRowsReady == true)
assert(status.customProductRowsEnabled == true)
assert(status.nativeMerchantSpawnEnabled == true)
assert(status.nativeShopBindingEnabled == true)
assert(status.dynamicRestockEnabled == false)
assert(status.procurementMoneyBonusEnabled == false)
assert(status.procurementCommerceReputationEnabled == true)
assert(
    status.merchantIslandPlacementStatus
        == "ready"
)
assert(
    status.serverSuccessSignalStatus
        == "native_server_request_plus_inventory_replication_confirmation_enabled"
)
assert(shops.capabilities.readOnlyCatalog == true)
assert(shops.capabilities.nativeItemShopProductRows == true)
assert(shops.capabilities.nativeItemShopLotteryRows == true)
assert(shops.capabilities.runtimeMerchantSpawn == true)
assert(shops.capabilities.runtimeMoneyMutation == false)
assert(shops.capabilities.runtimeReputationMutation == true)

local rayne = "pwft.faction.rayne_syndicate"
local fpa = "pwft.faction.free_pal_alliance"
local pidf = "pwft.faction.pidf"

local representative = assert(shops:representative(rayne))
assert(representative.slotIndex == 0)
assert(representative.nativeCharacterId == "NPC_Male_Trader01_v10")
assert(
    representative.nativeCharacterClassPath
        == "/Game/Pal/Blueprint/Character/NPC/Normal/"
            .. "BP_NPC_Male_Trader01_v10."
            .. "BP_NPC_Male_Trader01_v10_C"
)
assert(representative.sourceNativeShopRowName == "CaravanShop5")
assert(representative.lotteryRowName == "PFT_Economy_Rayne")
assert(
    representative.productGroupRowName
        == "PFT_Economy_Rayne_Products"
)
assert(
    string.find(
        representative.nativeCharacterId,
        "DarkTrader",
        1,
        true
    ) == nil
)

-- Public reads return copies; content consumers cannot alter the registry.
representative.slotIndex = 99
assert(assert(shops:representative(rayne)).slotIndex == 0)

local rayne_shop = assert(shops:shop_catalog(rayne))
assert(rayne_shop.rowsReady == true)
assert(rayne_shop.rowsEnabled == true)
assert(rayne_shop.nativeShopBindingEnabled == true)
assert(#rayne_shop.products == 1)
assert(rayne_shop.products[1].itemId == "CopperIngot")
assert(rayne_shop.products[1].price == 240)
assert(rayne_shop.products[1].stock == 66)
assert(rayne_shop.products[1].supplyBand == "established")

local fpa_shop = assert(shops:shop_catalog(fpa))
assert(#fpa_shop.products == 7)
local pidf_shop = assert(shops:shop_catalog(pidf))
assert(#pidf_shop.products == 4)

local rayne_procurement =
    assert(shops:procurement_catalog(rayne))
assert(#rayne_procurement.requested == 8)
assert(
    rayne_procurement.nativeRequestedItemFilterAvailable
        == false
)
assert(rayne_procurement.nativePriceOverrideAvailable == false)
assert(rayne_procurement.moneyBonusEnabled == false)
assert(rayne_procurement.commerceReputationEnabled == true)

local iron_requested, iron_direction =
    shops:is_requested_item(rayne, "IronIngot")
assert(iron_requested == true)
assert(iron_direction == "procure")
local copper_requested, copper_direction =
    shops:is_requested_item(rayne, "CopperIngot")
assert(copper_requested == false)
assert(copper_direction == "sell")

local quote = assert(
    shops:quote_procurement(rayne, "IronIngot", 10, 720)
)
assert(quote.requestedQuantity == 10)
assert(quote.eligibleQuantity == 10)
assert(quote.quota == 20)
assert(quote.overQuota == false)
assert(quote.targetUnitPrice == 860)
assert(quote.nativeUnitPrice == 720)
assert(quote.targetGross == 8600)
assert(quote.nativeGross == 7200)
assert(quote.maximumMoneyBonus == 1400)
assert(quote.settlementReady == false)
assert(quote.moneyMutationEnabled == false)
assert(quote.commerceReputationMutationEnabled == true)
assert(
    quote.serverSuccessSignalStatus
        == "native_server_request_plus_inventory_replication_confirmation_enabled"
)

local capped = assert(
    shops:quote_procurement(rayne, "IronIngot", 30, 720)
)
assert(capped.eligibleQuantity == 20)
assert(capped.overQuota == true)
assert(capped.maximumMoneyBonus == 2800)

local no_quote, no_quote_reason =
    shops:quote_procurement(rayne, "CopperIngot", 1, 240)
assert(no_quote == nil)
assert(no_quote_reason == "item-not-requested")

local invalid, invalid_reason =
    shops:quote_procurement(rayne, "IronIngot", 0, 720)
assert(invalid == nil)
assert(invalid_reason == "invalid-positive-integer-quantity")

local unknown, unknown_reason =
    shops:shop_catalog("pwft.faction.unknown")
assert(unknown == nil)
assert(unknown_reason == "unknown-economy-shop-faction")

print(
    "PASS faction economy shop read-only catalogs, "
        .. "native rows, and disabled procurement settlement"
)
