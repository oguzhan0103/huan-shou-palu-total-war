local ProgressionIdentity = {}

local UINT32_MODULUS = 4294967296
local UINT16_MODULUS = 65536

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function unwrap(value)
    if value == nil then
        return nil
    end
    local ok, unwrapped = pcall(function()
        if value.get ~= nil then
            return value:get()
        end
        if value.ToString ~= nil then
            local text = value:ToString()
            if type(text) == "string" then
                return text
            end
        end
        return value
    end)
    if ok then
        return unwrapped
    end
    return value
end

local function safe_property(object, name)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[name]
    end)
    if not ok then
        return nil
    end
    return unwrap(value)
end

local function is_valid_object(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        if object.IsValid ~= nil then
            return object:IsValid()
        end
        return true
    end)
    return ok and valid ~= false
end

local function safe_call(object, method_name, ...)
    if not is_valid_object(object) then
        return nil, "object-unavailable"
    end
    local arguments = { ... }
    local ok, result = pcall(function()
        local method = object[method_name]
        if method == nil then
            error("method-unavailable")
        end
        return method(object, table.unpack(arguments))
    end)
    if not ok then
        return nil, tostring(result)
    end
    return unwrap(result), nil
end

local function uint32(value)
    local number = tonumber(unwrap(value))
    if number == nil or number ~= math.floor(number) then
        return nil
    end
    if number < 0 then
        number = number + UINT32_MODULUS
    end
    if number < 0 or number >= UINT32_MODULUS then
        return nil
    end
    return number
end

local function uint32_hex(value)
    local number = uint32(value)
    if number == nil then
        return nil
    end
    -- Split the value before formatting. This avoids Lua implementations
    -- coercing an unsigned 32-bit value through a signed integer.
    local high = math.floor(number / UINT16_MODULUS)
    local low = number % UINT16_MODULUS
    return string.format("%04X%04X", high, low)
end

local function normalize_hex_guid_string(value)
    local text = trim(value)
    if text == nil or text == "" then
        return nil
    end
    if string.find(text, "^[%x{}%-]+$") == nil then
        return nil
    end
    local compact = string.upper(string.gsub(text, "[{}%-]", ""))
    if #compact ~= 32 or string.find(compact, "^%x+$") == nil then
        return nil
    end
    if compact == string.rep("0", 32) then
        return nil
    end
    return compact
end

local function normalize_guid_text_representation(value)
    if value == nil then
        return nil
    end
    local ok, text = pcall(tostring, value)
    if not ok or type(text) ~= "string" then
        return nil
    end
    local direct = normalize_hex_guid_string(text)
    if direct ~= nil then
        return direct
    end
    -- UE4SS may expose an FString return value as userdata whose tostring()
    -- representation includes a type label. Accept only a delimited 32-hex
    -- token so a pointer/address or arbitrary userdata label cannot become a
    -- profile identity by accident.
    for token in string.gmatch(text, "[%x%-{}]+") do
        local normalized = normalize_hex_guid_string(token)
        if normalized ~= nil then
            return normalized
        end
    end
    return nil
end

function ProgressionIdentity.normalize_guid(value)
    if type(value) == "string" then
        return normalize_hex_guid_string(value)
    end
    if value == nil then
        return nil
    end
    local segments = {}
    for _, field_name in ipairs({ "A", "B", "C", "D" }) do
        local encoded = uint32_hex(safe_property(value, field_name))
        if encoded == nil then
            return nil
        end
        table.insert(segments, encoded)
    end
    local compact = table.concat(segments)
    if compact == string.rep("0", 32) then
        return nil
    end
    return compact
end

function ProgressionIdentity.normalize_world_directory(value)
    if type(value) == "string" then
        return normalize_hex_guid_string(value)
    end
    return normalize_guid_text_representation(value)
end

function ProgressionIdentity.build_profile_key(world_directory, player_uid)
    local world = ProgressionIdentity.normalize_world_directory(world_directory)
    if world == nil then
        return nil, "world-directory-invalid"
    end
    local player = ProgressionIdentity.normalize_guid(player_uid)
    if player == nil then
        return nil, "player-uid-invalid"
    end
    return "world-" .. world .. ".player-" .. player, nil
end

local function find_first_of(class_name, adapters)
    local finder = adapters.findFirstOf or _G.FindFirstOf
    if type(finder) ~= "function" then
        return nil
    end
    local ok, object = pcall(finder, class_name)
    if ok and is_valid_object(object) then
        return object
    end
    return nil
end

local function get_utility(adapters)
    if type(adapters.getPalUtility) == "function" then
        local ok, utility = pcall(adapters.getPalUtility)
        if ok and is_valid_object(utility) then
            return utility
        end
    end
    local finder = adapters.staticFindObject or _G.StaticFindObject
    if type(finder) ~= "function" then
        return nil
    end
    local ok, utility = pcall(
        finder,
        "/Script/Pal.Default__PalUtility"
    )
    if ok and is_valid_object(utility) then
        return utility
    end
    return nil
end

local function get_local_controller(adapters)
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
    for _, class_name in ipairs({
        "PalPlayerController",
        "PalPlayerController_C",
    }) do
        local controller = find_first_of(class_name, adapters)
        if controller ~= nil then
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
    return nil, "local-player-controller-not-ready"
end

local function get_world_state(controller, utility, adapters)
    if type(adapters.getGameState) == "function" then
        local ok, game_state = pcall(
            adapters.getGameState,
            controller
        )
        if ok and is_valid_object(game_state) then
            return game_state, "adapter"
        end
    end
    if is_valid_object(utility) then
        local game_state = safe_call(
            utility,
            "GetPalGameStateInGame",
            controller
        )
        if is_valid_object(game_state) then
            return game_state, "PalUtility.GetPalGameStateInGame"
        end
    end
    local game_state = find_first_of(
        "PalGameStateInGame",
        adapters
    )
    if game_state ~= nil then
        return game_state, "FindFirstOf(PalGameStateInGame)"
    end
    return nil, "game-state-not-ready"
end

local function get_world_directory(game_state)
    local raw, call_error = safe_call(
        game_state,
        "GetWorldSaveDirectoryName"
    )
    local normalized =
        ProgressionIdentity.normalize_world_directory(raw)
    if normalized == nil then
        local raw_type = type(raw)
        local raw_text = "<unavailable>"
        pcall(function()
            raw_text = tostring(raw)
        end)
        return nil,
            string.format(
                "world-directory-not-ready:%s:rawType=%s:rawText=%s",
                tostring(call_error),
                tostring(raw_type),
                tostring(raw_text)
            )
    end
    return normalized, "PalGameStateInGame.GetWorldSaveDirectoryName"
end

local function get_player_uid(controller, utility)
    local uid = safe_call(controller, "GetPlayerUId")
    local normalized = ProgressionIdentity.normalize_guid(uid)
    if normalized ~= nil then
        return normalized, "PalPlayerController.GetPlayerUId"
    end

    local player_state = safe_call(
        controller,
        "GetPalPlayerState"
    )
    if not is_valid_object(player_state) then
        player_state = safe_property(controller, "PlayerState")
    end
    normalized = ProgressionIdentity.normalize_guid(
        safe_property(player_state, "PlayerUId")
    )
    if normalized ~= nil then
        return normalized, "PalPlayerState.PlayerUId"
    end

    if is_valid_object(utility) then
        uid = safe_call(
            utility,
            "GetLocalPlayerUID",
            controller
        )
        normalized = ProgressionIdentity.normalize_guid(uid)
        if normalized ~= nil then
            return normalized, "PalUtility.GetLocalPlayerUID"
        end
    end
    return nil, "player-uid-not-ready"
end

local function controller_traits(controller)
    local has_authority = safe_call(controller, "HasAuthority") == true
    local is_local = safe_call(
        controller,
        "IsLocalPlayerController"
    ) == true
    local role = "non-authoritative-controller"
    if has_authority and is_local then
        role = "listen-or-standalone-host"
    elseif has_authority then
        role = "server-remote-controller"
    elseif is_local then
        role = "remote-client-local-controller"
    end
    return {
        serverAuthoritative = has_authority,
        localController = is_local,
        connectionRole = role,
    }
end

function ProgressionIdentity.resolve_controller(controller, adapters)
    adapters = adapters or {}
    if not is_valid_object(controller) then
        return nil, "player-controller-not-ready"
    end
    local utility = get_utility(adapters)
    local game_state, game_state_source =
        get_world_state(controller, utility, adapters)
    if game_state == nil then
        return nil, game_state_source
    end
    local world_directory, world_source =
        get_world_directory(game_state)
    if world_directory == nil then
        return nil, world_source
    end
    local player_uid, player_source =
        get_player_uid(controller, utility)
    if player_uid == nil then
        return nil, player_source
    end
    local profile_key, profile_error =
        ProgressionIdentity.build_profile_key(
            world_directory,
            player_uid
        )
    if profile_key == nil then
        return nil, profile_error
    end
    local traits = controller_traits(controller)
    return {
        schemaVersion = "1.0.0",
        readOnly = true,
        worldDirectory = world_directory,
        playerUid = player_uid,
        profileKey = profile_key,
        serverAuthoritative = traits.serverAuthoritative,
        localController = traits.localController,
        connectionRole = traits.connectionRole,
        sources = {
            controller = adapters.controllerSource
                or "explicit-player-controller",
            gameState = game_state_source,
            world = world_source,
            player = player_source,
        },
    }, nil
end

function ProgressionIdentity.resolve_native(adapters)
    adapters = adapters or {}
    local controller, controller_source =
        get_local_controller(adapters)
    if controller == nil then
        return nil, controller_source
    end
    local controller_adapters = {}
    for key, value in pairs(adapters) do
        controller_adapters[key] = value
    end
    controller_adapters.controllerSource = controller_source
    return ProgressionIdentity.resolve_controller(
        controller,
        controller_adapters
    )
end

return ProgressionIdentity
