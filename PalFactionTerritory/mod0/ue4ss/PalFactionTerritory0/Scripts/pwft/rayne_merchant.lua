local RayneMerchant = {}

local PREFIX = "[PalFactionTerritory0][RayneMerchant]"

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function safe_to_string(value)
    if value == nil then
        return "<nil>"
    end
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    end
    local ok, rendered = pcall(function()
        if value.ToString ~= nil then
            return value:ToString()
        end
        return tostring(value)
    end)
    return ok and rendered or "<unreadable>"
end

local function is_valid_object(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    return ok and value == true
end

local function safe_full_name(object)
    if not is_valid_object(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and safe_to_string(value) or "<unreadable>"
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

local function current_relation(shared_state, faction_id)
    local relation = shared_state.relations and shared_state.relations[faction_id] or nil
    if type(relation) == "table" then
        return relation.state or "Neutral"
    end
    return relation or "Neutral"
end

-- The standalone Rayne Pal merchant is not one of the seven Merchant Guild
-- counters.  A hostile relationship must therefore close its native
-- interaction route explicitly instead of relying on battle mode to suppress
-- the prompt as an incidental side effect.  The Dark Trader template is
-- natively aggressive, so peaceful relations must also suspend its AI and
-- battle flag.  The actor is respawned whenever the relation changes, giving
-- a later peaceful actor a clean native route and an empty hate list.
local function apply_relation_interaction_policy(actor, relation, options)
    if not is_valid_object(actor) then
        return false, "merchant-actor-unavailable"
    end
    local hostile = relation == "Hostile"
    local interaction = safe_property(actor, "BP_NPCInteractionComponent")
    local flags_ok = false
    local flags_error = "npc-interaction-component-unavailable"
    if is_valid_object(interaction) then
        flags_ok, flags_error = pcall(function()
            interaction.bDisableTalk = hostile
            interaction.bDisableTalkWhenCaptured = hostile
            if interaction.OnRep_DisableTalk ~= nil then
                interaction:OnRep_DisableTalk()
            end
        end)
    end
    local active_ok, active_error = pcall(function()
        actor:SetActive_Interact_ToAll(not hostile)
    end)
    local controller_ok, controller = pcall(function()
        return actor:GetController()
    end)
    local ai_ok = false
    local ai_error = "merchant-controller-unavailable"
    if controller_ok and is_valid_object(controller) then
        ai_ok, ai_error = pcall(function()
            controller:SetActiveAI(hostile)
            actor:ChangeBattleModeFlag_ToAll(hostile)
        end)
    elseif not controller_ok then
        ai_error = controller
    end
    if type(options) ~= "table" or options.log ~= false then
        log(string.format(
            "RELATION_INTERACTION_POLICY relation=%s hostile=%s flags=%s flagsDetail=%s active=%s activeDetail=%s interactEnabled=%s controller=%s ai=%s aiDetail=%s aiActive=%s battleMode=%s",
            tostring(relation),
            tostring(hostile),
            tostring(flags_ok),
            tostring(flags_error),
            tostring(active_ok),
            tostring(active_error),
            tostring(not hostile),
            safe_full_name(controller),
            tostring(ai_ok),
            tostring(ai_error),
            tostring(hostile),
            tostring(hostile)
        ))
    end
    if not flags_ok then
        return false, "npc-interaction-flags-failed:" .. tostring(flags_error)
    end
    if not active_ok then
        return false, "npc-interaction-activation-failed:" .. tostring(active_error)
    end
    if not ai_ok then
        return false, "merchant-ai-policy-failed:" .. tostring(ai_error)
    end
    return true, hostile and "hostile-interaction-disabled"
        or "peaceful-interaction-enabled"
end

local function find_player_pawns()
    if type(FindAllOf) ~= "function" then
        return nil, "FindAllOf-unavailable"
    end

    local scan_errors = {}
    for _, class_name in ipairs({ "PlayerController", "Controller" }) do
        local scan_ok, controllers_or_error = pcall(function()
            return FindAllOf(class_name)
        end)
        if scan_ok and controllers_or_error ~= nil then
            local pawns = {}
            local seen = {}
            for _, controller in pairs(controllers_or_error) do
                if is_valid_object(controller) then
                    local player_ok, is_player = pcall(function()
                        if controller.IsPlayerController ~= nil then
                            return controller:IsPlayerController()
                        end
                        return controller:IsLocalPlayerController()
                    end)
                    if player_ok and is_player then
                        local pawn = safe_property(controller, "Pawn")
                            or safe_property(controller, "AcknowledgedPawn")
                        if is_valid_object(pawn) then
                            local pawn_name = safe_full_name(pawn)
                            if seen[pawn_name] ~= true then
                                seen[pawn_name] = true
                                table.insert(pawns, pawn)
                            end
                        end
                    end
                end
            end
            if #pawns > 0 then
                return pawns, "controller-class:" .. class_name
            end
            table.insert(scan_errors, class_name .. ":no-player-pawn")
        else
            table.insert(scan_errors, class_name .. ":" .. tostring(controllers_or_error))
        end
    end
    return nil, table.concat(scan_errors, "|")
end

local function find_tower(fast_travel_id)
    if type(FindAllOf) ~= "function" then
        return nil, "FindAllOf-unavailable"
    end
    local ok, towers = pcall(function()
        return FindAllOf("PalLevelObjectUnlockableFastTravelPoint")
    end)
    if not ok or towers == nil then
        return nil, "tower-scan-failed"
    end
    for _, tower in pairs(towers) do
        if is_valid_object(tower) then
            local candidate = safe_to_string(safe_property(tower, "FastTravelPointID"))
            if candidate == fast_travel_id then
                return tower, nil
            end
        end
    end
    return nil, "tower-not-loaded"
end

local function copy_location(location)
    if location == nil then
        return nil
    end
    return {
        X = location.X,
        Y = location.Y,
        Z = location.Z,
    }
end

local function copy_rotation(rotation)
    if rotation == nil then
        return nil
    end
    return {
        Pitch = rotation.Pitch,
        Yaw = rotation.Yaw,
        Roll = rotation.Roll,
    }
end

local function capture_nearest_player_anchor(tower, config)
    local players, player_source_or_error = find_player_pawns()
    if players == nil then
        return nil, "player-scan-failed:" .. tostring(player_source_or_error)
    end

    local best_player = nil
    local best_distance_squared = nil
    for _, player in pairs(players) do
        if is_valid_object(player) then
            local distance_ok, distance_squared = pcall(function()
                return tower:GetSquaredDistanceTo(player)
            end)
            if distance_ok
                and distance_squared ~= nil
                and (best_distance_squared == nil or distance_squared < best_distance_squared) then
                best_player = player
                best_distance_squared = distance_squared
            end
        end
    end
    if best_player == nil then
        return nil, "local-player-not-ready"
    end

    local max_distance = config.playerAnchorCaptureMaxDistance
    if max_distance ~= nil
        and best_distance_squared > max_distance * max_distance then
        return nil, string.format(
            "nearest-player-too-far:%.1f>%.1f",
            math.sqrt(math.max(0, best_distance_squared)),
            max_distance
        )
    end

    local transform_ok, location, rotation = pcall(function()
        return best_player:K2_GetActorLocation(), best_player:K2_GetActorRotation()
    end)
    if not transform_ok or location == nil or rotation == nil then
        return nil, "player-transform-unavailable"
    end
    return {
        location = copy_location(location),
        rotation = copy_rotation(rotation),
        player = safe_full_name(best_player),
        playerSource = player_source_or_error,
        distanceToTower = math.sqrt(math.max(0, best_distance_squared)),
    }, nil
end

local function build_spawn_transform(tower, config, captured_anchor)
    local ok, location, rotation, forward, right = pcall(function()
        return tower:K2_GetActorLocation(),
            tower:K2_GetActorRotation(),
            tower:GetActorForwardVector(),
            tower:GetActorRightVector()
    end)
    if not ok or location == nil or rotation == nil or forward == nil or right == nil then
        return nil, nil, "tower-transform-unavailable"
    end

    local spawn_location
    local base_rotation
    if type(config.fixedSpawnLocation) == "table" then
        spawn_location = copy_location(config.fixedSpawnLocation)
        base_rotation = type(config.fixedSpawnRotation) == "table"
            and copy_rotation(config.fixedSpawnRotation)
            or copy_rotation(rotation)
    elseif captured_anchor ~= nil then
        spawn_location = copy_location(captured_anchor.location)
        base_rotation = copy_rotation(captured_anchor.rotation)
    else
        spawn_location = {
            X = location.X
                + forward.X * config.spawnOffsetForward
                + right.X * config.spawnOffsetRight,
            Y = location.Y
                + forward.Y * config.spawnOffsetForward
                + right.Y * config.spawnOffsetRight,
            Z = location.Z
                + forward.Z * config.spawnOffsetForward
                + right.Z * config.spawnOffsetRight
                + config.spawnOffsetUp,
        }
        base_rotation = copy_rotation(rotation)
    end
    local spawn_rotation = {
        Pitch = base_rotation.Pitch,
        Yaw = base_rotation.Yaw + config.facingYawOffset,
        Roll = base_rotation.Roll,
    }

    if type(StaticFindObject) ~= "function" then
        return nil, nil, "StaticFindObject-unavailable"
    end
    local found, math_library = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    end)
    if not found or not is_valid_object(math_library) then
        return nil, nil, "KismetMathLibrary-unavailable"
    end
    local made, transform = pcall(function()
        return math_library:MakeTransform(
            spawn_location,
            spawn_rotation,
            { X = 1.0, Y = 1.0, Z = 1.0 }
        )
    end)
    if not made or transform == nil then
        return nil, nil, "spawn-transform-construction-failed"
    end
    return transform, spawn_location, nil
end

local function load_blueprint_class(asset_path, class_path)
    if type(StaticFindObject) ~= "function" then
        return nil, "StaticFindObject-unavailable"
    end
    local found, blueprint_class = pcall(function()
        return StaticFindObject(class_path)
    end)
    if found and is_valid_object(blueprint_class) then
        return blueprint_class, nil
    end
    if type(LoadAsset) == "function" then
        pcall(function()
            LoadAsset(asset_path)
        end)
        found, blueprint_class = pcall(function()
            return StaticFindObject(class_path)
        end)
        if found and is_valid_object(blueprint_class) then
            return blueprint_class, nil
        end
    end
    return nil, "blueprint-class-unavailable:" .. tostring(class_path)
end

local function configure_native_spawner_template(
    spawner,
    config,
    controller_class,
    default_action_class
)
    local configured, configure_error = pcall(function()
        -- Keep the official BOSS Dark Trader spawner's complete native
        -- lifecycle, but replace the wanted target with the ordinary
        -- Black Marketeer before its Spawn() request is issued.
        spawner.CharaName = FName(config.nativeCharacterId)
        spawner.UniqueNPCID = FName(config.nativeUniqueNpcId)
        spawner.ControllerClass = controller_class
        spawner.DefaultActionClass = default_action_class
        spawner.Level = config.merchantLevel
    end)
    if not configured then
        return false, "native-template-write-failed:" .. tostring(configure_error)
    end
    return true, nil
end

local function expected_actor_tokens(config)
    if type(config.expectedActorClassTokens) == "table"
        and #config.expectedActorClassTokens > 0 then
        return config.expectedActorClassTokens
    end
    return { config.expectedActorClassToken }
end

local function actor_matches_config(actor, config)
    local actor_name = safe_full_name(actor)
    for _, token in ipairs(expected_actor_tokens(config)) do
        if type(token) == "string"
            and token ~= ""
            and string.find(actor_name, token, 1, true) then
            return true, actor_name, token
        end
    end
    return false, actor_name, nil
end

local function configure_vendor(actor, config)
    local actor_matches, actor_name = actor_matches_config(actor, config)
    if not actor_matches then
        return nil, "unexpected-native-actor:" .. actor_name
    end

    local vendor = safe_property(actor, "BP_PalShopVenderDataComponent")
    if not is_valid_object(vendor) then
        return nil, "vendor-component-unavailable"
    end

    local lottery_ok, lottery_error = pcall(function()
        vendor.palShopLotteryType = 1 -- EPalShopLotteryType::SimpleLottery
    end)
    if not lottery_ok then
        return nil, "lottery-type-write-failed:" .. tostring(lottery_error)
    end

    local row_name = safe_property(vendor, "palShopSimpleLotteryTableName")
    if row_name == nil then
        return nil, "shop-row-struct-unavailable"
    end
    local row_ok, row_error = pcall(function()
        row_name.Key = FName(config.shopRowName)
    end)
    if not row_ok then
        return nil, "shop-row-write-failed:" .. tostring(row_error)
    end

    pcall(function()
        vendor.PalShopRestockMinute = config.restockMinutes
    end)
    return vendor, nil
end

local function get_native_vendor(actor, config)
    local actor_matches, actor_name = actor_matches_config(actor, config)
    if not actor_matches then
        return nil, "unexpected-native-actor:" .. actor_name
    end

    local vendor = safe_property(actor, "BP_PalShopVenderDataComponent")
    if not is_valid_object(vendor) then
        return nil, "vendor-component-unavailable"
    end
    return vendor, nil
end

local function spawn_native_spawner(tower, config, captured_anchor)
    if type(StaticFindObject) ~= "function" then
        return nil, nil, nil, "StaticFindObject-unavailable"
    end
    local gameplay_ok, gameplay = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end)
    if not gameplay_ok or not is_valid_object(gameplay) then
        return nil, nil, nil, "GameplayStatics-unavailable"
    end

    local spawner_class, class_error = load_blueprint_class(
        config.spawnerAssetPath,
        config.spawnerClassPath
    )
    if spawner_class == nil then
        return nil, nil, nil, class_error
    end
    local controller_class, controller_error = load_blueprint_class(
        config.controllerAssetPath,
        config.controllerClassPath
    )
    if controller_class == nil then
        return nil, nil, nil, controller_error
    end
    local default_action_class, action_error = load_blueprint_class(
        config.defaultActionAssetPath,
        config.defaultActionClassPath
    )
    if default_action_class == nil then
        return nil, nil, nil, action_error
    end
    local transform, spawn_location, transform_error = build_spawn_transform(
        tower,
        config,
        captured_anchor
    )
    if transform == nil then
        return nil, nil, nil, transform_error
    end

    local deferred_ok, deferred_spawner = pcall(function()
        return gameplay:BeginDeferredActorSpawnFromClass(
            tower,
            spawner_class,
            transform,
            2, -- AdjustIfPossibleButAlwaysSpawn
            nil
        )
    end)
    if not deferred_ok or not is_valid_object(deferred_spawner) then
        return nil, nil, nil, "deferred-spawner-failed:" .. tostring(deferred_spawner)
    end

    -- Disable boss-save and distance suppression on this runtime copy while
    -- retaining the official spawner's character lifecycle.
    local lifecycle_ok, lifecycle_error = pcall(function()
        deferred_spawner.IsBossSpawner = false
        deferred_spawner.Ignore_FarCheck = true
        deferred_spawner.Ignore_DistanceLocationReset = true
        deferred_spawner.IgnoreBaseCampCheck = true
        deferred_spawner.Debug_Disable = false
        deferred_spawner.SaveKeyName = FName(config.spawnerSaveKey)
    end)
    if not lifecycle_ok then
        pcall(function()
            deferred_spawner:K2_DestroyActor()
        end)
        return nil, nil, nil, "native-spawner-lifecycle-config-failed:"
            .. tostring(lifecycle_error)
    end
    local template_ok, template_error = configure_native_spawner_template(
        deferred_spawner,
        config,
        controller_class,
        default_action_class
    )
    if not template_ok then
        pcall(function()
            deferred_spawner:K2_DestroyActor()
        end)
        return nil, nil, nil, template_error
    end

    local finish_ok, finished_spawner = pcall(function()
        return gameplay:FinishSpawningActor(deferred_spawner, transform)
    end)
    if not finish_ok then
        pcall(function()
            deferred_spawner:K2_DestroyActor()
        end)
        return nil, nil, nil, "finish-spawner-failed:" .. tostring(finished_spawner)
    end
    if not is_valid_object(finished_spawner) then
        finished_spawner = deferred_spawner
    end
    -- Blueprint Construction Script may restore the source BOSS defaults
    -- during FinishSpawningActor. Reapply the ordinary merchant template
    -- before the delayed native Spawn() request.
    template_ok, template_error = configure_native_spawner_template(
        finished_spawner,
        config,
        controller_class,
        default_action_class
    )
    if not template_ok then
        pcall(function()
            finished_spawner:K2_DestroyActor()
        end)
        return nil, nil, nil, template_error
    end
    return finished_spawner, nil, spawn_location, nil
end

local function find_network_transmitter(world_context)
    if type(StaticFindObject) == "function" then
        local utility_ok, utility = pcall(function()
            return StaticFindObject("/Script/Pal.Default__PalUtility")
        end)
        if utility_ok and is_valid_object(utility) then
            local transmitter_ok, transmitter = pcall(function()
                return utility:GetNetworkTransmitter(world_context)
            end)
            if transmitter_ok and is_valid_object(transmitter) then
                return transmitter, "PalUtility"
            end
        end
    end

    if type(FindAllOf) == "function" then
        local scan_ok, transmitters = pcall(function()
            return FindAllOf("PalNetworkTransmitter")
        end)
        if scan_ok and transmitters ~= nil then
            for _, transmitter in pairs(transmitters) do
                if is_valid_object(transmitter) then
                    return transmitter, "FindAllOf"
                end
            end
        end
    end
    return nil, "network-transmitter-unavailable"
end

local function request_shop_network_setup(instance)
    if not is_valid_object(instance.actor) then
        return false, "merchant-actor-unavailable"
    end

    local transmitter, source_or_error = find_network_transmitter(instance.actor)
    if not is_valid_object(transmitter) then
        return false, source_or_error
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
        network_shop:SetupShopDataForActor_ToServer(instance.actor)
    end)
    if not setup_ok then
        return false, "network-shop-setup-call-failed:" .. tostring(setup_error)
    end

    instance.networkSetupRequests = instance.networkSetupRequests + 1
    instance.networkSetupComplete = true
    log(string.format(
        "SHOP_NETWORK_SETUP_REQUESTED request=%d transmitterSource=%s transmitter=%s component=%s",
        instance.networkSetupRequests,
        tostring(source_or_error),
        safe_full_name(transmitter),
        safe_full_name(network_shop)
    ))
    return true, nil
end

local function unwrap_remote_value(value)
    if value == nil then
        return nil
    end
    local getter = safe_property(value, "get")
    if type(getter) == "function" then
        local ok, unwrapped = pcall(function()
            return value:get()
        end)
        if ok and unwrapped ~= nil then
            return unwrapped
        end
    end
    return value
end

local function for_each_array(array, callback)
    array = unwrap_remote_value(array)
    if array == nil then
        return false
    end

    -- Never prefer TArray:ForEach in the live game. UE4SS executes that
    -- callback from its native TArray bridge; if any UObject method called by
    -- the callback raises, UE4SS 3.0.1 may crash while constructing the Lua
    -- traceback (luaH_next/lua_next) instead of returning through pcall. A
    -- fixed-length, indexed snapshot keeps every potentially failing read in
    -- ordinary Lua control flow and fails the whole pass closed.
    local get_array_num = safe_property(array, "GetArrayNum")
    if type(get_array_num) == "function" then
        local count_ok, count = pcall(function()
            return array:GetArrayNum()
        end)
        count = count_ok and tonumber(count) or nil
        if count == nil or count < 0 then
            return false
        end
        for index = 1, count do
            local read_ok, element = pcall(function()
                return array[index]
            end)
            if not read_ok then
                return false
            end
            local callback_ok = pcall(callback, index, element)
            if not callback_ok then
                return false
            end
        end
        return true
    end

    -- Compatibility fallback for older UE4SS wrappers that expose only
    -- ForEach. Current Palworld product/passive TArrays expose GetArrayNum, so
    -- this route is not used by the production merchant.
    local for_each = safe_property(array, "ForEach")
    if type(for_each) == "function" then
        local ok = pcall(function()
            array:ForEach(function(index, element)
                return callback(index, element)
            end)
        end)
        return ok
    end
    -- Plain Lua tables are used by offline tests and content fixtures.
    if type(array) == "table" then
        for index, element in pairs(array) do
            callback(index, element)
        end
        return true
    end
    return false
end

local function get_shop(vendor)
    -- The native component exposes the replicated shop directly. Prefer this
    -- over manufacturing a Lua table for the C++ out parameter: UE4SS returns
    -- UFunction out parameters as additional Lua return values.
    local direct = unwrap_remote_value(safe_property(vendor, "MyPalShop"))
    if is_valid_object(direct) then
        return direct, "MyPalShop"
    end

    local ok, result, alternate = pcall(function()
        return vendor:TryGetPalShop()
    end)
    if not ok or result == false then
        return nil, "TryGetPalShop-not-ready"
    end
    result = unwrap_remote_value(result)
    alternate = unwrap_remote_value(alternate)
    if is_valid_object(result) then
        return result, "TryGetPalShop:return"
    end
    if is_valid_object(alternate) then
        return alternate, "TryGetPalShop:out"
    end
    return nil, "TryGetPalShop-empty"
end

local function get_products(shop)
    local direct = unwrap_remote_value(safe_property(shop, "ProductArray"))
    if direct ~= nil then
        return direct, "ProductArray"
    end

    local ok, returned, alternate = pcall(function()
        return shop:GetAllProduct()
    end)
    if not ok then
        return nil, "GetAllProduct-failed"
    end
    if returned ~= nil and returned ~= true then
        return returned, "GetAllProduct:return"
    end
    if alternate ~= nil then
        return alternate, "GetAllProduct:out"
    end
    return nil, "GetAllProduct-empty"
end

local function unreal_value_text(value)
    if value == nil then
        return "<nil>"
    end
    local string_ok, string_value = pcall(function()
        return value:ToString()
    end)
    if string_ok and string_value ~= nil then
        return tostring(string_value)
    end
    return tostring(value)
end

local function get_product_parameter_sources(product)
    local sources = {}
    local seen = {}

    local function add_source(label, parameter)
        parameter = unwrap_remote_value(parameter)
        if parameter == nil or type(parameter) == "boolean" then
            return
        end
        local address_ok, address = pcall(function()
            return parameter:GetStructAddress()
        end)
        local key = address_ok and tostring(address)
            or label .. ":" .. tostring(parameter)
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(sources, {
            label = label,
            parameter = parameter,
        })
    end

    add_source(
        "product",
        safe_property(product, "ProductPalSaveParameter")
    )

    local giver = unwrap_remote_value(safe_property(product, "MyProductGiver"))
    add_source(
        "giver",
        safe_property(giver, "ProductPalSaveParameter")
    )
    return sources
end

local function parameter_contains_passive(parameter, passive_name)
    local passive_array = unwrap_remote_value(
        safe_property(parameter, "PassiveSkillList")
    )
    if passive_array == nil then
        return false
    end
    local found = false
    for_each_array(passive_array, function(_, element)
        local get_ok, value = pcall(function()
            return element:get()
        end)
        if get_ok and unreal_value_text(value) == passive_name then
            found = true
            return true
        end
        return false
    end)
    return found
end

local function replace_first_passives(passive_array, desired_names)
    local replaced = 0
    local verified = 0
    local visited_count = 0
    local first_error = nil
    local first_mismatch = nil

    local function record_verification(index, replacement, before_ok, before_value, after_ok, after_value)
        local after_text = after_ok and unreal_value_text(after_value) or "<get-failed>"
        if after_ok and after_text == replacement then
            verified = verified + 1
            return
        end
        if first_mismatch == nil then
            first_mismatch = string.format(
                "index=%s expected=%s before=%s beforeOk=%s after=%s afterOk=%s",
                tostring(index),
                replacement,
                before_ok and unreal_value_text(before_value) or "<get-failed>",
                tostring(before_ok),
                after_text,
                tostring(after_ok)
            )
        end
    end

    local visited = for_each_array(passive_array, function(index, element)
        if replaced >= #desired_names then
            return true
        end
        visited_count = visited_count + 1
        local replacement = desired_names[replaced + 1]
        local replacement_name = FName(replacement)
        local before_ok, before_value = pcall(function()
            return element:get()
        end)
        -- UE4SS exposes TArray callback values as RemoteUnrealParam. Its
        -- get/set methods are callable directly, but are not reflected as
        -- ordinary UObject properties, so safe_property(element, "set")
        -- incorrectly reports that the setter is absent.
        local set_ok, set_error = pcall(function()
            element:set(replacement_name)
        end)
        if not set_ok and type(passive_array) == "table" then
            set_ok, set_error = pcall(function()
                passive_array[index] = FName(replacement)
            end)
        end
        if set_ok then
            replaced = replaced + 1
            local verify_ok, after_value = pcall(function()
                return element:get()
            end)
            record_verification(
                index,
                replacement,
                before_ok,
                before_value,
                verify_ok,
                after_value
            )
        elseif first_error == nil then
            first_error = string.format(
                "index=%s passive=%s error=%s",
                tostring(index),
                replacement,
                tostring(set_error)
            )
        end
        return replaced >= #desired_names
    end)

    -- UE4SS 3.x grows a TArray when __newindex writes at #array + 1.
    -- Pal shop save parameters start with an empty PassiveSkillList, so the
    -- desired passives must be appended instead of only replacing elements.
    if visited and replaced < #desired_names then
        local count_ok, current_count = pcall(function()
            return passive_array:GetArrayNum()
        end)
        if not count_ok and type(passive_array) == "table" then
            count_ok = true
            current_count = #passive_array
        end
        if count_ok then
            while replaced < #desired_names do
                local replacement = desired_names[replaced + 1]
                local append_index = current_count + 1
                local append_ok, append_error = pcall(function()
                    passive_array[append_index] = FName(replacement)
                end)
                if not append_ok then
                    if first_error == nil then
                        first_error = string.format(
                            "appendIndex=%s passive=%s error=%s",
                            tostring(append_index),
                            replacement,
                            tostring(append_error)
                        )
                    end
                    break
                end

                replaced = replaced + 1
                current_count = append_index
                local verify_ok, after_value = pcall(function()
                    return passive_array[append_index]
                end)
                record_verification(
                    append_index,
                    replacement,
                    true,
                    "<new-slot>",
                    verify_ok,
                    after_value
                )
            end
        elseif first_error == nil then
            first_error = "passive-array-size-unavailable"
        end
    end

    if not visited and first_error == nil then
        first_error = "passive-array-traversal-failed"
    end
    return visited and replaced or 0,
        verified,
        first_error,
        visited_count,
        first_mismatch
end

local function choose_rainbow_passives(config)
    local function choose_one(excluded)
        local pool = config.rainbowPassives
        local rank = 4
        if math.random() <= config.rankFiveChance then
            pool = config.rankFivePassives
            rank = 5
        end
        local candidates = {}
        for _, name in ipairs(pool) do
            if name ~= excluded then
                table.insert(candidates, name)
            end
        end
        local selected = candidates[math.random(1, #candidates)]
        return selected, rank
    end

    local first, first_rank = choose_one(nil)
    local selected = { first }
    local ranks = { first_rank }
    if math.random() <= config.secondRainbowChance then
        local second, second_rank = choose_one(first)
        table.insert(selected, second)
        table.insert(ranks, second_rank)
    end
    return selected, ranks
end

local function inject_rainbow_passives(instance)
    local shop, shop_source = get_shop(instance.vendor)
    if shop == nil then
        return false, "shop-not-ready"
    end
    local products, product_source = get_products(shop)
    if products == nil then
        return false, "product-array-unavailable"
    end

    local total = 0
    local selected = 0
    local modified = 0
    local rank_four = 0
    local rank_five = 0
    local rank_five_test = 0
    local rank_five_test_samples = {}
    local empty = 0
    local read_failures = 0
    local passive_slots = 0
    local verified_writes = 0
    local set_failure_products = 0
    local verify_mismatch_writes = 0
    local mutation_diagnostics = {}
    local physical_target_writes = 0
    local physical_target_verified = 0
    local getter_visible = 0
    local selected_samples = {}
    local source_write_counts = {}
    local traversed = for_each_array(products, function(_, product_or_param)
        local product = unwrap_remote_value(product_or_param)
        if is_valid_object(product) then
            total = total + 1
            if math.random() <= instance.config.rainbowChance then
                selected = selected + 1
                local sources = get_product_parameter_sources(product)
                if #sources == 0 then
                    read_failures = read_failures + 1
                else
                    local desired, desired_ranks = choose_rainbow_passives(instance.config)
                    local product_replaced = 0
                    local product_verified = 0
                    local product_set_failed = false
                    for _, source in ipairs(sources) do
                        local passive_array = unwrap_remote_value(
                            safe_property(source.parameter, "PassiveSkillList")
                        )
                        if passive_array ~= nil then
                            local replaced,
                                verified,
                                set_error,
                                visited_slots,
                                mismatch = replace_first_passives(
                                    passive_array,
                                    desired
                                )
                            passive_slots = passive_slots + visited_slots
                            physical_target_writes =
                                physical_target_writes + replaced
                            physical_target_verified =
                                physical_target_verified + verified
                            if replaced > product_replaced then
                                product_replaced = replaced
                            end
                            if verified > product_verified then
                                product_verified = verified
                            end
                            if replaced > 0 then
                                source_write_counts[source.label] =
                                    (source_write_counts[source.label] or 0) + 1
                            end
                            if set_error ~= nil then
                                product_set_failed = true
                                if #mutation_diagnostics < 4 then
                                    table.insert(
                                        mutation_diagnostics,
                                        source.label .. ":" .. set_error
                                    )
                                end
                            end
                            if verified < replaced then
                                verify_mismatch_writes =
                                    verify_mismatch_writes + (replaced - verified)
                                if mismatch ~= nil
                                    and #mutation_diagnostics < 4 then
                                    table.insert(
                                        mutation_diagnostics,
                                        source.label .. ":" .. mismatch
                                    )
                                end
                            end
                        end
                    end
                    verified_writes = verified_writes + product_verified
                    if product_set_failed then
                        set_failure_products = set_failure_products + 1
                    end
                    if product_replaced > 0 then
                        modified = modified + 1
                        if #selected_samples < 12 then
                            local character_id = unreal_value_text(
                                safe_property(
                                    sources[1].parameter,
                                    "CharacterID"
                                )
                            )
                            table.insert(
                                selected_samples,
                                character_id .. ":" .. desired[1]
                            )
                        end
                        for index = 1, product_replaced do
                            if desired_ranks[index] == 5 then
                                rank_five = rank_five + 1
                                local name = desired[index]
                                local is_test = name == "Logging_up5"
                                    or string.find(name, "Mining_up", 1, true) == 1
                                    or name == "Mute_5"
                                    or name == "LifeSteal_5"
                                if is_test then
                                    rank_five_test = rank_five_test + 1
                                    if #rank_five_test_samples < 8 then
                                        table.insert(rank_five_test_samples, name)
                                    end
                                end
                            else
                                rank_four = rank_four + 1
                            end
                        end
                    else
                        empty = empty + 1
                    end
                end
            end
        end
    end)
    if not traversed or total == 0 then
        return false, "product-traversal-empty"
    end

    instance.traitPasses = instance.traitPasses + 1
    instance.lastProductCount = total
    instance.lastRainbowSelectedCount = selected
    instance.lastRainbowModifiedCount = modified
    log(string.format(
        "SHOP_STOCK_AUDIT products=%d readable=%d single=%d infinite=%d other=%d restockMinutes=%d shopSource=%s productSource=%s nativeGetterAudit=disabled",
        total,
        0,
        0,
        0,
        0,
        instance.config.restockMinutes,
        tostring(shop_source),
        tostring(product_source)
    ))
    local source_write_parts = {}
    for label, count in pairs(source_write_counts) do
        table.insert(
            source_write_parts,
            label .. ":" .. tostring(count)
        )
    end
    table.sort(source_write_parts)
    log(string.format(
        "RAINBOW_PASS_COMPLETE pass=%d products=%d selected=%d modified=%d rank4=%d rank5=%d rank5Test=%d empty=%d readFailures=%d slots=%d verified=%d physicalWrites=%d physicalVerified=%d getterVisible=%d setFailureProducts=%d verifyMismatches=%d chance=%.2f rank5Chance=%.2f secondChance=%.2f sourceWrites=%s selectedSamples=%s testSamples=%s diagnostics=%s",
        instance.traitPasses,
        total,
        selected,
        modified,
        rank_four,
        rank_five,
        rank_five_test,
        empty,
        read_failures,
        passive_slots,
        verified_writes,
        physical_target_writes,
        physical_target_verified,
        getter_visible,
        set_failure_products,
        verify_mismatch_writes,
        instance.config.rainbowChance,
        instance.config.rankFiveChance,
        instance.config.secondRainbowChance,
        #source_write_parts > 0
            and table.concat(source_write_parts, ",")
            or "none",
        #selected_samples > 0
            and table.concat(selected_samples, ",")
            or "none",
        #rank_five_test_samples > 0 and table.concat(rank_five_test_samples, ",") or "none",
        #mutation_diagnostics > 0 and table.concat(mutation_diagnostics, " | ") or "none"
    ))
    if selected == 0 then
        return false, "rainbow-selection-empty"
    end
    if modified ~= selected then
        return false, string.format(
            "passives-modified=%d/%d getterVisible=%d",
            modified,
            selected,
            getter_visible
        )
    end
    -- Live UI validation on 2026-07-24 confirmed that the shop displays these
    -- traits. Product/giver UProperty writes are therefore the source of truth.
    -- Do not call product diagnostic UFunctions here: during map teardown or a
    -- fast reload Palworld can leave a product wrapper alive after its native
    -- object has gone stale, and UE4SS 3.0.1 may crash while formatting that
    -- UFunction error instead of returning through pcall.
    return true, nil
end

local schedule_shop_network_setup

local function schedule_trait_injection(instance, attempt)
    if type(ExecuteWithDelay) ~= "function" then
        return
    end
    local scheduled_generation = instance.lifecycleGeneration
    local scheduled_actor = instance.actor
    local scheduled_vendor = instance.vendor
    local callback = function()
        local function execute()
            if instance.lifecycleGeneration ~= scheduled_generation
                or instance.actor ~= scheduled_actor
                or instance.vendor ~= scheduled_vendor then
                return
            end
            if not is_valid_object(instance.actor) or not is_valid_object(instance.vendor) then
                return
            end
            local injected, reason = inject_rainbow_passives(instance)
            if injected then
                instance.traitInjectionComplete = true
                local requested, network_error =
                    request_shop_network_setup(instance)
                if not requested then
                    instance.lastShopSetupError = network_error
                    log(string.format(
                        "SHOP_NETWORK_SETUP_RETRY attempt=0 reason=%s",
                        tostring(network_error)
                    ))
                    schedule_shop_network_setup(instance, 1)
                end
            elseif attempt < instance.config.traitInjectionMaxAttempts then
                log(string.format(
                    "RAINBOW_PASS_RETRY attempt=%d reason=%s",
                    attempt,
                    tostring(reason)
                ))
                schedule_trait_injection(instance, attempt + 1)
            elseif not injected then
                log(string.format(
                    "RAINBOW_PASS_UNAVAILABLE attempts=%d reason=%s",
                    attempt,
                    tostring(reason)
                ))
                -- Preserve the usable merchant even when this optional trait
                -- enhancement cannot reach the UI-facing product copy.
                local requested, network_error =
                    request_shop_network_setup(instance)
                if not requested then
                    instance.lastShopSetupError = network_error
                    schedule_shop_network_setup(instance, 1)
                end
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(execute)
        else
            execute()
        end
    end
    instance.callbacks["traitInjection" .. tostring(attempt)] = callback
    ExecuteWithDelay(instance.config.traitInjectionRetryMs, callback)
end

schedule_shop_network_setup = function(instance, attempt)
    if type(ExecuteWithDelay) ~= "function" then
        return
    end
    local callback = function()
        local function execute()
            if not is_valid_object(instance.actor) or not is_valid_object(instance.vendor) then
                return
            end
            local requested, reason = request_shop_network_setup(instance)
            if not requested and attempt < instance.config.shopRegistrationMaxAttempts then
                log(string.format(
                    "SHOP_NETWORK_SETUP_RETRY attempt=%d reason=%s",
                    attempt,
                    tostring(reason)
                ))
                schedule_shop_network_setup(instance, attempt + 1)
            else
                instance.lastShopSetupError = reason
                log(string.format(
                    "SHOP_NETWORK_SETUP_FAILED attempts=%d reason=%s",
                    attempt,
                    tostring(reason)
                ))
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(execute)
        else
            execute()
        end
    end
    instance.callbacks["shopNetworkSetup" .. tostring(attempt)] = callback
    ExecuteWithDelay(instance.config.shopRegistrationRetryMs, callback)
end

local mark_nearby_players_hostile
local schedule_hostility_monitor

local function get_native_merchant_from_spawner(spawner)
    if not is_valid_object(spawner) then
        return nil, nil, "native-spawner-unavailable"
    end
    local handle = safe_property(spawner, "SpawnedHandle")
    if not is_valid_object(handle) then
        return nil, nil, "native-handle-not-ready"
    end
    local actor_ok, actor = pcall(function()
        return handle:TryGetIndividualActor()
    end)
    if not actor_ok or not is_valid_object(actor) then
        return nil, handle, "native-actor-not-ready"
    end
    return actor, handle, nil
end

local function collect_native_merchant_actor_names(config)
    local actor_names = {}
    if type(FindAllOf) ~= "function" then
        return actor_names
    end
    for _, token in ipairs(expected_actor_tokens(config)) do
        local scan_ok, actors = pcall(function()
            return FindAllOf(token)
        end)
        if scan_ok and actors ~= nil then
            for _, actor in pairs(actors) do
                if is_valid_object(actor) then
                    actor_names[safe_full_name(actor)] = true
                end
            end
        end
    end
    return actor_names
end

local function find_nearby_native_merchant(
    config,
    spawn_location,
    excluded_actor_names
)
    if type(FindAllOf) ~= "function" then
        return nil, nil, "native-actor-scan-unavailable"
    end
    if spawn_location == nil then
        return nil, nil, "native-actor-scan-location-unavailable"
    end

    local actors_or_error = {}
    for _, token in ipairs(expected_actor_tokens(config)) do
        local scan_ok, actors = pcall(function()
            return FindAllOf(token)
        end)
        if not scan_ok or actors == nil then
            return nil, nil, "native-actor-scan-failed:"
                .. tostring(actors)
                .. ":"
                .. tostring(token)
        end
        for _, actor in pairs(actors) do
            table.insert(actors_or_error, actor)
        end
    end

    local nearest = nil
    local nearest_distance_squared = nil
    for _, actor in pairs(actors_or_error) do
        local actor_name = safe_full_name(actor)
        if is_valid_object(actor)
            and actor_matches_config(actor, config)
            and not (
                type(excluded_actor_names) == "table"
                and excluded_actor_names[actor_name] == true
            ) then
            local vendor = safe_property(
                actor,
                "BP_PalShopVenderDataComponent"
            )
            local location_ok, actor_location = pcall(function()
                return actor:K2_GetActorLocation()
            end)
            if is_valid_object(vendor)
                and location_ok
                and actor_location ~= nil then
                local delta_x = actor_location.X - spawn_location.X
                local delta_y = actor_location.Y - spawn_location.Y
                local delta_z = actor_location.Z - spawn_location.Z
                local distance_squared = delta_x * delta_x
                    + delta_y * delta_y
                    + delta_z * delta_z
                if nearest_distance_squared == nil
                    or distance_squared < nearest_distance_squared then
                    nearest = actor
                    nearest_distance_squared = distance_squared
                end
            end
        end
    end

    if nearest == nil then
        return nil, nil, "native-actor-scan-empty"
    end
    local maximum_distance_squared = config.nativeActorFallbackRadius
        * config.nativeActorFallbackRadius
    if nearest_distance_squared > maximum_distance_squared then
        return nil,
            math.sqrt(math.max(0, nearest_distance_squared)),
            "native-actor-scan-too-far"
    end
    return nearest,
        math.sqrt(math.max(0, nearest_distance_squared)),
        nil
end

local function complete_native_merchant_setup(
    instance,
    actor,
    handle,
    actor_source
)
    local vendor, vendor_error
    if instance.config.enableCustomShop then
        vendor, vendor_error = configure_vendor(actor, instance.config)
    else
        vendor, vendor_error = get_native_vendor(actor, instance.config)
    end
    if vendor == nil then
        return false, vendor_error
    end
    if instance.config.enableCustomShop then
        local setup_ok, setup_error = pcall(function()
            vendor:SetupShopData()
        end)
        if not setup_ok then
            return false, "shop-setup-failed:" .. tostring(setup_error)
        end
    end

    instance.actor = actor
    instance.spawnHandle = handle
    instance.actorSource = actor_source or "spawner-handle"
    instance.vendor = vendor
    instance.lifecycleGeneration = instance.lifecycleGeneration + 1
    instance.lastSpawnError = nil
    instance.lastShopSetupError = nil
    instance.hostileTargets = {}
    instance.nativeSetupScheduled = false
    local relation = current_relation(
        instance.sharedState,
        instance.config.factionId
    )
    local interaction_ready, interaction_reason =
        apply_relation_interaction_policy(actor, relation)
    if not interaction_ready then
        return false, interaction_reason
    end

    if relation ~= "Hostile"
        and instance.sharedState.factionMerchantRuntime ~= nil then
        local binding =
            instance.sharedState.factionMerchantRuntime
                :bind_existing_fixed(
                    instance.config.factionId,
                    actor,
                    {
                        existingRuntimeBinding =
                            "rayneMerchant",
                    }
                )
        if not binding.ok then
            log(
                "MERCHANT_LIFECYCLE_BIND_FAILED reason="
                    .. tostring(binding.reason)
            )
        end
    elseif relation ~= "Hostile"
        and instance.sharedState.commerceBridge ~= nil then
        local bridge_ok, bridge_reason =
            instance.sharedState.commerceBridge:register_vendor_actor(
                instance.config.factionId,
                actor,
                {
                    mode = "fixed-market",
                    commercialTruce = true,
                    existingRuntimeBinding =
                        "rayneMerchant",
                }
            )
        if not bridge_ok then
            log(
                "COMMERCE_VENDOR_BIND_FAILED reason="
                    .. tostring(bridge_reason)
            )
        end
    end

    local controller_ok, controller = pcall(function()
        return actor:GetController()
    end)
    local collision_ok, collision_enabled = pcall(function()
        return actor:GetActorEnableCollision()
    end)
    log(string.format(
        "NATIVE_MERCHANT_READY actor=%s handle=%s actorSource=%s controller=%s collision=%s vendor=%s shopMode=%s shopRow=%s relation=%s",
        safe_full_name(actor),
        safe_full_name(handle),
        tostring(actor_source or "spawner-handle"),
        controller_ok and safe_full_name(controller) or "<unavailable>",
        collision_ok and tostring(collision_enabled) or "<unavailable>",
        safe_full_name(vendor),
        instance.config.enableCustomShop and "custom" or "vanilla",
        instance.config.enableCustomShop and instance.config.shopRowName or "<native>",
        relation
    ))

    if relation == "Hostile" then
        instance.networkSetupComplete = false
        log(string.format(
            "SHOP_ACCESS_BLOCKED relation=Hostile actor=%s interaction=false networkShop=false commercialTruce=false",
            safe_full_name(actor)
        ))
    elseif instance.config.enableCustomShop then
        if instance.config.enableRainbowPassives == true then
            -- SetupShopData may report READY before all 288 product wrappers
            -- have finished their native reconstruction. Fence the optional
            -- pass to this exact actor generation.
            log(string.format(
                "RAINBOW_PASS_SCHEDULED attempt=1 delayMs=%d generation=%d",
                instance.config.traitInjectionRetryMs,
                instance.lifecycleGeneration
            ))
            schedule_trait_injection(instance, 1)
        else
            log("RAINBOW_PASS_DISABLED safety=ue4ss-tarray-reload-crash catalog=preserved")
            local requested, network_error = request_shop_network_setup(instance)
            if not requested then
                instance.lastShopSetupError = network_error
                schedule_shop_network_setup(instance, 1)
            end
        end
    else
        log("VANILLA_SHOP_PRESERVED stage=1")
    end
    if instance.config.enableFactionHostility then
        mark_nearby_players_hostile(instance)
        schedule_hostility_monitor(instance)
    end
    return true, nil
end

local function schedule_native_merchant_setup(instance, attempt, generation)
    if type(ExecuteWithDelay) ~= "function" then
        return
    end
    generation = generation or instance.lifecycleGeneration
    instance.nativeSetupScheduled = true
    local callback = function()
        local function execute()
            instance.nativeSetupScheduled = false
            if generation ~= instance.lifecycleGeneration then
                return
            end
            if not is_valid_object(instance.spawner) then
                return
            end

            local actor, handle, reason = get_native_merchant_from_spawner(instance.spawner)
            local actor_source = "spawner-handle"
            if actor == nil
                and attempt >= instance.config.nativeActorFallbackAttempt then
                local scanned_actor,
                    scan_distance,
                    scan_reason = find_nearby_native_merchant(
                        instance.config,
                        instance.lastSpawnLocation,
                        instance.nativeActorScanBaseline
                    )
                if scanned_actor ~= nil then
                    actor = scanned_actor
                    handle = nil
                    actor_source = string.format(
                        "nearby-scan:distance=%.1f",
                        scan_distance
                    )
                else
                    reason = tostring(reason)
                        .. "|"
                        .. tostring(scan_reason)
                end
            end
            if actor ~= nil then
                local completed, setup_reason = complete_native_merchant_setup(
                    instance,
                    actor,
                    handle,
                    actor_source
                )
                if completed then
                    return
                end
                reason = setup_reason
                if type(reason) == "string"
                    and string.find(reason, "unexpected-native-actor:", 1, true) == 1 then
                    instance.lastSpawnError = reason
                    pcall(function()
                        instance.spawner:Despawn()
                    end)
                    log(string.format(
                        "NATIVE_TEMPLATE_MISMATCH reason=%s spawner=%s",
                        reason,
                        safe_full_name(instance.spawner)
                    ))
                    return
                end
            elseif not instance.nativeSpawnRequested then
                local is_spawned = safe_property(instance.spawner, "Spawned")
                local is_loading = safe_property(instance.spawner, "IsLoading")
                if is_spawned ~= true and is_loading ~= true then
                    local spawn_ok, spawn_error = pcall(function()
                        instance.spawner:Spawn()
                    end)
                    if spawn_ok then
                        instance.nativeSpawnRequested = true
                        log(string.format(
                            "NATIVE_SPAWN_REQUESTED attempt=%d spawner=%s",
                            attempt,
                            safe_full_name(instance.spawner)
                        ))
                    else
                        reason = "native-spawn-call-failed:" .. tostring(spawn_error)
                    end
                else
                    reason = string.format(
                        "native-spawner-busy:spawned=%s,loading=%s",
                        tostring(is_spawned),
                        tostring(is_loading)
                    )
                end
            end

            if attempt < instance.config.nativeSetupMaxAttempts then
                if attempt == 1 or attempt % 5 == 0 then
                    log(string.format(
                        "NATIVE_MERCHANT_RETRY attempt=%d reason=%s",
                        attempt,
                        tostring(reason)
                    ))
                end
                schedule_native_merchant_setup(
                    instance,
                    attempt + 1,
                    generation
                )
            else
                instance.lastSpawnError = reason
                log(string.format(
                    "NATIVE_MERCHANT_FAILED attempts=%d reason=%s spawner=%s",
                    attempt,
                    tostring(reason),
                    safe_full_name(instance.spawner)
                ))
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(execute)
        else
            execute()
        end
    end
    instance.callbacks[
        "nativeSetup"
            .. tostring(generation)
            .. "_"
            .. tostring(attempt)
    ] = callback
    ExecuteWithDelay(instance.config.nativeSetupRetryMs, callback)
end

mark_nearby_players_hostile = function(instance)
    if instance.config.enableFactionHostility ~= true then
        return 0
    end
    if current_relation(instance.sharedState, instance.config.factionId) ~= "Hostile" then
        return 0
    end
    if not is_valid_object(instance.actor) then
        return 0
    end

    local controller_ok, controller = pcall(function()
        return instance.actor:GetController()
    end)
    if not controller_ok or not is_valid_object(controller) then
        return 0
    end

    local players, player_error = find_player_pawns()
    if players == nil then
        instance.lastPlayerScanError = player_error
        return 0
    end
    instance.lastPlayerScanError = nil

    local added = 0
    local radius_squared = instance.config.hostileAwarenessRadius
        * instance.config.hostileAwarenessRadius
    for _, player in pairs(players) do
        if is_valid_object(player) then
            local player_name = safe_full_name(player)
            if instance.hostileTargets[player_name] ~= true then
                local distance_ok, distance_squared = pcall(function()
                    return instance.actor:GetSquaredDistanceTo(player)
                end)
                if distance_ok and distance_squared <= radius_squared then
                    local target_ok = pcall(function()
                        controller:AddTargetPlayer_ForEnemy(player)
                        instance.actor:ChangeBattleModeFlag_ToAll(true)
                    end)
                    if target_ok then
                        instance.hostileTargets[player_name] = true
                        instance.hostileTargetCount = instance.hostileTargetCount + 1
                        added = added + 1
                        log(string.format(
                            "HOSTILE_TARGET_ADDED player=%s distance=%.1f relation=Hostile",
                            player_name,
                            math.sqrt(math.max(0, distance_squared))
                        ))
                    end
                end
            end
        end
    end
    return added
end

schedule_hostility_monitor = function(instance, generation)
    generation = generation or instance.lifecycleGeneration
    if instance.config.enableFactionHostility ~= true
        or type(ExecuteWithDelay) ~= "function"
        or (instance.monitorScheduled
            and instance.monitorGeneration == generation) then
        return
    end
    instance.monitorScheduled = true
    instance.monitorGeneration = generation
    local callback
    callback = function()
        local function execute()
            -- Delayed callbacks from a destroyed actor must never clear or
            -- reschedule the monitor that belongs to its replacement.
            if generation ~= instance.lifecycleGeneration then
                return
            end
            instance.monitorScheduled = false
            instance.monitorGeneration = nil
            if not is_valid_object(instance.actor) then
                return
            end
            local relation = current_relation(
                instance.sharedState,
                instance.config.factionId
            )
            -- The Dark Trader template can reactivate its native combat AI
            -- after initialization.  Reassert both peaceful and hostile
            -- policies on every monitor pass; only failures are logged.
            local maintained, policy_reason =
                apply_relation_interaction_policy(
                    instance.actor,
                    relation,
                    { log = false }
                )
            if not maintained then
                if instance.lastRelationPolicyError ~= policy_reason then
                    log(string.format(
                        "RELATION_POLICY_MONITOR_FAILED relation=%s reason=%s generation=%d",
                        tostring(relation),
                        tostring(policy_reason),
                        generation
                    ))
                end
                instance.lastRelationPolicyError = policy_reason
            else
                instance.lastRelationPolicyError = nil
            end
            if relation == "Hostile" then
                mark_nearby_players_hostile(instance)
            end
            schedule_hostility_monitor(instance, generation)
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(execute)
        else
            execute()
        end
    end
    instance.callbacks["hostilityMonitor" .. tostring(generation)] = callback
    ExecuteWithDelay(instance.config.hostilityCheckIntervalMs, callback)
end

local function destroy_actor(instance, reason)
    -- Invalidate delayed native callbacks before touching any UObject.
    instance.lifecycleGeneration = instance.lifecycleGeneration + 1
    if instance.sharedState.factionMerchantRuntime ~= nil
        and instance.actor ~= nil then
        instance.sharedState.factionMerchantRuntime
            :unbind_existing_fixed(
                instance.config.factionId,
                instance.actor,
                reason
            )
    end
    local native_despawn_requested = false
    if is_valid_object(instance.spawner) then
        native_despawn_requested = pcall(function()
            instance.spawner:Despawn()
        end)
    end
    if is_valid_object(instance.actor) then
        local actor_name = safe_full_name(instance.actor)
        local explicit_actor_destroy_required = instance.spawnHandle == nil
        if not native_despawn_requested
            or explicit_actor_destroy_required then
            pcall(function()
                instance.actor:K2_DestroyActor()
            end)
        end
        log(string.format(
            "DESTROYED reason=%s actor=%s nativeDespawn=%s explicitActorDestroy=%s actorSource=%s",
            tostring(reason),
            actor_name,
            tostring(native_despawn_requested),
            tostring(explicit_actor_destroy_required),
            tostring(instance.actorSource or "unknown")
        ))
    end
    if is_valid_object(instance.spawner) then
        local spawner_name = safe_full_name(instance.spawner)
        pcall(function()
            instance.spawner:K2_DestroyActor()
        end)
        log(string.format(
            "SPAWNER_DESTROYED reason=%s spawner=%s",
            tostring(reason),
            spawner_name
        ))
    end
    instance.actor = nil
    instance.spawner = nil
    instance.spawnHandle = nil
    instance.actorSource = nil
    instance.vendor = nil
    instance.monitorScheduled = false
    instance.monitorGeneration = nil
    instance.nativeSetupScheduled = false
    instance.nativeSpawnRequested = false
    instance.nativeActorScanBaseline = {}
    instance.hostileTargets = {}
    instance.networkSetupComplete = false
    instance.traitInjectionComplete = false
end

local function validate_config(config)
    assert(type(config) == "table", "rayne merchant config is required")
    assert(type(config.enabled) == "boolean", "rayne merchant enabled flag is required")
    assert(type(config.factionId) == "string" and config.factionId ~= "", "rayne merchant factionId is required")
    assert(type(config.towerFastTravelPointId) == "string", "rayne merchant tower ID is required")
    assert(config.spawnerMode == "BossDarkTrader", "unsupported native spawner mode")
    assert(type(config.spawnerAssetPath) == "string" and config.spawnerAssetPath ~= "", "native spawner asset is required")
    assert(type(config.spawnerClassPath) == "string" and config.spawnerClassPath ~= "", "native spawner class is required")
    assert(type(config.spawnerSaveKey) == "string" and config.spawnerSaveKey ~= "", "native spawner save key is required")
    assert(type(config.nativeCharacterId) == "string" and config.nativeCharacterId ~= "", "native merchant character is required")
    assert(type(config.nativeUniqueNpcId) == "string" and config.nativeUniqueNpcId ~= "", "native merchant unique ID is required")
    assert(type(config.controllerAssetPath) == "string" and config.controllerAssetPath ~= "", "native controller asset is required")
    assert(type(config.controllerClassPath) == "string" and config.controllerClassPath ~= "", "native controller class is required")
    assert(type(config.defaultActionAssetPath) == "string" and config.defaultActionAssetPath ~= "", "native action asset is required")
    assert(type(config.defaultActionClassPath) == "string" and config.defaultActionClassPath ~= "", "native action class is required")
    assert(type(config.expectedActorClassToken) == "string" and config.expectedActorClassToken ~= "", "expected merchant actor class is required")
    if config.expectedActorClassTokens ~= nil then
        assert(type(config.expectedActorClassTokens) == "table" and #config.expectedActorClassTokens > 0, "expected merchant actor class list is invalid")
        for _, token in ipairs(config.expectedActorClassTokens) do
            assert(type(token) == "string" and token ~= "", "expected merchant actor class token is invalid")
        end
    end
    assert(type(config.merchantLevel) == "number" and config.merchantLevel > 0, "invalid native merchant level")
    assert(type(config.merchantLevelCap) == "number" and config.merchantLevelCap > 0, "invalid native merchant level cap")
    assert(config.merchantLevel <= config.merchantLevelCap, "native merchant level exceeds the supported game cap")
    assert(type(config.enableCustomShop) == "boolean", "custom shop stage flag is required")
    assert(type(config.enableRainbowPassives) == "boolean", "rainbow passive safety flag is required")
    assert(type(config.enableFactionHostility) == "boolean", "faction hostility stage flag is required")
    assert(type(config.shopRowName) == "string" and config.shopRowName ~= "", "rayne merchant shop row is required")
    assert(type(config.rainbowPassives) == "table" and #config.rainbowPassives > 0, "rainbow passives are required")
    assert(type(config.rankFivePassives) == "table" and #config.rankFivePassives > 0, "rank-five passives are required")
    assert(config.shopRegistrationRetryMs > 0, "invalid shop registration retry delay")
    assert(config.shopRegistrationMaxAttempts > 0, "invalid shop registration attempt count")
    assert(config.nativeSetupRetryMs > 0, "invalid native setup retry delay")
    assert(config.nativeSetupMaxAttempts > 0, "invalid native setup attempt count")
    assert(config.nativeActorFallbackAttempt > 0, "invalid native actor fallback attempt")
    assert(config.nativeActorFallbackRadius > 0, "invalid native actor fallback radius")
    assert(type(config.capturePlayerAnchorOnLoad) == "boolean", "invalid player anchor capture flag")
    assert(config.playerAnchorCaptureMaxDistance > 0, "invalid player anchor capture distance")
    assert(config.rainbowChance >= 0 and config.rainbowChance <= 1, "invalid rainbow chance")
    assert(config.rankFiveChance >= 0 and config.rankFiveChance <= 1, "invalid rank-five chance")
    assert(config.secondRainbowChance >= 0 and config.secondRainbowChance <= 1, "invalid second rainbow chance")
end

function RayneMerchant.create(config, shared_state)
    validate_config(config)
    local instance = {
        config = config,
        sharedState = shared_state,
        actor = nil,
        spawner = nil,
        spawnHandle = nil,
        vendor = nil,
        tower = nil,
        spawnCount = 0,
        spawnFailureCount = 0,
        lastSpawnError = nil,
        lastSpawnLocation = nil,
        capturedAnchor = nil,
        capturedAnchorError = nil,
        networkSetupRequests = 0,
        networkSetupComplete = false,
        traitInjectionComplete = false,
        lastShopSetupError = nil,
        traitPasses = 0,
        lastProductCount = 0,
        lastRainbowSelectedCount = 0,
        lastRainbowModifiedCount = 0,
        hostileTargets = {},
        hostileTargetCount = 0,
        lastPlayerScanError = nil,
        monitorScheduled = false,
        monitorGeneration = nil,
        lastRelationPolicyError = nil,
        nativeSetupScheduled = false,
        nativeSpawnRequested = false,
        nativeActorScanBaseline = {},
        actorSource = nil,
        spawnScheduled = false,
        lifecycleGeneration = 0,
        callbacks = {},
    }

    function instance:spawn(source)
        if self.config.enabled ~= true then
            return false, "disabled"
        end
        if is_valid_object(self.actor) or is_valid_object(self.spawner) then
            return true, "already-spawned"
        end
        local tower, tower_error = find_tower(self.config.towerFastTravelPointId)
        if tower == nil then
            self.spawnFailureCount = self.spawnFailureCount + 1
            self.lastSpawnError = tower_error
            log(string.format(
                "SPAWN_DEFERRED source=%s failure=%d reason=%s",
                tostring(source),
                self.spawnFailureCount,
                tostring(tower_error)
            ))
            return false, tower_error
        end

        if type(self.config.fixedSpawnLocation) ~= "table"
            and self.config.capturePlayerAnchorOnLoad
            and self.capturedAnchor == nil then
            local captured_anchor, capture_error = capture_nearest_player_anchor(
                tower,
                self.config
            )
            if captured_anchor == nil then
                self.capturedAnchorError = capture_error
                self.spawnFailureCount = self.spawnFailureCount + 1
                self.lastSpawnError = capture_error
                log(string.format(
                    "ANCHOR_CAPTURE_DEFERRED source=%s failure=%d reason=%s",
                    tostring(source),
                    self.spawnFailureCount,
                    tostring(capture_error)
                ))
                return false, capture_error
            end
            self.capturedAnchor = captured_anchor
            self.capturedAnchorError = nil
            log(string.format(
                "PLAYER_ANCHOR_CAPTURED source=%s player=%s distanceToTower=%.1f location=(%.3f,%.3f,%.3f) rotation=(%.3f,%.3f,%.3f)",
                captured_anchor.playerSource,
                captured_anchor.player,
                captured_anchor.distanceToTower,
                captured_anchor.location.X,
                captured_anchor.location.Y,
                captured_anchor.location.Z,
                captured_anchor.rotation.Pitch,
                captured_anchor.rotation.Yaw,
                captured_anchor.rotation.Roll
            ))
        end

        self.nativeActorScanBaseline =
            collect_native_merchant_actor_names(self.config)
        local spawner, _, spawn_location, spawn_error = spawn_native_spawner(
            tower,
            self.config,
            self.capturedAnchor
        )
        if spawner == nil then
            self.spawnFailureCount = self.spawnFailureCount + 1
            self.lastSpawnError = spawn_error
            log(string.format(
                "SPAWN_FAILED source=%s failure=%d reason=%s",
                tostring(source),
                self.spawnFailureCount,
                tostring(spawn_error)
            ))
            return false, spawn_error
        end

        self.tower = tower
        self.spawner = spawner
        self.actor = nil
        self.spawnHandle = nil
        self.vendor = nil
        self.spawnCount = self.spawnCount + 1
        self.lastSpawnError = nil
        self.lastSpawnLocation = spawn_location
        self.hostileTargets = {}
        self.networkSetupComplete = false
        self.traitInjectionComplete = false
        self.nativeSpawnRequested = false
        self.lastShopSetupError = nil
        log(string.format(
            "NATIVE_SPAWNER_CREATED count=%d source=%s spawner=%s character=%s uniqueNpc=%s level=%d customShop=%s factionHostility=%s relation=%s location=(%.1f,%.1f,%.1f)",
            self.spawnCount,
            tostring(source),
            safe_full_name(spawner),
            self.config.nativeCharacterId,
            self.config.nativeUniqueNpcId,
            self.config.merchantLevel,
            tostring(self.config.enableCustomShop),
            tostring(self.config.enableFactionHostility),
            current_relation(self.sharedState, self.config.factionId),
            spawn_location.X,
            spawn_location.Y,
            spawn_location.Z
        ))
        schedule_native_merchant_setup(self, 1)
        return true, nil
    end

    function instance:schedule_spawn(source, delay_ms)
        if self.config.enabled ~= true or self.spawnScheduled then
            return false
        end
        if type(ExecuteWithDelay) ~= "function" then
            return self:spawn(source)
        end
        self.spawnScheduled = true
        local callback = function()
            local function execute()
                self.spawnScheduled = false
                self:spawn(source)
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(execute)
            else
                execute()
            end
        end
        self.callbacks.spawn = callback
        ExecuteWithDelay(delay_ms or self.config.spawnDelayMs, callback)
        return true
    end

    function instance:on_relation_changed(relation)
        if self.config.enabled ~= true then
            return
        end
        if self.config.enableFactionHostility ~= true then
            return
        end
        -- Destroying and recreating the one merchant is the safe way to clear
        -- a native AI target when diplomacy changes from Hostile to peaceful.
        destroy_actor(self, "relation-change-" .. tostring(relation))
        self:schedule_spawn("relation-change", self.config.relationRespawnDelayMs)
    end

    function instance:respawn(source)
        destroy_actor(self, source or "console-respawn")
        return self:schedule_spawn(source or "console-respawn", self.config.relationRespawnDelayMs)
    end

    function instance:inject_traits()
        if self.config.enableCustomShop ~= true then
            return false, "custom-shop-disabled"
        end
        if self.config.enableRainbowPassives ~= true then
            return false, "rainbow-passives-disabled-for-ue4ss-safety"
        end
        if not is_valid_object(self.actor) or not is_valid_object(self.vendor) then
            return false, "merchant-not-spawned"
        end
        return inject_rainbow_passives(self)
    end

    function instance:status()
        local location = self.lastSpawnLocation
        return string.format(
            "enabled=%s spawner=%s spawned=%s nativeRequested=%s nativePending=%s relation=%s customShop=%s factionHostility=%s shopRow=%s shopRegistered=%s shopRequests=%d spawns=%d failures=%d products=%d rainbowSelected=%d rainbowModified=%d hostileTargets=%d lastError=%s shopError=%s anchorError=%s playerScanError=%s location=%s",
            tostring(self.config.enabled),
            tostring(is_valid_object(self.spawner)),
            tostring(is_valid_object(self.actor)),
            tostring(self.nativeSpawnRequested),
            tostring(self.nativeSetupScheduled),
            current_relation(self.sharedState, self.config.factionId),
            tostring(self.config.enableCustomShop),
            tostring(self.config.enableFactionHostility),
            self.config.shopRowName,
            tostring(self.networkSetupComplete),
            self.networkSetupRequests,
            self.spawnCount,
            self.spawnFailureCount,
            self.lastProductCount,
            self.lastRainbowSelectedCount,
            self.lastRainbowModifiedCount,
            self.hostileTargetCount,
            tostring(self.lastSpawnError or "none"),
            tostring(self.lastShopSetupError or "none"),
            tostring(self.capturedAnchorError or "none"),
            tostring(self.lastPlayerScanError or "none"),
            location and string.format("(%.1f,%.1f,%.1f)", location.X, location.Y, location.Z) or "unset"
        )
    end

    return instance
end

RayneMerchant._test = {
    current_relation = current_relation,
    actor_matches_config = actor_matches_config,
    apply_relation_interaction_policy = apply_relation_interaction_policy,
    choose_rainbow_passives = choose_rainbow_passives,
    unwrap_remote_value = unwrap_remote_value,
    for_each_array = for_each_array,
    replace_first_passives = replace_first_passives,
    find_nearby_native_merchant = find_nearby_native_merchant,
    collect_native_merchant_actor_names = collect_native_merchant_actor_names,
}

return RayneMerchant
