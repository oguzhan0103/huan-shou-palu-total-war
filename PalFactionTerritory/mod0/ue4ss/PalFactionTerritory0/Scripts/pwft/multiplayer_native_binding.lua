local ProgressionIdentity = require("pwft.progression_identity")

local MultiplayerNativeBinding = {}

local API_VERSION = "1.0.0"
local POST_LOGIN_PATH = "/Script/Engine.GameModeBase:K2_PostLogin"
local LOGOUT_PATH = "/Script/Engine.GameModeBase:K2_OnLogout"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function valid(object)
    if object == nil then return false end
    local called, response = pcall(function()
        if object.IsValid ~= nil then return object:IsValid() end
        return true
    end)
    return called and response ~= false
end

local function call(object, method, ...)
    if not valid(object) then return nil end
    local arguments = { ... }
    local called, response = pcall(function()
        if object[method] == nil then return nil end
        return object[method](object, table.unpack(arguments))
    end)
    return called and response or nil
end

local function hook_value(parameter)
    if parameter == nil then return nil end
    local called, response = pcall(function()
        if parameter.get ~= nil then return parameter:get() end
        return parameter
    end)
    return called and response or parameter
end

local function default_controller_key(controller)
    local name = call(controller, "GetFullName")
    if type(name) == "string" and name ~= "" then return name end
    local called, rendered = pcall(tostring, controller)
    if called and type(rendered) == "string" and rendered ~= "" then
        return rendered
    end
    return nil
end

local function default_schedule(delay_ms, callback)
    if type(_G.ExecuteWithDelay) ~= "function" then return false end
    _G.ExecuteWithDelay(delay_ms, function()
        if type(_G.ExecuteInGameThread) == "function" then
            _G.ExecuteInGameThread(callback)
        else
            callback()
        end
    end)
    return true
end

local function default_find_all(class_name)
    if type(_G.FindAllOf) ~= "function" then return nil end
    local called, values = pcall(_G.FindAllOf, class_name)
    return called and values or nil
end

function MultiplayerNativeBinding.create(authority, options)
    assert(type(authority) == "table"
            and type(authority.register_session) == "function"
            and type(authority.unregister_controller) == "function"
            and type(authority.context_for_controller) == "function",
        "multiplayer profile authority is required")
    options = options or {}
    local retry_delays = options.retryDelaysMs or {
        0, 250, 1000, 3000, 8000,
    }
    assert(type(retry_delays) == "table" and #retry_delays > 0,
        "multiplayer identity retry delays are required")
    return setmetatable({
        version = API_VERSION,
        authority = authority,
        registerHook = options.registerHook or _G.RegisterHook,
        findAllOf = options.findAllOf or default_find_all,
        resolveIdentity = options.resolveIdentity
            or ProgressionIdentity.resolve_controller,
        controllerKey = options.controllerKey
            or default_controller_key,
        schedule = options.schedule or default_schedule,
        logger = options.logger,
        retryDelaysMs = retry_delays,
        worldGeneration = nil,
        controllersByKey = {},
        retainedCallbacks = {},
        postLoginHook = nil,
        logoutHook = nil,
        started = false,
        discoveredCount = 0,
        registeredCount = 0,
        rejectedCount = 0,
        clientObserverCount = 0,
        retryCount = 0,
        logoutCount = 0,
        lastError = nil,
        capabilities = {
            postLoginHook = true,
            logoutHook = true,
            existingControllerEnumeration = true,
            exactPlayerUidResolution = true,
            listenHostAndRemoteServerControllers = true,
            dedicatedServerWithoutLocalController = true,
            nonAuthoritativeClientObserverOnly = true,
            noCustomClientRpcTrust = true,
            worldGenerationFencing = true,
            broadPawnAttribution = false,
            directPalworldSaveMutation = false,
        },
    }, { __index = MultiplayerNativeBinding })
end

function MultiplayerNativeBinding:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[MultiplayerNativeBinding] " .. tostring(message))
    end
end

function MultiplayerNativeBinding:_key(controller)
    local called, key = pcall(self.controllerKey, controller)
    if not called or type(key) ~= "string" or key == "" then
        return nil
    end
    return key
end

function MultiplayerNativeBinding:_schedule_retry(
    controller,
    source,
    attempt
)
    if attempt > #self.retryDelaysMs then return false end
    local expected_generation = self.worldGeneration
    local callback = function()
        if self.worldGeneration == expected_generation then
            self:_activate_controller(controller, source, attempt)
        end
    end
    self.retainedCallbacks[#self.retainedCallbacks + 1] = callback
    local called, accepted = pcall(
        self.schedule,
        self.retryDelaysMs[attempt],
        callback
    )
    if not called or accepted == false then
        self.lastError = "multiplayer-identity-retry-scheduler-unavailable"
        return false
    end
    self.retryCount = self.retryCount + 1
    return true
end

function MultiplayerNativeBinding:_activate_controller(
    controller,
    source,
    attempt
)
    if self.worldGeneration == nil or not valid(controller) then
        return result(false, "multiplayer-controller-unavailable")
    end
    attempt = attempt or 1
    local key = self:_key(controller)
    if key == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-controller-key-unavailable")
    end
    local called, identity, identity_error = pcall(
        self.resolveIdentity,
        controller,
        { controllerSource = source }
    )
    if not called then
        identity_error = tostring(identity)
        identity = nil
    end
    if identity == nil then
        if attempt < #self.retryDelaysMs
            and self:_schedule_retry(
                controller,
                source,
                attempt + 1
            ) then
            return result(false,
                "multiplayer-controller-identity-retry-pending", {
                controllerKey = key,
                identityError = tostring(identity_error),
                retryAttempt = attempt + 1,
            })
        end
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = tostring(identity_error)
        return result(false,
            "multiplayer-controller-identity-unavailable", {
            controllerKey = key,
            identityError = tostring(identity_error),
        })
    end
    self.discoveredCount = self.discoveredCount + 1
    if identity.serverAuthoritative ~= true then
        self.clientObserverCount = self.clientObserverCount + 1
        self:_log(string.format(
            "CLIENT_OBSERVER_ONLY controller=%s player=%s role=%s mutations=false",
            key,
            tostring(identity.playerUid),
            tostring(identity.connectionRole)
        ))
        return result(true, "multiplayer-client-observer-only", {
            controllerKey = key,
            playerUid = identity.playerUid,
            registered = false,
            mutationsAllowed = false,
        })
    end
    local registered = self.authority:register_session(identity, {
        controllerKey = key,
        serverAuthoritative = true,
        worldGeneration = self.worldGeneration,
        source = source,
    })
    if registered.ok then
        self.controllersByKey[key] = controller
        self.registeredCount = self.registeredCount + 1
        self:_log(string.format(
            "PLAYER_SESSION_READY controller=%s player=%s role=%s local=%s context=%s generation=%d",
            key,
            tostring(registered.playerUid),
            tostring(registered.connectionRole),
            tostring(registered.localController == true),
            tostring(registered.contextReady == true),
            self.worldGeneration
        ))
    else
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = registered.reason
    end
    return registered
end

function MultiplayerNativeBinding:_deactivate_controller(
    controller,
    source
)
    if self.worldGeneration == nil then
        return result(true, "multiplayer-world-already-unbound")
    end
    local key = self:_key(controller)
    if key == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-controller-key-unavailable")
    end
    local removed = self.authority:unregister_controller(
        key,
        self.worldGeneration,
        source or "K2_OnLogout"
    )
    self.controllersByKey[key] = nil
    if removed.ok and removed.removed then
        self.logoutCount = self.logoutCount + 1
    end
    return removed
end

function MultiplayerNativeBinding:_register_hooks()
    if self.postLoginHook ~= nil and self.logoutHook ~= nil then
        return true
    end
    if type(self.registerHook) ~= "function" then
        self.lastError = "RegisterHook-unavailable"
        return false
    end
    local post_callback = function(_, new_player_parameter)
        local controller = hook_value(new_player_parameter)
        local called, response = pcall(function()
            return self:_activate_controller(
                controller,
                "K2_PostLogin.NewPlayer",
                1
            )
        end)
        if not called then
            self.lastError = tostring(response)
            self:_log("POST_LOGIN_ERROR " .. self.lastError)
        end
    end
    local logout_callback = function(_, exiting_controller_parameter)
        local controller = hook_value(exiting_controller_parameter)
        local called, response = pcall(function()
            return self:_deactivate_controller(
                controller,
                "K2_OnLogout.ExitingController"
            )
        end)
        if not called then
            self.lastError = tostring(response)
            self:_log("LOGOUT_ERROR " .. self.lastError)
        end
    end
    local post_ok, post_hook = pcall(
        self.registerHook,
        POST_LOGIN_PATH,
        post_callback
    )
    local logout_ok, logout_hook = pcall(
        self.registerHook,
        LOGOUT_PATH,
        logout_callback
    )
    if not post_ok or post_hook == false
        or not logout_ok or logout_hook == false then
        self.lastError = string.format(
            "postLogin=%s;logout=%s",
            tostring(post_ok and post_hook or false),
            tostring(logout_ok and logout_hook or false)
        )
        return false
    end
    self.postLoginHook = post_hook or post_callback
    self.logoutHook = logout_hook or logout_callback
    self.retainedCallbacks[#self.retainedCallbacks + 1] = post_callback
    self.retainedCallbacks[#self.retainedCallbacks + 1] = logout_callback
    return true
end

function MultiplayerNativeBinding:scan_existing(source)
    if self.worldGeneration == nil then
        return result(false, "multiplayer-world-not-bound")
    end
    local found = nil
    for _, class_name in ipairs({
        "PalPlayerController",
        "PalPlayerController_C",
    }) do
        local called, values = pcall(self.findAllOf, class_name)
        if called and type(values) == "table" and #values > 0 then
            found = values
            break
        end
    end
    if found == nil then
        return result(true, "multiplayer-no-existing-controllers", {
            discovered = 0,
        })
    end
    local outcomes = {}
    local seen = {}
    for _, controller in ipairs(found) do
        local key = self:_key(controller)
        if key ~= nil and not seen[key] then
            seen[key] = true
            outcomes[#outcomes + 1] = self:_activate_controller(
                controller,
                source or "world-controller-scan",
                1
            )
        end
    end
    return result(true, "multiplayer-existing-controllers-scanned", {
        discovered = #outcomes,
        outcomes = outcomes,
    })
end

function MultiplayerNativeBinding:start(world_generation)
    assert(type(world_generation) == "number"
            and world_generation >= 1
            and world_generation == math.floor(world_generation),
        "multiplayer native world generation is invalid")
    self.worldGeneration = world_generation
    if not self:_register_hooks() then
        return result(false,
            "multiplayer-native-hook-registration-failed", self:status())
    end
    self.started = true
    local scan = self:scan_existing("native-binding-start")
    return result(true, "multiplayer-native-binding-started", {
        worldGeneration = world_generation,
        existingControllerCount = scan.discovered or 0,
        hookReady = true,
    })
end

function MultiplayerNativeBinding:on_world_loaded(world_generation)
    self.worldGeneration = world_generation
    return self:scan_existing("load-map-post")
end

function MultiplayerNativeBinding:controller_for_player(player_uid)
    local normalized = ProgressionIdentity.normalize_guid(player_uid)
    if normalized == nil then
        return nil, "multiplayer-player-uid-invalid"
    end
    local matched_controller = nil
    local matched_context = nil
    for controller_key, controller in pairs(self.controllersByKey) do
        if valid(controller) then
            local context = self.authority
                :context_for_controller(controller_key)
            if context ~= nil and context.playerUid == normalized then
                if matched_controller ~= nil
                    and matched_controller ~= controller then
                    return nil,
                        "multiplayer-player-controller-ambiguous"
                end
                matched_controller = controller
                matched_context = context
            end
        end
    end
    if matched_controller == nil then
        return nil, "multiplayer-player-controller-unavailable"
    end
    return matched_controller, nil, matched_context
end

function MultiplayerNativeBinding:resolve_controller(controller)
    local key = self:_key(controller)
    if key == nil then
        return nil, "multiplayer-controller-key-unavailable"
    end
    return self.authority:context_for_controller(key)
end

function MultiplayerNativeBinding:unbind_world(reason)
    local previous = self.worldGeneration
    self.worldGeneration = nil
    self.controllersByKey = {}
    local unbound = self.authority:unbind_world(
        reason or "native-world-unloading")
    return result(unbound.ok == true,
        unbound.ok == true
            and "multiplayer-native-world-unbound"
            or unbound.reason, {
        previousWorldGeneration = previous,
        authority = unbound,
    })
end

function MultiplayerNativeBinding:status()
    local authority_status = self.authority:status()
    return {
        apiVersion = self.version,
        started = self.started,
        worldGeneration = self.worldGeneration,
        postLoginHookPath = POST_LOGIN_PATH,
        logoutHookPath = LOGOUT_PATH,
        postLoginHookReady = self.postLoginHook ~= nil,
        logoutHookReady = self.logoutHook ~= nil,
        trackedControllerCount = authority_status.activeSessionCount,
        localSessionCount = authority_status.localSessionCount,
        remoteSessionCount = authority_status.remoteSessionCount,
        pendingContextCount = authority_status.pendingContextCount,
        discoveredCount = self.discoveredCount,
        registeredCount = self.registeredCount,
        rejectedCount = self.rejectedCount,
        clientObserverCount = self.clientObserverCount,
        retryCount = self.retryCount,
        logoutCount = self.logoutCount,
        lastError = self.lastError,
        capabilities = self.capabilities,
    }
end

MultiplayerNativeBinding.paths = {
    postLogin = POST_LOGIN_PATH,
    logout = LOGOUT_PATH,
}

return MultiplayerNativeBinding
