package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StaticEconomy = require("pwft.faction_economy")
local DynamicEconomy = require("pwft.faction_dynamic_economy")
local ResourceLedger = require("pwft.faction_resource_ledger")
local EconomyWar = require("pwft.faction_economy_war")
local LiveTest = require("pwft.faction_economy_war_live_test")

local faction = "pwft.faction.rayne_syndicate"
local static = StaticEconomy.create(Registry.economy)

local function make_runtime(snapshot, boot_token)
    local progression = Progression.create(
        Registry.progression,
        snapshot
    )
    local ledger = ResourceLedger.create(
        progression,
        Registry.economy
    )
    local economy = DynamicEconomy.create(static, ledger)
    local war = EconomyWar.create(progression, ledger, {
        cooldownTicks = 3,
    })
    local actor = { identity = "same-merchant" }
    local refresh_count = 0
    local merchant = {
        records = {
            [faction] = { actor = actor },
        },
        refresh_dynamic_market = function(self, faction_id)
            assert(faction_id == faction)
            refresh_count = refresh_count + 1
            return {
                ok = true,
                active = true,
                reason = "dynamic-market-native-refreshed",
                resourceLedgerRevision = ledger:status().revision,
            }
        end,
        status = function()
            return {
                activeCount = 1,
                dynamicMarketRefreshCount = refresh_count,
            }
        end,
    }
    local persisted = 0
    local live = LiveTest.create(
        progression,
        ledger,
        economy,
        war,
        merchant,
        {
            runId = "b6-unit-1",
            factionId = faction,
            resourceId = "metal_ore",
            productItemId = "CopperIngot",
            initialQuantity = 150,
            firstReduction = 100,
            secondReduction = 1,
            nativeMerchantRequired = true,
            bootToken = boot_token,
            persist = function()
                persisted = persisted + 1
                return { ok = true }
            end,
        }
    )
    return progression, ledger, economy, war, merchant, live,
        function() return persisted end
end

local progression, ledger, _, war, merchant, live, persisted =
    make_runtime(nil, "boot-a")
assert(live.version == "1.0.0")
assert(live.capabilities.restartPersistenceGate)
assert(live.capabilities.palworldSaveMutation == false)

local limited = live:advance()
assert(limited.ok and limited.reason == "limited-sale-applied")
assert(limited.snapshot.supplyBand == "limited")
assert(limited.snapshot.sellPrice == 280)
assert(limited.snapshot.stock == 25)
assert(limited.nativeRefresh.sameMerchantActor == true)
assert(limited.snapshot.merchantActiveCount == 1)

local requested = live:advance()
assert(requested.ok)
assert(requested.reason == "procurement-and-trade-request-applied")
assert(requested.snapshot.quantity == 49)
assert(requested.snapshot.direction == "procure")
assert(requested.snapshot.procurementPrice == 290)
assert(requested.snapshot.conflictStatus == "trade_requested")
assert(requested.snapshot.supplierFactionId
    == "pwft.faction.pal_genetic_research_unit")

local threat = live:advance()
assert(threat.ok and threat.snapshot.conflictStatus == "threat")
local declared = live:advance()
assert(declared.ok and declared.restartRequired == true)
assert(declared.snapshot.conflictStatus == "war")
assert(live:advance().reason == "game-restart-required")
assert(persisted() == 4)
assert(merchant:status().activeCount == 1)

local restart_snapshot = progression:export_snapshot()
local restarted_progression, restarted_ledger, _, restarted_war,
    restarted_merchant, restarted_live, restarted_persisted =
    make_runtime(restart_snapshot, "boot-b")
local persistence = restarted_live:advance()
assert(persistence.ok)
assert(persistence.reason == "restart-persistence-confirmed")
assert(persistence.snapshot.quantity == 49)
assert(persistence.snapshot.conflictStatus == "war")
assert(persistence.snapshot.persistenceConfirmed == true)

local ceasefire = restarted_live:advance()
assert(ceasefire.ok and ceasefire.snapshot.quantity == 150)
assert(ceasefire.snapshot.direction == "sell")
assert(ceasefire.snapshot.sellPrice == 240)
assert(ceasefire.snapshot.stock == 66)
assert(ceasefire.snapshot.conflictStatus == "ceasefire")
assert(ceasefire.nativeRefresh.sameMerchantActor == true)
local complete = restarted_live:advance()
assert(complete.ok)
assert(complete.reason == "economy-war-live-test-complete")
assert(complete.snapshot.conflictStatus == "stable")
assert(restarted_live:status().phase == "complete")
assert(restarted_live:status().persistenceConfirmed == true)
assert(restarted_merchant:status().activeCount == 1)
assert(restarted_persisted() == 3)

-- Every operation survived restart and remains idempotent.
assert(restarted_ledger:apply_event({
    operationId = "b6-unit-1.limited-sale",
    type = "consumption",
    factionId = faction,
    resourceId = "metal_ore",
    amount = 100,
}).reason == "duplicate-operation")
assert(restarted_war:advance_shortage(
    faction,
    "metal_ore",
    "b6-unit-1.war",
    6
).reason == "duplicate-operation")
assert(restarted_progression.state.factionEconomyWarLiveTest
    .persistenceConfirmed == true)

print("PASS B6 live route (price, stock, procurement, trade, threat, war, restart, ceasefire, no duplicate merchant)")
