package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local MultiplayerProfileAuthority =
    require("pwft.multiplayer_profile_authority")

local world = "E0D5ECDC46B379829F8F31A729ACFD92"
local host_uid = "D9AB288B1234567887654321ABCDEF01"
local remote_uid = "A9AB288B1234567887654321ABCDEF02"

local function identity(player_uid, is_local)
    return {
        schemaVersion = "1.0.0",
        worldDirectory = world,
        playerUid = player_uid,
        profileKey = "world-" .. world .. ".player-" .. player_uid,
        serverAuthoritative = true,
        localController = is_local,
        connectionRole = is_local
                and "listen-or-standalone-host"
            or "server-remote-controller",
        sources = { controller = "test" },
    }
end

local persisted = {}
local created = {}
local function make_context(player_uid)
    return {
        playerUid = player_uid,
        factionApi = {},
        factionConsequenceRouter = {},
        progressionStore = {},
    }
end

local authority = MultiplayerProfileAuthority.create({
    contextFactory = function(value)
        created[#created + 1] = value.playerUid
        return make_context(value.playerUid)
    end,
    persistContext = function(context, reason)
        persisted[#persisted + 1] = context.playerUid .. ":" .. reason
        return { ok = true, reason = "saved" }
    end,
})

local bound = authority:bind_world(nil, 7)
assert(bound.ok and bound.worldGeneration == 7)

local remote = authority:register_session(identity(remote_uid, false), {
    controllerKey = "PalPlayerController Remote1",
    serverAuthoritative = true,
    worldGeneration = 7,
    source = "K2_PostLogin",
})
assert(remote.ok and remote.contextReady)
assert(remote.connectionRole == "server-remote-controller")
assert(#created == 1 and created[1] == remote_uid)

local remote_context = authority:context_for_controller(
    "PalPlayerController Remote1")
assert(remote_context.playerUid == remote_uid)
assert(remote_context.context.playerUid == remote_uid)

local duplicate = authority:register_session(
    identity(remote_uid, false),
    {
        controllerKey = "PalPlayerController Remote1",
        serverAuthoritative = true,
        worldGeneration = 7,
    }
)
assert(duplicate.ok and duplicate.idempotent)
assert(#created == 1)

local reconnect = authority:register_session(
    identity(remote_uid, false),
    {
        controllerKey = "PalPlayerController Remote2",
        serverAuthoritative = true,
        worldGeneration = 7,
    }
)
assert(reconnect.ok and reconnect.reconnected)
assert(authority:context_for_controller(
    "PalPlayerController Remote1") == nil)
assert(authority:context_for_controller(
    "PalPlayerController Remote2").context == remote_context.context)

local host = authority:register_session(identity(host_uid, true), {
    controllerKey = "PalPlayerController Host",
    serverAuthoritative = true,
    worldGeneration = 7,
})
assert(host.ok and host.contextReady == false)
assert(host.contextReason == "local-profile-context-pending")
assert(authority:context_for_controller(
    "PalPlayerController Host") == nil)
local host_context = make_context(host_uid)
local local_registered = authority:register_local_context(
    identity(host_uid, true),
    host_context
)
assert(local_registered.ok and local_registered.sessionActive)
assert(authority:context_for_player(host_uid).context == host_context)

local client_identity = identity(
    "B9AB288B1234567887654321ABCDEF03",
    true
)
client_identity.serverAuthoritative = false
local client = authority:register_session(client_identity, {
    controllerKey = "PalPlayerController Client",
    serverAuthoritative = false,
    worldGeneration = 7,
})
assert(not client.ok)
assert(client.reason == "invalid-multiplayer-player-identity")

local spoof = authority:register_session(identity(remote_uid, false), {
    controllerKey = "PalPlayerController Spoof",
    serverAuthoritative = false,
    worldGeneration = 7,
})
assert(not spoof.ok)
assert(spoof.reason
    == "multiplayer-server-authoritative-controller-required")

local stale_logout = authority:unregister_controller(
    "PalPlayerController Remote2", 6, "stale")
assert(not stale_logout.ok)
assert(authority:context_for_controller(
    "PalPlayerController Remote2") ~= nil)

local logout = authority:unregister_controller(
    "PalPlayerController Remote2", 7, "remote-logout")
assert(logout.ok and logout.removed)
assert(#persisted == 1)
assert(persisted[1] == remote_uid .. ":remote-logout")

local status = authority:status()
assert(status.activeSessionCount == 1)
assert(status.localSessionCount == 1)
assert(status.remoteSessionCount == 0)
assert(status.contextCount == 2)
assert(status.reconnectCount == 1)
assert(status.logoutCount == 1)
assert(status.capabilities.dedicatedServerWithoutLocalController == true)
assert(status.capabilities.arbitraryClientMutation == false)

local unbound = authority:unbind_world("test-complete")
assert(unbound.ok)
assert(authority:status().activeSessionCount == 0)
assert(authority:status().contextCount == 0)
assert(#persisted == 3)

print("PASS multiplayer profile authority (listen host, remote, reconnect, logout, generation fence, dedicated-ready)")
