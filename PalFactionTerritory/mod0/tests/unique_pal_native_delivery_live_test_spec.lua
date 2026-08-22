package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local LiveTest =
    require("pwft.unique_pal_native_delivery_live_test")

local generation = 8
local queued = {}
local calls = {
    bind = 0,
    preflight = 0,
    create = 0,
    capture = 0,
    verify = 0,
    rollback = 0,
    unbind = 0,
}
local adapter = {}
function adapter:bind_world(value)
    calls.bind = calls.bind + 1
    assert(value == generation)
    return { ok = true }
end
function adapter:preflight(request)
    calls.preflight = calls.preflight + 1
    assert(request.speciesId == "Anubis")
    assert(request.buildId == "24575825")
    assert(request.worldGeneration == generation)
    return { ok = true, capacityAvailable = true }
end
function adapter:create_individual(request)
    calls.create = calls.create + 1
    return {
        ok = true,
        nativeDeliveryId = "native." .. request.deliveryId,
        individualKey = "pal-AAA-BBB",
    }
end
function adapter:commit_capture()
    calls.capture = calls.capture + 1
    if calls.capture == 1 then
        return {
            ok = false,
            reason = "actor-not-ready",
            retryable = true,
        }
    end
    return { ok = true, accepted = true }
end
function adapter:verify_storage()
    calls.verify = calls.verify + 1
    if calls.verify == 1 then
        return {
            ok = false,
            delivered = false,
            reason = "storage-pending",
            retryable = true,
        }
    end
    return {
        ok = true,
        delivered = true,
        individualKey = "pal-AAA-BBB",
    }
end
function adapter:rollback()
    calls.rollback = calls.rollback + 1
    return { ok = true, rolledBack = true }
end
function adapter:unbind_world()
    calls.unbind = calls.unbind + 1
    return {
        ok = true,
        worldGeneration = generation + 1,
    }
end

local messages = {}
local live = LiveTest.create(adapter, {
    enabled = true,
    buildId = "24575825",
    speciesId = "Anubis",
    retryDelayMs = 25,
    maxAttempts = 6,
    schedule = function(delay_ms, callback)
        assert(delay_ms == 25)
        table.insert(queued, callback)
        return true
    end,
    logger = function(message)
        table.insert(messages, message)
    end,
})

local started = live:start(generation)
assert(started.ok)
assert(calls.bind == 1 and calls.preflight == 1 and calls.create == 1)
assert(#queued == 1)
assert(live:start(generation).reason
    == "native-pal-delivery-live-test-already-running")

-- Actor pending, then capture accepted with storage pending, then exact
-- readback succeeds. No phase can recreate or recapture the individual.
table.remove(queued, 1)()
assert(calls.capture == 1 and calls.verify == 0)
assert(#queued == 1)
table.remove(queued, 1)()
assert(calls.capture == 2 and calls.verify == 1)
assert(#queued == 1)
table.remove(queued, 1)()
assert(calls.capture == 2 and calls.verify == 2)
assert(calls.create == 1)
assert(#queued == 0)
local status = live:status()
assert(status.running == false)
assert(status.stage == "verified")
assert(status.successCount == 1 and status.failureCount == 0)
assert(status.lastResult.exactIndividualIdentity == true)
assert(status.lastResult.directContainerMutation == false)
assert(string.find(messages[#messages],
    "RESULT ok=true", 1, true) ~= nil)

local unbound = live:unbind_world("spec-complete")
assert(unbound.ok and calls.unbind == 1)
assert(calls.rollback == 0)
assert(live:status().stage == "idle")

-- World unload before capture rolls back the exact created individual.
queued = {}
calls.capture = 0
calls.verify = 0
local pending = LiveTest.create(adapter, {
    enabled = true,
    buildId = "24575825",
    speciesId = "Anubis",
    schedule = function(_, callback)
        table.insert(queued, callback)
        return true
    end,
})
assert(pending:start(generation).ok)
assert(pending:status().stage == "created")
local pending_unbind = pending:unbind_world("spec-pending-unload")
assert(pending_unbind.ok)
assert(calls.rollback == 1)
assert(calls.unbind == 2)
-- A stale callback retained by UE4SS must become inert after unbind.
local stale = table.remove(queued, 1)()
assert(stale.ok == false)
assert(stale.reason == "native-pal-delivery-live-test-not-running")

-- Full storage fails before creation, and the harness honestly reports it.
local full_adapter = {}
for _, method_name in ipairs({
    "bind_world",
    "create_individual",
    "commit_capture",
    "verify_storage",
    "rollback",
    "unbind_world",
}) do
    full_adapter[method_name] = adapter[method_name]
end
function full_adapter:preflight()
    return {
        ok = true,
        reason = "native-pal-storage-full",
        capacityAvailable = false,
        retryable = true,
    }
end
local full = LiveTest.create(full_adapter, {
    enabled = true,
    buildId = "24575825",
    speciesId = "Anubis",
    schedule = function() error("full storage must not schedule") end,
})
local full_result = full:start(generation)
assert(full_result.ok == false)
assert(full_result.reason == "native-pal-storage-full")
assert(full:status().failureCount == 1)

print("PASS unique-Pal native delivery live-test harness requires explicit QA enablement, retries actor/capture/readback without duplication, proves exact identity, rolls back only pre-capture work, and fails closed on full storage")
