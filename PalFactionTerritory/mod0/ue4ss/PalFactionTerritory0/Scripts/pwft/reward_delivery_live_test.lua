local RewardDeliveryLiveTest = {}

local API_VERSION = "1.0.0"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function RewardDeliveryLiveTest.create(bus, policy, configuration, options)
    assert(type(bus) == "table"
            and type(bus.register_channel) == "function"
            and type(bus.settle) == "function"
            and type(bus.delivery_status) == "function",
        "reward delivery bus is required")
    assert(type(policy) == "table"
            and type(policy.register_pack) == "function",
        "reward policy is required")
    configuration = configuration or {}
    options = options or {}
    assert(type(configuration.enabled) == "boolean",
        "reward delivery live-test enabled flag is required")
    for _, name in ipairs({
        "key", "operationId", "contentPackId", "policyId",
        "channelId", "providerId", "nativeItemId",
    }) do
        assert(type(configuration[name]) == "string"
                and configuration[name] ~= "",
            "reward delivery live-test " .. name .. " is required")
    end
    assert(type(configuration.units) == "number"
            and configuration.units >= 1
            and configuration.units == math.floor(configuration.units),
        "reward delivery live-test units must be a positive integer")
    return setmetatable({
        version = API_VERSION,
        bus = bus,
        policy = policy,
        enabled = configuration.enabled == true,
        key = configuration.key,
        requireControlModifier =
            configuration.requireControlModifier == true,
        operationId = configuration.operationId,
        contentPackId = configuration.contentPackId,
        policyId = configuration.policyId,
        channelId = configuration.channelId,
        providerId = configuration.providerId,
        nativeItemId = configuration.nativeItemId,
        units = configuration.units,
        logger = options.logger,
        registerKeyBind = options.registerKeyBind or _G.RegisterKeyBind,
        keyTable = options.keyTable or _G.Key,
        modifierKey = options.modifierKey or _G.ModifierKey,
        executeInGameThread = options.executeInGameThread
            or _G.ExecuteInGameThread,
        started = false,
        runCount = 0,
        successCount = 0,
        failureCount = 0,
        lastResult = nil,
        retainedCallbacks = {},
    }, { __index = RewardDeliveryLiveTest })
end

function RewardDeliveryLiveTest:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[RewardDeliveryLiveTest] " .. tostring(message))
    end
end

function RewardDeliveryLiveTest:run()
    if not self.enabled then
        return result(false, "reward-delivery-live-test-disabled")
    end
    self.runCount = self.runCount + 1
    local registered_pack = self.policy:register_pack({
        schemaVersion = "pwft.reward-policy.pack.v1",
        contentPackId = self.contentPackId,
        policies = {
            {
                id = self.policyId,
                sourceKind = "boss",
                difficultyBands = {
                    { minimumScore = 0, multiplierBps = 10000 },
                },
                milestoneEvery = 1,
                milestoneBonusBps = 0,
                rewards = {
                    {
                        channelId = self.channelId,
                        baseUnits = self.units,
                        maximumUnits = self.units,
                    },
                },
            },
        },
    })
    if registered_pack.ok ~= true then
        self.failureCount = self.failureCount + 1
        self.lastResult = registered_pack
        return registered_pack
    end
    local registered_channel = self.bus:register_channel({
        schemaVersion = "pwft.reward-delivery-channel.v1",
        channelId = self.channelId,
        providerId = self.providerId,
        rewardKind = "item",
        nativeItemId = self.nativeItemId,
        maximumUnitsPerDelivery = self.units,
    })
    if registered_channel.ok ~= true then
        self.failureCount = self.failureCount + 1
        self.lastResult = registered_channel
        return registered_channel
    end
    local settled = self.bus:settle({
        schemaVersion = "pwft.reward-settlement.v1",
        authority = "pwft.authoritative-reward-outcome.v1",
        operationId = self.operationId,
        contentPackId = self.contentPackId,
        policyId = self.policyId,
        sourceKind = "boss",
        difficultyScore = 100,
        playerParticipated = true,
        playerSideWon = true,
    })
    local delivery_id = self.operationId .. ":" .. self.channelId
    local delivery = self.bus:delivery_status(delivery_id)
    local passed = settled.ok == true
        and type(delivery) == "table"
        and (delivery.stage == "applied"
            or delivery.stage == "pending"
            or delivery.stage == "dispatching")
    local outcome = result(passed, passed
            and "reward-delivery-live-test-request-processed"
        or (settled.reason or "reward-delivery-live-test-failed"), {
        runCount = self.runCount,
        settlement = settled,
        deliveryId = delivery_id,
        deliveryStage = delivery and delivery.stage or "missing",
        nativeItemId = self.nativeItemId,
        units = self.units,
        beforeCount = delivery and delivery.beforeCount or nil,
        afterCount = delivery and delivery.afterCount or nil,
        dispatchAttemptCount = delivery
            and delivery.dispatchAttemptCount or 0,
        idempotent = settled.policyOutcome
                and settled.policyOutcome.reason
                    == "duplicate-reward-settlement"
            or false,
    })
    self.lastResult = outcome
    if passed then self.successCount = self.successCount + 1
    else self.failureCount = self.failureCount + 1 end
    self:_log(string.format(
        "RESULT ok=%s reason=%s run=%d delivery=%s stage=%s item=%s units=%d before=%s after=%s dispatches=%s idempotent=%s restorationRequired=true",
        tostring(outcome.ok == true),
        tostring(outcome.reason),
        self.runCount,
        delivery_id,
        tostring(outcome.deliveryStage),
        self.nativeItemId,
        self.units,
        tostring(outcome.beforeCount),
        tostring(outcome.afterCount),
        tostring(outcome.dispatchAttemptCount),
        tostring(outcome.idempotent == true)
    ))
    return outcome
end

function RewardDeliveryLiveTest:start()
    if not self.enabled then
        return result(true, "reward-delivery-live-test-disabled")
    end
    if self.started then
        return result(true, "reward-delivery-live-test-already-started")
    end
    if type(self.registerKeyBind) ~= "function"
        or type(self.keyTable) ~= "table"
        or self.keyTable[self.key] == nil then
        return result(false, "reward-delivery-live-test-key-api-unavailable")
    end
    if self.requireControlModifier
        and (type(self.modifierKey) ~= "table"
            or self.modifierKey.CONTROL == nil) then
        return result(false,
            "reward-delivery-live-test-modifier-api-unavailable")
    end
    local callback = function()
        local execute = function() self:run() end
        if type(self.executeInGameThread) == "function" then
            self.executeInGameThread(execute)
        else
            execute()
        end
    end
    self.retainedCallbacks.key = callback
    local called, registration = pcall(function()
        if self.requireControlModifier then
            return self.registerKeyBind(
                self.keyTable[self.key],
                { self.modifierKey.CONTROL },
                callback
            )
        end
        return self.registerKeyBind(self.keyTable[self.key], callback)
    end)
    if not called or registration == false then
        return result(false, "reward-delivery-live-test-key-bind-failed", {
            error = called and tostring(registration) or tostring(registration),
        })
    end
    self.started = true
    self:_log(string.format(
        "READY key=%s%s item=%s units=%d operation=%s repeatSameKeyTestsIdempotency=true restorationRequired=true",
        self.requireControlModifier and "Ctrl+" or "",
        self.key,
        self.nativeItemId,
        self.units,
        self.operationId
    ))
    return result(true, "reward-delivery-live-test-started")
end

function RewardDeliveryLiveTest:status()
    return {
        version = self.version,
        enabled = self.enabled,
        started = self.started,
        key = (self.requireControlModifier and "Ctrl+" or "") .. self.key,
        operationId = self.operationId,
        nativeItemId = self.nativeItemId,
        units = self.units,
        runCount = self.runCount,
        successCount = self.successCount,
        failureCount = self.failureCount,
        lastResult = self.lastResult,
    }
end

return RewardDeliveryLiveTest
