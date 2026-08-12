package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ResourceLedger = require("pwft.faction_resource_ledger")

local rayne = "pwft.faction.rayne_syndicate"
local feybreak = "pwft.faction.feybreak_army"
local metal = "metal_ore"
local oil = "crude_oil"

local notifications = {}
local progression = Progression.create(Registry.progression)
local ledger = ResourceLedger.create(progression, Registry.economy, {
    maxHistory = 3,
    onChange = function(faction_id, event)
        notifications[#notifications + 1] = faction_id .. ":" .. event.type
    end,
})

local status = ledger:status()
assert(status.apiVersion == "1.0.0")
assert(status.factionCount == 7 and status.resourceCount == 8)
assert(status.eventCount == 0 and status.historyCount == 0)
assert(ledger.capabilities.modOwnedProgressionSnapshot)
assert(ledger.capabilities.gameObjectMutation == false)
assert(ledger.capabilities.currencyMutation == false)
assert(ledger.capabilities.palworldSaveMutation == false)
assert(progression.state.factionResourceLedger == ledger.state)

-- The audited seven-faction/eight-resource baseline is converted to explicit
-- Mod-owned quantities without pretending to be a Palworld inventory.
local rayne_metal = ledger:resource_status(rayne, metal)
assert(rayne_metal.quantity == 150)
assert(rayne_metal.initialSupplyBand == "established")
assert(rayne_metal.supplyBand == "established")
local rayne_oil = ledger:resource_status(rayne, oil)
assert(rayne_oil.quantity == 0 and rayne_oil.supplyBand == "absent")
assert(ledger:resource_status("unknown", oil) == nil)

local sell = ledger:market_signal(rayne, metal)
assert(sell.direction == "sell" and sell.supplyBand == "established")
assert(sell.priceMultiplier == 1.0)
assert(sell.exactStockCount > 0 and sell.exactProcurementQuota == nil)
local procure = ledger:market_signal(rayne, oil)
assert(procure.direction == "procure" and procure.supplyBand == "absent")
assert(procure.priceMultiplier == 1.4)
assert(procure.exactProcurementQuota > 0
    and procure.exactProcurementQuota <= 50
    and procure.exactStockCount == nil)

local revision = ledger:status().revision
assert(ledger:apply_event(nil).reason == "event-table-required")
assert(ledger:apply_event({
    operationId = "bad.extra",
    type = "production",
    factionId = rayne,
    resourceId = oil,
    amount = 1,
    note = "not allowed",
}).reason == "event-field-not-allowed")
assert(ledger:apply_event({
    operationId = "bad.type",
    type = "gift",
    factionId = rayne,
    resourceId = oil,
    amount = 1,
}).reason == "unsupported-resource-event")
assert(ledger:apply_event({
    operationId = "bad.amount",
    type = "production",
    factionId = rayne,
    resourceId = oil,
    amount = 0,
}).reason == "positive-integer-amount-required")
assert(ledger:apply_event({
    operationId = "bad.direction",
    type = "trade",
    factionId = rayne,
    resourceId = oil,
    amount = 1,
}).reason == "trade-direction-required")
assert(ledger:apply_event({
    operationId = "bad.nontrade-direction",
    type = "import",
    factionId = rayne,
    resourceId = oil,
    amount = 1,
    direction = "inbound",
}).reason == "direction-only-allowed-for-trade")
assert(ledger:apply_event({
    operationId = "bad.stock",
    type = "loss",
    factionId = rayne,
    resourceId = oil,
    amount = 1,
}).reason == "insufficient-resource-stock")
assert(ledger:status().revision == revision)

-- Every allowed event changes only this ledger and keeps exact counters.
local production = ledger:apply_event({
    operationId = "ledger.production.1",
    type = "production",
    factionId = rayne,
    resourceId = oil,
    amount = 10,
})
assert(production.ok and production.after == 10 and production.supplyBand == "scarce")
local duplicate = ledger:apply_event({
    operationId = "ledger.production.1",
    type = "production",
    factionId = rayne,
    resourceId = oil,
    amount = 10,
})
assert(duplicate.ok and duplicate.reason == "duplicate-operation")
assert(ledger:resource_status(rayne, oil).quantity == 10)
assert(ledger:apply_event({
    operationId = "ledger.production.1",
    type = "production",
    factionId = rayne,
    resourceId = oil,
    amount = 11,
}).reason == "operation-id-conflict")

assert(ledger:apply_event({
    operationId = "ledger.consumption.1", type = "consumption",
    factionId = rayne, resourceId = oil, amount = 2,
}).ok)
assert(ledger:apply_event({
    operationId = "ledger.trade.in.1", type = "trade", direction = "inbound",
    factionId = rayne, resourceId = oil, amount = 20,
}).ok)
assert(ledger:apply_event({
    operationId = "ledger.trade.out.1", type = "trade", direction = "outbound",
    factionId = rayne, resourceId = oil, amount = 3,
}).ok)
assert(ledger:apply_event({
    operationId = "ledger.import.1", type = "import",
    factionId = rayne, resourceId = oil, amount = 30,
}).ok)
assert(ledger:apply_event({
    operationId = "ledger.loss.1", type = "loss",
    factionId = rayne, resourceId = oil, amount = 4,
}).ok)

local after = ledger:resource_status(rayne, oil)
assert(after.quantity == 51 and after.supplyBand == "limited")
assert(after.production == 10 and after.consumption == 2)
assert(after.tradeInbound == 20 and after.tradeOutbound == 3)
assert(after.imports == 30 and after.losses == 4)
local new_sell = ledger:market_signal(rayne, oil)
assert(new_sell.direction == "sell" and new_sell.exactStockCount <= after.quantity)
assert(ledger:status().historyCount == 3)
assert(ledger:status().historyDropped == 3)
assert(ledger:status().operationSignatureCount == 6)
assert(#notifications == 6)

-- Operation signatures remain in the snapshot even after display history is
-- trimmed, so old operations cannot silently apply twice.
local old_duplicate = ledger:apply_event({
    operationId = "ledger.production.1",
    type = "production",
    factionId = rayne,
    resourceId = oil,
    amount = 10,
})
assert(old_duplicate.reason == "duplicate-operation")
assert(ledger:resource_status(rayne, oil).quantity == 51)

-- Restore listeners rebind the module to the progression's new root rather
-- than continuing to mutate a stale Lua table.
local snapshot = progression:export_snapshot()
assert(ledger:apply_event({
    operationId = "ledger.after.snapshot", type = "import",
    factionId = feybreak, resourceId = oil, amount = 7,
}).ok)
local stale_state = ledger.state
local restored = progression:restore_snapshot(snapshot)
assert(restored.ok and restored.reboundListenerCount == 1)
assert(ledger.state == progression.state.factionResourceLedger)
assert(ledger.state ~= stale_state)
assert(ledger:resource_status(feybreak, oil).quantity == 500)

local restored_progression = Progression.create(
    Registry.progression,
    progression:export_snapshot()
)
local restored_ledger = ResourceLedger.create(restored_progression, Registry.economy)
assert(restored_ledger:resource_status(rayne, oil).quantity == 51)
assert(restored_ledger:apply_event({
    operationId = "ledger.production.1", type = "production",
    factionId = rayne, resourceId = oil, amount = 10,
}).reason == "duplicate-operation")

print("PASS faction resource ledger (7 factions, 8 resources, strict idempotent events, deterministic signals, restore)")
