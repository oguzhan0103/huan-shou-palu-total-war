local ProgressionIdentity = require("pwft.progression_identity")

local UniquePalNativeDeliveryAdapter = {}

local API_VERSION = "1.0.0"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function unwrap(value)
    if value == nil then return nil end
    local ok, unwrapped = pcall(function()
        if value.get ~= nil then return value:get() end
        return value
    end)
    if ok then return unwrapped end
    return value
end

local function is_valid_object(object)
    if object == nil then return false end
    local ok, valid = pcall(function()
        if object.IsValid ~= nil then return object:IsValid() end
        return true
    end)
    return ok and valid ~= false
end

local function safe_property(object, property_name)
    if not is_valid_object(object) then return nil end
    local ok, value = pcall(function()
        return object[property_name]
    end)
    if not ok then return nil end
    return unwrap(value)
end

local function safe_call(object, method_name, ...)
    if not is_valid_object(object) then
        return nil, "object-unavailable"
    end
    local arguments = { ... }
    local ok, value = pcall(function()
        local method = object[method_name]
        if method == nil then error("method-unavailable") end
        return method(object, table.unpack(arguments))
    end)
    if not ok then return nil, tostring(value) end
    return unwrap(value), nil
end

local function stable_text(value)
    return type(value) == "string"
        and value ~= ""
        and string.match(value, "^[%w][%w%._:%-]+$") ~= nil
end

local function local_controller(adapters)
    if type(adapters.getPlayerController) == "function" then
        local ok, controller = pcall(adapters.getPlayerController)
        if ok and is_valid_object(controller) then
            return controller, "adapter"
        end
    end
    if _G.UEHelpers ~= nil
        and type(_G.UEHelpers.GetPlayerController) == "function" then
        local ok, controller = pcall(
            _G.UEHelpers.GetPlayerController
        )
        if ok and is_valid_object(controller) then
            return controller, "UEHelpers.GetPlayerController"
        end
    end
    local find_all = adapters.findAllOf or _G.FindAllOf
    if type(find_all) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
            "PlayerController",
        }) do
            local ok, controllers = pcall(find_all, class_name)
            if ok and type(controllers) == "table" then
                for _, controller in pairs(controllers) do
                    if is_valid_object(controller) then
                        local is_local = safe_call(
                            controller,
                            "IsLocalPlayerController"
                        )
                        if is_local == true then
                            return controller,
                                "FindAllOf(" .. class_name .. ")"
                        end
                    end
                end
            end
        end
    end
    local find_first = adapters.findFirstOf or _G.FindFirstOf
    if type(find_first) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
        }) do
            local ok, controller = pcall(find_first, class_name)
            if ok and is_valid_object(controller) then
                local is_local = safe_call(
                    controller,
                    "IsLocalPlayerController"
                )
                if is_local == true then
                    return controller,
                        "FindFirstOf(" .. class_name .. ")"
                end
            end
        end
    end
    return nil, "local-player-controller-not-ready"
end

local function pal_utility(adapters)
    if type(adapters.getPalUtility) == "function" then
        local ok, utility = pcall(adapters.getPalUtility)
        if ok and is_valid_object(utility) then return utility end
    end
    local finder = adapters.staticFindObject or _G.StaticFindObject
    if type(finder) ~= "function" then return nil end
    local ok, utility = pcall(
        finder,
        "/Script/Pal.Default__PalUtility"
    )
    if ok and is_valid_object(utility) then return utility end
    return nil
end

local function player_state(controller)
    local state, call_error = safe_call(
        controller,
        "GetPalPlayerState"
    )
    if is_valid_object(state) then
        return state, "PalPlayerController.GetPalPlayerState"
    end
    state = safe_property(controller, "PlayerState")
    if is_valid_object(state) then
        return state, "PalPlayerController.PlayerState"
    end
    return nil, "pal-player-state-not-ready:" .. tostring(call_error)
end

local function player_character(controller)
    for _, method_name in ipairs({
        "GetDefaultPlayerCharacter",
        "K2_GetPawn",
    }) do
        local character = safe_call(controller, method_name)
        if is_valid_object(character) then
            return character,
                "PalPlayerController." .. method_name
        end
    end
    local character = safe_property(controller, "AcknowledgedPawn")
        or safe_property(controller, "Pawn")
    if is_valid_object(character) then
        return character, "PalPlayerController.Pawn"
    end
    return nil, "local-player-character-not-ready"
end

local function individual_key(handle)
    local id, id_error = safe_call(handle, "GetIndividualID")
    if id == nil then
        return nil, "native-pal-individual-id-unavailable:"
            .. tostring(id_error)
    end
    local player_uid = ProgressionIdentity.normalize_guid(
        safe_property(id, "PlayerUId")
    )
    local instance_id = ProgressionIdentity.normalize_guid(
        safe_property(id, "InstanceId")
    )
    if player_uid == nil or instance_id == nil then
        return nil, "native-pal-individual-id-invalid"
    end
    return "pal-" .. player_uid .. "-" .. instance_id, nil
end

function UniquePalNativeDeliveryAdapter.create(options)
    options = options or {}
    assert(type(options.buildId) == "string"
            and options.buildId ~= "",
        "native Pal delivery adapter Build ID is required")
    assert(type(options.objectDumpSha256) == "string"
            and #options.objectDumpSha256 == 64
            and string.match(options.objectDumpSha256,
                "^[%x]+$") ~= nil,
        "native Pal delivery ObjectDump SHA-256 is required")
    local instance = {
        version = API_VERSION,
        buildId = options.buildId,
        objectDumpSha256 = string.lower(options.objectDumpSha256),
        allowMutatingDelivery =
            options.allowMutatingDelivery == true,
        adapters = options.adapters or {},
        logger = options.logger,
        deliveryLevel = options.deliveryLevel or 1,
        spawnOffset = options.spawnOffset or {
            X = 180,
            Y = 0,
            Z = 30,
        },
        worldBound = false,
        worldGeneration = 0,
        recordsByNativeDeliveryId = {},
        recordsByCoreDeliveryId = {},
        createCount = 0,
        captureCount = 0,
        verifyCount = 0,
        rollbackCount = 0,
        worldUnbindCount = 0,
        failureCount = 0,
        lastError = nil,
    }
    assert(type(instance.deliveryLevel) == "number"
            and instance.deliveryLevel >= 1,
        "native Pal delivery level must be positive")
    return setmetatable(instance, {
        __index = UniquePalNativeDeliveryAdapter,
    })
end

function UniquePalNativeDeliveryAdapter:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[UniquePalNativeDeliveryAdapter] " .. tostring(message))
    end
end

function UniquePalNativeDeliveryAdapter:bind_world(generation)
    assert(type(generation) == "number" and generation >= 1,
        "native Pal delivery adapter generation is required")
    self.worldGeneration = generation
    self.worldBound = true
    self.lastError = nil
    return result(true, "native-pal-delivery-adapter-world-bound", {
        worldGeneration = generation,
    })
end

function UniquePalNativeDeliveryAdapter:_resolve_context(
    require_capacity
)
    local controller, controller_source =
        local_controller(self.adapters)
    if controller == nil then
        return nil, controller_source
    end
    local state, state_source = player_state(controller)
    if state == nil then return nil, state_source end
    local character, character_source = player_character(controller)
    if character == nil then return nil, character_source end
    local storage, storage_error = safe_call(state, "GetPalStorage")
    if not is_valid_object(storage) then
        return nil, "pal-storage-not-ready:" .. tostring(storage_error)
    end
    local container = safe_property(storage, "TargetContainer")
    if not is_valid_object(container) then
        return nil, "pal-storage-container-not-ready"
    end
    local capacity_available = nil
    if require_capacity == true then
        local empty_page, page_error = safe_call(
            storage,
            "GetPageIndexExistEmptySlot",
            0
        )
        empty_page = tonumber(unwrap(empty_page))
        if empty_page == nil then
            return nil, "pal-storage-empty-page-unavailable:"
                .. tostring(page_error)
        end
        capacity_available = empty_page >= 0
        if capacity_available then
            local empty_slot, slot_error = safe_call(
                container,
                "FindEmptySlot"
            )
            if not is_valid_object(empty_slot) then
                return nil, "pal-storage-empty-slot-unavailable:"
                    .. tostring(slot_error)
            end
            local is_empty, empty_error = safe_call(
                empty_slot,
                "IsEmpty"
            )
            if is_empty ~= true then
                return nil, "pal-storage-empty-slot-not-empty:"
                    .. tostring(empty_error)
            end
        end
    end
    local utility = pal_utility(self.adapters)
    if not is_valid_object(utility) then
        return nil, "pal-utility-not-ready"
    end
    return {
        controller = controller,
        controllerSource = controller_source,
        playerState = state,
        playerStateSource = state_source,
        playerCharacter = character,
        playerCharacterSource = character_source,
        storage = storage,
        container = container,
        utility = utility,
        capacityAvailable = capacity_available,
    }, nil
end

function UniquePalNativeDeliveryAdapter:_validate_request(request)
    if type(request) ~= "table"
        or not stable_text(request.deliveryId)
        or not stable_text(request.speciesId)
        or type(request.worldGeneration) ~= "number" then
        return nil, "native-pal-delivery-request-invalid"
    end
    if self.worldBound ~= true
        or request.worldGeneration ~= self.worldGeneration then
        return nil, "native-pal-delivery-generation-stale"
    end
    if request.buildId ~= self.buildId then
        return nil, "native-pal-delivery-build-mismatch"
    end
    return request, nil
end

function UniquePalNativeDeliveryAdapter:preflight(request)
    local validated, validation_error =
        self:_validate_request(request)
    if validated == nil then
        self.failureCount = self.failureCount + 1
        self.lastError = validation_error
        return result(false, validation_error, { retryable = false })
    end
    local existing = self.recordsByCoreDeliveryId[
        validated.deliveryId]
    if existing ~= nil and existing.verified == true then
        return result(true,
            "native-pal-delivery-already-verified", {
            existingDelivered = true,
            nativeDeliveryId = existing.nativeDeliveryId,
            individualKey = existing.individualKey,
            capacityAvailable = true,
        })
    end
    local context, context_error = self:_resolve_context(true)
    if context == nil then
        self.failureCount = self.failureCount + 1
        self.lastError = context_error
        return result(false, context_error, { retryable = true })
    end
    self.lastError = nil
    return result(true,
        context.capacityAvailable
                and "native-pal-storage-capacity-confirmed"
            or "native-pal-storage-full", {
        capacityAvailable = context.capacityAvailable,
        existingDelivered = false,
        controllerSource = context.controllerSource,
        playerStateSource = context.playerStateSource,
        playerCharacterSource = context.playerCharacterSource,
        readOnly = true,
    })
end

function UniquePalNativeDeliveryAdapter:_make_name(value)
    if type(self.adapters.fName) == "function" then
        local ok, name = pcall(self.adapters.fName, value)
        if ok and name ~= nil then return name end
    end
    if type(_G.FName) == "function" then
        local ok, name = pcall(_G.FName, value)
        if ok and name ~= nil then return name end
    end
    local finder = self.adapters.staticFindObject
        or _G.StaticFindObject
    if type(finder) == "function" then
        local ok, library = pcall(
            finder,
            "/Script/Engine.Default__KismetStringLibrary"
        )
        if ok and is_valid_object(library) then
            local name = safe_call(
                library,
                "Conv_StringToName",
                value
            )
            if name ~= nil then return name end
        end
    end
    return value
end

function UniquePalNativeDeliveryAdapter:create_individual(
    request,
    preflight
)
    local validated, validation_error =
        self:_validate_request(request)
    if validated == nil then
        return result(false, validation_error, { retryable = false })
    end
    local existing = self.recordsByCoreDeliveryId[
        validated.deliveryId]
    if existing ~= nil then
        return result(true,
            "native-pal-individual-already-created", {
            nativeDeliveryId = existing.nativeDeliveryId,
            individualKey = existing.individualKey,
            idempotent = true,
        })
    end
    if self.allowMutatingDelivery ~= true then
        self.lastError = "native-pal-delivery-mutation-disabled"
        return result(false, self.lastError, { retryable = false })
    end
    if type(preflight) ~= "table"
        or preflight.ok ~= true
        or preflight.capacityAvailable ~= true then
        return result(false,
            "native-pal-delivery-preflight-required", {
            retryable = false,
        })
    end
    local context, context_error = self:_resolve_context(true)
    if context == nil then
        self.failureCount = self.failureCount + 1
        self.lastError = context_error
        return result(false, context_error, { retryable = true })
    end
    if context.capacityAvailable ~= true then
        return result(false,
            "native-pal-storage-capacity-unavailable", {
            retryable = true,
        })
    end
    local manager, manager_error = safe_call(
        context.utility,
        "GetNPCManager",
        context.controller
    )
    if not is_valid_object(manager) then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-npc-manager-not-ready:"
            .. tostring(manager_error)
        return result(false, self.lastError, { retryable = true })
    end
    local controller_class = safe_property(
        manager,
        "NPCAIControllerBaseClass"
    )
    if not is_valid_object(controller_class) then
        return result(false,
            "pal-npc-controller-class-not-ready", {
            retryable = true,
        })
    end
    local location, location_error = safe_call(
        context.playerCharacter,
        "K2_GetActorLocation"
    )
    if location == nil then
        return result(false,
            "local-player-location-not-ready:"
                .. tostring(location_error), {
            retryable = true,
        })
    end
    local spawn_location = {
        X = (tonumber(safe_property(location, "X")) or 0)
            + (tonumber(self.spawnOffset.X) or 0),
        Y = (tonumber(safe_property(location, "Y")) or 0)
            + (tonumber(self.spawnOffset.Y) or 0),
        Z = (tonumber(safe_property(location, "Z")) or 0)
            + (tonumber(self.spawnOffset.Z) or 0),
    }
    local handle, spawn_error = safe_call(
        manager,
        "SpawnNPCForServer",
        {
            ControllerClass = controller_class,
            CharacterID = self:_make_name(validated.speciesId),
            Level = self.deliveryLevel,
            Location = spawn_location,
            Yaw = 0,
            Squad = nil,
        },
        -- UE4SS 3.0.1 cannot marshal a Lua closure into the native
        -- FPalSpawnedCharacterDelegate parameter.  The native raid route on
        -- this same build proves that SpawnNPCForServer accepts a nil
        -- delegate and still returns the stable individual handle we need.
        nil
    )
    if not is_valid_object(handle) then
        self.failureCount = self.failureCount + 1
        self.lastError = "native-pal-server-spawn-not-accepted:"
            .. tostring(spawn_error)
        return result(false, self.lastError, { retryable = true })
    end
    local key, key_error = individual_key(handle)
    if key == nil then
        local actor = safe_call(handle, "TryGetIndividualActor")
        if is_valid_object(actor) then
            safe_call(actor, "K2_DestroyActor")
        end
        self.failureCount = self.failureCount + 1
        self.lastError = key_error
        return result(false, key_error, { retryable = false })
    end
    local native_delivery_id =
        "pwft.native-pal-delivery." .. validated.deliveryId
    local record = {
        coreDeliveryId = validated.deliveryId,
        nativeDeliveryId = native_delivery_id,
        individualKey = key,
        speciesId = validated.speciesId,
        worldGeneration = validated.worldGeneration,
        handle = handle,
        actor = nil,
        playerCharacter = context.playerCharacter,
        captureAccepted = false,
        verified = false,
    }
    self.recordsByCoreDeliveryId[validated.deliveryId] = record
    self.recordsByNativeDeliveryId[native_delivery_id] = record
    self.createCount = self.createCount + 1
    self.lastError = nil
    self:_log(string.format(
        "INDIVIDUAL_CREATED delivery=%s species=%s individual=%s generation=%d capture=false",
        validated.deliveryId,
        validated.speciesId,
        key,
        validated.worldGeneration
    ))
    return result(true, "native-pal-individual-created", {
        nativeDeliveryId = native_delivery_id,
        individualKey = key,
        serverAuthoritativeSpawn = true,
    })
end

function UniquePalNativeDeliveryAdapter:_exact_record(
    request,
    native_delivery_id,
    expected_individual_key
)
    local validated, validation_error =
        self:_validate_request(request)
    if validated == nil then return nil, validation_error end
    local record = self.recordsByNativeDeliveryId[native_delivery_id]
    if record == nil
        or record.coreDeliveryId ~= validated.deliveryId then
        return nil, "native-pal-delivery-record-not-found"
    end
    if record.individualKey ~= expected_individual_key then
        return nil, "native-pal-delivery-individual-mismatch"
    end
    if record.worldGeneration ~= validated.worldGeneration then
        return nil, "native-pal-delivery-generation-stale"
    end
    return record, nil
end

function UniquePalNativeDeliveryAdapter:commit_capture(
    request,
    native_delivery_id,
    expected_individual_key
)
    local record, record_error = self:_exact_record(
        request,
        native_delivery_id,
        expected_individual_key
    )
    if record == nil then
        return result(false, record_error, { retryable = false })
    end
    if self.allowMutatingDelivery ~= true then
        return result(false,
            "native-pal-delivery-mutation-disabled", {
            retryable = false,
        })
    end
    if record.captureAccepted == true then
        return result(true,
            "native-pal-capture-already-accepted", {
            accepted = true,
            idempotent = true,
        })
    end
    local actor, actor_error = safe_call(
        record.handle,
        "TryGetIndividualActor"
    )
    if not is_valid_object(actor) then
        return result(false,
            "native-pal-individual-actor-not-ready:"
                .. tostring(actor_error), {
            retryable = true,
        })
    end
    local player = record.playerCharacter
    if not is_valid_object(player) then
        local context, context_error = self:_resolve_context(false)
        if context == nil then
            return result(false, context_error, { retryable = true })
        end
        player = context.playerCharacter
        record.playerCharacter = player
    end
    local utility = pal_utility(self.adapters)
    if not is_valid_object(utility) then
        return result(false, "pal-utility-not-ready", {
            retryable = true,
        })
    end
    local _, capture_error = safe_call(
        utility,
        "PalCaptureSuccess",
        player,
        actor
    )
    if capture_error ~= nil then
        self.failureCount = self.failureCount + 1
        self.lastError = "native-pal-capture-call-failed:"
            .. tostring(capture_error)
        return result(false, self.lastError, { retryable = true })
    end
    record.actor = actor
    record.captureAccepted = true
    self.captureCount = self.captureCount + 1
    self.lastError = nil
    self:_log(string.format(
        "CAPTURE_ACCEPTED delivery=%s individual=%s directContainerMutation=false",
        record.coreDeliveryId,
        record.individualKey
    ))
    return result(true, "native-pal-capture-accepted", {
        accepted = true,
        serverAuthoritativeCapture = true,
    })
end

function UniquePalNativeDeliveryAdapter:verify_storage(
    request,
    native_delivery_id,
    expected_individual_key
)
    local record, record_error = self:_exact_record(
        request,
        native_delivery_id,
        expected_individual_key
    )
    if record == nil then
        return result(false, record_error, { retryable = false })
    end
    if record.captureAccepted ~= true then
        return result(false,
            "native-pal-capture-not-accepted", {
            delivered = false,
            retryable = false,
        })
    end
    local context, context_error = self:_resolve_context(false)
    if context == nil then
        return result(false, context_error, {
            delivered = false,
            retryable = true,
        })
    end
    local slot, slot_error = safe_call(
        context.container,
        "FindByHandle",
        record.handle
    )
    if not is_valid_object(slot) then
        return result(false,
            "native-pal-storage-readback-pending:"
                .. tostring(slot_error), {
            delivered = false,
            retryable = true,
        })
    end
    local is_empty, empty_error = safe_call(slot, "IsEmpty")
    if is_empty ~= false then
        return result(false,
            "native-pal-storage-slot-empty:"
                .. tostring(empty_error), {
            delivered = false,
            retryable = true,
        })
    end
    local stored_handle, handle_error = safe_call(
        slot,
        "GetHandle"
    )
    if not is_valid_object(stored_handle) then
        return result(false,
            "native-pal-storage-handle-unavailable:"
                .. tostring(handle_error), {
            delivered = false,
            retryable = true,
        })
    end
    local stored_key, key_error = individual_key(stored_handle)
    if stored_key == nil then
        return result(false, key_error, {
            delivered = false,
            retryable = true,
        })
    end
    if stored_key ~= expected_individual_key then
        self.failureCount = self.failureCount + 1
        self.lastError = "native-pal-storage-individual-mismatch"
        return result(false, self.lastError, {
            delivered = false,
            individualKey = stored_key,
            retryable = false,
        })
    end
    record.verified = true
    record.handle = stored_handle
    record.actor = nil
    record.playerCharacter = nil
    self.verifyCount = self.verifyCount + 1
    self.lastError = nil
    self:_log(string.format(
        "STORAGE_VERIFIED delivery=%s individual=%s directContainerMutation=false",
        record.coreDeliveryId,
        stored_key
    ))
    return result(true, "native-pal-storage-verified", {
        delivered = true,
        individualKey = stored_key,
        exactIndividualIdentity = true,
    })
end

function UniquePalNativeDeliveryAdapter:rollback(
    request,
    native_delivery_id,
    expected_individual_key,
    source
)
    local record, record_error = self:_exact_record(
        request,
        native_delivery_id,
        expected_individual_key
    )
    if record == nil then
        return result(false, record_error, { retryable = false })
    end
    if record.captureAccepted == true or record.verified == true then
        return result(false,
            "native-pal-delivery-already-committed", {
            rolledBack = false,
            retryable = false,
        })
    end
    local actor = record.actor
    if not is_valid_object(actor) then
        actor = safe_call(record.handle, "TryGetIndividualActor")
    end
    if not is_valid_object(actor) then
        return result(false,
            "native-pal-rollback-actor-not-ready", {
            rolledBack = false,
            retryable = true,
        })
    end
    local _, destroy_error = safe_call(actor, "K2_DestroyActor")
    if destroy_error ~= nil then
        return result(false,
            "native-pal-rollback-destroy-failed:"
                .. tostring(destroy_error), {
            rolledBack = false,
            retryable = true,
        })
    end
    self.recordsByCoreDeliveryId[record.coreDeliveryId] = nil
    self.recordsByNativeDeliveryId[record.nativeDeliveryId] = nil
    record.handle = nil
    record.actor = nil
    record.playerCharacter = nil
    self.rollbackCount = self.rollbackCount + 1
    self.lastError = source or "native-pal-delivery-rolled-back"
    return result(true, "native-pal-delivery-rolled-back", {
        rolledBack = true,
        source = source,
    })
end

function UniquePalNativeDeliveryAdapter:unbind_world(reason)
    local cleared, destroyed, committed = 0, 0, 0
    for _, record in pairs(self.recordsByNativeDeliveryId) do
        cleared = cleared + 1
        if record.captureAccepted == true or record.verified == true then
            committed = committed + 1
        else
            local actor = record.actor
            if not is_valid_object(actor) then
                actor = safe_call(
                    record.handle,
                    "TryGetIndividualActor"
                )
            end
            if is_valid_object(actor) then
                local _, destroy_error = safe_call(
                    actor,
                    "K2_DestroyActor"
                )
                if destroy_error == nil then destroyed = destroyed + 1 end
            end
        end
        record.handle = nil
        record.actor = nil
        record.playerCharacter = nil
    end
    self.recordsByNativeDeliveryId = {}
    self.recordsByCoreDeliveryId = {}
    self.worldBound = false
    self.worldGeneration = self.worldGeneration + 1
    self.worldUnbindCount = self.worldUnbindCount + 1
    self.lastError = reason or "world-unloading"
    return result(true, "native-pal-delivery-adapter-world-unbound", {
        clearedRecordCount = cleared,
        destroyedUncommittedCount = destroyed,
        preservedCommittedCount = committed,
        worldGeneration = self.worldGeneration,
    })
end

function UniquePalNativeDeliveryAdapter:status()
    local active, committed, verified = 0, 0, 0
    for _, record in pairs(self.recordsByNativeDeliveryId) do
        active = active + 1
        if record.captureAccepted == true then committed = committed + 1 end
        if record.verified == true then verified = verified + 1 end
    end
    return {
        apiVersion = self.version,
        buildId = self.buildId,
        objectDumpSha256 = self.objectDumpSha256,
        allowMutatingDelivery = self.allowMutatingDelivery,
        worldBound = self.worldBound,
        worldGeneration = self.worldGeneration,
        activeRecordCount = active,
        committedRecordCount = committed,
        verifiedRecordCount = verified,
        createCount = self.createCount,
        captureCount = self.captureCount,
        verifyCount = self.verifyCount,
        rollbackCount = self.rollbackCount,
        worldUnbindCount = self.worldUnbindCount,
        failureCount = self.failureCount,
        lastError = self.lastError,
        capabilities = {
            currentBuildSignatureBound = true,
            capacityPreflight = true,
            serverAuthoritativeSpawn = true,
            stableIndividualIdentity = true,
            serverAuthoritativeCapture = true,
            exactStorageReadback = true,
            directContainerMutation = false,
            PalworldSaveMutation = false,
        },
    }
end

return UniquePalNativeDeliveryAdapter
