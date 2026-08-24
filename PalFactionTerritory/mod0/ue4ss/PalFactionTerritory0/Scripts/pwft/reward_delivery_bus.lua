local RewardDeliveryBus = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local CHANNEL_SCHEMA = "pwft.reward-delivery-channel.v1"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "", name .. " is required")
    return value
end

local function stable_id(value, name)
    require_text(value, name)
    assert(string.match(value, "^[a-z0-9][a-z0-9_.:-]+$") ~= nil,
        name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil,
        name .. " cannot contain an empty namespace segment")
    return value
end

local function positive_integer(value, name)
    assert(type(value) == "number" and value > 0
            and value == math.floor(value),
        name .. " must be a positive integer")
    return value
end

local function make_state()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        operationSignatures = {},
        deliveriesById = {},
    }
end

local function ensure_state(instance)
    local root = instance.progression.state
    if type(root.rewardDelivery) ~= "table" then
        root.rewardDelivery = make_state()
    end
    local state = root.rewardDelivery
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported reward-delivery snapshot schema")
    state.revision = state.revision or 0
    state.operationSignatures = state.operationSignatures or {}
    state.deliveriesById = state.deliveriesById or {}
    return state
end

local function count_keys(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
end

local function intent_signature(outcome)
    local parts = {
        tostring(outcome.operationId),
        tostring(outcome.policyId),
        tostring(outcome.sourceKind),
        tostring(outcome.eligible == true),
    }
    local intents = copy(outcome.rewardIntents or {})
    table.sort(intents, function(first, second)
        return tostring(first.channelId) < tostring(second.channelId)
    end)
    for _, intent in ipairs(intents) do
        parts[#parts + 1] = tostring(intent.channelId)
        parts[#parts + 1] = tostring(intent.units)
    end
    return table.concat(parts, "|")
end

local function provider_signature(definition)
    return table.concat({
        definition.providerId,
        definition.authoritySource,
        definition.rewardKind,
        definition.buildId,
        definition.routeKey,
    }, "|")
end

local function channel_signature(channel)
    return table.concat({
        channel.channelId,
        channel.providerId,
        channel.rewardKind,
        channel.nativeItemId,
        tostring(channel.maximumUnitsPerDelivery),
    }, "|")
end

local function delivery_signature(operation_id, intent)
    return table.concat({
        operation_id,
        intent.channelId,
        tostring(intent.units),
    }, "|")
end

local function notify(instance, event)
    instance.state.revision = instance.state.revision + 1
    event = event or {}
    event.revision = instance.state.revision
    if instance.onChange ~= nil then
        local called, response = pcall(instance.onChange, nil, copy(event))
        if not called then instance.lastNotificationError = tostring(response) end
    end
end

local function adapter_call(provider, method, ...)
    local callback = provider.adapter[method]
    local called, response = pcall(callback, provider.adapter, ...)
    if not called then
        return result(false, "reward-native-adapter-error", {
            stage = method,
            adapterError = tostring(response),
            retryable = true,
        })
    end
    if type(response) ~= "table" then
        return result(false, "reward-native-adapter-invalid-result", {
            stage = method,
            retryable = true,
        })
    end
    return response
end

function RewardDeliveryBus.create(progression, reward_policy, options)
    assert(type(progression) == "table" and type(progression.state) == "table",
        "progression state root is required")
    assert(type(reward_policy) == "table"
            and type(reward_policy.operation_status) == "function",
        "reward policy with operation replay is required")
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "reward delivery onChange must be a function")
    assert(options.persistFence == nil
            or type(options.persistFence) == "function",
        "reward delivery persistence fence must be a function")
    assert(options.identityResolver == nil
            or type(options.identityResolver) == "function",
        "reward delivery identity resolver must be a function")
    assert(options.schedule == nil or type(options.schedule) == "function",
        "reward delivery scheduler must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        rewardPolicy = reward_policy,
        onChange = options.onChange,
        persistFence = options.persistFence,
        requirePersistenceFence = options.requirePersistenceFence ~= false,
        identityResolver = options.identityResolver,
        schedule = options.schedule,
        retryDelayMs = options.retryDelayMs or 500,
        maxVerifyAttempts = options.maxVerifyAttempts or 60,
        providersById = {},
        channelsById = {},
        scheduledByDeliveryId = {},
        retainedCallbacks = {},
        worldGeneration = nil,
        acceptedCount = 0,
        appliedCount = 0,
        rejectedCount = 0,
        reconciliationRequiredCount = 0,
        persistenceFenceFailureCount = 0,
        lastNotificationError = nil,
        lastError = nil,
        capabilities = {
            persistedIntentReplay = true,
            writeAheadDeliveryLedger = true,
            exactNativeReadbackRequired = true,
            deterministicDeliveryIdentity = true,
            partialChannelRecovery = true,
            modelAuthority = false,
            currencyMutation = false,
            directSavePayloadMutation = false,
            atMostOnceAfterDispatchFence = true,
            automaticRedispatchAfterAmbiguity = false,
        },
    }, { __index = RewardDeliveryBus })
    instance.state = ensure_state(instance)
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.reward-delivery.v1",
            function() return instance:rebind_progression_state() end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function RewardDeliveryBus:rebind_progression_state()
    local rebound, state_or_error = pcall(ensure_state, self)
    if not rebound then
        return result(false, "reward-delivery-snapshot-invalid", {
            error = tostring(state_or_error),
        })
    end
    self.state = state_or_error
    for _, record in pairs(self.state.deliveriesById) do
        if record.stage == "dispatching" then
            record.stage = "reconciliation-required"
            record.lastError = "reward-delivery-restored-after-dispatch"
        end
    end
    return result(true, "reward-delivery-state-rebound")
end

function RewardDeliveryBus:register_provider(definition, adapter)
    local valid, normalized = pcall(function()
        assert(type(definition) == "table", "reward provider definition is required")
        assert(type(adapter) == "table", "reward provider adapter is required")
        for _, method in ipairs({
            "status", "bind_world", "unbind_world", "preflight",
            "dispatch", "verify",
        }) do
            assert(type(adapter[method]) == "function",
                "reward provider adapter missing " .. method)
        end
        assert(definition.currentBuildVerified == true,
            "reward provider is not verified for the current Build")
        assert(definition.serverAuthoritativeGrant == true,
            "reward provider is not server authoritative")
        assert(definition.exactInventoryReadback == true,
            "reward provider lacks exact inventory readback")
        assert(definition.stablePlayerIdentity == true,
            "reward provider lacks stable player identity")
        assert(definition.modelAuthority == false,
            "model authority must remain disabled")
        local reward_kind = require_text(definition.rewardKind,
            "reward provider kind")
        assert(reward_kind == "item",
            "only the verified item reward route is supported")
        local value = {
            providerId = stable_id(definition.providerId,
                "reward provider ID"),
            authoritySource = stable_id(definition.authoritySource,
                "reward provider authority"),
            rewardKind = reward_kind,
            buildId = require_text(definition.buildId,
                "reward provider Build ID"),
            routeKey = require_text(definition.routeKey,
                "reward provider route key"),
            adapter = adapter,
        }
        local status = adapter:status()
        assert(type(status) == "table"
                and status.buildId == value.buildId,
            "reward adapter Build ID mismatch")
        local capabilities = status.capabilities or {}
        assert(capabilities.stablePlayerIdentity == true
                and capabilities.serverAuthoritativeGrant == true
                and capabilities.exactInventoryReadback == true
                and capabilities.directCurrencyMutation == false
                and capabilities.directSavePayloadMutation == false,
            "reward adapter capabilities do not meet the production contract")
        value.signature = provider_signature(value)
        return value
    end)
    if not valid then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = tostring(normalized)
        return result(false, "invalid-reward-delivery-provider", {
            validationError = self.lastError,
        })
    end
    local existing = self.providersById[normalized.providerId]
    if existing ~= nil and existing.signature ~= normalized.signature then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-delivery-provider-conflict")
    end
    self.providersById[normalized.providerId] = normalized
    if self.worldGeneration ~= nil then
        local bound = adapter_call(normalized, "bind_world",
            self.worldGeneration)
        if bound.ok ~= true then
            self.providersById[normalized.providerId] = existing
            self.rejectedCount = self.rejectedCount + 1
            return result(false, bound.reason or "reward-provider-world-bind-failed")
        end
    end
    return result(true, existing and "reward-delivery-provider-rebound"
        or "reward-delivery-provider-registered", {
        providerId = normalized.providerId,
    })
end

function RewardDeliveryBus:register_channel(definition)
    local valid, channel = pcall(function()
        assert(type(definition) == "table"
                and definition.schemaVersion == CHANNEL_SCHEMA,
            "unsupported reward-delivery channel schema")
        local provider_id = stable_id(definition.providerId,
            "reward channel provider ID")
        local provider = self.providersById[provider_id]
        assert(provider ~= nil, "reward channel provider is unavailable")
        assert(definition.rewardKind == provider.rewardKind,
            "reward channel/provider kind mismatch")
        local value = {
            schemaVersion = CHANNEL_SCHEMA,
            channelId = stable_id(definition.channelId,
                "reward channel ID"),
            providerId = provider_id,
            rewardKind = provider.rewardKind,
            nativeItemId = require_text(definition.nativeItemId,
                "native reward item ID"),
            maximumUnitsPerDelivery = positive_integer(
                definition.maximumUnitsPerDelivery,
                "reward channel maximum units"),
        }
        assert(#value.nativeItemId <= 128,
            "native reward item ID is too long")
        value.signature = channel_signature(value)
        return value
    end)
    if not valid then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = tostring(channel)
        return result(false, "invalid-reward-delivery-channel", {
            validationError = self.lastError,
        })
    end
    local existing = self.channelsById[channel.channelId]
    if existing ~= nil and existing.signature ~= channel.signature then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-delivery-channel-conflict")
    end
    self.channelsById[channel.channelId] = channel
    return result(true, existing and "reward-delivery-channel-rebound"
        or "reward-delivery-channel-registered", {
        channelId = channel.channelId,
        providerId = channel.providerId,
    })
end

function RewardDeliveryBus:_persist_fence(event)
    if self.persistFence == nil then
        if self.requirePersistenceFence then
            self.persistenceFenceFailureCount =
                self.persistenceFenceFailureCount + 1
            return result(false, "reward-delivery-persistence-fence-unavailable")
        end
        return result(true, "reward-delivery-persistence-fence-not-required")
    end
    local called, response = pcall(
        self.persistFence,
        self.progression:export_snapshot(),
        copy(event or {})
    )
    local accepted = called and (response == true
        or (type(response) == "table" and response.ok == true))
    if not accepted then
        self.persistenceFenceFailureCount =
            self.persistenceFenceFailureCount + 1
        self.lastError = called and (type(response) == "table"
                and response.reason or tostring(response))
            or tostring(response)
        return result(false, "reward-delivery-persistence-fence-failed", {
            persistenceError = self.lastError,
        })
    end
    return result(true, "reward-delivery-persistence-confirmed")
end

function RewardDeliveryBus:accept_operation(operation_id, options)
    options = options or {}
    local outcome = self.rewardPolicy:operation_status(operation_id)
    if type(outcome) ~= "table" or outcome.ok ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-operation-unavailable")
    end
    local signature = intent_signature(outcome)
    local previous = self.state.operationSignatures[operation_id]
    if previous ~= nil and previous.signature ~= signature then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-delivery-operation-conflict")
    end
    local delivery_ids, created = {}, 0
    if previous == nil then
        self.state.operationSignatures[operation_id] = { signature = signature }
        for _, intent in ipairs(outcome.rewardIntents or {}) do
            local channel_id = stable_id(intent.channelId,
                "reward intent channel ID")
            local units = positive_integer(intent.units, "reward intent units")
            local delivery_id = operation_id .. ":" .. channel_id
            local record = {
                deliveryId = delivery_id,
                operationId = operation_id,
                policyId = outcome.policyId,
                sourceKind = outcome.sourceKind,
                channelId = channel_id,
                units = units,
                signature = delivery_signature(operation_id, intent),
                stage = "pending",
                dispatchAttemptCount = 0,
                verifyAttemptCount = 0,
            }
            self.state.deliveriesById[delivery_id] = record
            delivery_ids[#delivery_ids + 1] = delivery_id
            created = created + 1
        end
        notify(self, {
            type = "reward-deliveries-accepted",
            operationId = operation_id,
            deliveryCount = created,
        })
        self.acceptedCount = self.acceptedCount + created
    else
        for delivery_id, record in pairs(self.state.deliveriesById) do
            if record.operationId == operation_id then
                delivery_ids[#delivery_ids + 1] = delivery_id
            end
        end
    end
    table.sort(delivery_ids)
    local processed = {}
    if options.dispatch ~= false then
        for _, delivery_id in ipairs(delivery_ids) do
            processed[#processed + 1] = self:process_pending(delivery_id)
        end
    end
    return result(true, previous and "reward-delivery-operation-replayed"
        or (#delivery_ids > 0 and "reward-delivery-operation-accepted"
            or "reward-delivery-operation-has-no-intents"), {
        operationId = operation_id,
        deliveryIds = delivery_ids,
        createdDeliveryCount = created,
        processed = processed,
        idempotent = previous ~= nil,
    })
end

-- Public one-shot entry point for authoritative gameplay outcomes.  Policy
-- calculation and native delivery stay separate internally so either ledger
-- can recover after a restart, while callers cannot accidentally forget the
-- delivery phase after a successful settlement.
function RewardDeliveryBus:settle(input, options)
    local policy_outcome = self.rewardPolicy:settle(input)
    if type(policy_outcome) ~= "table" or policy_outcome.ok ~= true then
        return result(false, type(policy_outcome) == "table"
                and policy_outcome.reason
            or "reward-policy-settlement-invalid", {
            policyOutcome = copy(policy_outcome),
            deliveryAccepted = false,
        })
    end
    local delivery = self:accept_operation(input.operationId, options)
    return result(delivery.ok == true, delivery.ok == true
            and "reward-settlement-and-delivery-accepted"
        or delivery.reason, {
        operationId = input.operationId,
        policyOutcome = copy(policy_outcome),
        delivery = copy(delivery),
        deliveryAccepted = delivery.ok == true,
    })
end

function RewardDeliveryBus:_identity()
    if self.identityResolver == nil then
        return nil, "reward-delivery-identity-resolver-unavailable"
    end
    local called, identity = pcall(self.identityResolver)
    if not called or type(identity) ~= "table"
        or type(identity.playerUid) ~= "string"
        or identity.playerUid == "" then
        return nil, "reward-delivery-player-identity-unavailable"
    end
    return copy(identity), nil
end

function RewardDeliveryBus:_schedule_verify(record)
    if self.schedule == nil or self.scheduledByDeliveryId[record.deliveryId]
        or record.verifyAttemptCount >= self.maxVerifyAttempts then
        return false
    end
    local delivery_id = record.deliveryId
    local generation = record.worldGeneration
    self.scheduledByDeliveryId[delivery_id] = true
    local callback = function()
        self.scheduledByDeliveryId[delivery_id] = nil
        local current = self.state.deliveriesById[delivery_id]
        if current ~= nil and current.stage == "dispatching"
            and current.worldGeneration == generation
            and self.worldGeneration == generation then
            self:verify_delivery(delivery_id)
        end
    end
    self.retainedCallbacks[#self.retainedCallbacks + 1] = callback
    local called, accepted = pcall(self.schedule, self.retryDelayMs, callback)
    if not called or accepted == false then
        self.scheduledByDeliveryId[delivery_id] = nil
        return false
    end
    return true
end

function RewardDeliveryBus:_apply_confirmation(record, confirmation)
    local valid = type(confirmation) == "table"
        and confirmation.ok == true
        and confirmation.applied == true
        and confirmation.deliveryId == record.deliveryId
        and confirmation.attemptId == record.attemptId
        and confirmation.playerUid == record.playerUid
        and confirmation.nativeItemId == record.nativeItemId
        and confirmation.buildId == record.buildId
        and confirmation.worldGeneration == record.worldGeneration
        and confirmation.beforeCount == record.beforeCount
        and confirmation.afterCount == record.expectedCount
    if not valid then
        record.stage = "reconciliation-required"
        record.lastError = "reward-delivery-confirmation-mismatch"
        self.reconciliationRequiredCount =
            self.reconciliationRequiredCount + 1
        notify(self, {
            type = "reward-delivery-reconciliation-required",
            deliveryId = record.deliveryId,
            reason = record.lastError,
        })
        return result(false, record.lastError, {
            deliveryId = record.deliveryId,
            automaticRedispatch = false,
        })
    end
    record.stage = "applied"
    record.afterCount = confirmation.afterCount
    record.nativeResult = tostring(confirmation.nativeResult or "confirmed")
    record.lastError = nil
    notify(self, {
        type = "reward-delivery-applied",
        deliveryId = record.deliveryId,
        operationId = record.operationId,
        channelId = record.channelId,
        units = record.units,
    })
    local persisted = self:_persist_fence({
        type = "reward-delivery-applied",
        deliveryId = record.deliveryId,
    })
    if not persisted.ok then
        record.stage = "reconciliation-required"
        record.lastError = persisted.reason
        self.reconciliationRequiredCount =
            self.reconciliationRequiredCount + 1
        return result(false, persisted.reason, {
            deliveryId = record.deliveryId,
            nativeMutationConfirmed = true,
            automaticRedispatch = false,
        })
    end
    self.appliedCount = self.appliedCount + 1
    return result(true, "reward-delivery-applied", {
        deliveryId = record.deliveryId,
        operationId = record.operationId,
        channelId = record.channelId,
        units = record.units,
        nativeItemId = record.nativeItemId,
        beforeCount = record.beforeCount,
        afterCount = record.afterCount,
    })
end

function RewardDeliveryBus:process_pending(delivery_id)
    local record = self.state.deliveriesById[delivery_id]
    if record == nil then return result(false, "reward-delivery-not-found") end
    if record.stage == "applied" then
        return result(true, "reward-delivery-already-applied", {
            deliveryId = delivery_id,
            idempotent = true,
        })
    end
    if record.stage ~= "pending" then
        return result(false, record.stage == "reconciliation-required"
            and "reward-delivery-reconciliation-required"
            or "reward-delivery-already-dispatched", {
            deliveryId = delivery_id,
            automaticRedispatch = false,
        })
    end
    if self.worldGeneration == nil then
        return result(false, "reward-delivery-world-not-bound", {
            deliveryId = delivery_id,
            retryable = true,
        })
    end
    local channel = self.channelsById[record.channelId]
    if channel == nil then
        return result(false, "reward-delivery-channel-unbound", {
            deliveryId = delivery_id,
            retryable = true,
        })
    end
    if record.units > channel.maximumUnitsPerDelivery then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-delivery-channel-cap-exceeded", {
            deliveryId = delivery_id,
        })
    end
    local provider = self.providersById[channel.providerId]
    if provider == nil then
        return result(false, "reward-delivery-provider-unbound", {
            deliveryId = delivery_id,
            retryable = true,
        })
    end
    local identity, identity_error = self:_identity()
    if identity == nil then
        return result(false, identity_error, {
            deliveryId = delivery_id,
            retryable = true,
        })
    end
    local attempt_number = record.dispatchAttemptCount + 1
    local request = {
        deliveryId = delivery_id,
        attemptId = delivery_id .. ":attempt:" .. tostring(attempt_number),
        operationId = record.operationId,
        channelId = record.channelId,
        units = record.units,
        rewardKind = channel.rewardKind,
        nativeItemId = channel.nativeItemId,
        providerId = provider.providerId,
        authoritySource = provider.authoritySource,
        buildId = provider.buildId,
        routeKey = provider.routeKey,
        playerUid = identity.playerUid,
        profileKey = identity.profileKey,
        worldGeneration = self.worldGeneration,
    }
    local preflight = adapter_call(provider, "preflight", copy(request))
    if preflight.ok ~= true then
        return result(false, preflight.reason or "reward-delivery-preflight-failed", {
            deliveryId = delivery_id,
            retryable = preflight.retryable ~= false,
        })
    end
    assert(type(preflight.beforeCount) == "number"
            and preflight.beforeCount >= 0
            and preflight.beforeCount == math.floor(preflight.beforeCount),
        "reward adapter returned an invalid inventory baseline")
    record.dispatchAttemptCount = attempt_number
    record.attemptId = request.attemptId
    record.providerId = provider.providerId
    record.authoritySource = provider.authoritySource
    record.rewardKind = channel.rewardKind
    record.nativeItemId = channel.nativeItemId
    record.buildId = provider.buildId
    record.routeKey = provider.routeKey
    record.playerUid = identity.playerUid
    record.profileKey = identity.profileKey
    record.worldGeneration = self.worldGeneration
    record.beforeCount = preflight.beforeCount
    record.expectedCount = preflight.beforeCount + record.units
    record.nativeRoute = preflight.nativeRoute
    record.inventoryKey = preflight.inventoryKey
    record.stage = "dispatching"
    notify(self, {
        type = "reward-delivery-dispatch-fenced",
        deliveryId = delivery_id,
        attemptId = record.attemptId,
    })
    local fenced = self:_persist_fence({
        type = "reward-delivery-before-native-mutation",
        deliveryId = delivery_id,
        attemptId = record.attemptId,
    })
    if not fenced.ok then
        record.stage = "pending"
        record.lastError = fenced.reason
        notify(self, {
            type = "reward-delivery-dispatch-fence-reverted",
            deliveryId = delivery_id,
        })
        return result(false, fenced.reason, {
            deliveryId = delivery_id,
            nativeMutationStarted = false,
            retryable = true,
        })
    end
    local dispatched = adapter_call(provider, "dispatch",
        copy(request), copy(preflight))
    if dispatched.ok == true and dispatched.applied == true then
        return self:_apply_confirmation(record, dispatched)
    end
    if dispatched.ok == true and dispatched.accepted == true then
        self:_schedule_verify(record)
        return result(true, "reward-delivery-native-request-accepted", {
            deliveryId = delivery_id,
            attemptId = record.attemptId,
            nativeRoute = record.nativeRoute,
            awaitingConfirmation = true,
        })
    end
    if dispatched.mutationStarted == true then
        record.stage = "reconciliation-required"
        record.lastError = dispatched.reason
            or "reward-delivery-native-result-ambiguous"
        self.reconciliationRequiredCount =
            self.reconciliationRequiredCount + 1
        notify(self, {
            type = "reward-delivery-reconciliation-required",
            deliveryId = delivery_id,
            reason = record.lastError,
        })
        return result(false, record.lastError, {
            deliveryId = delivery_id,
            automaticRedispatch = false,
        })
    end
    record.stage = "pending"
    record.lastError = dispatched.reason or "reward-delivery-native-request-failed"
    notify(self, {
        type = "reward-delivery-dispatch-rejected",
        deliveryId = delivery_id,
        reason = record.lastError,
    })
    return result(false, record.lastError, {
        deliveryId = delivery_id,
        retryable = dispatched.retryable ~= false,
        nativeMutationStarted = false,
    })
end

function RewardDeliveryBus:verify_delivery(delivery_id)
    local record = self.state.deliveriesById[delivery_id]
    if record == nil then return result(false, "reward-delivery-not-found") end
    if record.stage == "applied" then
        return result(true, "reward-delivery-already-applied", {
            deliveryId = delivery_id,
            idempotent = true,
        })
    end
    if record.stage ~= "dispatching"
        and record.stage ~= "reconciliation-required" then
        return result(false, "reward-delivery-not-awaiting-confirmation")
    end
    local provider = self.providersById[record.providerId]
    if provider == nil then
        return result(false, "reward-delivery-provider-unbound", {
            retryable = true,
        })
    end
    record.verifyAttemptCount = (record.verifyAttemptCount or 0) + 1
    local verified = adapter_call(provider, "verify", copy(record))
    if verified.ok == true and verified.applied == true then
        return self:_apply_confirmation(record, verified)
    end
    if verified.pending == true and record.stage == "dispatching"
        and record.verifyAttemptCount < self.maxVerifyAttempts then
        self:_schedule_verify(record)
        return result(false, "reward-delivery-confirmation-pending", {
            deliveryId = delivery_id,
            retryable = true,
            verifyAttemptCount = record.verifyAttemptCount,
        })
    end
    record.stage = "reconciliation-required"
    record.lastError = verified.reason
        or "reward-delivery-confirmation-ambiguous"
    self.reconciliationRequiredCount =
        self.reconciliationRequiredCount + 1
    notify(self, {
        type = "reward-delivery-reconciliation-required",
        deliveryId = delivery_id,
        reason = record.lastError,
    })
    return result(false, record.lastError, {
        deliveryId = delivery_id,
        automaticRedispatch = false,
    })
end

function RewardDeliveryBus:reconcile_delivery(delivery_id)
    local record = self.state.deliveriesById[delivery_id]
    if record == nil then return result(false, "reward-delivery-not-found") end
    if record.stage == "pending" then
        return self:process_pending(delivery_id)
    end
    return self:verify_delivery(delivery_id)
end

function RewardDeliveryBus:bind_world(generation)
    assert(type(generation) == "number" and generation >= 1
            and generation == math.floor(generation),
        "reward delivery world generation must be a positive integer")
    self.worldGeneration = generation
    local failures = {}
    for provider_id, provider in pairs(self.providersById) do
        local bound = adapter_call(provider, "bind_world", generation)
        if bound.ok ~= true then failures[#failures + 1] = provider_id end
    end
    return result(#failures == 0, #failures == 0
        and "reward-delivery-world-bound"
        or "reward-delivery-world-bind-partial", {
        worldGeneration = generation,
        failedProviderIds = failures,
    })
end

function RewardDeliveryBus:unbind_world(reason)
    local previous = self.worldGeneration
    self.worldGeneration = nil
    self.scheduledByDeliveryId = {}
    local fenced = 0
    for _, record in pairs(self.state.deliveriesById) do
        if record.stage == "dispatching" then
            record.stage = "reconciliation-required"
            record.lastError = "reward-delivery-world-unloaded-during-dispatch"
            fenced = fenced + 1
        end
    end
    for _, provider in pairs(self.providersById) do
        adapter_call(provider, "unbind_world", reason or "world-unloading")
    end
    if fenced > 0 then
        notify(self, {
            type = "reward-delivery-world-unbound",
            reconciliationRequiredCount = fenced,
        })
    end
    return result(true, "reward-delivery-world-unbound", {
        previousWorldGeneration = previous,
        reconciliationRequiredCount = fenced,
    })
end

function RewardDeliveryBus:delivery_status(delivery_id)
    return copy(self.state.deliveriesById[delivery_id])
end

function RewardDeliveryBus:status()
    local stages = {
        pending = 0,
        dispatching = 0,
        applied = 0,
        ["reconciliation-required"] = 0,
    }
    for _, record in pairs(self.state.deliveriesById) do
        stages[record.stage] = (stages[record.stage] or 0) + 1
    end
    return {
        version = self.version,
        schemaVersion = self.state.schemaVersion,
        revision = self.state.revision,
        worldGeneration = self.worldGeneration,
        providerCount = count_keys(self.providersById),
        channelCount = count_keys(self.channelsById),
        operationCount = count_keys(self.state.operationSignatures),
        deliveryCount = count_keys(self.state.deliveriesById),
        stages = stages,
        acceptedCount = self.acceptedCount,
        appliedCount = self.appliedCount,
        rejectedCount = self.rejectedCount,
        reconciliationRequiredCount = self.reconciliationRequiredCount,
        persistenceFenceFailureCount = self.persistenceFenceFailureCount,
        lastNotificationError = self.lastNotificationError,
        lastError = self.lastError,
        capabilities = copy(self.capabilities),
    }
end

function RewardDeliveryBus:export_snapshot()
    return copy(self.state)
end

return RewardDeliveryBus
