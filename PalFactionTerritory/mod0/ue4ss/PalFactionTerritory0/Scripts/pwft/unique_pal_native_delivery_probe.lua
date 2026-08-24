local UniquePalNativeDeliveryProbe = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
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

local function scalar(value)
    value = unwrap(value)
    if type(value) == "string"
        or type(value) == "number"
        or type(value) == "boolean" then
        return value
    end
    return nil
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

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function UniquePalNativeDeliveryProbe.create(options)
    options = options or {}
    assert(type(options.buildId) == "string"
            and options.buildId ~= "",
        "native delivery probe Build ID is required")
    assert(options.readOnly == true,
        "native delivery probe must be read-only")
    assert(type(options.objectDumpSha256) == "string"
            and string.match(options.objectDumpSha256,
                "^[%x]+$") ~= nil
            and #options.objectDumpSha256 == 64,
        "current-build ObjectDump SHA-256 is required")
    return setmetatable({
        version = API_VERSION,
        buildId = options.buildId,
        objectDumpSha256 = string.lower(options.objectDumpSha256),
        readOnly = true,
        adapters = options.adapters or {},
        logger = options.logger,
        worldGeneration = 0,
        worldBound = false,
        attemptCount = 0,
        successCount = 0,
        failureCount = 0,
        lastResult = nil,
        lastError = nil,
    }, { __index = UniquePalNativeDeliveryProbe })
end

function UniquePalNativeDeliveryProbe:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[UniquePalNativeDeliveryProbe] " .. tostring(message))
    end
end

function UniquePalNativeDeliveryProbe:bind_world(generation)
    assert(type(generation) == "number" and generation >= 1,
        "native delivery probe generation is required")
    self.worldGeneration = generation
    self.worldBound = true
    self.lastResult = nil
    self.lastError = nil
    return result(true, "native-delivery-probe-world-bound", {
        worldGeneration = generation,
    })
end

function UniquePalNativeDeliveryProbe:unbind_world(reason)
    self.worldBound = false
    self.lastResult = nil
    self.lastError = nil
    self.worldGeneration = self.worldGeneration + 1
    return result(true, "native-delivery-probe-world-unbound", {
        source = reason or "world-unload",
        worldGeneration = self.worldGeneration,
    })
end

function UniquePalNativeDeliveryProbe:probe(generation)
    self.attemptCount = self.attemptCount + 1
    if self.worldBound ~= true
        or generation ~= self.worldGeneration then
        self.failureCount = self.failureCount + 1
        self.lastError = "native-delivery-probe-generation-stale"
        return result(false, self.lastError, {
            retryable = false,
            requestedGeneration = generation,
            worldGeneration = self.worldGeneration,
        })
    end

    local controller, controller_source =
        local_controller(self.adapters)
    if controller == nil then
        self.failureCount = self.failureCount + 1
        self.lastError = controller_source
        return result(false, controller_source, { retryable = true })
    end
    local state, state_source = player_state(controller)
    if state == nil then
        self.failureCount = self.failureCount + 1
        self.lastError = state_source
        return result(false, state_source, { retryable = true })
    end
    local storage, storage_error = safe_call(state, "GetPalStorage")
    if not is_valid_object(storage) then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-storage-not-ready:" .. tostring(storage_error)
        return result(false, self.lastError, { retryable = true })
    end

    local page_num, page_error = safe_call(storage, "GetPageNum")
    page_num = tonumber(scalar(page_num))
    if page_num == nil or page_num < 0 then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-storage-page-count-unavailable:"
            .. tostring(page_error)
        return result(false, self.lastError, { retryable = true })
    end
    local empty_page, empty_page_error = safe_call(
        storage,
        "GetPageIndexExistEmptySlot",
        0
    )
    empty_page = tonumber(scalar(empty_page))
    if empty_page == nil then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-storage-empty-page-unavailable:"
            .. tostring(empty_page_error)
        return result(false, self.lastError, { retryable = true })
    end
    if empty_page < 0 then
        local full_result = result(true,
            "native-delivery-storage-full", {
            buildId = self.buildId,
            objectDumpSha256 = self.objectDumpSha256,
            worldGeneration = generation,
            readOnly = true,
            capacityAvailable = false,
            pageCount = page_num,
            firstEmptyPageIndex = empty_page,
            sources = {
                controller = controller_source,
                playerState = state_source,
                storage = "PalPlayerState.GetPalStorage",
                capacity = "PalPlayerDataPalStorage.GetPageIndexExistEmptySlot",
            },
        })
        self.successCount = self.successCount + 1
        self.lastResult = copy(full_result)
        self.lastError = nil
        self:_log(string.format(
            "STORAGE_READBACK_OK generation=%d pages=%d emptyPage=%d capacity=false mutation=false",
            generation,
            page_num,
            empty_page
        ))
        return full_result
    end
    local container = safe_property(storage, "TargetContainer")
    if not is_valid_object(container) then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-storage-container-not-ready"
        return result(false, self.lastError, { retryable = true })
    end
    local empty_slot, empty_slot_error = safe_call(
        container,
        "FindEmptySlot"
    )
    if not is_valid_object(empty_slot) then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-storage-empty-slot-unavailable:"
            .. tostring(empty_slot_error)
        return result(false, self.lastError, { retryable = true })
    end
    local is_empty, is_empty_error = safe_call(empty_slot, "IsEmpty")
    if is_empty ~= true then
        self.failureCount = self.failureCount + 1
        self.lastError = "pal-storage-empty-slot-not-empty:"
            .. tostring(is_empty_error)
        return result(false, self.lastError, { retryable = false })
    end
    local slot_index = scalar(safe_call(empty_slot, "GetSlotIndex"))
    local slot_id = scalar(safe_call(empty_slot, "GetSlotId"))
    local probe_result = result(true,
        "native-delivery-storage-capacity-confirmed", {
        buildId = self.buildId,
        objectDumpSha256 = self.objectDumpSha256,
        worldGeneration = generation,
        readOnly = true,
        capacityAvailable = true,
        pageCount = page_num,
        firstEmptyPageIndex = empty_page,
        emptySlotIndex = slot_index,
        emptySlotId = slot_id,
        sources = {
            controller = controller_source,
            playerState = state_source,
            storage = "PalPlayerState.GetPalStorage",
            capacity = "PalPlayerDataPalStorage.GetPageIndexExistEmptySlot",
            container = "PalPlayerDataPalStorage.TargetContainer",
            emptySlot = "PalIndividualCharacterContainer.FindEmptySlot",
        },
    })
    self.successCount = self.successCount + 1
    self.lastResult = copy(probe_result)
    self.lastError = nil
    self:_log(string.format(
        "STORAGE_READBACK_OK generation=%d pages=%d emptyPage=%d emptySlot=%s capacity=%s mutation=false",
        generation,
        page_num,
        empty_page,
        tostring(slot_index),
        "true"
    ))
    return probe_result
end

function UniquePalNativeDeliveryProbe:status()
    return {
        apiVersion = self.version,
        buildId = self.buildId,
        objectDumpSha256 = self.objectDumpSha256,
        readOnly = true,
        worldBound = self.worldBound,
        worldGeneration = self.worldGeneration,
        attemptCount = self.attemptCount,
        successCount = self.successCount,
        failureCount = self.failureCount,
        lastResult = copy(self.lastResult),
        lastError = self.lastError,
        capabilities = {
            localPlayerStateRead = true,
            palStorageRead = true,
            capacityRead = true,
            emptySlotRead = true,
            createIndividual = false,
            capturePal = false,
            directContainerMutation = false,
            PalworldSaveMutation = false,
        },
    }
end

return UniquePalNativeDeliveryProbe
