local UniquePalNativeDeliveryBridge = {}

local API_VERSION = "1.0.0"

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
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function require_true(value, name)
    assert(value == true, name .. " must be explicitly verified")
    return true
end

local function stable_id(value, name)
    require_text(value, name)
    assert(string.match(value, "^[%w][%w%._:%-]+$") ~= nil,
        name .. " contains unsupported characters")
    return value
end

local function log(instance, message)
    if instance.logger ~= nil then
        pcall(instance.logger, "[UniquePalNativeDelivery] " .. message)
    end
end

local function normalize_species_map(value)
    assert(type(value) == "table",
        "unique-Pal native delivery species map is required")
    local output, count = {}, 0
    for unique_pal_id, species_id in pairs(value) do
        output[stable_id(unique_pal_id, "unique Pal ID")] =
            stable_id(species_id, "native Pal species ID")
        count = count + 1
    end
    assert(count > 0,
        "unique-Pal native delivery species map cannot be empty")
    return output
end

local function binding_signature(binding)
    local species = {}
    for unique_pal_id, species_id in pairs(binding.speciesByUniquePalId) do
        species[#species + 1] = unique_pal_id .. "=" .. species_id
    end
    table.sort(species)
    return table.concat({
        binding.bindingId,
        binding.targetBindingId,
        binding.providerId,
        binding.authoritySource,
        binding.buildId,
        binding.palDeliveryKey,
        tostring(binding.worldGeneration),
        table.concat(species, ","),
    }, "|")
end

local function delivery_signature(payload, context, binding)
    return table.concat({
        payload.deliveryId,
        payload.targetKey,
        payload.uniquePalId,
        payload.speciesId,
        payload.playerId,
        tostring(payload.worldGeneration),
        context.providerId,
        context.bindingId,
        context.buildId,
        binding.bindingId,
        binding.palDeliveryKey,
    }, "|")
end

local function adapter_call(binding, method, ...)
    local callback = binding.adapter[method]
    local called, response = pcall(callback, binding.adapter, ...)
    if not called then
        return false, result(false,
            "native-pal-delivery-adapter-error", {
                stage = method,
                adapterError = tostring(response),
                retryable = true,
            })
    end
    if type(response) ~= "table" then
        return false, result(false,
            "native-pal-delivery-adapter-invalid-result", {
                stage = method,
                retryable = true,
            })
    end
    return true, response
end

function UniquePalNativeDeliveryBridge.create(world_effect_bus, options)
    assert(type(world_effect_bus) == "table"
            and type(world_effect_bus.status) == "function"
            and type(world_effect_bus.provider_status) == "function"
            and type(world_effect_bus.delivery_status) == "function"
            and type(world_effect_bus.confirm_pal_delivery) == "function",
        "unique-Pal world-effect bus with delivery callback API is required")
    options = options or {}
    assert(options.schedule == nil or type(options.schedule) == "function",
        "native Pal delivery scheduler must be a function")
    return setmetatable({
        version = API_VERSION,
        worldEffectBus = world_effect_bus,
        logger = options.logger,
        schedule = options.schedule,
        retryDelayMs = options.retryDelayMs or 250,
        maxAutomaticAttempts = options.maxAutomaticAttempts or 30,
        bindingsByTargetBindingId = {},
        recordsByDeliveryId = {},
        acceptedDeliveryCount = 0,
        confirmedDeliveryCount = 0,
        rejectedDeliveryCount = 0,
        verificationPendingCount = 0,
        rollbackCount = 0,
        worldUnbindCount = 0,
        retainedScheduledCallbacks = {},
        lastError = nil,
    }, { __index = UniquePalNativeDeliveryBridge })
end

function UniquePalNativeDeliveryBridge:register_binding(
    definition,
    adapter
)
    local called, normalized = pcall(function()
        assert(type(definition) == "table",
            "native Pal delivery binding is required")
        assert(type(adapter) == "table",
            "native Pal delivery adapter is required")
        for _, method in ipairs({
            "preflight", "create_individual", "commit_capture",
            "verify_storage", "rollback",
        }) do
            assert(type(adapter[method]) == "function",
                "native Pal delivery adapter missing " .. method)
        end
        local bus_status = self.worldEffectBus:status()
        local provider_id = stable_id(definition.providerId,
            "native Pal delivery provider ID")
        local provider = self.worldEffectBus:provider_status(provider_id)
        assert(provider ~= nil and provider.enabled == true
                and provider.deliveryKinds["pal-delivery"] == true,
            "active pal-delivery provider is required")
        assert(definition.worldGeneration == bus_status.worldGeneration,
            "native Pal delivery binding generation is stale")
        assert(definition.buildId == definition.verifiedBuildId,
            "native Pal delivery route is not verified for the target build")
        require_true(definition.currentBuildVerified,
            "current-build native Pal delivery signature")
        require_true(definition.serverAuthoritativeSpawn,
            "server-authoritative Pal creation")
        require_true(definition.serverAuthoritativeCapture,
            "server-authoritative Pal capture")
        require_true(definition.capacityPreflight,
            "Pal storage capacity preflight")
        require_true(definition.storageVerification,
            "post-capture Pal storage verification")
        require_true(definition.stableIndividualIdentity,
            "stable native individual identity")
        local binding = {
            bindingId = stable_id(definition.bindingId,
                "native Pal delivery binding ID"),
            targetBindingId = stable_id(definition.targetBindingId,
                "world-effect target binding ID"),
            providerId = provider_id,
            authoritySource = require_text(provider.authoritySource,
                "native Pal delivery authority"),
            buildId = require_text(definition.buildId,
                "native Pal delivery build ID"),
            palDeliveryKey = require_text(definition.palDeliveryKey,
                "native Pal delivery route key"),
            speciesByUniquePalId = normalize_species_map(
                definition.speciesByUniquePalId),
            worldGeneration = bus_status.worldGeneration,
            adapter = adapter,
        }
        binding.signature = binding_signature(binding)
        return binding
    end)
    if not called then
        self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
        self.lastError = tostring(normalized)
        return result(false, "invalid-native-pal-delivery-binding", {
            validationError = self.lastError,
        })
    end
    local existing = self.bindingsByTargetBindingId[
        normalized.targetBindingId]
    if existing ~= nil and existing.signature ~= normalized.signature then
        self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
        self.lastError = "native-pal-delivery-binding-conflict"
        return result(false, "native-pal-delivery-binding-conflict")
    end
    self.bindingsByTargetBindingId[normalized.targetBindingId] = normalized
    self.lastError = nil
    return result(true,
        existing and "native-pal-delivery-binding-rebound"
            or "native-pal-delivery-binding-registered", {
            bindingId = normalized.bindingId,
            targetBindingId = normalized.targetBindingId,
        })
end

function UniquePalNativeDeliveryBridge:_schedule(record, delay_ms)
    if self.schedule == nil or record.scheduled == true
        or record.stage == "applied"
        or record.processAttemptCount >= self.maxAutomaticAttempts then
        return false
    end
    record.scheduled = true
    local callback = function()
        record.scheduled = false
        self:process_pending(record.deliveryId)
    end
    -- Retain every one-shot callback on the long-lived bridge.  Records are
    -- cleared on world unload while UE4SS may still own a delayed callback;
    -- dropping the last Lua reference can invalidate the global EngineTick.
    table.insert(self.retainedScheduledCallbacks, callback)
    local scheduled, accepted = pcall(
        self.schedule,
        delay_ms or self.retryDelayMs,
        callback
    )
    if not scheduled or accepted == false then
        record.scheduled = false
        record.lastError = scheduled
                and "native-pal-delivery-scheduler-rejected"
            or "native-pal-delivery-scheduler-error:"
                .. tostring(accepted)
        return false
    end
    return true
end

function UniquePalNativeDeliveryBridge:handle_delivery(payload, context)
    local called, validated = pcall(function()
        assert(type(payload) == "table"
                and payload.deliveryKind == "pal-delivery",
            "pal-delivery payload is required")
        assert(type(context) == "table",
            "pal-delivery provider context is required")
        local bus_status = self.worldEffectBus:status()
        assert(payload.worldGeneration == bus_status.worldGeneration
                and context.worldGeneration == bus_status.worldGeneration,
            "native Pal delivery generation is stale")
        local binding = self.bindingsByTargetBindingId[context.bindingId]
        assert(binding ~= nil
                and binding.worldGeneration == bus_status.worldGeneration,
            "verified native Pal delivery binding is unavailable")
        assert(context.providerId == binding.providerId
                and context.buildId == binding.buildId
                and payload.buildId == binding.buildId,
            "native Pal delivery provider or build mismatch")
        assert(type(payload.nativeRoutes) == "table"
                and payload.nativeRoutes.palDeliveryKey
                    == binding.palDeliveryKey,
            "native Pal delivery route mismatch")
        local unique_pal_id = stable_id(payload.uniquePalId,
            "unique Pal delivery ID")
        local species_id = stable_id(payload.speciesId,
            "native Pal delivery species ID")
        assert(binding.speciesByUniquePalId[unique_pal_id]
                == species_id,
            "native Pal delivery species is not whitelisted")
        local core_delivery = self.worldEffectBus:delivery_status(
            payload.deliveryId)
        assert(core_delivery ~= nil
                and core_delivery.deliveryKind == "pal-delivery",
            "Core pal-delivery record is unavailable")
        return {
            binding = binding,
            signature = delivery_signature(payload, context, binding),
            request = {
                deliveryId = require_text(payload.deliveryId,
                    "Core Pal delivery ID"),
                targetKey = require_text(payload.targetKey,
                    "Pal delivery target key"),
                uniquePalId = unique_pal_id,
                speciesId = species_id,
                playerId = require_text(payload.playerId,
                    "Pal delivery player ID"),
                providerId = binding.providerId,
                authoritySource = binding.authoritySource,
                bindingId = context.bindingId,
                nativeBindingId = binding.bindingId,
                buildId = binding.buildId,
                palDeliveryKey = binding.palDeliveryKey,
                worldGeneration = bus_status.worldGeneration,
            },
        }
    end)
    if not called then
        self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
        self.lastError = tostring(validated)
        return result(false, "invalid-native-pal-delivery-request", {
            deliveryId = type(payload) == "table"
                    and payload.deliveryId or nil,
            validationError = self.lastError,
        })
    end

    local request = validated.request
    local existing = self.recordsByDeliveryId[request.deliveryId]
    if existing ~= nil then
        if existing.signature ~= validated.signature then
            self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
            return result(false, "native-pal-delivery-id-conflict")
        end
        self:_schedule(existing, 0)
        return result(true, "native-pal-delivery-already-accepted", {
            deliveryId = request.deliveryId,
            accepted = true,
            requestId = existing.nativeDeliveryId,
            individualKey = existing.individualKey,
            idempotent = true,
        })
    end

    local binding = validated.binding
    local ok_preflight, preflight = adapter_call(
        binding, "preflight", copy(request))
    if not ok_preflight or preflight.ok ~= true then
        self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
        self.lastError = preflight.reason
        return result(false, preflight.reason
            or "native-pal-delivery-preflight-failed", {
                deliveryId = request.deliveryId,
                retryable = preflight.retryable ~= false,
            })
    end
    if preflight.existingDelivered ~= true
        and preflight.capacityAvailable ~= true then
        self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
        self.lastError = "native-pal-storage-capacity-unavailable"
        return result(false, "native-pal-storage-capacity-unavailable", {
            deliveryId = request.deliveryId,
            retryable = true,
        })
    end

    local native_delivery_id, individual_key, stage
    if preflight.existingDelivered == true then
        local valid_identity, identity_or_error = pcall(function()
            return {
                nativeDeliveryId = stable_id(preflight.nativeDeliveryId,
                    "existing native Pal delivery ID"),
                individualKey = stable_id(preflight.individualKey,
                    "existing native Pal individual key"),
            }
        end)
        if not valid_identity then
            self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
            self.lastError = tostring(identity_or_error)
            return result(false,
                "existing-native-pal-delivery-identity-invalid", {
                    deliveryId = request.deliveryId,
                    validationError = self.lastError,
                    retryable = false,
                })
        end
        native_delivery_id = identity_or_error.nativeDeliveryId
        individual_key = identity_or_error.individualKey
        stage = "verified"
    else
        local ok_create, created = adapter_call(
            binding,
            "create_individual",
            copy(request),
            preflight
        )
        if not ok_create or created.ok ~= true then
            self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
            self.lastError = created.reason
            return result(false, created.reason
                or "native-pal-individual-create-failed", {
                    deliveryId = request.deliveryId,
                    retryable = created.retryable ~= false,
                })
        end
        local valid_identity, identity_or_error = pcall(function()
            return {
                nativeDeliveryId = stable_id(created.nativeDeliveryId,
                    "native Pal delivery ID"),
                individualKey = stable_id(created.individualKey,
                    "native Pal individual key"),
            }
        end)
        if not valid_identity then
            local rollback_called, rollback_result = adapter_call(
                binding,
                "rollback",
                copy(request),
                created.nativeDeliveryId,
                created.individualKey,
                "invalid-created-individual-identity"
            )
            if rollback_called and rollback_result.ok == true then
                self.rollbackCount = self.rollbackCount + 1
            end
            self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
            self.lastError = tostring(identity_or_error)
            return result(false,
                "native-pal-individual-identity-invalid", {
                    deliveryId = request.deliveryId,
                    validationError = self.lastError,
                    retryable = false,
                })
        end
        native_delivery_id = identity_or_error.nativeDeliveryId
        individual_key = identity_or_error.individualKey
        stage = "created"
    end
    local record = {
        deliveryId = request.deliveryId,
        signature = validated.signature,
        request = request,
        targetBindingId = request.bindingId,
        nativeDeliveryId = native_delivery_id,
        individualKey = individual_key,
        stage = stage,
        processAttemptCount = 0,
        scheduled = false,
        lastError = nil,
    }
    self.recordsByDeliveryId[request.deliveryId] = record
    self.acceptedDeliveryCount = self.acceptedDeliveryCount + 1
    self.lastError = nil
    self:_schedule(record, 0)
    log(self, string.format(
        "DELIVERY_ACCEPTED delivery=%s pal=%s species=%s individual=%s stage=%s generation=%d",
        request.deliveryId,
        request.uniquePalId,
        request.speciesId,
        individual_key,
        stage,
        request.worldGeneration
    ))
    return result(true, "native-pal-delivery-accepted", {
        deliveryId = request.deliveryId,
        accepted = true,
        requestId = native_delivery_id,
        individualKey = individual_key,
    })
end

function UniquePalNativeDeliveryBridge:process_pending(delivery_id)
    local record = self.recordsByDeliveryId[delivery_id]
    if record == nil then
        return result(false, "unknown-native-pal-delivery")
    end
    if record.stage == "applied" then
        return result(true, "native-pal-delivery-already-confirmed", {
            deliveryId = delivery_id,
            individualKey = record.individualKey,
            idempotent = true,
        })
    end
    record.processAttemptCount = record.processAttemptCount + 1
    local binding = self.bindingsByTargetBindingId[record.targetBindingId]
    local bus_status = self.worldEffectBus:status()
    if binding == nil
        or binding.worldGeneration ~= bus_status.worldGeneration
        or record.request.worldGeneration ~= bus_status.worldGeneration then
        record.lastError = "native-pal-delivery-generation-unavailable"
        return result(false, record.lastError, { retryable = false })
    end
    local core_delivery = self.worldEffectBus:delivery_status(delivery_id)
    if core_delivery == nil
        or core_delivery.status ~= "awaiting-confirmation"
        or core_delivery.providerRequestId ~= record.nativeDeliveryId
        or core_delivery.providerIndividualKey ~= record.individualKey then
        record.lastError = "Core-native-pal-delivery-not-awaiting-exact-request"
        self:_schedule(record, self.retryDelayMs)
        return result(false, record.lastError, { retryable = true })
    end

    if record.stage == "created" then
        local ok_commit, committed = adapter_call(
            binding,
            "commit_capture",
            copy(record.request),
            record.nativeDeliveryId,
            record.individualKey
        )
        if not ok_commit or committed.ok ~= true
            or committed.accepted ~= true then
            record.lastError = committed.reason
                or "native-pal-capture-not-accepted"
            local retryable = committed.retryable ~= false
            if retryable then self:_schedule(record, self.retryDelayMs) end
            return result(false, record.lastError, {
                retryable = retryable,
            })
        end
        record.stage = "committed"
    end

    if record.stage == "committed" then
        local ok_verify, verified = adapter_call(
            binding,
            "verify_storage",
            copy(record.request),
            record.nativeDeliveryId,
            record.individualKey
        )
        if not ok_verify or verified.ok ~= true
            or verified.delivered ~= true then
            record.lastError = verified.reason
                or "native-pal-storage-verification-pending"
            self.verificationPendingCount =
                self.verificationPendingCount + 1
            local retryable = verified.retryable ~= false
            if retryable then self:_schedule(record, self.retryDelayMs) end
            return result(false, record.lastError, {
                retryable = retryable,
            })
        end
        if verified.individualKey ~= record.individualKey then
            record.lastError = "native-pal-storage-individual-mismatch"
            self.rejectedDeliveryCount = self.rejectedDeliveryCount + 1
            return result(false, record.lastError, { retryable = false })
        end
        record.stage = "verified"
    end

    local callback = {
        callbackId = "pwft.native-pal-delivery." .. delivery_id,
        providerId = record.request.providerId,
        authoritySource = record.request.authoritySource,
        bindingId = record.request.bindingId,
        worldGeneration = record.request.worldGeneration,
        deliveryId = delivery_id,
        nativeDeliveryId = record.nativeDeliveryId,
        nativeIndividualKey = record.individualKey,
        palDeliveryKey = record.request.palDeliveryKey,
        uniquePalId = record.request.uniquePalId,
        speciesId = record.request.speciesId,
        playerId = record.request.playerId,
    }
    local response = self.worldEffectBus:confirm_pal_delivery(callback)
    if response.ok ~= true then
        record.lastError = response.reason
        self:_schedule(record, self.retryDelayMs)
        return response
    end
    record.stage = "applied"
    record.lastError = nil
    self.confirmedDeliveryCount = self.confirmedDeliveryCount + 1
    self.lastError = nil
    log(self, string.format(
        "DELIVERY_CONFIRMED delivery=%s pal=%s species=%s individual=%s attempts=%d",
        delivery_id,
        record.request.uniquePalId,
        record.request.speciesId,
        record.individualKey,
        record.processAttemptCount
    ))
    return response
end

function UniquePalNativeDeliveryBridge:unbind_world(reason)
    local record_count, binding_count = 0, 0
    for _, record in pairs(self.recordsByDeliveryId) do
        record_count = record_count + 1
        if record.stage == "created" then
            local binding = self.bindingsByTargetBindingId[
                record.targetBindingId]
            if binding ~= nil then
                local called, rolled_back = adapter_call(
                    binding,
                    "rollback",
                    copy(record.request),
                    record.nativeDeliveryId,
                    record.individualKey,
                    reason or "world-unloading"
                )
                if called and rolled_back.ok == true then
                    self.rollbackCount = self.rollbackCount + 1
                end
            end
        end
    end
    for _ in pairs(self.bindingsByTargetBindingId) do
        binding_count = binding_count + 1
    end
    self.recordsByDeliveryId = {}
    self.bindingsByTargetBindingId = {}
    self.worldUnbindCount = self.worldUnbindCount + 1
    self.lastError = reason or "world-unloading"
    return result(true, "native-pal-delivery-world-unbound", {
        clearedRecordCount = record_count,
        clearedBindingCount = binding_count,
    })
end

function UniquePalNativeDeliveryBridge:status()
    local binding_count, pending, applied = 0, 0, 0
    for _ in pairs(self.bindingsByTargetBindingId) do
        binding_count = binding_count + 1
    end
    for _, record in pairs(self.recordsByDeliveryId) do
        if record.stage == "applied" then applied = applied + 1
        else pending = pending + 1 end
    end
    return {
        apiVersion = self.version,
        bindingCount = binding_count,
        pendingDeliveryCount = pending,
        appliedDeliveryCount = applied,
        acceptedDeliveryCount = self.acceptedDeliveryCount,
        confirmedDeliveryCount = self.confirmedDeliveryCount,
        rejectedDeliveryCount = self.rejectedDeliveryCount,
        verificationPendingCount = self.verificationPendingCount,
        rollbackCount = self.rollbackCount,
        worldUnbindCount = self.worldUnbindCount,
        lastError = self.lastError,
        route = "verified-server-spawn-capture-storage-readback",
        currentNativeBindings = binding_count,
        directContainerMutation = false,
        debugCaptureApiAllowed = false,
        PalworldSaveMutation = false,
        exactIndividualIdentityRequired = true,
    }
end

return UniquePalNativeDeliveryBridge
