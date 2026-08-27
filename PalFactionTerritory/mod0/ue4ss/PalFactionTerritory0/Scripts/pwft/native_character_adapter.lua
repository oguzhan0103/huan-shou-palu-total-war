local NativeCharacterAdapter = {}

local SHOP_PROPERTIES = {
    ItemShop = {
        lottery = "itemShopLotteryType",
        row = "itemShopSimpleLotteryTableName",
        restock = "ItemShopRestockMinute",
    },
    PalShop = {
        lottery = "palShopLotteryType",
        row = "palShopSimpleLotteryTableName",
        restock = "PalShopRestockMinute",
    },
}

local function require_non_empty_string(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function is_valid_object(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function safe_full_name(object)
    if not is_valid_object(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or "<unreadable>"
end

local function safe_property(object, name)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[name]
    end)
    return ok and value or nil
end

local function safe_actor_location(actor)
    if not is_valid_object(actor) then
        return nil
    end
    local ok, value = pcall(function()
        return actor:K2_GetActorLocation()
    end)
    if not ok or value == nil then
        return nil
    end
    local x = safe_property(value, "X")
    local y = safe_property(value, "Y")
    local z = safe_property(value, "Z")
    if type(x) ~= "number"
        or type(y) ~= "number"
        or type(z) ~= "number" then
        return nil
    end
    return { X = x, Y = y, Z = z }
end

local function vector_distance(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return nil
    end
    local dx = left.X - right.X
    local dy = left.Y - right.Y
    local dz = left.Z - right.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function safe_unwrap(value)
    if value == nil then
        return nil
    end
    local ok, unwrapped = pcall(function()
        return value:get()
    end)
    if ok and unwrapped ~= nil then
        return unwrapped
    end
    return value
end

local function for_each_native_array(array, callback)
    array = safe_unwrap(array)
    if array == nil then
        return false, "array-unavailable"
    end

    -- Current Palworld/UE4SS returns reflected TArray properties as userdata,
    -- so Lua pairs() is invalid.  Use the same fixed-length indexed route as
    -- the already live-accepted Rayne merchant implementation.  Keeping the
    -- callback in ordinary Lua control flow also avoids UE4SS 3.0.1's native
    -- ForEach traceback/crash edge case.
    local get_array_num = safe_property(array, "GetArrayNum")
    if type(get_array_num) == "function" then
        local count_ok, count = pcall(function()
            return array:GetArrayNum()
        end)
        count = count_ok and tonumber(count) or nil
        if count == nil or count < 0 then
            return false, "array-count-unavailable"
        end
        for index = 1, count do
            local read_ok, element = pcall(function()
                return array[index]
            end)
            if not read_ok then
                return false, "array-index-read-failed:" .. tostring(index)
            end
            local callback_ok, callback_error = pcall(
                callback,
                index,
                element
            )
            if not callback_ok then
                return false,
                    "array-callback-failed:" .. tostring(callback_error)
            end
        end
        return true, nil
    end

    -- Older wrappers may expose only ForEach.  This is a compatibility
    -- fallback; Build 24575825's product array uses GetArrayNum above.
    local for_each = safe_property(array, "ForEach")
    if type(for_each) == "function" then
        local callback_error = nil
        local ok, bridge_error = pcall(function()
            array:ForEach(function(index, element)
                local callback_ok, detail = pcall(
                    callback,
                    index,
                    element
                )
                if not callback_ok then
                    callback_error = detail
                    error(detail)
                end
            end)
        end)
        if not ok then
            return false,
                "array-foreach-failed:"
                    .. tostring(callback_error or bridge_error)
        end
        return true, nil
    end

    -- Plain Lua tables remain supported for offline tests and fixtures.
    if type(array) == "table" then
        for index, element in pairs(array) do
            local callback_ok, callback_error = pcall(
                callback,
                index,
                element
            )
            if not callback_ok then
                return false,
                    "array-callback-failed:" .. tostring(callback_error)
            end
        end
        return true, nil
    end
    return false, "array-iteration-unsupported:" .. type(array)
end

local function native_name_string(value)
    value = safe_unwrap(value)
    if value == nil then return nil end
    local ok, rendered = pcall(function()
        if value.ToString ~= nil then
            return value:ToString()
        end
        return tostring(value)
    end)
    if not ok or rendered == nil then return nil end
    rendered = tostring(rendered)
    rendered = string.gsub(rendered, "^FName:", "")
    rendered = string.gsub(rendered, '^"(.*)"$', "%1")
    return rendered
end

local function native_guid_string(value)
    value = safe_unwrap(value)
    if value == nil then return nil end
    -- UE4SS's reflected Guid is a struct userdata. Reading an absent member
    -- such as ToString raises instead of returning nil, so inspect the four
    -- declared Guid fields first through the protected property helper.
    local words = {
        safe_property(value, "A"),
        safe_property(value, "B"),
        safe_property(value, "C"),
        safe_property(value, "D"),
    }
    local complete = true
    for index = 1, 4 do
        local numeric = tonumber(safe_unwrap(words[index]))
        if numeric == nil then
            complete = false
            break
        end
        words[index] = math.floor(numeric % 4294967296)
    end
    if complete then
        return string.format(
            "%08x-%08x-%08x-%08x",
            words[1],
            words[2],
            words[3],
            words[4]
        )
    end

    local to_string = safe_property(value, "ToString")
    if type(to_string) == "function" then
        local ok, rendered = pcall(function() return value:ToString() end)
        if ok and rendered ~= nil and tostring(rendered) ~= "" then
            return tostring(rendered)
        end
    end
    return nil
end

local function native_object_guid(object, property_name)
    local property_guid = native_guid_string(
        safe_property(object, property_name)
    )
    if property_guid ~= nil then return property_guid end
    if not is_valid_object(object) then return nil end
    -- UE4SS exposes reflected UFunction out parameters as additional Lua
    -- return values.  PalShopBase.GetId has only an OutID parameter in Build
    -- 24575825, so its GUID is normally the second value after the empty
    -- ordinary return slot.  Keep the first-value route for mocks and older
    -- builds, then accept either out-parameter slot.
    local called, reflected_guid, reflected_out_guid, reflected_extra_guid = pcall(function()
        return object:GetId()
    end)
    local resolved = called and (
        native_guid_string(reflected_guid)
        or native_guid_string(reflected_out_guid)
        or native_guid_string(reflected_extra_guid)
    ) or nil
    if resolved ~= nil then return resolved end

    -- Some UE4SS builds require an explicit Lua table for an out parameter.
    -- Keep this last so the normal reflected-property and return-value paths
    -- remain untouched.
    local explicit_out = {}
    local explicit_ok, explicit_return = pcall(function()
        return object:GetId(explicit_out)
    end)
    if not explicit_ok then return nil end
    return native_guid_string(explicit_return)
        or native_guid_string(explicit_out)
end

local function copy_vector(value, defaults)
    assert(type(value) == "table", "spawn vector is required")
    return {
        X = value.X or defaults.X,
        Y = value.Y or defaults.Y,
        Z = value.Z or defaults.Z,
    }
end

local function class_to_asset_path(class_path)
    local package_path, object_name = string.match(
        class_path,
        "^(.*)%.([^%.]+)_C$"
    )
    if package_path == nil or object_name == nil then
        return nil
    end
    return package_path .. "." .. object_name
end

local function class_to_package_path(class_path)
    return string.match(class_path, "^(.*)%.[^%.]+_C$")
end

local function class_token(class_path)
    return string.match(class_path, "%.([^%.]+)$")
end

local function make_result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function NativeCharacterAdapter.create(options)
    options = options or {}
    local instance = {
        version = "1.0.0",
        staticFindObject =
            options.staticFindObject or _G.StaticFindObject,
        loadAsset = options.loadAsset or _G.LoadAsset,
        findAllOf = options.findAllOf or _G.FindAllOf,
        -- UE4SS exposes FName through the Lua global resolver on the live
        -- build, but it is not necessarily materialised as a raw _G field.
        fName = options.fName or FName,
        worldContextProvider = options.worldContextProvider,
        collisionHandlingOverride =
            options.collisionHandlingOverride or 2,
        restockMinutes = options.restockMinutes or 30,
        refreshVendorOnSpawn =
            options.refreshVendorOnSpawn ~= false,
        controllerClassPath = options.controllerClassPath,
        guardControllerClassPath =
            options.guardControllerClassPath,
        guardFollowIntervalMs =
            options.guardFollowIntervalMs or 1000,
        guardAcceptanceRadius =
            options.guardAcceptanceRadius or 350,
        guardFollowMaxFailures =
            options.guardFollowMaxFailures or 8,
        merchantSpawnerClassPath =
            options.merchantSpawnerClassPath,
        merchantDefaultActionClassPath =
            options.merchantDefaultActionClassPath,
        asyncMerchantSpawnerEnabled =
            options.asyncMerchantSpawnerEnabled == true,
        merchantLevel = options.merchantLevel or 30,
        nativeSetupRetryMs =
            options.nativeSetupRetryMs or 500,
        nativeSetupMaxAttempts =
            options.nativeSetupMaxAttempts or 40,
        nativeActorFallbackAttempt =
            options.nativeActorFallbackAttempt or 2,
        nativeActorFallbackRadius =
            options.nativeActorFallbackRadius or 2500,
        executeWithDelay =
            options.executeWithDelay or _G.ExecuteWithDelay,
        loopAsync = options.loopAsync or _G.LoopAsync,
        executeInGameThread =
            options.executeInGameThread or _G.ExecuteInGameThread,
        logger = options.logger,
        records = {},
        -- Recursive ExecuteWithDelay chains accumulate native Lua callback
        -- registry entries on UE4SS 3.0.1.  The live Build 24575825 client
        -- eventually crashed in lua_getiuservalue after 95 guard pulses.  A
        -- single lifecycle-scoped LoopAsync callback owns each durable follow
        -- clock instead.  Keep both closures strongly referenced until process
        -- exit so UE4SS never observes a released callback while unwinding it.
        guardFollowLoopActive = {},
        guardFollowAsyncCallbacks = {},
        guardFollowGameCallbacks = {},
        -- Palworld's AI hate system can retain a valid actor reference after
        -- OnDeadCharacter has already authoritatively fired. Remember those
        -- exact actors so guard follow does not wait for reflected IsDead.
        observedDeadActorNames = {},
        -- SetupInteraction binds BP_InteractableSphere delegates.  Keep a
        -- per-actor latch so a commerce refresh/re-entry cannot bind the same
        -- Blueprint delegate twice; SetActive_Interact_ToAll remains safe to
        -- repeat when an already prepared actor needs reactivation.
        interactionReadyActors = {},
        spawnAttemptCount = 0,
        merchantSpawnCount = 0,
        guardSpawnCount = 0,
        despawnCount = 0,
        failureCount = 0,
        capabilities = {
            directNativeBlueprintSpawn = true,
            palNpcManagerServerSpawn = true,
            nativeMerchantSpawnerLifecycle =
                options.asyncMerchantSpawnerEnabled == true,
            asynchronousMerchantReadiness = true,
            itemShopBinding = true,
            itemShopDynamicProductMutationRoute = true,
            itemShopDynamicPriceMutationRoute = true,
            itemShopDynamicStockMutationRoute = true,
            palShopBinding = true,
            guardBlueprintSpawn = true,
            guardProviderFactory = true,
            guardVisitorLeaderBinding = true,
            guardScopedFollowPulse = true,
            guardCombatPreservation = true,
            guardDeathStop = true,
            noGlobalPermanentLoop = true,
            PalworldSaveMutation = false,
        },
    }
    assert(
        type(instance.collisionHandlingOverride) == "number",
        "collision handling override must be numeric"
    )
    assert(
        type(instance.restockMinutes) == "number"
            and instance.restockMinutes > 0,
        "shop restock minutes must be positive"
    )
    assert(
        type(instance.nativeSetupRetryMs) == "number"
            and instance.nativeSetupRetryMs > 0,
        "native setup retry milliseconds must be positive"
    )
    assert(
        type(instance.nativeSetupMaxAttempts) == "number"
            and instance.nativeSetupMaxAttempts > 0,
        "native setup attempt count must be positive"
    )
    assert(
        type(instance.guardFollowIntervalMs) == "number"
            and instance.guardFollowIntervalMs > 0,
        "guard follow interval must be positive"
    )
    assert(
        type(instance.guardAcceptanceRadius) == "number"
            and instance.guardAcceptanceRadius > 0,
        "guard acceptance radius must be positive"
    )
    assert(
        type(instance.guardFollowMaxFailures) == "number"
            and instance.guardFollowMaxFailures > 0,
        "guard follow failure limit must be positive"
    )
    -- UE4SS can report an inherited Lua method as unavailable when queried
    -- through type(instance.method).  Publish the post-registration refresh
    -- as an explicit instance field so the commerce runtime always performs
    -- the second SetupShopData/network bind after it registers the faction.
    instance.refresh_merchant_shop = function(adapter, actor, plan)
        return NativeCharacterAdapter.refresh_merchant_shop(
            adapter,
            actor,
            plan
        )
    end
    return setmetatable(
        instance,
        { __index = NativeCharacterAdapter }
    )
end

function NativeCharacterAdapter:_log(message)
    if type(self.logger) == "function" then
        self.logger(
            "[NativeCharacterAdapter] " .. tostring(message)
        )
    end
end

function NativeCharacterAdapter:_resolve_world_context()
    if type(self.worldContextProvider) == "function" then
        local ok, context_or_error = pcall(
            self.worldContextProvider
        )
        if ok and is_valid_object(context_or_error) then
            return context_or_error, nil
        end
        return nil, "world-context-provider-failed:"
            .. tostring(context_or_error)
    end
    if type(self.findAllOf) ~= "function" then
        return nil, "FindAllOf-unavailable"
    end
    for _, class_name in ipairs({
        "PalPlayerController",
        "PlayerController",
    }) do
        local ok, controllers = pcall(
            self.findAllOf,
            class_name
        )
        if ok and type(controllers) == "table" then
            for _, controller in pairs(controllers) do
                if is_valid_object(controller) then
                    local local_ok, is_local = pcall(function()
                        if controller.IsLocalPlayerController ~= nil then
                            return controller:IsLocalPlayerController()
                        end
                        return true
                    end)
                    if local_ok and is_local then
                        return controller, nil
                    end
                end
            end
        end
    end
    return nil, "local-player-controller-unavailable"
end

function NativeCharacterAdapter:_find_default_object(path)
    if type(self.staticFindObject) ~= "function" then
        return nil, "StaticFindObject-unavailable"
    end
    local ok, object_or_error = pcall(
        self.staticFindObject,
        path
    )
    if not ok or not is_valid_object(object_or_error) then
        return nil, "default-object-unavailable:" .. path
            .. ":" .. tostring(object_or_error)
    end
    return object_or_error, nil
end

function NativeCharacterAdapter:_load_class(class_path)
    require_non_empty_string(
        class_path,
        "native character class path"
    )
    if type(self.staticFindObject) ~= "function" then
        return nil, "StaticFindObject-unavailable"
    end
    local ok, class_or_error = pcall(
        self.staticFindObject,
        class_path
    )
    if ok and is_valid_object(class_or_error) then
        return class_or_error, nil
    end
    local asset_path = class_to_asset_path(class_path)
    local package_path = class_to_package_path(class_path)
    if asset_path == nil or package_path == nil then
        return nil, "invalid-native-class-path:" .. class_path
    end
    if type(self.loadAsset) == "function" then
        for _, load_path in ipairs({
            asset_path,
            package_path,
            class_path,
        }) do
            local loaded_ok, loaded = pcall(
                self.loadAsset,
                load_path
            )
            if loaded_ok and is_valid_object(loaded) then
                local generated_class = safe_property(
                    loaded,
                    "GeneratedClass"
                )
                if is_valid_object(generated_class) then
                    return generated_class, nil
                end
                local loaded_name = safe_full_name(loaded)
                local expected_token = class_token(class_path)
                if expected_token ~= nil
                    and string.find(
                        loaded_name,
                        expected_token,
                        1,
                        true
                    ) ~= nil then
                    return loaded, nil
                end
            end
            ok, class_or_error = pcall(
                self.staticFindObject,
                class_path
            )
            if ok and is_valid_object(class_or_error) then
                return class_or_error, nil
            end
        end
    end
    return nil, "native-character-class-unavailable:"
        .. class_path
end

function NativeCharacterAdapter:_make_name(value)
    require_non_empty_string(value, "native name value")
    if type(self.fName) == "function" then
        local ok, native_name = pcall(self.fName, value)
        if ok and native_name ~= nil then
            return native_name, nil
        end
    end
    local string_library, library_error =
        self:_find_default_object(
            "/Script/Engine.Default__KismetStringLibrary"
        )
    if string_library == nil then
        return nil, "native-name-construction-unavailable:"
            .. tostring(library_error)
    end
    local ok, native_name = pcall(function()
        return string_library:Conv_StringToName(value)
    end)
    if not ok or native_name == nil then
        return nil, "native-name-conversion-failed:"
            .. tostring(native_name)
    end
    return native_name, nil
end

function NativeCharacterAdapter:_make_transform(plan)
    local math_library, library_error =
        self:_find_default_object(
            "/Script/Engine.Default__KismetMathLibrary"
        )
    if math_library == nil then
        return nil, library_error
    end
    local location = copy_vector(
        plan.location,
        { X = 0, Y = 0, Z = 0 }
    )
    local rotation = copy_vector(
        plan.rotation or {},
        { X = 0, Y = 0, Z = 0 }
    )
    rotation = {
        Pitch = plan.rotation
                and plan.rotation.Pitch
            or 0,
        Yaw = plan.rotation
                and plan.rotation.Yaw
            or 0,
        Roll = plan.rotation
                and plan.rotation.Roll
            or 0,
    }
    local ok, transform_or_error = pcall(function()
        return math_library:MakeTransform(
            location,
            rotation,
            { X = 1.0, Y = 1.0, Z = 1.0 }
        )
    end)
    if not ok or transform_or_error == nil then
        return nil, "spawn-transform-construction-failed:"
            .. tostring(transform_or_error)
    end
    return transform_or_error, nil
end

function NativeCharacterAdapter:_configure_vendor(actor, plan)
    if plan.salesChannel ~= "ItemShop"
        and plan.salesChannel ~= "PalShop" then
        return false, "unsupported-sales-channel:"
            .. tostring(plan.salesChannel)
    end
    local vendor = safe_property(
        actor,
        "BP_PalShopVenderDataComponent"
    )
    if not is_valid_object(vendor) then
        return false, "vendor-component-unavailable"
    end
    local properties = SHOP_PROPERTIES[plan.salesChannel]
    local lottery_property = properties.lottery
    local row_property = properties.row
    local restock_property = properties.restock
    local row_name = safe_property(vendor, row_property)
    if row_name == nil then
        return false, "shop-row-struct-unavailable:"
            .. row_property
    end
    local native_row_name, name_error =
        self:_make_name(plan.shopRowName)
    if native_row_name == nil then
        return false, name_error
    end
    local ok, configure_error = pcall(function()
        vendor[lottery_property] = 1
        row_name.Key = native_row_name
        vendor[restock_property] = self.restockMinutes
    end)
    if not ok then
        return false, "vendor-configuration-failed:"
            .. tostring(configure_error)
    end
    if self.refreshVendorOnSpawn then
        if plan.salesChannel == "ItemShop" then
            local previous_shop = safe_property(
                vendor,
                "MyItemShop"
            )
            local cleared, clear_error = pcall(function()
                vendor.MyItemShop = nil
            end)
            if not cleared then
                return false, "item-shop-reset-failed:"
                    .. tostring(clear_error)
            end
            self:_log(string.format(
                "MERCHANT_ITEM_SHOP_RESET actor=%s previous=%s row=%s",
                safe_full_name(actor),
                safe_full_name(previous_shop),
                tostring(plan.shopRowName)
            ))
        end
        local refreshed, refresh_error = pcall(function()
            -- Reflected Blueprint/native functions are callable through
            -- UE4SS __namecall even when reading the member does not yield a
            -- Lua value whose type is "function".
            vendor:SetupShopData()
        end)
        if not refreshed then
            return false, "vendor-refresh-failed:"
                .. tostring(refresh_error)
        end
    end
    return true, nil
end

-- Build 24575825 exposes PalShopBase.ProductArray and the static-item giver's
-- ProductStaticItemID, OverridePrice, StockNum and MaxStockNum.  Mutate only
-- the nine audited economy products already present in this merchant's
-- cooked row; every unrelated native product is left untouched.  A product
-- that changed from sell to procure stays in the native row with zero stock,
-- while the confirmed native sell-replication bridge handles the procurement
-- request.  This edits the transient server shop object, never Palworld save
-- data or the static DataTable.
function NativeCharacterAdapter:apply_dynamic_item_shop_market(actor, plan)
    if not is_valid_object(actor) then
        return false, "merchant-actor-unavailable"
    end
    if type(plan) ~= "table" or plan.salesChannel ~= "ItemShop" then
        return false, "dynamic-item-shop-plan-unavailable"
    end
    if plan.dynamicMarketEnabled ~= true then
        return false, "dynamic-item-shop-disabled"
    end
    local vendor = safe_property(
        actor,
        "BP_PalShopVenderDataComponent"
    )
    if not is_valid_object(vendor) then
        return false, "vendor-component-unavailable"
    end
    local shop = safe_unwrap(safe_property(vendor, "MyItemShop"))
    if not is_valid_object(shop) then
        return false, "item-shop-unavailable"
    end
    local product_array = safe_property(shop, "ProductArray")
    if product_array == nil then
        return false, "item-shop-product-array-unavailable"
    end

    local sell_by_item = {}
    local procure_by_item = {}
    local audited_items = {}
    for _, item_id in ipairs(plan.marketUniverseItemIds or {}) do
        audited_items[item_id] = true
    end
    for _, row in ipairs(plan.products or {}) do
        sell_by_item[row.itemId] = row
        audited_items[row.itemId] = true
    end
    for _, row in ipairs(plan.requested or {}) do
        procure_by_item[row.itemId] = row
        audited_items[row.itemId] = true
    end

    local inspected = 0
    local matched = 0
    local changed = 0
    local failed = 0
    local sell_lines = 0
    local procurement_lines = 0
    local observed_items = {}
    local iterated, iteration_error = for_each_native_array(
        product_array,
        function(_, remote_product)
            local product = safe_unwrap(remote_product)
            if is_valid_object(product) then
                inspected = inspected + 1
                local giver = safe_unwrap(
                    safe_property(product, "MyProductGiver")
                )
                if is_valid_object(giver) then
                    local item_id = native_name_string(
                        safe_property(giver, "ProductStaticItemID")
                    )
                    if item_id ~= nil then
                        observed_items[item_id] = true
                    end
                    local sell = item_id and sell_by_item[item_id] or nil
                    local procure = item_id
                            and procure_by_item[item_id]
                        or nil
                    if item_id ~= nil
                        and audited_items[item_id] == true
                        and (sell ~= nil or procure ~= nil) then
                        matched = matched + 1
                        local price = sell and sell.price
                            or procure.targetPrice
                        local stock = sell and sell.stock or 0
                        local mutation_ok, mutation_error = pcall(function()
                            giver.OverridePrice = price
                            giver.bIsInfinityStockFlag = false
                            giver.StockNum = stock
                            giver.MaxStockNum = stock
                            local create_data = safe_property(
                                giver,
                                "ProductCreateData"
                            )
                            local item_data = create_data and safe_property(
                                create_data,
                                "ItemShopCreateData"
                            )
                            if item_data ~= nil then
                                item_data.OverridePrice = price
                                item_data.Stock = stock
                            end
                        end)
                        if mutation_ok then
                            changed = changed + 1
                            if sell ~= nil then
                                sell_lines = sell_lines + 1
                            else
                                procurement_lines = procurement_lines + 1
                            end
                            pcall(function() giver:OnRep_StockNum() end)
                            pcall(function() giver:OnRep_MaxStockNum() end)
                            pcall(function()
                                product:OnUpdateProductStock(stock)
                            end)
                            pcall(function()
                                product:OnUpdateProductMaxStock(stock)
                            end)
                        else
                            failed = failed + 1
                            self:_log(string.format(
                                "DYNAMIC_ITEM_SHOP_PRODUCT_FAILED item=%s error=%s",
                                tostring(item_id),
                                tostring(mutation_error)
                            ))
                        end
                    end
                end
            end
        end
    )
    if not iterated then
        return false, "item-shop-product-array-iteration-failed:"
            .. tostring(iteration_error)
    end
    pcall(function() shop:OnRep_ProductArray() end)
    local reason = changed > 0 and failed == 0
            and "dynamic-item-shop-applied"
        or changed > 0
            and "dynamic-item-shop-partial"
        or "no-dynamic-product-match"
    self:_log(string.format(
        "DYNAMIC_ITEM_SHOP_MARKET_APPLIED actor=%s faction=%s ok=%s reason=%s revision=%s inspected=%d matched=%d changed=%d failed=%d sell=%d procureSoldOut=%d",
        safe_full_name(actor),
        tostring(plan.factionId),
        tostring(changed > 0 and failed == 0),
        reason,
        tostring(plan.resourceLedgerRevision or "none"),
        inspected,
        matched,
        changed,
        failed,
        sell_lines,
        procurement_lines
    ))
    return changed > 0 and failed == 0, reason, {
        shop = shop,
        inspectedCount = inspected,
        matchedCount = matched,
        changedCount = changed,
        failedCount = failed,
        sellLineCount = sell_lines,
        procurementSoldOutLineCount = procurement_lines,
        observedItems = observed_items,
    }
end

-- Bind one already-authored ItemShop product to an open unique-Pal ransom.
-- The product and shop GUIDs are read from the transient authoritative shop
-- object after SetupShopData; only the matched product's price/stock fields
-- are changed. No DataTable or Palworld save payload is written.
function NativeCharacterAdapter:configure_unique_pal_ransom_product(
    actor,
    offer
)
    if not is_valid_object(actor) then
        return nil, "merchant-actor-unavailable"
    end
    if type(offer) ~= "table"
        or type(offer.productItemId) ~= "string"
        or offer.productItemId == ""
        or type(offer.unitPrice) ~= "number"
        or offer.unitPrice <= 0 then
        return nil, "invalid-unique-pal-ransom-offer"
    end
    local vendor = safe_unwrap(safe_property(
        actor,
        "BP_PalShopVenderDataComponent"
    ))
    if not is_valid_object(vendor) then
        return nil, "vendor-component-unavailable"
    end
    local shop = safe_unwrap(safe_property(vendor, "MyItemShop"))
    if not is_valid_object(shop) then
        return nil, "item-shop-unavailable"
    end
    local shop_id = native_object_guid(shop, "MyShopID")
        or native_guid_string(safe_property(vendor, "MyShopID"))
    if shop_id == nil then return nil, "item-shop-id-unavailable" end
    local product_array = safe_property(shop, "ProductArray")
    if product_array == nil then
        return nil, "item-shop-product-array-unavailable"
    end
    local product_id = nil
    local mutation_error = nil
    local iterated, iteration_error = for_each_native_array(
        product_array,
        function(_, remote_product)
            if product_id ~= nil then return end
            local product = safe_unwrap(remote_product)
            if not is_valid_object(product) then return end
            local giver = safe_unwrap(safe_property(
                product,
                "MyProductGiver"
            ))
            if not is_valid_object(giver) then return end
            local item_id = native_name_string(safe_property(
                giver,
                "ProductStaticItemID"
            ))
            if item_id ~= offer.productItemId then return end
            local price = math.floor(offer.unitPrice)
            local stock = math.floor(offer.buyQuantity or 1)
            local changed, detail = pcall(function()
                giver.OverridePrice = price
                giver.bIsInfinityStockFlag = false
                giver.StockNum = stock
                giver.MaxStockNum = stock
                local create_data = safe_property(giver, "ProductCreateData")
                local item_data = create_data and safe_property(
                    create_data,
                    "ItemShopCreateData"
                ) or nil
                if item_data ~= nil then
                    item_data.OverridePrice = price
                    item_data.Stock = stock
                end
                pcall(function() giver:OnRep_StockNum() end)
                pcall(function() giver:OnRep_MaxStockNum() end)
                pcall(function() product:OnUpdateProductStock(stock) end)
                pcall(function() product:OnUpdateProductMaxStock(stock) end)
            end)
            if not changed then
                mutation_error = tostring(detail)
                return
            end
            product_id = native_object_guid(product, "MyProductID")
        end
    )
    if not iterated then
        return nil, "item-shop-product-array-iteration-failed:"
            .. tostring(iteration_error)
    end
    if product_id == nil then
        return nil, mutation_error ~= nil
                and "unique-pal-ransom-product-mutation-failed:"
                    .. mutation_error
            or "unique-pal-ransom-product-unavailable:"
                .. offer.productItemId
    end
    pcall(function() shop:OnRep_ProductArray() end)
    self:_log(string.format(
        "UNIQUE_PAL_RANSOM_PRODUCT_READY actor=%s item=%s shop=%s product=%s price=%d stock=1",
        safe_full_name(actor),
        offer.productItemId,
        shop_id,
        product_id,
        math.floor(offer.unitPrice)
    ))
    return {
        shopId = shop_id,
        productId = product_id,
        productItemId = offer.productItemId,
        unitPrice = math.floor(offer.unitPrice),
        buyQuantity = 1,
        singlePurchaseStock = true,
        serverAuthoritativePrice = true,
        serverAuthoritativePaymentResult = true,
    }, nil
end

function NativeCharacterAdapter:_ensure_default_controller(actor)
    local controller = nil
    local read_ok = pcall(function()
        controller = actor:GetController()
    end)
    if read_ok and is_valid_object(controller) then
        return controller, "existing"
    end

    -- UE4SS can resolve reflected/native functions through __namecall even
    -- when reading the same member as a Lua property yields nil.  Calling the
    -- method directly is therefore the authoritative capability probe.
    local spawned, spawn_error = pcall(function()
        actor:SpawnDefaultController()
    end)
    if not spawned then
        return nil, "SpawnDefaultController-unavailable-or-failed:"
            .. tostring(spawn_error)
    end
    local reread_ok = pcall(function()
        controller = actor:GetController()
    end)
    if reread_ok and is_valid_object(controller) then
        return controller, "spawned"
    end
    return nil, "controller-not-ready"
end

function NativeCharacterAdapter:_configure_salesperson_controller(
    controller,
    plan
)
    if not is_valid_object(controller) then
        return false, "merchant-controller-unavailable"
    end
    local action_class_path = plan.defaultActionClassPath
        or self.merchantDefaultActionClassPath
    require_non_empty_string(
        action_class_path,
        "merchant default action class path"
    )
    local action_class, action_error =
        self:_load_class(action_class_path)
    if action_class == nil then
        return false, action_error
    end
    local property_ok, property_error = pcall(function()
        controller.DefaultActionClass = action_class
    end)
    local override_ok, override_error = pcall(function()
        controller:OverrideDefaultAction(action_class)
    end)
    if not property_ok and not override_ok then
        return false, "salesperson-action-override-failed:"
            .. tostring(property_error)
            .. "|" .. tostring(override_error)
    end
    -- ReceiveBeginPlay normally calls SetAutoDefaultAIAction for an NPC
    -- controller created by a native Pal spawner.  A directly spawned pawn
    -- already passed that point before this adapter replaces the action
    -- class, so run the same Blueprint setup explicitly before starting it.
    local auto_ok, auto_error = pcall(function()
        controller:SetAutoDefaultAIAction()
    end)
    -- A directly spawned controller may already have started its Blueprint
    -- default action. Restart it after the override so the merchant enters
    -- the same salesperson action used by authored shop NPC spawners.
    local start_ok, start_error = pcall(function()
        controller:StartDefaultAIAction()
    end)
    self:_log(string.format(
        "SALESPERSON_ACTION_CONFIGURED controller=%s property=%s override=%s auto=%s autoDetail=%s start=%s startDetail=%s action=%s",
        safe_full_name(controller),
        tostring(property_ok),
        tostring(override_ok),
        tostring(auto_ok),
        tostring(auto_error),
        tostring(start_ok),
        tostring(start_error),
        tostring(action_class_path)
    ))
    return true, nil
end

function NativeCharacterAdapter:_initialize_merchant_interaction(actor)
    local interaction = safe_property(
        actor,
        "BP_NPCInteractionComponent"
    )
    if not is_valid_object(interaction) then
        return false, "npc-interaction-component-unavailable"
    end
    local sphere = safe_property(actor, "BP_InteractableSphere")
    if not is_valid_object(sphere) then
        return false, "npc-interactable-sphere-unavailable"
    end

    local already_bound =
        self.interactionReadyActors[actor] == true
    local flags_ok = true
    local flags_error = "already-bound"
    local initialize_ok = true
    local initialize_error = "already-bound"
    local replicate_ok = true
    local replicate_error = "already-bound"
    local setup_ok = true
    local setup_error = "already-bound"
    if not already_bound then
        flags_ok, flags_error = pcall(function()
            interaction.bDisableTalk = false
            interaction.bDisableTalkWhenCaptured = false
        end)
        initialize_ok, initialize_error = pcall(function()
            interaction:Initialize()
        end)
        replicate_ok, replicate_error = pcall(function()
            interaction:OnRep_DisableTalk()
        end)
        -- BP_NPC_Base_C.SetupInteraction is the authored path that binds
        -- BP_InteractableSphere.OnTriggerInteract and installs the indicator
        -- interface.  Component Initialize alone does not create that route.
        setup_ok, setup_error = pcall(function()
            actor:SetupInteraction()
        end)
    end
    local active_ok, active_error = pcall(function()
        actor:SetActive_Interact_ToAll(true)
    end)
    self:_log(string.format(
        "MERCHANT_INTERACTION_INITIALIZED actor=%s component=%s flags=%s flagsDetail=%s initialize=%s initializeDetail=%s replicate=%s replicateDetail=%s disableTalk=%s capturedDisable=%s",
        safe_full_name(actor),
        safe_full_name(interaction),
        tostring(flags_ok),
        tostring(flags_error),
        tostring(initialize_ok),
        tostring(initialize_error),
        tostring(replicate_ok),
        tostring(replicate_error),
        tostring(safe_property(interaction, "bDisableTalk")),
        tostring(safe_property(
            interaction,
            "bDisableTalkWhenCaptured"
        ))
    ))
    self:_log(string.format(
        "MERCHANT_INTERACTION_ROUTE_READY actor=%s sphere=%s alreadyBound=%s setup=%s setupDetail=%s active=%s activeDetail=%s",
        safe_full_name(actor),
        safe_full_name(sphere),
        tostring(already_bound),
        tostring(setup_ok),
        tostring(setup_error),
        tostring(active_ok),
        tostring(active_error)
    ))
    if not flags_ok or not initialize_ok
        or not setup_ok or not active_ok then
        return false, "npc-interaction-initialize-failed:"
            .. tostring(flags_error)
            .. "|" .. tostring(initialize_error)
            .. "|" .. tostring(setup_error)
            .. "|" .. tostring(active_error)
    end
    self.interactionReadyActors[actor] = true
    return true, nil
end

function NativeCharacterAdapter:_request_network_shop_setup(actor)
    local utility, utility_error = self:_find_default_object(
        "/Script/Pal.Default__PalUtility"
    )
    if utility == nil then
        return false, utility_error
    end
    local transmitter_ok, transmitter = pcall(function()
        return utility:GetNetworkTransmitter(actor)
    end)
    if not transmitter_ok or not is_valid_object(transmitter) then
        return false, "network-transmitter-unavailable:"
            .. tostring(transmitter)
    end
    local shop_ok, network_shop = pcall(function()
        return transmitter:GetShop()
    end)
    if not shop_ok or not is_valid_object(network_shop) then
        network_shop = safe_property(transmitter, "Shop")
    end
    if not is_valid_object(network_shop) then
        return false, "network-shop-component-unavailable"
    end
    local setup_ok, setup_error = pcall(function()
        network_shop:SetupShopDataForActor_ToServer(actor)
    end)
    if not setup_ok then
        return false, "network-shop-setup-failed:"
            .. tostring(setup_error)
    end
    return true, safe_full_name(network_shop)
end

function NativeCharacterAdapter:refresh_merchant_shop(actor, plan)
    if not is_valid_object(actor) then
        return false, "merchant-actor-unavailable"
    end
    if type(plan) ~= "table" then
        return false, "merchant-plan-unavailable"
    end
    local configured, configure_error =
        self:_configure_vendor(actor, plan)
    if not configured then
        return false, configure_error
    end
    local requested, detail =
        self:_request_network_shop_setup(actor)
    -- SetupShopDataForActor_ToServer may replace the transient PalShopBase
    -- produced by the vendor component.  Apply prices and stock only after
    -- that authoritative server shop exists; otherwise the values and the
    -- Product GUID belong to the retired pre-network object.
    local dynamic_ok = nil
    local dynamic_detail = "dynamic-item-shop-not-requested"
    if plan.dynamicMarketEnabled == true then
        local applied, reason = self:apply_dynamic_item_shop_market(
            actor,
            plan
        )
        dynamic_ok = applied
        dynamic_detail = reason
        -- Keep the previously accepted static shop available if a future
        -- game build removes one reflected field.  The explicit failure log
        -- prevents the dynamic acceptance layer from claiming success.
        if not applied then
            self:_log(string.format(
                "DYNAMIC_ITEM_SHOP_REFRESH_FAILED actor=%s faction=%s reason=%s staticFallback=true",
                safe_full_name(actor),
                tostring(plan.factionId),
                tostring(reason)
            ))
        end
    end
    self:_log(string.format(
        "MERCHANT_SHOP_REFRESHED actor=%s row=%s requested=%s detail=%s dynamic=%s dynamicDetail=%s",
        safe_full_name(actor),
        tostring(plan.shopRowName),
        tostring(requested),
        tostring(detail),
        tostring(dynamic_ok),
        tostring(dynamic_detail)
    ))
    return requested, tostring(detail)
        .. "|dynamic=" .. tostring(dynamic_ok)
        .. ":" .. tostring(dynamic_detail)
end

function NativeCharacterAdapter:_destroy_untracked(actor)
    if not is_valid_object(actor) then
        return
    end
    pcall(function()
        actor:K2_DestroyActor()
    end)
end

function NativeCharacterAdapter:_configure_merchant_spawner(
    spawner,
    plan,
    controller_class,
    default_action_class
)
    local save_key = plan.spawnerSaveKey
        or ("PFT_Economy_" .. string.gsub(
            plan.runtimeId,
            "[^%w_]",
            "_"
        ))
    local save_name, save_name_error = self:_make_name(save_key)
    local character_name, character_name_error =
        self:_make_name(plan.characterId)
    local unique_name, unique_name_error = self:_make_name(
        plan.uniqueNpcId or plan.characterId
    )
    if save_name == nil
        or character_name == nil
        or unique_name == nil then
        return false, save_name_error
            or character_name_error
            or unique_name_error
    end
    local ok, configure_error = pcall(function()
        spawner.IsBossSpawner = false
        spawner.Ignore_FarCheck = true
        spawner.Ignore_DistanceLocationReset = true
        spawner.IgnoreBaseCampCheck = true
        spawner.Debug_Disable = false
        spawner.SaveKeyName = save_name
        spawner.CharaName = character_name
        spawner.UniqueNPCID = unique_name
        spawner.ControllerClass = controller_class
        spawner.DefaultActionClass = default_action_class
        spawner.Level = plan.merchantLevel or self.merchantLevel
    end)
    if not ok then
        return false, "native-spawner-template-write-failed:"
            .. tostring(configure_error)
    end
    return true, nil
end

function NativeCharacterAdapter:_find_spawner_actor(record)
    if not is_valid_object(record.spawner) then
        return nil, nil, "native-spawner-unavailable"
    end
    local handle = safe_property(record.spawner, "SpawnedHandle")
    if is_valid_object(handle) then
        local actor_ok, actor = pcall(function()
            return handle:TryGetIndividualActor()
        end)
        if actor_ok and is_valid_object(actor) then
            return actor, handle, "spawner-handle"
        end
    end
    if record.attempt < self.nativeActorFallbackAttempt
        or type(self.findAllOf) ~= "function" then
        return nil, handle, "native-handle-not-ready"
    end
    local token = class_token(record.characterClassPath)
    if token == nil then
        return nil, handle, "native-character-token-unavailable"
    end
    local scan_ok, actors = pcall(self.findAllOf, token)
    if not scan_ok or type(actors) ~= "table" then
        return nil, handle, "native-actor-scan-failed:"
            .. tostring(actors)
    end
    local nearest = nil
    local nearest_distance_squared = nil
    for _, actor in pairs(actors) do
        if is_valid_object(actor)
            and string.find(
                safe_full_name(actor),
                token,
                1,
                true
            ) ~= nil then
            local vendor = safe_property(
                actor,
                "BP_PalShopVenderDataComponent"
            )
            local location_ok, location = pcall(function()
                return actor:K2_GetActorLocation()
            end)
            if is_valid_object(vendor)
                and location_ok
                and location ~= nil then
                local dx = location.X - record.location.X
                local dy = location.Y - record.location.Y
                local dz = location.Z - record.location.Z
                local distance_squared = dx * dx + dy * dy + dz * dz
                if nearest_distance_squared == nil
                    or distance_squared < nearest_distance_squared then
                    nearest = actor
                    nearest_distance_squared = distance_squared
                end
            end
        end
    end
    if nearest == nil then
        return nil, handle, "native-actor-scan-empty"
    end
    local maximum = self.nativeActorFallbackRadius
        * self.nativeActorFallbackRadius
    if nearest_distance_squared > maximum then
        return nil, handle, "native-actor-scan-too-far:"
            .. tostring(math.sqrt(nearest_distance_squared))
    end
    return nearest, handle, "nearby-scan:distance="
        .. tostring(math.sqrt(nearest_distance_squared))
end

function NativeCharacterAdapter:_complete_async_merchant(
    record,
    actor,
    handle,
    actor_source
)
    local expected_token = record.plan.expectedActorClassToken
        or class_token(record.characterClassPath)
    local actor_name = safe_full_name(actor)
    if expected_token == nil
        or string.find(actor_name, expected_token, 1, true) == nil then
        return false, "native-character-class-mismatch:"
            .. actor_name
    end
    local configured, configure_error =
        self:_configure_vendor(actor, record.plan)
    if not configured then
        return false, configure_error
    end
    local network_setup, network_detail =
        self:_request_network_shop_setup(actor)
    local controller = nil
    pcall(function()
        controller = actor:GetController()
    end)
    record.actor = actor
    record.handle = handle
    record.pending = false
    record.ready = true
    record.controller = controller
    record.controllerSource = "native-spawner"
    record.networkSetup = network_setup
    record.networkDetail = network_detail
    self.merchantSpawnCount = self.merchantSpawnCount + 1
    self:_log(string.format(
        "NATIVE_MERCHANT_READY runtime=%s actor=%s actorSource=%s controller=%s networkSetup=%s networkDetail=%s shopRow=%s salesChannel=%s",
        record.runtimeId,
        actor_name,
        tostring(actor_source),
        safe_full_name(controller),
        tostring(network_setup),
        tostring(network_detail),
        tostring(record.plan.shopRowName),
        tostring(record.plan.salesChannel)
    ))
    if type(record.callbacks.onReady) == "function" then
        local callback_ok, callback_error = pcall(
            record.callbacks.onReady,
            actor,
            record
        )
        if not callback_ok then
            self:_log(
                "NATIVE_MERCHANT_READY_CALLBACK_FAILED runtime="
                    .. record.runtimeId
                    .. " reason=" .. tostring(callback_error)
            )
        end
    end
    return true, nil
end

function NativeCharacterAdapter:_schedule_npc_manager_merchant_poll(record)
    if type(self.executeWithDelay) ~= "function" then
        self:_fail_async_merchant(
            record,
            "ExecuteWithDelay-unavailable"
        )
        return
    end
    local callback = function()
        local execute = function()
            if record.cancelled or record.ready or record.failed then
                return
            end
            record.attempt = record.attempt + 1
            local actor = nil
            local reason = "native-manager-spawn-callback-pending"
            if not is_valid_object(record.handle)
                and record.spawnId ~= nil then
                local handle_ok, handle_or_error = pcall(function()
                    return record.characterManager:GetIndividualHandle(
                        record.spawnId
                    )
                end)
                if handle_ok and is_valid_object(handle_or_error) then
                    record.handle = handle_or_error
                    if not record.handleReadyLogged then
                        record.handleReadyLogged = true
                        self:_log(string.format(
                            "NATIVE_MANAGER_MERCHANT_HANDLE_READY runtime=%s source=spawn-callback-id handle=%s",
                            record.runtimeId,
                            safe_full_name(record.handle)
                        ))
                    end
                elseif not handle_ok then
                    reason = "native-manager-handle-resolve-failed:"
                        .. tostring(handle_or_error)
                else
                    reason = "native-manager-handle-not-ready"
                end
            end
            local actor_ok = false
            local actor_or_error = nil
            if is_valid_object(record.handle) then
                actor_ok, actor_or_error = pcall(function()
                    return record.handle:TryGetIndividualActor()
                end)
                reason = "native-manager-actor-not-ready"
            end
            if actor_ok and is_valid_object(actor_or_error) then
                actor = actor_or_error
                local complete, complete_error =
                    self:_complete_async_merchant(
                        record,
                        actor,
                        record.handle,
                        "PalNPCManager.SpawnNPCForServer"
                    )
                if complete then
                    return
                end
                reason = complete_error
            elseif is_valid_object(record.handle) and not actor_ok then
                reason = "native-manager-handle-read-failed:"
                    .. tostring(actor_or_error)
            end
            if record.attempt >= self.nativeSetupMaxAttempts then
                self:_fail_async_merchant(record, reason)
                return
            end
            if record.attempt == 1
                or record.attempt % 5 == 0 then
                self:_log(string.format(
                    "NATIVE_MANAGER_MERCHANT_RETRY runtime=%s attempt=%d reason=%s",
                    record.runtimeId,
                    record.attempt,
                    tostring(reason)
                ))
            end
            self:_schedule_npc_manager_merchant_poll(record)
        end
        if type(self.executeInGameThread) == "function" then
            -- ExecuteInGameThread registers the Lua function with UE4SS and
            -- may run it on a later engine tick.  The outer delay callback is
            -- retained in pollCallbacks, but that does not retain this inner
            -- closure after the outer callback returns.  Keep it on the
            -- lifecycle-scoped record so UE4SS never observes a collected
            -- registry reference while resolving a merchant.
            table.insert(record.gameThreadCallbacks, execute)
            self.executeInGameThread(execute)
        else
            execute()
        end
    end
    table.insert(record.pollCallbacks, callback)
    self.executeWithDelay(self.nativeSetupRetryMs, callback)
end

function NativeCharacterAdapter:spawn_merchant_via_npc_manager(
    plan,
    callbacks
)
    assert(type(plan) == "table", "native spawn plan is required")
    callbacks = callbacks or {}
    local runtime_id = require_non_empty_string(
        plan.runtimeId,
        "native spawn runtime ID"
    )
    require_non_empty_string(plan.characterId, "native character ID")
    require_non_empty_string(
        plan.characterClassPath,
        "native character class path"
    )
    require_non_empty_string(plan.shopRowName, "native shop row name")
    assert(
        type(plan.location) == "table",
        "native character location is required"
    )
    if self.records[runtime_id] ~= nil then
        error("native-runtime-id-already-active:" .. runtime_id)
    end
    self.spawnAttemptCount = self.spawnAttemptCount + 1
    local world_context, context_error = self:_resolve_world_context()
    if world_context == nil then
        self.failureCount = self.failureCount + 1
        error(context_error)
    end
    local utility, utility_error = self:_find_default_object(
        "/Script/Pal.Default__PalUtility"
    )
    if utility == nil then
        self.failureCount = self.failureCount + 1
        error(utility_error)
    end
    local manager_ok, npc_manager = pcall(function()
        return utility:GetNPCManager(world_context)
    end)
    if not manager_ok or not is_valid_object(npc_manager) then
        self.failureCount = self.failureCount + 1
        error("NPC-manager-unavailable:" .. tostring(npc_manager))
    end
    local character_manager_ok, character_manager = pcall(function()
        return utility:GetCharacterManager(world_context)
    end)
    if not character_manager_ok
        or not is_valid_object(character_manager) then
        self.failureCount = self.failureCount + 1
        error("character-manager-unavailable:"
            .. tostring(character_manager))
    end
    local controller_class = safe_property(
        npc_manager,
        "NPCAIControllerBaseClass"
    )
    if not is_valid_object(controller_class) then
        self.failureCount = self.failureCount + 1
        error("NPC-controller-class-unavailable")
    end
    local character_name, name_error =
        self:_make_name(plan.characterId)
    if character_name == nil then
        self.failureCount = self.failureCount + 1
        error(name_error)
    end
    local record = {
        runtimeId = runtime_id,
        actor = nil,
        handle = nil,
        spawnId = nil,
        spawnCallback = nil,
        characterManager = character_manager,
        spawner = nil,
        nativeManagerSpawn = true,
        characterId = plan.characterId,
        characterClassPath = plan.characterClassPath,
        merchant = true,
        pending = true,
        ready = false,
        failed = false,
        cancelled = false,
        attempt = 0,
        location = copy_vector(
            plan.location,
            { X = 0, Y = 0, Z = 0 }
        ),
        plan = plan,
        callbacks = callbacks,
        pollCallbacks = {},
        gameThreadCallbacks = {},
    }
    -- NPCSpawnCallback__DelegateSignature returns an FPalInstanceID, not
    -- the PalIndividualCharacterHandle.  Keep this closure alive on the
    -- record, then resolve the handle through PalCharacterManager.
    record.spawnCallback = function(id_parameter)
        if record.cancelled or record.failed then
            return
        end
        local spawn_id = safe_unwrap(id_parameter)
        if spawn_id == nil then
            self:_log(
                "NATIVE_MANAGER_MERCHANT_CALLBACK_FAILED runtime="
                    .. runtime_id .. " reason=empty-instance-id"
            )
            return
        end
        record.spawnId = spawn_id
        self:_log(
            "NATIVE_MANAGER_MERCHANT_CALLBACK runtime="
                .. runtime_id .. " instanceId=received"
        )
    end
    local spawn_ok, handle_or_error = pcall(function()
        return npc_manager:SpawnNPCForServer({
            ControllerClass = controller_class,
            CharacterID = character_name,
            Level = plan.merchantLevel or self.merchantLevel,
            Location = copy_vector(
                plan.location,
                { X = 0, Y = 0, Z = 0 }
            ),
            Yaw = plan.rotation and plan.rotation.Yaw or 0.0,
            Squad = nil,
        }, record.spawnCallback)
    end)
    if not spawn_ok then
        self.failureCount = self.failureCount + 1
        error("NPC-manager-merchant-spawn-failed:"
            .. tostring(handle_or_error))
    end
    if is_valid_object(handle_or_error) then
        record.handle = handle_or_error
        record.handleReadyLogged = true
    end
    self.records[runtime_id] = record
    self:_log(string.format(
        "NATIVE_MANAGER_MERCHANT_REQUESTED runtime=%s manager=%s returnHandle=%s callbackPending=%s character=%s shopRow=%s spawnCall=SpawnNPCForServer",
        runtime_id,
        safe_full_name(npc_manager),
        safe_full_name(record.handle),
        tostring(record.spawnId == nil),
        plan.characterId,
        plan.shopRowName
    ))
    self:_schedule_npc_manager_merchant_poll(record)
    return record
end

function NativeCharacterAdapter:_fail_async_merchant(record, reason)
    if record.failed or record.ready or record.cancelled then
        return
    end
    record.pending = false
    record.failed = true
    record.lastError = reason
    self.failureCount = self.failureCount + 1
    self:_log(string.format(
        "NATIVE_MERCHANT_FAILED runtime=%s attempts=%d reason=%s",
        record.runtimeId,
        record.attempt,
        tostring(reason)
    ))
    if type(record.callbacks.onError) == "function" then
        pcall(record.callbacks.onError, reason, record)
    end
end

function NativeCharacterAdapter:_schedule_async_merchant_poll(record)
    if type(self.executeWithDelay) ~= "function" then
        self:_fail_async_merchant(
            record,
            "ExecuteWithDelay-unavailable"
        )
        return
    end
    local callback = function()
        local execute = function()
            if record.cancelled or record.ready or record.failed then
                return
            end
            if not is_valid_object(record.spawner) then
                self:_fail_async_merchant(
                    record,
                    "native-spawner-unavailable"
                )
                return
            end
            record.attempt = record.attempt + 1
            local actor, handle, reason =
                self:_find_spawner_actor(record)
            if actor ~= nil then
                local complete, complete_error =
                    self:_complete_async_merchant(
                        record,
                        actor,
                        handle,
                        reason
                    )
                if complete then
                    return
                end
                reason = complete_error
            elseif not record.spawnRequested then
                local spawned = safe_property(
                    record.spawner,
                    "Spawned"
                )
                local loading = safe_property(
                    record.spawner,
                    "IsLoading"
                )
                if spawned ~= true and loading ~= true then
                    -- APalNPCSpawnerBase exposes SpawnRequest_ByOutside as
                    -- the public Blueprint lifecycle entry.  Calling the
                    -- concrete Blueprint's Spawn helper directly skips the
                    -- group/individual-handle initialisation used by native
                    -- NPC spawners on Build 24467282.
                    -- The current public Boss Respawner implementation uses
                    -- deleteAlive=true.  A live Build 24467282 probe with
                    -- false accepted the request but never created a group,
                    -- IndividualHandle, or actor for a transient spawner.
                    local boss_dark_trader_route =
                        record.plan.provenNativeSpawnerRoute
                            == "BossDarkTrader"
                    local spawn_route = boss_dark_trader_route
                            and "Spawn() proven BossDarkTrader route"
                        or "SpawnRequest_ByOutside(true)"
                    local spawn_ok, spawn_error
                    if boss_dark_trader_route then
                        spawn_ok, spawn_error = pcall(function()
                            record.spawner:Spawn()
                        end)
                    else
                        spawn_ok, spawn_error = pcall(function()
                            record.spawner:SpawnRequest_ByOutside(true)
                        end)
                        if not spawn_ok then
                            spawn_route =
                                "Spawn() compatibility fallback"
                            spawn_ok, spawn_error = pcall(function()
                                record.spawner:Spawn()
                            end)
                        end
                    end
                    if spawn_ok then
                        record.spawnRequested = true
                        record.spawnRequestRoute = spawn_route
                        self:_log(string.format(
                            "NATIVE_MERCHANT_SPAWN_REQUESTED runtime=%s attempt=%d route=%s spawner=%s",
                            record.runtimeId,
                            record.attempt,
                            spawn_route,
                            safe_full_name(record.spawner)
                        ))
                    else
                        reason = "native-spawn-call-failed:"
                            .. tostring(spawn_error)
                    end
                end
            end
            if record.attempt >= self.nativeSetupMaxAttempts then
                self:_fail_async_merchant(record, reason)
                return
            end
            if record.attempt == 1
                or record.attempt % 5 == 0 then
                self:_log(string.format(
                    "NATIVE_MERCHANT_RETRY runtime=%s attempt=%d reason=%s",
                    record.runtimeId,
                    record.attempt,
                    tostring(reason)
                ))
            end
            self:_schedule_async_merchant_poll(record)
        end
        if type(self.executeInGameThread) == "function" then
            table.insert(record.gameThreadCallbacks, execute)
            self.executeInGameThread(execute)
        else
            execute()
        end
    end
    table.insert(record.pollCallbacks, callback)
    self.executeWithDelay(self.nativeSetupRetryMs, callback)
end

function NativeCharacterAdapter:spawn_merchant_async(plan, callbacks)
    assert(type(plan) == "table", "native spawn plan is required")
    callbacks = callbacks or {}
    local runtime_id = require_non_empty_string(
        plan.runtimeId,
        "native spawn runtime ID"
    )
    require_non_empty_string(
        plan.characterId,
        "native character ID"
    )
    require_non_empty_string(
        plan.characterClassPath,
        "native character class path"
    )
    require_non_empty_string(
        plan.shopRowName,
        "native shop row name"
    )
    assert(
        type(plan.location) == "table",
        "native character location is required"
    )
    if self.records[runtime_id] ~= nil then
        error("native-runtime-id-already-active:" .. runtime_id)
    end
    self.spawnAttemptCount = self.spawnAttemptCount + 1
    local world_context, context_error =
        self:_resolve_world_context()
    if world_context == nil then
        self.failureCount = self.failureCount + 1
        error(context_error)
    end
    local spawner_class_path = plan.spawnerClassPath
        or self.merchantSpawnerClassPath
    local controller_class_path = plan.controllerClassPath
        or self.controllerClassPath
    local default_action_class_path =
        plan.defaultActionClassPath
            or self.merchantDefaultActionClassPath
    require_non_empty_string(
        spawner_class_path,
        "native merchant spawner class path"
    )
    require_non_empty_string(
        controller_class_path,
        "native merchant controller class path"
    )
    require_non_empty_string(
        default_action_class_path,
        "native merchant default action class path"
    )
    local spawner_class, spawner_error =
        self:_load_class(spawner_class_path)
    local controller_class, controller_error =
        self:_load_class(controller_class_path)
    local default_action_class, action_error =
        self:_load_class(default_action_class_path)
    if spawner_class == nil
        or controller_class == nil
        or default_action_class == nil then
        self.failureCount = self.failureCount + 1
        error(spawner_error or controller_error or action_error)
    end
    local transform, transform_error = self:_make_transform(plan)
    if transform == nil then
        self.failureCount = self.failureCount + 1
        error(transform_error)
    end
    local gameplay, gameplay_error = self:_find_default_object(
        "/Script/Engine.Default__GameplayStatics"
    )
    if gameplay == nil then
        self.failureCount = self.failureCount + 1
        error(gameplay_error)
    end
    local begin_ok, deferred = pcall(function()
        return gameplay:BeginDeferredActorSpawnFromClass(
            world_context,
            spawner_class,
            transform,
            self.collisionHandlingOverride,
            nil
        )
    end)
    if not begin_ok or not is_valid_object(deferred) then
        self.failureCount = self.failureCount + 1
        error("deferred-merchant-spawner-failed:"
            .. tostring(deferred))
    end
    local configured, configure_error =
        self:_configure_merchant_spawner(
            deferred,
            plan,
            controller_class,
            default_action_class
        )
    if not configured then
        self:_destroy_untracked(deferred)
        self.failureCount = self.failureCount + 1
        error(configure_error)
    end
    local finish_ok, finished = pcall(function()
        return gameplay:FinishSpawningActor(deferred, transform)
    end)
    if not finish_ok then
        self:_destroy_untracked(deferred)
        self.failureCount = self.failureCount + 1
        error("finish-merchant-spawner-failed:"
            .. tostring(finished))
    end
    local spawner = is_valid_object(finished) and finished or deferred
    configured, configure_error = self:_configure_merchant_spawner(
        spawner,
        plan,
        controller_class,
        default_action_class
    )
    if not configured then
        self:_destroy_untracked(spawner)
        self.failureCount = self.failureCount + 1
        error(configure_error)
    end
    local record = {
        runtimeId = runtime_id,
        actor = nil,
        spawner = spawner,
        characterId = plan.characterId,
        characterClassPath = plan.characterClassPath,
        merchant = true,
        pending = true,
        ready = false,
        failed = false,
        cancelled = false,
        spawnRequested = false,
        spawnRequestRoute = nil,
        attempt = 0,
        location = copy_vector(
            plan.location,
            { X = 0, Y = 0, Z = 0 }
        ),
        plan = plan,
        callbacks = callbacks,
        pollCallbacks = {},
        gameThreadCallbacks = {},
    }
    self.records[runtime_id] = record
    self:_log(string.format(
        "NATIVE_MERCHANT_SPAWNER_READY runtime=%s spawner=%s character=%s shopRow=%s",
        runtime_id,
        safe_full_name(spawner),
        plan.characterId,
        plan.shopRowName
    ))
    self:_schedule_async_merchant_poll(record)
    return record
end

function NativeCharacterAdapter:_spawn(plan, merchant)
    assert(type(plan) == "table", "native spawn plan is required")
    local runtime_id = require_non_empty_string(
        plan.runtimeId,
        "native spawn runtime ID"
    )
    require_non_empty_string(
        plan.characterId,
        "native character ID"
    )
    require_non_empty_string(
        plan.characterClassPath,
        "native character class path"
    )
    assert(
        type(plan.location) == "table",
        "native character location is required"
    )
    if self.records[runtime_id] ~= nil then
        error("native-runtime-id-already-active:" .. runtime_id)
    end
    self.spawnAttemptCount = self.spawnAttemptCount + 1

    local world_context, context_error =
        self:_resolve_world_context()
    if world_context == nil then
        self.failureCount = self.failureCount + 1
        error(context_error)
    end
    local character_class, class_error =
        self:_load_class(plan.characterClassPath)
    if character_class == nil then
        self.failureCount = self.failureCount + 1
        error(class_error)
    end
    local transform, transform_error =
        self:_make_transform(plan)
    if transform == nil then
        self.failureCount = self.failureCount + 1
        error(transform_error)
    end
    local gameplay, gameplay_error =
        self:_find_default_object(
            "/Script/Engine.Default__GameplayStatics"
        )
    if gameplay == nil then
        self.failureCount = self.failureCount + 1
        error(gameplay_error)
    end

    local begin_ok, deferred_or_error = pcall(function()
        return gameplay:BeginDeferredActorSpawnFromClass(
            world_context,
            character_class,
            transform,
            self.collisionHandlingOverride,
            nil
        )
    end)
    if not begin_ok
        or not is_valid_object(deferred_or_error) then
        self.failureCount = self.failureCount + 1
        error(
            "deferred-character-spawn-failed:"
                .. tostring(deferred_or_error)
        )
    end
    if merchant then
        require_non_empty_string(
            plan.shopRowName,
            "native shop row name"
        )
    end
    local finish_ok, actor_or_error = pcall(function()
        -- Ordinary merchants are normally born through a Pal NPC spawner,
        -- which supplies their controller.  A deferred direct spawn needs the
        -- same controller class and auto-possession policy before Finish so
        -- the engine can create an interactable merchant pawn.
        local controller_class_path = plan.controllerClassPath
            or self.controllerClassPath
        if controller_class_path ~= nil then
            local controller_class = self:_load_class(
                controller_class_path
            )
            if is_valid_object(controller_class) then
                pcall(function()
                    deferred_or_error.AIControllerClass = controller_class
                end)
                pcall(function()
                    deferred_or_error.ControllerClass = controller_class
                end)
                pcall(function()
                    -- EAutoPossessAI::PlacedInWorldOrSpawned
                    deferred_or_error.AutoPossessAI = 3
                end)
            end
        end
        return gameplay:FinishSpawningActor(
            deferred_or_error,
            transform
        )
    end)
    if not finish_ok then
        self:_destroy_untracked(deferred_or_error)
        self.failureCount = self.failureCount + 1
        error(
            "finish-character-spawn-failed:"
                .. tostring(actor_or_error)
        )
    end
    local actor = is_valid_object(actor_or_error)
            and actor_or_error
        or deferred_or_error
    local expected_class_token =
        class_token(plan.characterClassPath)
    local actor_name = safe_full_name(actor)
    if expected_class_token == nil
        or not string.find(
            actor_name,
            expected_class_token,
            1,
            true
        ) then
        self:_destroy_untracked(actor)
        self.failureCount = self.failureCount + 1
        error(
            "native-character-class-mismatch:"
                .. tostring(actor_name)
        )
    end
    local controller, controller_source =
        self:_ensure_default_controller(actor)
    local network_setup = false
    local network_detail = "not-requested"
    if merchant then
        local action_configured, action_error =
            self:_configure_salesperson_controller(
                controller,
                plan
            )
        if not action_configured then
            self:_destroy_untracked(actor)
            self.failureCount = self.failureCount + 1
            error(action_error)
        end
        local interaction_ready, interaction_error =
            self:_initialize_merchant_interaction(actor)
        if not interaction_ready then
            self:_destroy_untracked(actor)
            self.failureCount = self.failureCount + 1
            error(interaction_error)
        end
        require_non_empty_string(
            plan.shopRowName,
            "native shop row name"
        )
        local configured, configure_error =
            self:_configure_vendor(actor, plan)
        if not configured then
            self:_destroy_untracked(actor)
            self.failureCount = self.failureCount + 1
            error(configure_error)
        end
        network_setup, network_detail =
            self:_request_network_shop_setup(actor)
        self.merchantSpawnCount =
            self.merchantSpawnCount + 1
    else
        self.guardSpawnCount = self.guardSpawnCount + 1
    end
    self.records[runtime_id] = {
        runtimeId = runtime_id,
        actor = actor,
        characterId = plan.characterId,
        characterClassPath = plan.characterClassPath,
        merchant = merchant,
        controller = controller,
        controllerSource = controller_source,
        networkSetup = network_setup,
        networkDetail = network_detail,
    }
    self:_log(string.format(
        "SPAWNED runtime=%s kind=%s character=%s actor=%s controller=%s controllerSource=%s networkSetup=%s networkDetail=%s",
        runtime_id,
        merchant and "merchant" or "guard",
        plan.characterId,
        actor_name,
        safe_full_name(controller),
        tostring(controller_source),
        tostring(network_setup),
        tostring(network_detail)
    ))
    return actor
end

function NativeCharacterAdapter:spawn_merchant(plan)
    return self:_spawn(plan, true)
end

function NativeCharacterAdapter:spawn_guard(plan)
    return self:_spawn(plan, false)
end

function NativeCharacterAdapter:_guard_is_dead(actor)
    if not is_valid_object(actor) then
        return true, "guard-actor-unavailable"
    end
    if self.observedDeadActorNames[safe_full_name(actor)] == true then
        return true, "authoritative-death-observed"
    end
    local component = safe_property(actor, "CharacterParameterComponent")
    if not is_valid_object(component) then
        local component_ok, component_value = pcall(function()
            return actor:GetCharacterParameterComponent()
        end)
        component = component_ok and component_value or nil
    end
    if not is_valid_object(component) then
        return false, "death-probe-unavailable"
    end
    local dead_ok, dead = pcall(function()
        return component:IsDead()
    end)
    if not dead_ok then
        return false, "death-probe-failed:"
            .. tostring(dead)
    end
    return dead == true, dead == true
            and "guard-dead"
        or "guard-alive"
end

function NativeCharacterAdapter:observe_character_death(actor)
    if actor == nil then
        return false, "death-actor-unavailable"
    end
    local actor_name = safe_full_name(actor)
    if actor_name == "<invalid>"
        or actor_name == "<unreadable>" then
        return false, "death-actor-name-unavailable"
    end
    self.observedDeadActorNames[actor_name] = true
    self:_log(string.format(
        "CHARACTER_DEATH_OBSERVED actor=%s authority=PalCharacter.OnDeadCharacter",
        actor_name
    ))
    return true, "authoritative-death-recorded"
end

local function same_native_object(left, right)
    if not is_valid_object(left) or not is_valid_object(right) then
        return false
    end
    if left == right then
        return true
    end
    local left_name = safe_full_name(left)
    return left_name ~= "<invalid>"
        and left_name ~= "<unreadable>"
        and left_name == safe_full_name(right)
end

function NativeCharacterAdapter:_guard_target_is_follow_ally(
    target,
    follow_target
)
    if same_native_object(target, follow_target) then
        return true, "follow-target"
    end
    local static_component = safe_property(
        target,
        "StaticCharacterParameterComponent"
    )
    if not is_valid_object(static_component)
        or safe_property(static_component, "IsPal") ~= true then
        return false, "not-pal"
    end
    local component = safe_property(
        target,
        "CharacterParameterComponent"
    )
    if not is_valid_object(component) then
        local component_ok, component_value = pcall(function()
            return target:GetCharacterParameterComponent()
        end)
        component = component_ok and component_value or nil
    end
    if not is_valid_object(component) then
        return false, "pal-character-parameter-unavailable"
    end
    local owned_ok, is_owned_pal = pcall(function()
        return component:IsPlayersOtomo()
    end)
    if not owned_ok or is_owned_pal ~= true then
        return false, "not-player-owned-pal"
    end
    return true, "player-owned-pal"
end

function NativeCharacterAdapter:_guard_combat_target(
    controller,
    follow_target
)
    if not is_valid_object(controller) then
        return nil
    end
    local hate_ok, hate_system = pcall(function()
        return controller:GetHateSystem()
    end)
    if not hate_ok or not is_valid_object(hate_system) then
        return nil
    end
    local target_ok, target = pcall(function()
        return hate_system:FindMostHateTarget()
    end)
    if target_ok and is_valid_object(target) then
        -- Palworld's hate system can retain a native actor for a short time
        -- after that character has died.  Treating that stale reference as
        -- live combat leaves a guard permanently parked after a raid.
        local target_dead = self:_guard_is_dead(target)
        if not target_dead then
            local allied, allied_reason =
                self:_guard_target_is_follow_ally(
                    target,
                    follow_target
                )
            if allied then
                return nil, allied_reason, target
            end
            return target, nil, nil
        end
    end
    return nil, nil, nil
end

function NativeCharacterAdapter:_guard_follow_once(record)
    if type(record) ~= "table"
        or record.cancelled == true
        or self.records[record.runtimeId] ~= record then
        return false, "guard-follow-cancelled"
    end
    if not is_valid_object(record.followTarget) then
        return false, "guard-follow-target-unavailable"
    end
    local dead, death_reason = self:_guard_is_dead(record.actor)
    if dead then
        record.downed = true
        record.following = false
        record.followScheduled = false
        record.cancelled = true
        if not record.downedLogged then
            record.downedLogged = true
            self:_log(string.format(
                "PLAYER_GUARD_DOWNED runtime=%s actor=%s reason=%s",
                record.runtimeId,
                safe_full_name(record.actor),
                tostring(death_reason)
            ))
        end
        if self.records[record.runtimeId] == record then
            self.records[record.runtimeId] = nil
        end
        if not record.terminatedNotified then
            record.terminatedNotified = true
            local callback_ok = true
            local callback_detail = "not-registered"
            if type(record.onTerminated) == "function" then
                callback_ok, callback_detail = pcall(
                    record.onTerminated,
                    {
                        runtimeId = record.runtimeId,
                        actor = record.actor,
                        reason = "guard-downed",
                    }
                )
                if callback_ok then
                    callback_detail = "notified"
                end
            end
            self:_log(string.format(
                "PLAYER_GUARD_RUNTIME_RELEASED runtime=%s actor=%s reason=guard-downed callback=%s detail=%s",
                record.runtimeId,
                safe_full_name(record.actor),
                tostring(callback_ok),
                tostring(callback_detail)
            ))
        end
        return false, "guard-downed"
    end

    local controller = record.controller
    if not is_valid_object(controller) then
        controller = self:_ensure_default_controller(record.actor)
        record.controller = controller
    end
    if not is_valid_object(controller) then
        return false, "guard-controller-unavailable"
    end

    if not record.guardAIInitialized then
        local leader_ok, leader_error = pcall(function()
            controller.VisitorLeader = record.followTarget
        end)
        local initial_ok, initial_error = pcall(function()
            controller:SetInitialValue(false, true)
        end)
        local active_ok, active_error = pcall(function()
            controller:SetActiveAI(true)
        end)
        if not leader_ok or not initial_ok or not active_ok then
            return false,
                "guard-ai-initialize-failed:leader="
                    .. tostring(leader_error)
                    .. ";initial=" .. tostring(initial_error)
                    .. ";active=" .. tostring(active_error)
        end
        record.guardAIInitialized = true
    end

    local combat_target, ignored_reason, ignored_target =
        self:_guard_combat_target(
            controller,
            record.followTarget
        )
    if combat_target ~= nil then
        if record.inCombat ~= true then
            self:_log(string.format(
                "PLAYER_GUARD_COMBAT_PRESERVED runtime=%s actor=%s target=%s",
                record.runtimeId,
                safe_full_name(record.actor),
                safe_full_name(combat_target)
            ))
        end
        record.inCombat = true
        record.following = false
        return true, "guard-combat-preserved"
    end

    local ignored_target_name = ignored_target ~= nil
        and safe_full_name(ignored_target)
        or nil
    if ignored_target_name ~= nil
        and record.lastIgnoredFriendlyTargetName
            ~= ignored_target_name then
        record.lastIgnoredFriendlyTargetName =
            ignored_target_name
        self:_log(string.format(
            "PLAYER_GUARD_FRIENDLY_TARGET_IGNORED runtime=%s actor=%s target=%s reason=%s",
            record.runtimeId,
            safe_full_name(record.actor),
            safe_full_name(ignored_target),
            tostring(ignored_reason)
        ))
    end

    local resumed = record.inCombat == true
    record.inCombat = false
    local move_ok, move_result = pcall(function()
        return controller:MoveToActor(
            record.followTarget,
            self.guardAcceptanceRadius,
            true,
            true,
            true,
            nil,
            true
        )
    end)
    if not move_ok then
        record.following = false
        return false, "guard-move-to-player-failed:"
            .. tostring(move_result)
    end
    record.following = true
    record.followPulseCount =
        (record.followPulseCount or 0) + 1
    local actor_location = safe_actor_location(record.actor)
    local target_location = safe_actor_location(record.followTarget)
    local remaining_distance = vector_distance(
        actor_location,
        target_location
    )
    if actor_location ~= nil
        and target_location ~= nil
        and (record.followPulseCount == 1
            or record.followPulseCount % 5 == 0
            or resumed) then
        self:_log(string.format(
            "PLAYER_GUARD_FOLLOW_PULSE runtime=%s pulse=%d actor=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) distance=%.2f moveResult=%s",
            record.runtimeId,
            record.followPulseCount,
            actor_location.X,
            actor_location.Y,
            actor_location.Z,
            target_location.X,
            target_location.Y,
            target_location.Z,
            remaining_distance,
            tostring(move_result)
        ))
    end
    local actor_delta = vector_distance(
        actor_location,
        record.followInitialActorLocation
    )
    local target_delta = vector_distance(
        target_location,
        record.followInitialTargetLocation
    )
    if record.followMovementLogged ~= true
        and actor_delta ~= nil
        and actor_delta >= 100 then
        record.followMovementLogged = true
        self:_log(string.format(
            "PLAYER_GUARD_FOLLOW_MOVEMENT_CONFIRMED runtime=%s pulse=%d actorDelta=%.2f targetDelta=%.2f remainingDistance=%.2f",
            record.runtimeId,
            record.followPulseCount,
            actor_delta,
            target_delta or 0,
            remaining_distance or -1
        ))
    end
    if not record.followReadyLogged or resumed then
        self:_log(string.format(
            "PLAYER_GUARD_FOLLOW_READY runtime=%s actor=%s controller=%s visitorLeader=true activeAI=true move=true acceptanceRadius=%s pulse=%d resumedAfterCombat=%s",
            record.runtimeId,
            safe_full_name(record.actor),
            safe_full_name(controller),
            tostring(self.guardAcceptanceRadius),
            record.followPulseCount,
            tostring(resumed)
        ))
        record.followReadyLogged = true
    end
    return true, "guard-follow-command-issued"
end

function NativeCharacterAdapter:_schedule_guard_follow(record)
    local use_loop_async = type(self.loopAsync) == "function"
        and type(self.executeInGameThread) == "function"
    if not use_loop_async
        and type(self.executeWithDelay) ~= "function" then
        return false, "guard-follow-scheduler-unavailable"
    end
    if record.cancelled == true
        or self.records[record.runtimeId] ~= record
        or record.followScheduled == true then
        return false, "guard-follow-not-scheduled"
    end
    record.followScheduled = true
    local runtime_id = record.runtimeId
    local function run_pulse(reschedule)
        local current = self.records[runtime_id]
        if type(current) ~= "table" or current.cancelled == true then
            self.guardFollowLoopActive[runtime_id] = false
            return false
        end
        current.followScheduled = false
        local ok, reason = self:_guard_follow_once(current)
        if reason == "guard-downed" then
            self.guardFollowLoopActive[runtime_id] = false
            return false
        end
        if ok then
            current.followFailureCount = 0
        else
            current.followFailureCount =
                (current.followFailureCount or 0) + 1
            self:_log(string.format(
                "PLAYER_GUARD_FOLLOW_RETRY runtime=%s failure=%d limit=%d reason=%s",
                runtime_id,
                current.followFailureCount,
                self.guardFollowMaxFailures,
                tostring(reason)
            ))
            if current.followFailureCount
                >= self.guardFollowMaxFailures then
                current.following = false
                current.followStopped = true
                self.guardFollowLoopActive[runtime_id] = false
                self:_log(string.format(
                    "PLAYER_GUARD_FOLLOW_STOPPED runtime=%s reason=%s",
                    runtime_id,
                    tostring(reason)
                ))
                return false
            end
        end
        if reschedule == true then
            self:_schedule_guard_follow(current)
        else
            current.followScheduled = true
        end
        return true
    end

    if use_loop_async then
        if self.guardFollowLoopActive[runtime_id] == true then
            return false, "guard-follow-loop-already-active"
        end
        self.guardFollowLoopActive[runtime_id] = true
        local game_callback = function()
            run_pulse(false)
        end
        local callback = function()
            if self.guardFollowLoopActive[runtime_id] ~= true
                or type(self.records[runtime_id]) ~= "table" then
                -- Return true only after the Lua-owned lifecycle fence has
                -- closed.  The strong references below remain in place, which
                -- avoids UE4SS 3.0.1's stale registry-ref crash on teardown.
                return true
            end
            self.executeInGameThread(game_callback)
            return false
        end
        self.guardFollowGameCallbacks[runtime_id] = game_callback
        self.guardFollowAsyncCallbacks[runtime_id] = callback
        self.loopAsync(self.guardFollowIntervalMs, callback)
        record.followScheduler = "LoopAsync"
        self:_log(string.format(
            "PLAYER_GUARD_FOLLOW_SCHEDULER_READY runtime=%s mode=LoopAsync intervalMs=%d recursiveDelay=false",
            runtime_id,
            self.guardFollowIntervalMs
        ))
        return true, "guard-follow-loop-scheduled"
    end

    local callback = function()
        local execute = function()
            local current = self.records[runtime_id]
            if type(current) ~= "table" or current.cancelled == true then
                return
            end
            run_pulse(true)
        end
        if type(self.executeInGameThread) == "function" then
            self.executeInGameThread(execute)
        else
            execute()
        end
    end
    self.executeWithDelay(self.guardFollowIntervalMs, callback)
    record.followScheduler = "ExecuteWithDelay-fallback"
    return true, "guard-follow-scheduled"
end

function NativeCharacterAdapter:_activate_guard_follow(
    runtime_id,
    follow_target
)
    local record = self.records[runtime_id]
    if type(record) ~= "table" then
        return false, "guard-record-unavailable"
    end
    if not is_valid_object(follow_target) then
        return false, "guard-follow-target-unavailable"
    end
    record.followTarget = follow_target
    record.followFailureCount = 0
    record.cancelled = false
    record.followInitialActorLocation = safe_actor_location(record.actor)
    record.followInitialTargetLocation = safe_actor_location(follow_target)
    record.followMovementLogged = false
    local followed, follow_reason =
        self:_guard_follow_once(record)
    if not followed then
        return false, follow_reason
    end
    local scheduled, schedule_reason =
        self:_schedule_guard_follow(record)
    if not scheduled then
        return false, schedule_reason
    end
    return true, "native-guard-follow-active"
end

function NativeCharacterAdapter:create_guard_provider(
    character_id,
    character_class_path,
    provider_options
)
    require_non_empty_string(
        character_id,
        "guard provider character ID"
    )
    require_non_empty_string(
        character_class_path,
        "guard provider character class path"
    )
    provider_options = provider_options or {}
    assert(type(provider_options) == "table",
        "guard provider options must be a table")
    local runtime_prefix = provider_options.runtimePrefix
        or "player-guard"
    local spawn_mode = provider_options.mode or "player-guard"
    require_non_empty_string(runtime_prefix,
        "guard provider runtime prefix")
    require_non_empty_string(spawn_mode,
        "guard provider spawn mode")
    local adapter = self
    return {
        deploy = function(faction_id, request_id, context)
            context = context or {}
            assert(
                type(context.location) == "table",
                "guard deployment context.location is required"
            )
            local runtime_id = runtime_prefix .. ":"
                .. require_non_empty_string(
                    faction_id,
                    "guard provider faction ID"
                )
                .. ":"
                .. require_non_empty_string(
                    request_id,
                    "guard provider request ID"
                )
            local actor = adapter:spawn_guard({
                runtimeId = runtime_id,
                mode = spawn_mode,
                factionId = faction_id,
                characterId = character_id,
                characterClassPath = character_class_path,
                controllerClassPath =
                    context.controllerClassPath
                        or adapter.guardControllerClassPath,
                location = context.location,
                rotation = context.rotation
                    or { Pitch = 0, Yaw = 0, Roll = 0 },
            })
            local record = adapter.records[runtime_id]
            if type(record) == "table" then
                record.onTerminated = context.onTerminated
            end
            local follow_ready, follow_error =
                adapter:_activate_guard_follow(
                    runtime_id,
                    context.followTarget
                )
            if not follow_ready then
                adapter:despawn(
                    actor,
                    "guard-follow-activation-failed"
                )
                error(follow_error)
            end
            return {
                runtimeId = runtime_id,
                actor = actor,
                followTarget = context.followTarget,
                followBehaviourStatus =
                    "native-visitor-leader-follow-active-live-combat-validation-pending",
            }
        end,
        recall = function(handle, reason)
            if type(handle) ~= "table" then
                return false
            end
            -- UE4SS may hand Lua a different wrapper for the same native
            -- actor between deploy and recall.  Resolve the authoritative
            -- lifecycle record by runtime ID so cancellation never depends
            -- on wrapper identity.
            local record = adapter.records[handle.runtimeId]
            local actor = type(record) == "table"
                    and record.actor
                or handle.actor
            local outcome = adapter:despawn(
                actor,
                reason or "guard-recall"
            )
            return outcome.ok
        end,
    }
end

function NativeCharacterAdapter:despawn(actor, reason)
    if type(actor) == "table"
        and actor.runtimeId ~= nil
        and (actor.spawner ~= nil
            or actor.nativeManagerSpawn == true) then
        local record = actor
        record.cancelled = true
        record.pending = false
        local destroyed = false
        local destroy_error = nil
        if is_valid_object(record.spawner) then
            local despawn_ok, detail = pcall(function()
                record.spawner:Despawn()
            end)
            destroyed = despawn_ok
            destroy_error = detail
        end
        if record.nativeManagerSpawn == true
            and is_valid_object(record.handle) then
            local despawn_ok, detail = pcall(function()
                record.handle:Despawn()
            end)
            destroyed = despawn_ok
            destroy_error = detail
        end
        -- A successful native Despawn owns the actor lifecycle. Never read the
        -- handle or destroy the actor again after that call; only use the actor
        -- fallback when no native lifecycle route was available or it failed.
        if not destroyed and is_valid_object(record.actor) then
            self.interactionReadyActors[record.actor] = nil
            local actor_ok, detail = pcall(function()
                record.actor:K2_DestroyActor()
            end)
            destroyed = actor_ok
            destroy_error = detail
        end
        if not destroyed then
            return make_result(false, "native-spawner-despawn-failed", {
                detail = tostring(destroy_error),
            })
        end
        self.records[record.runtimeId] = nil
        self.despawnCount = self.despawnCount + 1
        self:_log(string.format(
            "DESPAWNED runtime=%s reason=%s lifecycle=%s",
            tostring(record.runtimeId),
            tostring(reason or "unspecified"),
            record.nativeManagerSpawn == true
                    and "PalNPCManager.SpawnNPCForServer"
                or "native-spawner"
        ))
        return make_result(true, "despawned", {
            runtimeId = record.runtimeId,
        })
    end
    if not is_valid_object(actor) then
        local stale_runtime_id = nil
        for runtime_id, record in pairs(self.records) do
            if record.actor == actor then
                stale_runtime_id = runtime_id
                record.cancelled = true
                record.followScheduled = false
                record.following = false
                break
            end
        end
        if stale_runtime_id ~= nil then
            self.records[stale_runtime_id] = nil
            self.despawnCount = self.despawnCount + 1
            self:_log(string.format(
                "DESPAWNED runtime=%s reason=%s lifecycle=already-invalid-record-cleanup",
                stale_runtime_id,
                tostring(reason or "unspecified")
            ))
        end
        return make_result(true, "already-despawned", {
            runtimeId = stale_runtime_id,
        })
    end
    local removed_runtime_id = nil
    local removed_record = nil
    for runtime_id, record in pairs(self.records) do
        if record.actor == actor then
            removed_runtime_id = runtime_id
            removed_record = record
            break
        end
    end
    if removed_record ~= nil then
        -- ExecuteWithDelay callbacks cannot be unscheduled through UE4SS.
        -- Invalidating this lifecycle-scoped record makes every already queued
        -- follow pulse inert before the actor is destroyed.
        removed_record.cancelled = true
        removed_record.followScheduled = false
        removed_record.following = false
        self.guardFollowLoopActive[removed_record.runtimeId] = false
    end
    local ok, destroy_error = pcall(function()
        actor:K2_DestroyActor()
    end)
    if not ok then
        return make_result(false, "native-despawn-failed", {
            detail = tostring(destroy_error),
        })
    end
    if removed_runtime_id ~= nil then
        self.records[removed_runtime_id] = nil
    end
    self.interactionReadyActors[actor] = nil
    self.despawnCount = self.despawnCount + 1
    self:_log(string.format(
        "DESPAWNED runtime=%s reason=%s",
        tostring(removed_runtime_id or "untracked"),
        tostring(reason or "unspecified")
    ))
    return make_result(true, "despawned", {
        runtimeId = removed_runtime_id,
    })
end

function NativeCharacterAdapter:abandon_world_records(reason)
    -- UWorld owns these temporary actors and destroys them during map unload.
    -- UE4SS UObject wrappers may already point at freed memory by the time the
    -- load-map callback runs, so world-reload cleanup must drop Lua references
    -- without calling IsValid, Despawn, K2_DestroyActor, or tostring on them.
    local abandoned = 0
    for _, record in pairs(self.records) do
        abandoned = abandoned + 1
        -- Delayed UE4SS callbacks cannot be unscheduled.  Flip only Lua-owned
        -- state before dropping the table so every pending resolver/delegate
        -- exits without touching an object from the unloaded world.
        if type(record) == "table" then
            record.cancelled = true
            record.pending = false
            record.callbacks = {}
            if record.runtimeId ~= nil then
                self.guardFollowLoopActive[record.runtimeId] = false
            end
        end
    end
    self.records = {}
    self.interactionReadyActors = {}
    self.despawnCount = self.despawnCount + abandoned
    self:_log(string.format(
        "WORLD_RECORDS_ABANDONED count=%d reason=%s lifecycle=uworld-owned",
        abandoned,
        tostring(reason or "world-reload")
    ))
    return make_result(true, "world-records-abandoned", {
        abandonedCount = abandoned,
    })
end

function NativeCharacterAdapter:status()
    local active_count = 0
    local pending_count = 0
    for _, record in pairs(self.records) do
        active_count = active_count + 1
        if record.pending == true then
            pending_count = pending_count + 1
        end
    end
    return {
        version = self.version,
        activeCount = active_count,
        pendingCount = pending_count,
        spawnAttemptCount = self.spawnAttemptCount,
        merchantSpawnCount = self.merchantSpawnCount,
        guardSpawnCount = self.guardSpawnCount,
        despawnCount = self.despawnCount,
        failureCount = self.failureCount,
        saveWrites = 0,
    }
end

return NativeCharacterAdapter
