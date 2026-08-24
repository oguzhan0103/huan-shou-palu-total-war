local ProgressionIdentity = require("pwft.progression_identity")

local RewardItemNativeAdapter = {}

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

local function unwrap(value)
    if value == nil then return nil end
    local ok, unwrapped = pcall(function()
        if value.get ~= nil then return value:get() end
        return value
    end)
    return ok and unwrapped or value
end

local function is_valid(object)
    object = unwrap(object)
    if object == nil then return false end
    local ok, valid = pcall(function()
        if object.IsValid ~= nil then return object:IsValid() end
        return true
    end)
    return ok and valid ~= false
end

local function safe_property(object, name)
    object = unwrap(object)
    if not is_valid(object) then return nil end
    local ok, value = pcall(function() return object[name] end)
    return ok and unwrap(value) or nil
end

local function safe_call(object, method, ...)
    object = unwrap(object)
    if not is_valid(object) then return nil, "object-unavailable" end
    local arguments = { ... }
    local ok, value = pcall(function()
        local callback = object[method]
        if callback == nil then error("method-unavailable") end
        return callback(object, table.unpack(arguments))
    end)
    return ok and unwrap(value) or nil, ok and nil or tostring(value)
end

local function full_name(object)
    local value = safe_call(object, "GetFullName")
    if type(value) == "string" and value ~= "" then return value end
    local ok, text = pcall(tostring, object)
    return ok and tostring(text) or "<unavailable>"
end

local function integer(value)
    value = tonumber(unwrap(value))
    if value == nil or value < 0 or value ~= math.floor(value) then
        return nil
    end
    return value
end

local function make_name(value, adapters)
    local constructor = adapters.makeName or _G.FName
    if type(constructor) == "function" then
        local ok, native_name = pcall(constructor, value)
        if ok and native_name ~= nil then return native_name, "FName" end
    end
    local finder = adapters.staticFindObject or _G.StaticFindObject
    if type(finder) == "function" then
        local ok, strings = pcall(finder,
            "/Script/Engine.Default__KismetStringLibrary")
        if ok and is_valid(strings) then
            local native_name = safe_call(strings, "Conv_StringToName", value)
            if native_name ~= nil then
                return native_name,
                    "KismetStringLibrary.Conv_StringToName"
            end
        end
    end
    return nil, "native-name-conversion-unavailable"
end

local function get_local_controller(adapters)
    if type(adapters.getPlayerController) == "function" then
        local ok, controller = pcall(adapters.getPlayerController)
        if ok and is_valid(controller) then return controller, "adapter" end
    end
    if _G.UEHelpers ~= nil
        and type(_G.UEHelpers.GetPlayerController) == "function" then
        local ok, controller = pcall(_G.UEHelpers.GetPlayerController)
        if ok and is_valid(controller) then
            return controller, "UEHelpers.GetPlayerController"
        end
    end
    local finder = adapters.findFirstOf or _G.FindFirstOf
    if type(finder) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController", "PalPlayerController_C",
        }) do
            local ok, controller = pcall(finder, class_name)
            if ok and is_valid(controller)
                and safe_call(controller, "IsLocalPlayerController") == true then
                return controller, "FindFirstOf(" .. class_name .. ")"
            end
        end
    end
    return nil, "local-player-controller-not-ready"
end

local function find_player_inventory(adapters, player_uid, native_name)
    local finder = adapters.findAllOf or _G.FindAllOf
    if type(finder) ~= "function" then
        return nil, nil, "FindAllOf-unavailable"
    end
    local ok, inventories = pcall(finder, "PalPlayerInventoryData")
    if not ok or type(inventories) ~= "table" then
        return nil, nil, "player-inventory-list-unavailable"
    end
    local matches = {}
    for _, raw_inventory in pairs(inventories) do
        local inventory = unwrap(raw_inventory)
        local key = full_name(inventory)
        local owner_uid = ProgressionIdentity.normalize_guid(
            safe_property(inventory, "OwnerPlayerUId"))
        if is_valid(inventory)
            and string.find(key, "Default__", 1, true) == nil
            and owner_uid == player_uid then
            local count = integer(safe_call(
                inventory, "CountItemNum", native_name))
            if count ~= nil then
                matches[#matches + 1] = {
                    inventory = inventory,
                    inventoryKey = key,
                    count = count,
                }
            end
        end
    end
    if #matches == 0 then
        return nil, nil, "exact-player-inventory-not-ready"
    end
    if #matches > 1 then
        return nil, nil, "exact-player-inventory-ambiguous"
    end
    return matches[1], nil, nil
end

local function request_signature(request)
    return table.concat({
        tostring(request.deliveryId),
        tostring(request.attemptId),
        tostring(request.nativeItemId),
        tostring(request.units),
        tostring(request.playerUid),
        tostring(request.buildId),
        tostring(request.worldGeneration),
    }, "|")
end

local function confirmation(request, before_count, after_count, native_result)
    return result(true, "reward-item-native-readback-confirmed", {
        applied = true,
        deliveryId = request.deliveryId,
        attemptId = request.attemptId,
        playerUid = request.playerUid,
        nativeItemId = request.nativeItemId,
        buildId = request.buildId,
        worldGeneration = request.worldGeneration,
        beforeCount = before_count,
        afterCount = after_count,
        nativeResult = native_result,
    })
end

function RewardItemNativeAdapter.create(configuration, options)
    configuration = configuration or {}
    options = options or {}
    assert(type(configuration.enabled) == "boolean",
        "reward item native adapter enabled flag is required")
    assert(type(configuration.buildId) == "string"
            and configuration.buildId ~= "",
        "reward item native adapter Build ID is required")
    assert(type(configuration.objectDumpSha256) == "string"
            and #configuration.objectDumpSha256 == 64
            and string.match(configuration.objectDumpSha256, "^[%x]+$") ~= nil,
        "reward item native adapter ObjectDump hash is invalid")
    assert(configuration.currentBuildVerified == true,
        "reward item native adapter current Build must be verified")
    assert(type(options.adapters or {}) == "table",
        "reward item native adapter overrides must be a table")
    return setmetatable({
        version = API_VERSION,
        enabled = configuration.enabled == true,
        buildId = configuration.buildId,
        objectDumpSha256 = string.lower(configuration.objectDumpSha256),
        currentBuildVerified = true,
        adapters = options.adapters or {},
        worldGeneration = nil,
        contextsByAttemptId = {},
        dispatchCount = 0,
        confirmedCount = 0,
        rejectedCount = 0,
        ambiguousCount = 0,
        worldUnbindCount = 0,
        lastError = nil,
        capabilities = {
            currentBuildSignatureBound = true,
            stablePlayerIdentity = true,
            serverAuthoritativeGrant = true,
            exactInventoryReadback = true,
            exactOwnerPlayerUIdMatch = true,
            listenServerInternalRoute = true,
            clientServerRequestRoute = true,
            directCurrencyMutation = false,
            directSavePayloadMutation = false,
            automaticAmbiguousRetry = false,
        },
    }, { __index = RewardItemNativeAdapter })
end

function RewardItemNativeAdapter:bind_world(generation)
    if not self.enabled then
        return result(false, "reward-item-native-adapter-disabled")
    end
    if type(generation) ~= "number" or generation < 1
        or generation ~= math.floor(generation) then
        return result(false, "reward-item-native-world-generation-invalid")
    end
    if self.worldGeneration ~= generation then
        self.contextsByAttemptId = {}
    end
    self.worldGeneration = generation
    return result(true, "reward-item-native-world-bound", {
        worldGeneration = generation,
    })
end

function RewardItemNativeAdapter:unbind_world(reason)
    local previous = self.worldGeneration
    self.worldGeneration = nil
    self.contextsByAttemptId = {}
    self.worldUnbindCount = self.worldUnbindCount + 1
    return result(true, "reward-item-native-world-unbound", {
        previousWorldGeneration = previous,
        unbindReason = tostring(reason or "world-unloading"),
    })
end

function RewardItemNativeAdapter:preflight(request)
    if not self.enabled then
        return result(false, "reward-item-native-adapter-disabled", {
            retryable = false,
        })
    end
    if type(request) ~= "table" or request.rewardKind ~= "item"
        or request.buildId ~= self.buildId
        or request.worldGeneration ~= self.worldGeneration then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-item-native-request-mismatch", {
            retryable = false,
        })
    end
    local normalized_uid = ProgressionIdentity.normalize_guid(request.playerUid)
    if normalized_uid == nil or normalized_uid ~= request.playerUid then
        return result(false, "reward-item-player-identity-invalid", {
            retryable = false,
        })
    end
    if type(request.units) ~= "number" or request.units < 1
        or request.units ~= math.floor(request.units) then
        return result(false, "reward-item-unit-count-invalid", {
            retryable = false,
        })
    end
    local controller, controller_source = get_local_controller(self.adapters)
    if controller == nil then
        return result(false, controller_source, { retryable = true })
    end
    local controller_uid = ProgressionIdentity.normalize_guid(
        safe_call(controller, "GetPlayerUId"))
    if controller_uid ~= request.playerUid then
        return result(false, "reward-item-local-controller-identity-mismatch", {
            retryable = true,
        })
    end
    local native_name, name_route = make_name(
        request.nativeItemId, self.adapters)
    if native_name == nil then
        return result(false, name_route, { retryable = true })
    end
    local inventory, _, inventory_error = find_player_inventory(
        self.adapters, request.playerUid, native_name)
    if inventory == nil then
        return result(false, inventory_error, { retryable = true })
    end
    local has_authority = safe_call(controller, "HasAuthority") == true
    local native_route, network_component
    if has_authority then
        native_route = "PalPlayerInventoryData.AddItem_ServerInternal"
    else
        local transmitter = safe_property(controller, "Transmitter")
        network_component = safe_call(transmitter, "GetPlayer")
        if not is_valid(network_component) then
            return result(false,
                "reward-item-local-network-component-not-ready", {
                    retryable = true,
                })
        end
        native_route = "PalNetworkPlayerComponent.RequestAddItem_ToServer"
    end
    local context = {
        signature = request_signature(request),
        inventory = inventory.inventory,
        inventoryKey = inventory.inventoryKey,
        nativeName = native_name,
        nameRoute = name_route,
        controller = controller,
        controllerSource = controller_source,
        networkComponent = network_component,
        nativeRoute = native_route,
        beforeCount = inventory.count,
    }
    self.contextsByAttemptId[request.attemptId] = context
    return result(true, "reward-item-native-preflight-ready", {
        deliveryId = request.deliveryId,
        attemptId = request.attemptId,
        beforeCount = inventory.count,
        inventoryKey = inventory.inventoryKey,
        nativeRoute = native_route,
        nameRoute = name_route,
        controllerSource = controller_source,
        serverAuthoritative = true,
        exactOwnerMatched = true,
    })
end

function RewardItemNativeAdapter:dispatch(request, preflight)
    local context = self.contextsByAttemptId[request.attemptId]
    if context == nil or context.signature ~= request_signature(request)
        or type(preflight) ~= "table"
        or preflight.beforeCount ~= context.beforeCount
        or preflight.inventoryKey ~= context.inventoryKey
        or preflight.nativeRoute ~= context.nativeRoute then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "reward-item-native-preflight-context-mismatch", {
            retryable = false,
            mutationStarted = false,
        })
    end
    self.dispatchCount = self.dispatchCount + 1
    if context.nativeRoute
        == "PalPlayerInventoryData.AddItem_ServerInternal" then
        local called, native_result = pcall(function()
            return context.inventory:AddItem_ServerInternal(
                context.nativeName,
                request.units,
                false,
                0.0,
                true
            )
        end)
        if not called then
            self.lastError = tostring(native_result)
            return result(false, "reward-item-server-internal-call-failed", {
                adapterError = self.lastError,
                retryable = true,
                mutationStarted = false,
            })
        end
        local after = integer(safe_call(
            context.inventory, "CountItemNum", context.nativeName))
        local expected = context.beforeCount + request.units
        if after == expected then
            self.confirmedCount = self.confirmedCount + 1
            return confirmation(request, context.beforeCount, after,
                tostring(native_result))
        end
        if after == context.beforeCount then
            return result(false, "reward-item-server-internal-no-count-change", {
                retryable = true,
                mutationStarted = false,
                beforeCount = context.beforeCount,
                afterCount = after,
            })
        end
        self.ambiguousCount = self.ambiguousCount + 1
        return result(false, "reward-item-server-internal-readback-ambiguous", {
            retryable = false,
            mutationStarted = true,
            beforeCount = context.beforeCount,
            afterCount = after,
            expectedCount = expected,
        })
    end

    local called, request_error = pcall(function()
        return context.networkComponent:RequestAddItem_ToServer(
            context.nativeName,
            request.units,
            false
        )
    end)
    if not called then
        self.lastError = tostring(request_error)
        return result(false, "reward-item-server-request-call-failed", {
            adapterError = self.lastError,
            retryable = true,
            mutationStarted = false,
        })
    end
    return result(true, "reward-item-server-request-accepted", {
        accepted = true,
        deliveryId = request.deliveryId,
        attemptId = request.attemptId,
        nativeRoute = context.nativeRoute,
        mutationStarted = true,
    })
end

function RewardItemNativeAdapter:verify(record)
    if type(record) ~= "table"
        or record.buildId ~= self.buildId
        or record.worldGeneration ~= self.worldGeneration then
        return result(false, "reward-item-verification-context-stale", {
            pending = false,
        })
    end
    local native_name, name_error = make_name(
        record.nativeItemId, self.adapters)
    if native_name == nil then
        return result(false, name_error, { pending = true })
    end
    local inventory, _, inventory_error = find_player_inventory(
        self.adapters, record.playerUid, native_name)
    if inventory == nil then
        return result(false, inventory_error, { pending = true })
    end
    local current = inventory.count
    if current == record.expectedCount then
        self.confirmedCount = self.confirmedCount + 1
        return confirmation(record, record.beforeCount, current,
            "exact-inventory-readback")
    end
    if current < record.expectedCount then
        return result(false, "reward-item-readback-not-yet-replicated", {
            pending = true,
            currentCount = current,
            expectedCount = record.expectedCount,
        })
    end
    self.ambiguousCount = self.ambiguousCount + 1
    return result(false, "reward-item-readback-exceeded-expected-count", {
        pending = false,
        currentCount = current,
        expectedCount = record.expectedCount,
    })
end

function RewardItemNativeAdapter:status()
    return {
        version = self.version,
        enabled = self.enabled,
        buildId = self.buildId,
        objectDumpSha256 = self.objectDumpSha256,
        currentBuildVerified = self.currentBuildVerified,
        worldGeneration = self.worldGeneration,
        dispatchCount = self.dispatchCount,
        confirmedCount = self.confirmedCount,
        rejectedCount = self.rejectedCount,
        ambiguousCount = self.ambiguousCount,
        worldUnbindCount = self.worldUnbindCount,
        lastError = self.lastError,
        capabilities = copy(self.capabilities),
    }
end

return RewardItemNativeAdapter
