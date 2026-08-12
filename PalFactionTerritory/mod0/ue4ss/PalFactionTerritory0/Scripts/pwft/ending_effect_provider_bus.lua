local EndingEffectProviderBus = {}

local API_VERSION = "1.0.0"
local SNAPSHOT_SCHEMA_VERSION = "1.0.0"

local OUTPUT_KINDS = {
    set_title = true,
    set_world_disposition = true,
    set_faction_disposition = true,
    city_transition = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[copy(key)] = copy(item) end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function require_serializable(value, path, seen)
    local kind = type(value)
    if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then
        return
    end
    assert(kind == "table", path .. " contains a non-serializable value")
    seen = seen or {}
    assert(seen[value] == nil, path .. " contains a cycle")
    seen[value] = true
    for key, item in pairs(value) do
        local key_kind = type(key)
        assert(key_kind == "string" or key_kind == "number", path .. " contains an invalid key")
        require_serializable(item, path .. "." .. tostring(key), seen)
    end
    seen[value] = nil
end

local function normalize_provider(definition)
    assert(type(definition) == "table", "ending provider definition is required")
    assert(definition.idempotentDeliveryIds == true,
        "ending provider must guarantee idempotent delivery IDs")
    assert(definition.readOnlyInput == true,
        "ending provider input must be read-only")
    assert(type(definition.effectKinds) == "table" and #definition.effectKinds > 0,
        "ending provider effect kinds are required")
    local effect_kinds = {}
    for _, effect_kind in ipairs(definition.effectKinds) do
        require_text(effect_kind, "ending provider effect kind")
        assert(OUTPUT_KINDS[effect_kind] == true, "ending provider effect kind is not whitelisted")
        assert(effect_kinds[effect_kind] == nil, "duplicate ending provider effect kind")
        effect_kinds[effect_kind] = true
    end
    return {
        providerId = require_text(definition.providerId, "ending provider ID"),
        effectKinds = effect_kinds,
        idempotentDeliveryIds = true,
        readOnlyInput = true,
        enabled = definition.enabled ~= false,
    }
end

local function provider_equal(first, second)
    if first.enabled ~= second.enabled then return false end
    for effect_kind in pairs(first.effectKinds) do
        if second.effectKinds[effect_kind] ~= true then return false end
    end
    for effect_kind in pairs(second.effectKinds) do
        if first.effectKinds[effect_kind] ~= true then return false end
    end
    return true
end

local function normalize_output(effect, index, scope_id)
    assert(type(effect) == "table", "ending effect must be a table")
    if not OUTPUT_KINDS[effect.kind] then return nil end
    local output = {
        schemaVersion = "1.0.0",
        deliveryId = scope_id .. ":effect:" .. tostring(index),
        effectIndex = index,
        kind = effect.kind,
        readOnly = true,
        PalworldSaveMutation = false,
    }
    if effect.kind == "set_title" then
        output.titleKey = require_text(effect.titleKey, "ending title key")
    elseif effect.kind == "set_world_disposition" then
        output.value = require_text(effect.value, "ending world disposition")
    elseif effect.kind == "set_faction_disposition" then
        output.factionId = require_text(effect.factionId, "ending faction ID")
        output.value = require_text(effect.value, "ending faction disposition")
    elseif effect.kind == "city_transition" then
        output.cityId = require_text(effect.cityId, "ending city ID")
        output.status = require_text(effect.status, "ending city status")
        output.ownerFactionId = effect.ownerFactionId
    end
    return output
end

local function make_scope(scope_id, route_id, operation_id, effects, scope_kind)
    local scope = {
        scopeId = scope_id,
        scopeKind = scope_kind,
        routeId = route_id,
        operationId = operation_id,
        outputs = {},
        deliveryById = {},
        completed = false,
        attemptCount = 0,
    }
    for index, effect in ipairs(effects or {}) do
        local output = normalize_output(effect, index, scope_id)
        if output ~= nil then
            scope.outputs[#scope.outputs + 1] = output
            scope.deliveryById[output.deliveryId] = {
                deliveryId = output.deliveryId,
                applied = false,
                attemptCount = 0,
                lastError = nil,
            }
        end
    end
    return scope
end

local function delivery_status(instance, scope)
    local applied = 0
    local pending = 0
    local failures = {}
    for _, output in ipairs(scope.outputs) do
        local delivery = scope.deliveryById[output.deliveryId]
        if delivery.applied then
            applied = applied + 1
        else
            pending = pending + 1
            if delivery.lastError ~= nil then
                failures[#failures + 1] = {
                    deliveryId = output.deliveryId,
                    providerId = instance.providerByEffectKind[output.kind],
                    error = delivery.lastError,
                }
            end
        end
    end
    return applied, pending, failures
end

local function apply_scope(instance, scope)
    scope.attemptCount = scope.attemptCount + 1
    for _, output in ipairs(scope.outputs) do
        local delivery = scope.deliveryById[output.deliveryId]
        if not delivery.applied then
            local provider_id = instance.providerByEffectKind[output.kind]
            local provider = provider_id and instance.providers[provider_id] or nil
            local handler = provider_id and instance.handlers[provider_id] or nil
            delivery.attemptCount = delivery.attemptCount + 1
            if provider == nil or provider.enabled ~= true or type(handler) ~= "function" then
                delivery.lastError = "ending-effect-provider-unavailable"
            else
                local called, response = pcall(handler, copy(output), {
                    scopeId = scope.scopeId,
                    scopeKind = scope.scopeKind,
                    routeId = scope.routeId,
                    operationId = scope.operationId,
                    readOnly = true,
                })
                if not called then
                    delivery.lastError = "provider-error:" .. tostring(response)
                elseif type(response) ~= "table"
                    or response.ok ~= true
                    or response.applied ~= true
                    or response.deliveryId ~= output.deliveryId then
                    delivery.lastError = type(response) == "table"
                            and tostring(response.reason or "provider-did-not-confirm-application")
                        or "provider-returned-invalid-result"
                else
                    delivery.applied = true
                    delivery.lastError = nil
                    delivery.providerReason = response.reason
                end
            end
        end
    end
    local applied, pending, failures = delivery_status(instance, scope)
    scope.completed = pending == 0
    return applied, pending, failures
end

local function scope_outcome(instance, scope, duplicate)
    local applied, pending, failures = delivery_status(instance, scope)
    local ok = pending == 0
    local reason
    if scope.scopeKind == "commit" then
        reason = ok and (duplicate and "duplicate-ending-commit" or "ending-committed-effects-applied")
            or "ending-committed-effects-pending"
    else
        reason = ok and (duplicate and "duplicate-ending-world-replay" or "ending-world-replay-applied")
            or "ending-world-replay-pending"
    end
    return result(ok, reason, {
        routeId = scope.routeId,
        operationId = scope.operationId,
        coreCommitted = scope.scopeKind == "commit" or nil,
        outputCount = #scope.outputs,
        appliedCount = applied,
        pendingCount = pending,
        failures = failures,
        retryable = pending > 0,
        idempotent = duplicate == true,
        PalworldSaveMutation = false,
    })
end

local function rebuild_provider_index(instance)
    instance.providerByEffectKind = {}
    for provider_id, provider in pairs(instance.providers) do
        for effect_kind in pairs(provider.effectKinds) do
            local existing = instance.providerByEffectKind[effect_kind]
            assert(existing == nil or existing == provider_id,
                "restored ending providers conflict on effect kind")
            instance.providerByEffectKind[effect_kind] = provider_id
        end
    end
end

local function normalize_snapshot(snapshot)
    require_serializable(snapshot, "ending provider snapshot")
    assert(type(snapshot) == "table", "ending provider snapshot is required")
    assert(snapshot.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported ending provider snapshot schema")
    local restored = {
        providers = {},
        previews = copy(snapshot.previews or {}),
        confirmations = copy(snapshot.confirmations or {}),
        commits = copy(snapshot.commits or {}),
        replays = copy(snapshot.replays or {}),
        operationOwners = copy(snapshot.operationOwners or {}),
        completedOperationId = snapshot.completedOperationId,
    }
    for _, definition in ipairs(snapshot.providers or {}) do
        local provider = normalize_provider(definition)
        assert(restored.providers[provider.providerId] == nil, "duplicate restored ending provider")
        restored.providers[provider.providerId] = provider
    end
    return restored
end

local function persist_snapshot(instance)
    local progression = instance.progression
    if progression ~= nil and type(progression.state) == "table" then
        progression.state.endingEffectProviderBus =
            instance:export_snapshot()
    end
end

local function notify(instance, event)
    persist_snapshot(instance)
    if instance.onChange ~= nil then
        local called, message = pcall(instance.onChange, nil, copy(event))
        if not called then instance.lastNotificationError = tostring(message) end
    end
end

function EndingEffectProviderBus.create(ending_runtime, options)
    assert(type(ending_runtime) == "table", "ending runtime is required")
    for _, method_name in ipairs({ "available_routes", "evaluate", "commit", "post_ending_policy" }) do
        assert(type(ending_runtime[method_name]) == "function", "ending runtime lacks " .. method_name)
    end
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "ending provider bus onChange must be a function")
    local progression = ending_runtime.progression
    local progression_snapshot = progression
        and progression.state
        and progression.state.endingEffectProviderBus
        or nil
    local restored = (options.snapshot or progression_snapshot)
        and normalize_snapshot(options.snapshot or progression_snapshot) or {
        providers = {}, previews = {}, confirmations = {}, commits = {}, replays = {},
        operationOwners = {}, completedOperationId = nil,
    }
    local instance = setmetatable({
        version = API_VERSION,
        endingRuntime = ending_runtime,
        progression = progression,
        providers = restored.providers,
        handlers = {},
        providerByEffectKind = {},
        previews = restored.previews,
        confirmations = restored.confirmations,
        commits = restored.commits,
        replays = restored.replays,
        operationOwners = restored.operationOwners,
        completedOperationId = restored.completedOperationId,
        rejectedCount = 0,
        retryCount = 0,
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            availablePreview = true,
            explicitPlayerConfirmation = true,
            modelCommitAuthority = false,
            providerEffectWhitelist = true,
            retryableProviderFailure = true,
            worldLoadReplay = true,
            operationIdempotency = true,
            serializableRestoreWithoutUObjects = true,
            directUEMutation = false,
            PalworldSaveMutation = false,
        },
    }, { __index = EndingEffectProviderBus })
    rebuild_provider_index(instance)
    persist_snapshot(instance)
    if progression ~= nil
        and type(progression.register_restore_listener) == "function" then
        progression:register_restore_listener(
            "pwft.ending-effect-provider-bus.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
    end
    return instance
end

function EndingEffectProviderBus:rebind_progression_state()
    local snapshot = self.progression
        and self.progression.state.endingEffectProviderBus
        or nil
    local called, restored = pcall(normalize_snapshot, snapshot or {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = {},
        previews = {},
        confirmations = {},
        commits = {},
        replays = {},
        operationOwners = {},
    })
    if not called then
        return result(false, "ending-effect-provider-snapshot-invalid", {
            validationError = tostring(restored),
        })
    end
    self.providers = restored.providers
    self.previews = restored.previews
    self.confirmations = restored.confirmations
    self.commits = restored.commits
    self.replays = restored.replays
    self.operationOwners = restored.operationOwners
    self.completedOperationId = restored.completedOperationId
    self.handlers = {}
    rebuild_provider_index(self)
    persist_snapshot(self)
    return result(true, "ending-effect-provider-state-rebound", {
        handlersCleared = true,
    })
end

function EndingEffectProviderBus:register_provider(definition, handler)
    local ok, provider = pcall(normalize_provider, definition)
    if not ok or type(handler) ~= "function" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-ending-effect-provider", {
            validationError = ok and "provider-handler-must-be-a-function" or tostring(provider),
        })
    end
    local existing = self.providers[provider.providerId]
    if existing ~= nil and not provider_equal(existing, provider) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "ending-effect-provider-id-conflict")
    end
    for effect_kind in pairs(provider.effectKinds) do
        local owner = self.providerByEffectKind[effect_kind]
        if owner ~= nil and owner ~= provider.providerId then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "ending-effect-kind-provider-conflict", {
                effectKind = effect_kind,
                currentProviderId = owner,
            })
        end
    end
    self.providers[provider.providerId] = provider
    self.handlers[provider.providerId] = handler
    rebuild_provider_index(self)
    notify(self, {
        type = existing and "ending-effect-provider-rebound"
            or "ending-effect-provider-registered",
        providerId = provider.providerId,
    })
    return result(true, existing and "ending-effect-provider-rebound" or "ending-effect-provider-registered", {
        providerId = provider.providerId,
    })
end

function EndingEffectProviderBus:available_preview()
    return {
        ok = true,
        reason = "ending-routes-previewed",
        routes = copy(self.endingRuntime:available_routes()),
        postEnding = copy(self.endingRuntime:post_ending_policy()),
        readOnly = true,
    }
end

function EndingEffectProviderBus:preview(route_id, preview_id, context)
    require_text(route_id, "ending route ID")
    require_text(preview_id, "ending preview ID")
    context = context or {}
    local requester_kind = require_text(context.requesterKind, "ending preview requester kind")
    local existing = self.previews[preview_id]
    if existing ~= nil then
        if existing.routeId ~= route_id or existing.requesterKind ~= requester_kind then
            return result(false, "ending-preview-id-conflict")
        end
        local duplicate = copy(existing.evaluation)
        duplicate.reason = "duplicate-ending-preview"
        duplicate.idempotent = true
        return duplicate
    end
    local evaluation = self.endingRuntime:evaluate(route_id)
    if not evaluation.ok then return evaluation end
    local response = copy(evaluation)
    response.previewId = preview_id
    response.readOnly = true
    response.explicitConfirmationRequired = true
    self.previews[preview_id] = {
        previewId = preview_id,
        routeId = route_id,
        requesterKind = requester_kind,
        requesterId = context.requesterId,
        evaluation = copy(response),
    }
    notify(self, {
        type = "ending-preview-created",
        previewId = preview_id,
        routeId = route_id,
        requesterKind = requester_kind,
    })
    return response
end

function EndingEffectProviderBus:confirm(preview_id, confirmation_id, context)
    require_text(preview_id, "ending preview ID")
    require_text(confirmation_id, "ending confirmation ID")
    context = context or {}
    if context.authorityKind ~= "player" or context.explicitConfirmed ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, context.authorityKind == "model"
            and "model-has-no-ending-confirmation-authority"
            or "explicit-player-confirmation-required")
    end
    local player_id = require_text(context.playerId, "ending confirmation player ID")
    local preview = self.previews[preview_id]
    if preview == nil then return result(false, "unknown-ending-preview") end
    local existing = self.confirmations[confirmation_id]
    if existing ~= nil then
        if existing.previewId ~= preview_id or existing.playerId ~= player_id then
            return result(false, "ending-confirmation-id-conflict")
        end
        return result(true, "duplicate-ending-confirmation", copy(existing))
    end
    local evaluation = self.endingRuntime:evaluate(preview.routeId)
    if not evaluation.ok or not evaluation.ready then return evaluation end
    local confirmation = {
        confirmationId = confirmation_id,
        previewId = preview_id,
        routeId = preview.routeId,
        playerId = player_id,
        consumed = false,
    }
    self.confirmations[confirmation_id] = confirmation
    notify(self, {
        type = "ending-explicitly-confirmed",
        confirmationId = confirmation_id,
        previewId = preview_id,
        routeId = preview.routeId,
        authorityKind = "player",
    })
    return result(true, "ending-explicitly-confirmed", copy(confirmation))
end

function EndingEffectProviderBus:commit(confirmation_id, operation_id, context)
    require_text(confirmation_id, "ending confirmation ID")
    require_text(operation_id, "ending commit operation ID")
    context = context or {}
    if context.authorityKind ~= "player" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, context.authorityKind == "model"
            and "model-has-no-ending-commit-authority"
            or "player-ending-commit-authority-required")
    end
    local player_id = require_text(context.playerId, "ending commit player ID")
    local confirmation = self.confirmations[confirmation_id]
    if confirmation == nil then return result(false, "unknown-ending-confirmation") end
    if confirmation.playerId ~= player_id then return result(false, "ending-confirmation-player-mismatch") end
    local owner = self.operationOwners[operation_id]
    if owner ~= nil and owner ~= confirmation_id then
        return result(false, "ending-commit-operation-id-conflict")
    end
    local existing = self.commits[operation_id]
    if existing ~= nil then
        local was_pending = not existing.completed
        apply_scope(self, existing)
        if was_pending then self.retryCount = self.retryCount + 1 end
        notify(self, {
            type = "ending-provider-delivery-attempted",
            operationId = operation_id,
            scopeKind = "commit",
            retry = was_pending,
        })
        return scope_outcome(self, existing, not was_pending)
    end
    if confirmation.consumed then return result(false, "ending-confirmation-already-consumed") end
    local committed = self.endingRuntime:commit(
        confirmation.routeId,
        "ending-provider-bus:" .. operation_id
    )
    if not committed.ok then return committed end
    confirmation.consumed = true
    confirmation.operationId = operation_id
    local scope = make_scope(
        "ending-commit:" .. operation_id,
        confirmation.routeId,
        operation_id,
        committed.effects,
        "commit"
    )
    self.commits[operation_id] = scope
    self.operationOwners[operation_id] = confirmation_id
    self.completedOperationId = operation_id
    apply_scope(self, scope)
    notify(self, {
        type = "ending-commit-recorded",
        operationId = operation_id,
        confirmationId = confirmation_id,
        routeId = confirmation.routeId,
    })
    return scope_outcome(self, scope, false)
end

function EndingEffectProviderBus:replay_world_load(replay_operation_id)
    require_text(replay_operation_id, "ending world replay operation ID")
    local existing = self.replays[replay_operation_id]
    if existing ~= nil then
        local was_pending = not existing.completed
        apply_scope(self, existing)
        if was_pending then self.retryCount = self.retryCount + 1 end
        notify(self, {
            type = "ending-provider-delivery-attempted",
            operationId = replay_operation_id,
            scopeKind = "replay",
            retry = was_pending,
        })
        return scope_outcome(self, existing, not was_pending)
    end
    local committed = self.completedOperationId and self.commits[self.completedOperationId] or nil
    if committed == nil then
        return result(true, "no-ending-to-replay", {
            operationId = replay_operation_id,
            outputCount = 0,
            appliedCount = 0,
            pendingCount = 0,
            readOnly = true,
        })
    end
    local effects = {}
    for _, output in ipairs(committed.outputs) do
        effects[#effects + 1] = copy(output)
    end
    local replay = {
        scopeId = "ending-world-replay:" .. replay_operation_id,
        scopeKind = "replay",
        routeId = committed.routeId,
        operationId = replay_operation_id,
        outputs = {}, deliveryById = {}, completed = false, attemptCount = 0,
    }
    for index, original in ipairs(effects) do
        local output = copy(original)
        output.deliveryId = replay.scopeId .. ":effect:" .. tostring(index)
        output.effectIndex = index
        replay.outputs[#replay.outputs + 1] = output
        replay.deliveryById[output.deliveryId] = {
            deliveryId = output.deliveryId, applied = false, attemptCount = 0,
        }
    end
    self.replays[replay_operation_id] = replay
    apply_scope(self, replay)
    notify(self, {
        type = "ending-world-replay-recorded",
        operationId = replay_operation_id,
        routeId = committed.routeId,
    })
    return scope_outcome(self, replay, false)
end

function EndingEffectProviderBus:export_snapshot()
    local providers = {}
    for _, provider in pairs(self.providers) do
        local kinds = {}
        for kind in pairs(provider.effectKinds) do kinds[#kinds + 1] = kind end
        table.sort(kinds)
        providers[#providers + 1] = {
            providerId = provider.providerId,
            effectKinds = kinds,
            idempotentDeliveryIds = true,
            readOnlyInput = true,
            enabled = provider.enabled,
        }
    end
    table.sort(providers, function(first, second) return first.providerId < second.providerId end)
    local snapshot = {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = providers,
        previews = copy(self.previews),
        confirmations = copy(self.confirmations),
        commits = copy(self.commits),
        replays = copy(self.replays),
        operationOwners = copy(self.operationOwners),
        completedOperationId = self.completedOperationId,
    }
    require_serializable(snapshot, "ending provider snapshot")
    return snapshot
end

function EndingEffectProviderBus:status()
    local provider_count, commit_count, replay_count, pending_count = 0, 0, 0, 0
    for _ in pairs(self.providers) do provider_count = provider_count + 1 end
    for _, scope in pairs(self.commits) do
        commit_count = commit_count + 1
        local _, pending = delivery_status(self, scope)
        pending_count = pending_count + pending
    end
    for _, scope in pairs(self.replays) do
        replay_count = replay_count + 1
        local _, pending = delivery_status(self, scope)
        pending_count = pending_count + pending
    end
    return {
        apiVersion = self.version,
        providerCount = provider_count,
        activeProviderHandlerCount = (function()
            local count = 0
            for _ in pairs(self.handlers) do count = count + 1 end
            return count
        end)(),
        commitCount = commit_count,
        replayCount = replay_count,
        pendingDeliveryCount = pending_count,
        completedOperationId = self.completedOperationId,
        rejectedCount = self.rejectedCount,
        retryCount = self.retryCount,
        progressionSidecarState = self.progression ~= nil,
        lastNotificationError = self.lastNotificationError,
        modelCommitAuthority = false,
        handlersPersisted = false,
        directUEMutation = false,
        PalworldSaveMutation = false,
    }
end

return EndingEffectProviderBus
