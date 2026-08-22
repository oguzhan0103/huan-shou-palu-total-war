local UniquePalNativeDeliveryLiveTest = {}

local API_VERSION = "1.0.0"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function UniquePalNativeDeliveryLiveTest.create(adapter, options)
    assert(type(adapter) == "table"
            and type(adapter.bind_world) == "function"
            and type(adapter.preflight) == "function"
            and type(adapter.create_individual) == "function"
            and type(adapter.commit_capture) == "function"
            and type(adapter.verify_storage) == "function"
            and type(adapter.rollback) == "function"
            and type(adapter.unbind_world) == "function",
        "native Pal delivery adapter is required")
    options = options or {}
    assert(options.enabled == true,
        "native Pal delivery live test requires explicit enablement")
    assert(type(options.buildId) == "string"
            and options.buildId ~= "",
        "native Pal delivery live-test Build ID is required")
    assert(type(options.speciesId) == "string"
            and options.speciesId ~= "",
        "native Pal delivery live-test species is required")
    assert(type(options.schedule) == "function",
        "native Pal delivery live-test scheduler is required")
    return setmetatable({
        version = API_VERSION,
        adapter = adapter,
        buildId = options.buildId,
        speciesId = options.speciesId,
        schedule = options.schedule,
        logger = options.logger,
        retryDelayMs = options.retryDelayMs or 500,
        maxAttempts = options.maxAttempts or 60,
        worldGeneration = 0,
        sequence = 0,
        active = nil,
        startCount = 0,
        successCount = 0,
        failureCount = 0,
        rollbackCount = 0,
        lastResult = nil,
        lastError = nil,
    }, { __index = UniquePalNativeDeliveryLiveTest })
end

function UniquePalNativeDeliveryLiveTest:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[UniquePalNativeDeliveryLiveTest] " .. tostring(message))
    end
end

function UniquePalNativeDeliveryLiveTest:_finish(
    ok,
    reason,
    extra
)
    local outcome = result(ok, reason, extra)
    self.lastResult = outcome
    self.lastError = ok and nil or reason
    if ok then self.successCount = self.successCount + 1
    else self.failureCount = self.failureCount + 1 end
    local record = self.active
    if record ~= nil then record.running = false end
    self:_log(string.format(
        "RESULT ok=%s reason=%s delivery=%s individual=%s stage=%s attempts=%d generation=%d directContainerMutation=false",
        tostring(ok),
        tostring(reason),
        tostring(record and record.request.deliveryId or "none"),
        tostring(record and record.individualKey or "none"),
        tostring(record and record.stage or "none"),
        tonumber(record and record.attemptCount) or 0,
        self.worldGeneration
    ))
    return outcome
end

function UniquePalNativeDeliveryLiveTest:_schedule()
    local record = self.active
    if record == nil or record.running ~= true then return false end
    local accepted, schedule_error = pcall(
        self.schedule,
        self.retryDelayMs,
        function() return self:_process() end
    )
    if not accepted or schedule_error == false then
        self:_finish(false,
            accepted
                    and "native-pal-delivery-live-test-scheduler-rejected"
                or "native-pal-delivery-live-test-scheduler-error:"
                    .. tostring(schedule_error), {
            retryable = false,
        })
        return false
    end
    return true
end

function UniquePalNativeDeliveryLiveTest:_process()
    local record = self.active
    if record == nil or record.running ~= true then
        return result(false,
            "native-pal-delivery-live-test-not-running", {
            retryable = false,
        })
    end
    if record.request.worldGeneration ~= self.worldGeneration then
        return self:_finish(false,
            "native-pal-delivery-live-test-generation-stale", {
            retryable = false,
        })
    end
    record.attemptCount = record.attemptCount + 1
    if record.attemptCount > self.maxAttempts then
        return self:_finish(false,
            "native-pal-delivery-live-test-attempt-limit", {
            retryable = false,
        })
    end
    if record.stage == "identity-pending" then
        local created = self.adapter:create_individual(
            record.request,
            record.preflight
        )
        if created.ok ~= true then
            record.lastError = created.reason
            if created.retryable == false then
                return self:_finish(false, created.reason, {
                    retryable = false,
                })
            end
            self:_schedule()
            return created
        end
        if created.nativeDeliveryId ~= record.nativeDeliveryId
            or created.individualKey == nil then
            return self:_finish(false,
                "native-pal-delivery-live-test-identity-mismatch", {
                retryable = false,
            })
        end
        record.individualKey = created.individualKey
        record.stage = "created"
        record.lastError = nil
        self:_log(string.format(
            "IDENTITY_READY delivery=%s individual=%s attempt=%d",
            record.request.deliveryId,
            record.individualKey,
            record.attemptCount
        ))
    end
    if record.stage == "created" then
        local captured = self.adapter:commit_capture(
            record.request,
            record.nativeDeliveryId,
            record.individualKey
        )
        if captured.ok ~= true or captured.accepted ~= true then
            record.lastError = captured.reason
            if captured.retryable == false then
                return self:_finish(false, captured.reason, {
                    retryable = false,
                })
            end
            self:_schedule()
            return captured
        end
        record.stage = "captured"
        self:_log(string.format(
            "CAPTURE_ACCEPTED delivery=%s individual=%s attempt=%d",
            record.request.deliveryId,
            record.individualKey,
            record.attemptCount
        ))
    end
    if record.stage == "captured" then
        local verified = self.adapter:verify_storage(
            record.request,
            record.nativeDeliveryId,
            record.individualKey
        )
        if verified.ok ~= true or verified.delivered ~= true then
            record.lastError = verified.reason
            if verified.retryable == false then
                return self:_finish(false, verified.reason, {
                    retryable = false,
                })
            end
            self:_schedule()
            return verified
        end
        if verified.individualKey ~= record.individualKey then
            return self:_finish(false,
                "native-pal-delivery-live-test-individual-mismatch", {
                retryable = false,
            })
        end
        record.stage = "verified"
        return self:_finish(true,
            "native-pal-delivery-live-test-verified", {
            deliveryId = record.request.deliveryId,
            nativeDeliveryId = record.nativeDeliveryId,
            individualKey = record.individualKey,
            speciesId = record.request.speciesId,
            worldGeneration = record.request.worldGeneration,
            exactIndividualIdentity = true,
            directContainerMutation = false,
        })
    end
    return self:_finish(false,
        "native-pal-delivery-live-test-stage-invalid", {
        retryable = false,
    })
end

function UniquePalNativeDeliveryLiveTest:start(world_generation)
    if self.active ~= nil and self.active.running == true then
        return result(false,
            "native-pal-delivery-live-test-already-running", {
            retryable = false,
        })
    end
    assert(type(world_generation) == "number"
            and world_generation >= 1,
        "native Pal delivery live-test generation is required")
    self.worldGeneration = world_generation
    self.adapter:bind_world(world_generation)
    self.sequence = self.sequence + 1
    local request = {
        deliveryId = string.format(
            "qa.native-pal-delivery.g%d.r%d",
            world_generation,
            self.sequence
        ),
        speciesId = self.speciesId,
        buildId = self.buildId,
        worldGeneration = world_generation,
    }
    local preflight = self.adapter:preflight(request)
    if preflight.ok ~= true
        or preflight.capacityAvailable ~= true then
        return self:_finish(false,
            preflight.reason
                or "native-pal-delivery-live-test-preflight-failed", {
            retryable = preflight.retryable ~= false,
            capacityAvailable = preflight.capacityAvailable,
        })
    end
    local created = self.adapter:create_individual(
        request,
        preflight
    )
    local stage = "created"
    if created.ok ~= true
        and (created.retryable == false
            or created.nativeDeliveryId == nil) then
        return self:_finish(false,
            created.reason
                or "native-pal-delivery-live-test-create-failed", {
            retryable = created.retryable ~= false,
        })
    end
    if created.ok ~= true then stage = "identity-pending" end
    self.active = {
        request = request,
        preflight = preflight,
        nativeDeliveryId = created.nativeDeliveryId,
        individualKey = created.individualKey,
        stage = stage,
        attemptCount = 0,
        running = true,
        lastError = nil,
    }
    self.startCount = self.startCount + 1
    self.lastError = nil
    self:_log(string.format(
        "STARTED delivery=%s species=%s individual=%s generation=%d mutation=true",
        request.deliveryId,
        request.speciesId,
        tostring(created.individualKey or "pending"),
        world_generation
    ))
    self:_schedule()
    return result(true,
        "native-pal-delivery-live-test-started", {
        deliveryId = request.deliveryId,
        nativeDeliveryId = created.nativeDeliveryId,
        individualKey = created.individualKey,
        stage = stage,
    })
end

function UniquePalNativeDeliveryLiveTest:unbind_world(reason)
    local record = self.active
    local rollback = nil
    if record ~= nil
        and (record.stage == "identity-pending"
            or record.stage == "created")
        and record.nativeDeliveryId ~= nil then
        rollback = self.adapter:rollback(
            record.request,
            record.nativeDeliveryId,
            record.individualKey,
            reason or "live-test-world-unloading"
        )
        if rollback.ok == true then
            self.rollbackCount = self.rollbackCount + 1
        end
    end
    local unbound = self.adapter:unbind_world(
        reason or "live-test-world-unloading"
    )
    if record ~= nil then record.running = false end
    self.active = nil
    self.worldGeneration = unbound.worldGeneration
        or (self.worldGeneration + 1)
    return result(true,
        "native-pal-delivery-live-test-world-unbound", {
        rollback = rollback,
        adapter = unbound,
        worldGeneration = self.worldGeneration,
    })
end

function UniquePalNativeDeliveryLiveTest:status()
    local record = self.active
    return {
        apiVersion = self.version,
        buildId = self.buildId,
        speciesId = self.speciesId,
        worldGeneration = self.worldGeneration,
        running = record ~= nil and record.running == true,
        stage = record and record.stage or "idle",
        deliveryId = record and record.request.deliveryId or nil,
        nativeDeliveryId = record and record.nativeDeliveryId or nil,
        individualKey = record and record.individualKey or nil,
        attemptCount = record and record.attemptCount or 0,
        startCount = self.startCount,
        successCount = self.successCount,
        failureCount = self.failureCount,
        rollbackCount = self.rollbackCount,
        lastResult = self.lastResult,
        lastError = self.lastError,
        qaOnly = true,
        directContainerMutation = false,
    }
end

return UniquePalNativeDeliveryLiveTest
