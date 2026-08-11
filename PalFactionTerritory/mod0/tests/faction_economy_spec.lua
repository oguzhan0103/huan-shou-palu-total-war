package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionEconomy = require("pwft.faction_economy")

local economy = FactionEconomy.create(Registry.economy)
local status = economy:status()
assert(economy.version == "1.1.0")
assert(status.factionCount == 7)
assert(status.resourceCount == 8)
assert(status.auditedProductCount == 9)
assert(status.closedLoopProductCount == 4)
assert(status.merchantSuppliedInputProductCount == 5)
assert(status.unresolvedProductCount == 0)
assert(status.merchantOrganisationDisplayNameZhHans == "商人商会")
assert(status.customProductRowsEnabled == false)
assert(status.dynamicPriceRuntimeEnabled == false)
assert(status.requestedSaleReputationSettlementEnabled == true)
assert(status.balanceProfileId == "pwft.economy.balance.supply_band_v1")
assert(status.balanceRuntimeAuthority == false)
assert(status.balanceStatus
    == "offline_first_pass_complete_user_confirmation_and_live_calibration_pending")
assert(economy.capabilities.multiInputBottleneck == true)
assert(economy.capabilities.existingMerchantInputSupply == true)
assert(economy.capabilities.offlineBalanceProfile == true)
assert(economy.capabilities.exactPriceMultipliers == true)
assert(economy.capabilities.exactStockCounts == true)
assert(economy.capabilities.exactProcurementPrices == true)
assert(economy.capabilities.exactProcurementQuotas == true)
assert(economy.capabilities.runtimeMerchantMutation == false)

local rayne = "pwft.faction.rayne_syndicate"
local fpa = "pwft.faction.free_pal_alliance"
local pidf = "pwft.faction.pidf"
local genetics = "pwft.faction.pal_genetic_research_unit"
local moonflower = "pwft.faction.moonflower"
local pyre = "pwft.faction.eternal_pyre"
local feybreak = "pwft.faction.feybreak_army"

local function signal(faction_id, product_id, direction, band)
    local value, reason =
        economy:commodity_signal(faction_id, product_id)
    assert(value ~= nil, reason)
    assert(value.direction == direction)
    assert(value.effectiveSupplyBand == band)
    assert(value.exactPriceMultiplier ~= nil)
    if direction == "sell" then
        assert(value.exactSellPrice ~= nil)
        assert(value.exactStockCount ~= nil)
        assert(value.exactProcurementPrice == nil)
        assert(value.exactProcurementQuota == nil)
        assert(value.exactSellPrice >= value.merchantInputCostFloor)
    else
        assert(value.exactSellPrice == nil)
        assert(value.exactStockCount == nil)
        assert(value.exactProcurementPrice ~= nil)
        assert(value.exactProcurementQuota ~= nil)
    end
    return value
end

local rayne_copper =
    signal(rayne, "CopperIngot", "sell", "established")
assert(rayne_copper.exactPriceMultiplier == 1.0)
assert(rayne_copper.exactSellPrice == 240)
assert(rayne_copper.exactStockCount == 66)

local rayne_iron =
    signal(rayne, "IronIngot", "procure", "scarce")
assert(rayne_iron.exactProcurementPriceMultiplier == 1.2)
assert(rayne_iron.exactProcurementPrice == 860)
assert(rayne_iron.exactProcurementQuota == 20)
signal(rayne, "Plastic", "procure", "absent")
signal(rayne, "StainlessSteel", "procure", "absent")

signal(fpa, "CopperIngot", "sell", "established")
signal(fpa, "IronIngot", "sell", "established")
signal(fpa, "Plastic", "procure", "absent")

local pidf_copper =
    signal(pidf, "CopperIngot", "sell", "strong")
assert(pidf_copper.exactSellPrice == 220)
assert(pidf_copper.exactStockCount == 99)
signal(pidf, "IronIngot", "sell", "strong")
signal(pidf, "Plastic", "sell", "strong")

signal(genetics, "CopperIngot", "sell", "strong")
signal(genetics, "IronIngot", "procure", "scarce")
signal(genetics, "Plastic", "sell", "limited")

local moonflower_copper =
    signal(moonflower, "CopperIngot", "procure", "absent")
assert(moonflower_copper.exactProcurementPrice == 340)
assert(moonflower_copper.exactProcurementQuota == 88)
signal(moonflower, "IronIngot", "procure", "absent")
signal(moonflower, "Plastic", "procure", "absent")

signal(pyre, "CopperIngot", "sell", "established")
signal(pyre, "IronIngot", "sell", "established")
signal(pyre, "Plastic", "sell", "established")

signal(feybreak, "CopperIngot", "procure", "absent")
signal(feybreak, "IronIngot", "procure", "absent")
signal(feybreak, "Plastic", "procure", "absent")
local feybreak_hexolite =
    signal(feybreak, "StainlessSteel", "sell", "exclusive")
assert(feybreak_hexolite.exactSellPrice == 2100)
assert(feybreak_hexolite.exactStockCount == 38)

local circuit = economy:commodity_signal(genetics, "MachineParts2")
assert(circuit.direction == "sell")
assert(circuit.effectiveSupplyBand == "dominant")
assert(circuit.reason == "local-effective-supply-supports-production")
assert(circuit.supplyMode
    == "territorial-bottleneck-plus-existing-merchant-inputs")
assert(#circuit.merchantSuppliedInputs == 1)
assert(circuit.merchantSuppliedInputs[1].itemId == "Polymer")
assert(circuit.merchantInputNativeCost == 1080)
assert(circuit.merchantInputCostFloor == 1300)
assert(circuit.exactSellPrice == 1880)
assert(circuit.exactStockCount == 31)

local market = economy:faction_market(pidf)
assert(market.factionId == pidf)
assert(#market.sell == 4)
assert(#market.procure == 5)
assert(#market.unresolved == 0)
assert(economy:is_requested_item(moonflower, "CopperIngot") == true)
assert(economy:is_requested_item(pidf, "CopperIngot") == false)

local band_order = {
    absent = 1,
    scarce = 2,
    limited = 3,
    established = 4,
    strong = 5,
    abundant = 6,
    dominant = 7,
    exclusive = 8,
}
local all_factions = {
    rayne,
    fpa,
    pidf,
    genetics,
    moonflower,
    pyre,
    feybreak,
}
local signals_by_product = {}
local market_signal_count = 0
for _, faction_id in ipairs(all_factions) do
    local faction_market = assert(economy:faction_market(faction_id))
    assert(#faction_market.unresolved == 0)
    assert(#faction_market.sell + #faction_market.procure == 9)
    for _, row in ipairs(faction_market.sell) do
        market_signal_count = market_signal_count + 1
        assert(row.exactSellPrice % 10 == 0)
        assert(row.exactStockCount >= 1 and row.exactStockCount <= 99)
        assert(row.exactSellPrice >= row.merchantInputCostFloor)
        assert(
            row.exactSellPrice * row.exactStockCount
                <= row.stockValueBudget
        )
        signals_by_product[row.productItemId] =
            signals_by_product[row.productItemId] or {}
        table.insert(signals_by_product[row.productItemId], row)
    end
    for _, row in ipairs(faction_market.procure) do
        market_signal_count = market_signal_count + 1
        assert(row.exactProcurementPrice % 10 == 0)
        assert(
            row.exactProcurementQuota >= 1
                and row.exactProcurementQuota <= 99
        )
        assert(
            row.exactProcurementPrice * row.exactProcurementQuota
                <= row.procurementValueBudget
        )
        signals_by_product[row.productItemId] =
            signals_by_product[row.productItemId] or {}
        table.insert(signals_by_product[row.productItemId], row)
    end
end
assert(market_signal_count == 63)

for _, product_signals in pairs(signals_by_product) do
    for left_index, left in ipairs(product_signals) do
        for right_index, right in ipairs(product_signals) do
            if left_index < right_index and left.direction == right.direction then
                local left_band = band_order[left.effectiveSupplyBand]
                local right_band = band_order[right.effectiveSupplyBand]
                if left.direction == "sell" and left_band < right_band then
                    assert(left.exactSellPrice >= right.exactSellPrice)
                    assert(left.exactStockCount <= right.exactStockCount)
                elseif left.direction == "sell" and right_band < left_band then
                    assert(right.exactSellPrice >= left.exactSellPrice)
                    assert(right.exactStockCount <= left.exactStockCount)
                elseif left.direction == "procure" and left_band < right_band then
                    assert(
                        left.exactProcurementPrice
                            >= right.exactProcurementPrice
                    )
                    assert(
                        left.exactProcurementQuota
                            >= right.exactProcurementQuota
                    )
                elseif left.direction == "procure" and right_band < left_band then
                    assert(
                        right.exactProcurementPrice
                            >= left.exactProcurementPrice
                    )
                    assert(
                        right.exactProcurementQuota
                            >= left.exactProcurementQuota
                    )
                end
            end
        end
    end
end

local unknown, unknown_reason =
    economy:commodity_signal("pwft.faction.unknown", "CopperIngot")
assert(unknown == nil)
assert(unknown_reason == "unknown-economy-faction")

print(
    "PASS faction economy supply bottlenecks, "
        .. "processed-goods offers, and missing-goods procurement signals"
)
