package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StaticEconomy = require("pwft.faction_economy")
local ResourceLedger = require("pwft.faction_resource_ledger")
local DynamicEconomy = require("pwft.faction_dynamic_economy")

local rayne = "pwft.faction.rayne_syndicate"
local metal = "metal_ore"

local progression = Progression.create(Registry.progression)
local ledger = ResourceLedger.create(progression, Registry.economy)
local static = StaticEconomy.create(Registry.economy)
local economy = DynamicEconomy.create(static, ledger)

assert(economy.version == "1.0.0")
assert(economy.capabilities.resourceLedgerAuthority)
assert(economy.capabilities.gameObjectMutation == false)
assert(economy.capabilities.currencyMutation == false)
assert(economy.capabilities.palworldSaveMutation == false)

local baseline = assert(economy:commodity_signal(rayne, "CopperIngot"))
assert(baseline.direction == "sell")
assert(baseline.effectiveSupplyBand == "established")
assert(baseline.exactSellPrice == 240)
assert(baseline.exactStockCount == 66)
assert(baseline.resourceLedgerRevision == 0)

-- A real resource event changes both price and exact shop inventory without
-- editing the audited baseline contract.
local reduced = ledger:apply_event({
    operationId = "dynamic-economy.consume-metal.1",
    type = "consumption",
    factionId = rayne,
    resourceId = metal,
    amount = 100,
})
assert(reduced.ok and reduced.supplyBand == "limited")
local limited = assert(economy:commodity_signal(rayne, "CopperIngot"))
assert(limited.direction == "sell")
assert(limited.effectiveSupplyBand == "limited")
assert(limited.exactSellPrice == 280)
assert(limited.exactStockCount == 25)
assert(limited.resourceLedgerRevision == 1)

-- Crossing into scarcity removes the sale line from the dynamic catalog and
-- turns the same processed item into an exact procurement request.
assert(ledger:apply_event({
    operationId = "dynamic-economy.consume-metal.2",
    type = "loss",
    factionId = rayne,
    resourceId = metal,
    amount = 1,
}).ok)
local scarce = assert(economy:commodity_signal(rayne, "CopperIngot"))
assert(scarce.direction == "procure")
assert(scarce.effectiveSupplyBand == "scarce")
assert(scarce.exactSellPrice == nil)
assert(scarce.exactProcurementPrice == 290)
assert(scarce.exactProcurementQuota > 0)
assert(economy:is_requested_item(rayne, "CopperIngot"))

-- Supplying the missing mineral reopens the native sale projection. The
-- ledger snapshot is the only persistent authority, so a recreated wrapper
-- produces exactly the same result after restart/restore.
assert(ledger:apply_event({
    operationId = "dynamic-economy.import-metal.1",
    type = "import",
    factionId = rayne,
    resourceId = metal,
    amount = 101,
}).ok)
local reopened = assert(economy:commodity_signal(rayne, "CopperIngot"))
assert(reopened.direction == "sell")
assert(reopened.effectiveSupplyBand == "established")
assert(reopened.exactSellPrice == 240)
assert(reopened.exactStockCount == 66)

local restored_progression = Progression.create(
    Registry.progression,
    progression:export_snapshot()
)
local restored_ledger = ResourceLedger.create(
    restored_progression,
    Registry.economy
)
local restored = DynamicEconomy.create(static, restored_ledger)
local restored_signal = assert(
    restored:commodity_signal(rayne, "CopperIngot")
)
assert(restored_signal.direction == reopened.direction)
assert(restored_signal.exactSellPrice == reopened.exactSellPrice)
assert(restored_signal.exactStockCount == reopened.exactStockCount)
assert(restored:status().marketSignalCount == 63)

print("PASS faction dynamic economy (ledger-driven price, stock, procurement, restore)")
