local ProgressionIdentity = require("pwft.progression_identity")

local MultiplayerProfileAuthority = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do
        output[copy(key)] = copy(child)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function positive_integer(value, name)
    assert(type(value) == "number" and value >= 1
            and value == math.floor(value),
        name .. " must be a positive integer")
    return value
end

local function count(values)
    local total = 0
    for _ in pairs(values or {}) do total = total + 1 end
    return total
end

local function normalized_identity(identity)
    assert(type(identity) == "table",
        "multiplayer player identity is required")
    local world = ProgressionIdentity.normalize_world_directory(
        identity.worldDirectory)
    local player = ProgressionIdentity.normalize_guid(identity.playerUid)
    assert(world ~= nil, "multiplayer world identity is invalid")
    assert(player ~= nil, "multiplayer player identity is invalid")
    local profile_key = ProgressionIdentity.build_profile_key(world, player)
    assert(identity.profileKey == profile_key,
        "multiplayer profile key does not match world/player identity")
    assert(identity.serverAuthoritative == true,
        "multiplayer sessions require a server-authoritative controller")
    assert(type(identity.localController) == "boolean",
        "multiplayer local-controller flag must be explicit")
    return {
        schemaVersion = "1.0.0",
        readOnly = true,
        worldDirectory = world,
        playerUid = player,
        profileKey = profile_key,
        serverAuthoritative = true,
        localController = identity.localController,
        connectionRole = require_text(identity.connectionRole,
            "multiplayer connection role"),
        sources = copy(identity.sources or {}),
    }
end

local function context_ready(context)
    return type(context) == "table"
        and type(context.factionApi) == "table"
        and type(context.factionConsequenceRouter) == "table"
        and type(context.progressionStore) == "table"
end

function MultiplayerProfileAuthority.create(options)
    options = options or {}
    assert(options.contextFactory == nil
            or type(options.contextFactory) == "function",
        "multiplayer context factory must be a function")
    assert(options.persistContext == nil
            or type(options.persistContext) == "function",
        "multiplayer persistence callback must be a function")
    return setmetatable({
        version = API_VERSION,
        contextFactory = options.contextFactory,
        persistContext = options.persistContext,
        deferLocalContext = options.deferLocalContext ~= false,
        worldGeneration = nil,
        worldDirectory = nil,
        nextSessionSequence = 0,
        sessionsByController = {},
        sessionsByPlayer = {},
        contextsByPlayer = {},
        acceptedCount = 0,
        rejectedCount = 0,
        reconnectCount = 0,
        logoutCount = 0,
        persistenceFailureCount = 0,
        lastError = nil,
        capabilities = {
            exactWorldPlayerProfiles = true,
            listenHostAndRemotePlayers = true,
            dedicatedServerWithoutLocalController = true,
            authoritativeControllersOnly = true,
            exactControllerSessionBinding = true,
            reconnectGenerationFencing = true,
            perPlayerSidecarContext = true,
            arbitraryClientMutation = false,
            modelAuthority = false,
            directPalworldSaveMutation = false,
        },
    }, { __index = MultiplayerProfileAuthority })
end

function MultiplayerProfileAuthority:bind_world(
    world_directory,
    world_generation
)
    positive_integer(world_generation,
        "multiplayer world generation")
    local world = nil
    if world_directory ~= nil then
        world = ProgressionIdentity.normalize_world_directory(
            world_directory)
        assert(world ~= nil, "multiplayer world directory is invalid")
    end
    if self.worldGeneration ~= nil then
        self:unbind_world("multiplayer-world-rebound")
    end
    self.worldGeneration = world_generation
    self.worldDirectory = world
    return result(true, "multiplayer-world-bound", {
        worldGeneration = world_generation,
        worldDirectory = world,
    })
end

function MultiplayerProfileAuthority:_persist(context, reason)
    if self.persistContext == nil or not context_ready(context) then
        return result(true, "multiplayer-context-persistence-managed")
    end
    local called, response, detail = pcall(
        self.persistContext,
        context,
        reason
    )
    if not called or response == false
        or (type(response) == "table" and response.ok == false) then
        self.persistenceFailureCount =
            self.persistenceFailureCount + 1
        self.lastError = tostring(called
            and (type(response) == "table" and response.reason
                or detail)
            or response)
        return result(false, "multiplayer-context-persistence-failed", {
            persistenceError = self.lastError,
        })
    end
    return type(response) == "table" and response
        or result(true, "multiplayer-context-persisted")
end

function MultiplayerProfileAuthority:_create_context(identity)
    if identity.localController and self.deferLocalContext then
        return nil, "local-profile-context-pending"
    end
    if self.contextFactory == nil then
        return nil, "multiplayer-context-factory-unavailable"
    end
    local called, context, factory_error = pcall(
        self.contextFactory,
        copy(identity)
    )
    if not called or not context_ready(context) then
        return nil, called and tostring(factory_error
                or "multiplayer-context-invalid")
            or tostring(context)
    end
    return context, nil
end

function MultiplayerProfileAuthority:register_session(identity, descriptor)
    local valid, normalized = pcall(normalized_identity, identity)
    if not valid then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = tostring(normalized)
        return result(false, "invalid-multiplayer-player-identity", {
            validationError = self.lastError,
        })
    end
    descriptor = descriptor or {}
    local controller_key = descriptor.controllerKey
    if type(controller_key) ~= "string" or controller_key == "" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-controller-key-required")
    end
    if descriptor.serverAuthoritative ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-server-authoritative-controller-required")
    end
    if self.worldGeneration == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-world-not-bound")
    end
    if descriptor.worldGeneration ~= self.worldGeneration then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-controller-generation-stale")
    end
    if self.worldDirectory == nil then
        self.worldDirectory = normalized.worldDirectory
    elseif self.worldDirectory ~= normalized.worldDirectory then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-controller-world-mismatch")
    end

    local controller_session =
        self.sessionsByController[controller_key]
    if controller_session ~= nil then
        if controller_session.playerUid ~= normalized.playerUid
            or controller_session.profileKey ~= normalized.profileKey then
            self.rejectedCount = self.rejectedCount + 1
            return result(false,
                "multiplayer-controller-identity-conflict")
        end
        return result(true,
            "multiplayer-player-session-already-registered", {
            sessionId = controller_session.sessionId,
            playerUid = normalized.playerUid,
            profileKey = normalized.profileKey,
            contextReady = context_ready(
                self.contextsByPlayer[normalized.playerUid]),
            idempotent = true,
        })
    end

    local previous = self.sessionsByPlayer[normalized.playerUid]
    if previous ~= nil then
        self.sessionsByController[previous.controllerKey] = nil
        self.reconnectCount = self.reconnectCount + 1
    end
    local context = self.contextsByPlayer[normalized.playerUid]
    local context_error = nil
    if context == nil then
        context, context_error = self:_create_context(normalized)
        if context ~= nil then
            self.contextsByPlayer[normalized.playerUid] = context
        elseif not (normalized.localController
                and context_error == "local-profile-context-pending") then
            self.rejectedCount = self.rejectedCount + 1
            self.lastError = context_error
            return result(false,
                "multiplayer-player-context-unavailable", {
                contextError = context_error,
            })
        end
    end

    self.nextSessionSequence = self.nextSessionSequence + 1
    local session_id = string.format(
        "pwft.session.g%d.s%06d.%s",
        self.worldGeneration,
        self.nextSessionSequence,
        normalized.playerUid
    )
    local session = {
        sessionId = session_id,
        playerUid = normalized.playerUid,
        profileKey = normalized.profileKey,
        controllerKey = controller_key,
        localController = normalized.localController,
        connectionRole = normalized.connectionRole,
        worldDirectory = normalized.worldDirectory,
        worldGeneration = self.worldGeneration,
        source = descriptor.source or "native-controller",
        active = true,
    }
    self.sessionsByController[controller_key] = session
    self.sessionsByPlayer[normalized.playerUid] = session
    self.acceptedCount = self.acceptedCount + 1
    return result(true, previous
            and "multiplayer-player-session-reconnected"
            or "multiplayer-player-session-registered", {
        sessionId = session_id,
        playerUid = normalized.playerUid,
        profileKey = normalized.profileKey,
        localController = normalized.localController,
        connectionRole = normalized.connectionRole,
        contextReady = context_ready(context),
        contextReason = context_error,
        reconnected = previous ~= nil,
    })
end

function MultiplayerProfileAuthority:register_local_context(
    identity,
    context
)
    local valid, normalized = pcall(normalized_identity, identity)
    if not valid or normalized.localController ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-local-multiplayer-context", {
            validationError = tostring(normalized),
        })
    end
    if self.worldGeneration == nil
        or (self.worldDirectory ~= nil
            and self.worldDirectory ~= normalized.worldDirectory) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "local-multiplayer-context-world-mismatch")
    end
    if not context_ready(context) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "local-multiplayer-context-incomplete")
    end
    local existing = self.contextsByPlayer[normalized.playerUid]
    if existing ~= nil and existing ~= context then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "local-multiplayer-context-conflict")
    end
    self.contextsByPlayer[normalized.playerUid] = context
    if self.worldDirectory == nil then
        self.worldDirectory = normalized.worldDirectory
    end
    return result(true, "local-multiplayer-context-registered", {
        playerUid = normalized.playerUid,
        profileKey = normalized.profileKey,
        sessionActive = self.sessionsByPlayer[normalized.playerUid]
            ~= nil,
    })
end

function MultiplayerProfileAuthority:context_for_controller(controller_key)
    require_text(controller_key, "multiplayer controller key")
    local session = self.sessionsByController[controller_key]
    if session == nil or session.active ~= true then
        return nil, "multiplayer-controller-session-unavailable"
    end
    if session.worldGeneration ~= self.worldGeneration then
        return nil, "multiplayer-controller-session-stale"
    end
    local context = self.contextsByPlayer[session.playerUid]
    if not context_ready(context) then
        return nil, "multiplayer-player-context-pending"
    end
    return {
        sessionId = session.sessionId,
        playerUid = session.playerUid,
        profileKey = session.profileKey,
        controllerKey = session.controllerKey,
        localController = session.localController,
        connectionRole = session.connectionRole,
        worldGeneration = session.worldGeneration,
        context = context,
        factionApi = context.factionApi,
        factionConsequenceRouter =
            context.factionConsequenceRouter,
        progressionStore = context.progressionStore,
    }, nil
end

function MultiplayerProfileAuthority:context_for_player(player_uid)
    local normalized = ProgressionIdentity.normalize_guid(player_uid)
    if normalized == nil then
        return nil, "multiplayer-player-uid-invalid"
    end
    local session = self.sessionsByPlayer[normalized]
    if session == nil then
        return nil, "multiplayer-player-session-unavailable"
    end
    return self:context_for_controller(session.controllerKey)
end

function MultiplayerProfileAuthority:unregister_controller(
    controller_key,
    world_generation,
    reason
)
    require_text(controller_key, "multiplayer controller key")
    if world_generation ~= self.worldGeneration then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-logout-generation-stale")
    end
    local session = self.sessionsByController[controller_key]
    if session == nil then
        return result(true,
            "multiplayer-player-session-already-unregistered", {
            removed = false,
        })
    end
    session.active = false
    self.sessionsByController[controller_key] = nil
    if self.sessionsByPlayer[session.playerUid] == session then
        self.sessionsByPlayer[session.playerUid] = nil
    end
    local persistence = self:_persist(
        self.contextsByPlayer[session.playerUid],
        reason or "player-logout"
    )
    self.logoutCount = self.logoutCount + 1
    return result(persistence.ok == true,
        persistence.ok == true
            and "multiplayer-player-session-unregistered"
            or persistence.reason, {
        removed = true,
        playerUid = session.playerUid,
        sessionId = session.sessionId,
        persistence = persistence,
    })
end

function MultiplayerProfileAuthority:unbind_world(reason)
    local generation = self.worldGeneration
    local persistence_failures = {}
    for player_uid, context in pairs(self.contextsByPlayer) do
        local persisted = self:_persist(
            context,
            reason or "world-unloading"
        )
        if persisted.ok ~= true then
            persistence_failures[#persistence_failures + 1] = player_uid
        end
    end
    self.sessionsByController = {}
    self.sessionsByPlayer = {}
    self.contextsByPlayer = {}
    self.worldGeneration = nil
    self.worldDirectory = nil
    return result(#persistence_failures == 0,
        #persistence_failures == 0
            and "multiplayer-world-unbound"
            or "multiplayer-world-unbind-persistence-partial", {
        previousWorldGeneration = generation,
        failedPlayerUids = persistence_failures,
    })
end

function MultiplayerProfileAuthority:status()
    local local_sessions = 0
    local remote_sessions = 0
    local pending_contexts = 0
    for _, session in pairs(self.sessionsByController) do
        if session.localController then
            local_sessions = local_sessions + 1
        else
            remote_sessions = remote_sessions + 1
        end
        if not context_ready(
            self.contextsByPlayer[session.playerUid]) then
            pending_contexts = pending_contexts + 1
        end
    end
    return {
        apiVersion = self.version,
        worldGeneration = self.worldGeneration,
        worldDirectory = self.worldDirectory,
        activeSessionCount = count(self.sessionsByController),
        localSessionCount = local_sessions,
        remoteSessionCount = remote_sessions,
        contextCount = count(self.contextsByPlayer),
        pendingContextCount = pending_contexts,
        acceptedCount = self.acceptedCount,
        rejectedCount = self.rejectedCount,
        reconnectCount = self.reconnectCount,
        logoutCount = self.logoutCount,
        persistenceFailureCount = self.persistenceFailureCount,
        lastError = self.lastError,
        capabilities = copy(self.capabilities),
    }
end

return MultiplayerProfileAuthority
