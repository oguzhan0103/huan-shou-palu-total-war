package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local BackgroundRaidRecorder = require("pwft.background_raid_recorder")

local active = false
local fail_next_record = false
local events = {}
local ledger = {
    status = function()
        return { active = active }
    end,
    record = function(_, event)
        if fail_next_record then
            fail_next_record = false
            return false, "injected-ledger-failure"
        end
        table.insert(events, event)
        return true, event
    end,
}

local function background_record(generation)
    return {
        schemaVersion = "1.0.0",
        settlementId = "pwft.settlement.small_settlement",
        source = "countdown-complete-player-absent",
        generation = generation,
        resolvedAt = 1722140000 + generation,
        playerPresent = false,
        playerDistance = 80000 + generation,
        outcome = "raid-occurred-offscreen",
        actorSpawns = 0,
        worldCombat = false,
        saveWrites = false,
    }
end

local recorder = BackgroundRaidRecorder.create(ledger, {
    maxPending = 2,
})

local first_ok, first_reason = recorder:record(background_record(1))
assert(first_ok == false)
assert(first_reason == "queued:companion-profile-not-active")
assert(recorder:status().pendingCount == 1)

recorder:record(background_record(2))
recorder:record(background_record(3))
local bounded = recorder:status()
assert(bounded.pendingCount == 2)
assert(bounded.droppedCount == 1)

active = true
local flushed, flushed_count = recorder:flush()
assert(flushed == true)
assert(flushed_count == 2)
assert(#events == 2)
assert(events[1].generation == 2)
assert(events[2].generation == 3)
assert(events[1].type == "settlement-raid-background-resolved")
assert(events[1].schemaVersion == nil)

fail_next_record = true
local failed, failed_reason = recorder:record(background_record(4))
assert(failed == false)
assert(failed_reason == "queued:injected-ledger-failure")
assert(recorder:status().pendingCount == 1)
local retry_ok, retry_count = recorder:flush()
assert(retry_ok == true)
assert(retry_count == 1)
assert(events[3].generation == 4)

local rejected, rejected_reason = recorder:record({
    settlementId = "pwft.settlement.small_settlement",
    source = "unsafe",
    generation = 5,
    resolvedAt = 1722140005,
    playerPresent = false,
    outcome = "raid-occurred-offscreen",
    actorSpawns = 1,
    worldCombat = true,
    saveWrites = false,
})
assert(rejected == false)
assert(rejected_reason == "background-raid-safety-contract-violated")
assert(recorder:status().rejectedCount == 1)
assert(#events == 3)

print("PASS bounded background raid persistence and fail-closed safety contract")
