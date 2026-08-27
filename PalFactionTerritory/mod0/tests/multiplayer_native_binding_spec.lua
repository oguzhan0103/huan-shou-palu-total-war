package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local MultiplayerProfileAuthority =
    require("pwft.multiplayer_profile_authority")
local MultiplayerNativeBinding =
    require("pwft.multiplayer_native_binding")

local world = "E0D5ECDC46B379829F8F31A729ACFD92"
local function uid(prefix)
    return prefix .. "09AB288B1234567887654321ABCDEF0"
end

local function controller(key, player_uid, authority, is_local)
    return {
        key = key,
        playerUid = player_uid,
        authority = authority,
        localController = is_local,
        IsValid = function() return true end,
        GetFullName = function(self) return self.key end,
    }
end

local host = controller("Controller Host", uid("D"), true, true)
local remote = controller("Controller Remote", uid("A"), true, false)
local client = controller("Controller Client", uid("B"), false, true)
local joined = controller("Controller Joined", uid("C"), true, false)

local function context(player_uid)
    return {
        playerUid = player_uid,
        factionApi = {},
        factionConsequenceRouter = {},
        progressionStore = {},
    }
end

local authority = MultiplayerProfileAuthority.create({
    deferLocalContext = false,
    contextFactory = function(identity)
        return context(identity.playerUid)
    end,
})
authority:bind_world(world, 3)

local hooks = {}
local binding = MultiplayerNativeBinding.create(authority, {
    registerHook = function(path, callback)
        hooks[path] = callback
        return callback
    end,
    findAllOf = function(class_name)
        if class_name == "PalPlayerController" then
            return { host, remote, client }
        end
        return nil
    end,
    resolveIdentity = function(value, options)
        return {
            schemaVersion = "1.0.0",
            worldDirectory = world,
            playerUid = value.playerUid,
            profileKey = "world-" .. world
                .. ".player-" .. value.playerUid,
            serverAuthoritative = value.authority,
            localController = value.localController,
            connectionRole = value.authority
                    and (value.localController
                        and "listen-or-standalone-host"
                        or "server-remote-controller")
                or "remote-client-local-controller",
            sources = { controller = options.controllerSource },
        }, nil
    end,
    controllerKey = function(value) return value.key end,
    schedule = function(_, callback)
        callback()
        return true
    end,
    retryDelaysMs = { 0, 1 },
})

local started = binding:start(3)
assert(started.ok and started.existingControllerCount == 3)
local status = binding:status()
assert(status.postLoginHookReady and status.logoutHookReady)
assert(status.trackedControllerCount == 2)
assert(status.localSessionCount == 1)
assert(status.remoteSessionCount == 1)
assert(status.clientObserverCount == 1)

local remote_context = binding:resolve_controller(remote)
assert(remote_context.playerUid == remote.playerUid)
assert(remote_context.context.playerUid == remote.playerUid)
assert(binding:resolve_controller(client) == nil)
local remote_controller, remote_controller_error,
    resolved_remote_context = binding:controller_for_player(remote.playerUid)
assert(remote_controller == remote)
assert(remote_controller_error == nil)
assert(resolved_remote_context.playerUid == remote.playerUid)
assert(binding:controller_for_player(client.playerUid) == nil)

hooks[MultiplayerNativeBinding.paths.postLogin](nil, {
    get = function() return joined end,
})
assert(binding:status().remoteSessionCount == 2)
assert(binding:resolve_controller(joined).playerUid == joined.playerUid)

hooks[MultiplayerNativeBinding.paths.logout](nil, {
    get = function() return remote end,
})
assert(binding:status().remoteSessionCount == 1)
assert(binding:resolve_controller(remote) == nil)
assert(binding:controller_for_player(remote.playerUid) == nil)
assert(binding:status().logoutCount == 1)

local unbound = binding:unbind_world("test-complete")
assert(unbound.ok)
assert(binding:status().trackedControllerCount == 0)

print("PASS multiplayer native binding (post-login, logout, scan, client observer, dedicated-ready)")
