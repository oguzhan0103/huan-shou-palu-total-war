package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ResourceLedger = require("pwft.faction_resource_ledger")
local EconomyWar = require("pwft.faction_economy_war")

local rayne = "pwft.faction.rayne_syndicate"
local feybreak = "pwft.faction.feybreak_army"
local oil = "crude_oil"

local notifications = {}
local progression = Progression.create(Registry.progression)
local ledger = ResourceLedger.create(progression, Registry.economy)
local war = EconomyWar.create(progression, ledger, {
    cooldownTicks = 3,
    maxHistory = 3,
    onChange = function(_, event)
        notifications[#notifications + 1] = event.status
    end,
})

assert(war.version == "1.0.0")
assert(war.capabilities.shortageDrivenTransitions)
assert(war.capabilities.automaticCombatMutation == false)
assert(war.capabilities.automaticFactionRelationMutation == false)
assert(war.capabilities.gameObjectMutation == false)
assert(war.capabilities.currencyMutation == false)
assert(war.capabilities.palworldSaveMutation == false)
assert(war:status().conflictCount == 0)
assert(progression.state.factionEconomyWar == war.state)

assert(war:advance_shortage("unknown", oil, "war.bad.faction", 0).reason
    == "unknown-economy-faction")
assert(war:advance_shortage(rayne, "unknown", "war.bad.resource", 0).reason
    == "unknown-economy-resource")
assert(war:advance_shortage(rayne, oil, "", 0).reason
    == "operation-id-required")
assert(war:advance_shortage(rayne, oil, "war.bad.tick", -1).reason
    == "non-negative-logical-tick-required")

-- Rayne starts without oil; the deterministic supplier is the faction with
-- the strongest current oil band, with a stable faction-ID tie breaker.
local requested = war:advance_shortage(rayne, oil, "war.trade.1", 0)
assert(requested.ok and requested.reason == "resource-shortage-trade-requested")
assert(requested.beforeStatus == "stable" and requested.status == "trade_requested")
assert(requested.supplierFactionId == feybreak)
assert(requested.nextTransitionTick == 3)
local duplicate = war:advance_shortage(rayne, oil, "war.trade.1", 0)
assert(duplicate.ok and duplicate.reason == "duplicate-operation")
assert(war:advance_shortage(rayne, oil, "war.trade.1", 1).reason
    == "operation-id-conflict")
assert(war:status().revision == 1)

local cooldown = war:advance_shortage(rayne, oil, "war.cooldown.1", 2)
assert(not cooldown.ok and cooldown.reason == "transition-cooldown-active")
assert(cooldown.remainingTicks == 1)
assert(war:status().operationSignatureCount == 1)

local threat = war:advance_shortage(rayne, oil, "war.threat.1", 3)
assert(threat.ok and threat.status == "threat")
assert(threat.reason == "unresolved-shortage-threat-issued")
local war_declared = war:advance_shortage(rayne, oil, "war.declare.1", 6)
assert(war_declared.ok and war_declared.status == "war")
assert(war_declared.reason == "unresolved-shortage-war-declared")
assert(war:advance_shortage(rayne, oil, "war.still.1", 9).reason
    == "war-already-active")
assert(war:status().counts.war == 1)

-- Resolving the stock shortage produces a ceasefire signal only. It never
-- starts/stops native combat or edits faction relations on its own.
assert(ledger:apply_event({
    operationId = "war.resolve.stock.1",
    type = "import",
    factionId = rayne,
    resourceId = oil,
    amount = 60,
}).ok)
local ceasefire = war:advance_shortage(rayne, oil, "war.ceasefire.1", 7)
assert(ceasefire.ok and ceasefire.status == "ceasefire")
assert(ceasefire.reason == "shortage-resolved-ceasefire")
assert(war:advance_shortage(rayne, oil, "war.ceasefire.cooldown", 9).reason
    == "transition-cooldown-active")
local stable = war:advance_shortage(rayne, oil, "war.stable.1", 10)
assert(stable.ok and stable.status == "stable")
assert(stable.reason == "ceasefire-stabilized")
assert(#war:active_conflicts() == 0)
assert(war:status().historyCount == 3)
assert(war:status().historyDropped == 2)
assert(war:status().operationSignatureCount == 5)
assert(#notifications == 5)

-- A later shortage starts a new cycle only after the old ceasefire has
-- stabilized and the logical cooldown has elapsed.
assert(ledger:apply_event({
    operationId = "war.shortage.again.stock",
    type = "consumption",
    factionId = rayne,
    resourceId = oil,
    amount = 60,
}).ok)
local again = war:advance_shortage(rayne, oil, "war.trade.again", 13)
assert(again.ok and again.status == "trade_requested")
assert(again.supplierFactionId == feybreak)
assert(#war:active_conflicts() == 1)
assert(war:advance_shortage(rayne, oil, "war.tick.regression", 12).reason
    == "logical-tick-regression")

-- Both machines survive a progression restore and rebind in listener order.
local snapshot = progression:export_snapshot()
local stale_ledger_state = ledger.state
local stale_war_state = war.state
local restored = progression:restore_snapshot(snapshot)
assert(restored.ok and restored.reboundListenerCount == 2)
assert(ledger.state == progression.state.factionResourceLedger)
assert(war.state == progression.state.factionEconomyWar)
assert(ledger.state ~= stale_ledger_state and war.state ~= stale_war_state)
assert(war:conflict_status(rayne, oil).status == "trade_requested")

local restored_progression = Progression.create(
    Registry.progression,
    progression:export_snapshot()
)
local restored_ledger = ResourceLedger.create(restored_progression, Registry.economy)
local restored_war = EconomyWar.create(restored_progression, restored_ledger, {
    cooldownTicks = 3,
})
assert(restored_war:conflict_status(rayne, oil).status == "trade_requested")
assert(restored_war:advance_shortage(rayne, oil, "war.trade.again", 13).reason
    == "duplicate-operation")

print("PASS faction economy-war state machine (shortage, trade, threat, war, ceasefire, cooldown, restore)")
