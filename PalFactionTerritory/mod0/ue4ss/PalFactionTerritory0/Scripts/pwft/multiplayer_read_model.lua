local ProgressionIdentity = require("pwft.progression_identity")

local MultiplayerReadModel = {}

local API_VERSION = "1.0.0"
local SCHEMA_VERSION = "1.0.0"
local AUTHORITY = "pwft.server-read-model.v1"

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

local function safe_value(value, depth)
    local kind = type(value)
    if kind == "nil" or kind == "boolean"
        or kind == "number" or kind == "string" then
        return true
    end
    if kind ~= "table" or depth > 8 then return false end
    for key, child in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" then
            return false
        end
        if not safe_value(child, depth + 1) then return false end
    end
    return true
end

local function non_negative_integer(value)
    return type(value) == "number" and value >= 0
        and value == math.floor(value)
end

local function player_context(value)
    if type(value) ~= "table" then return nil end
    return type(value.context) == "table" and value.context or value
end

local function safe_faction_row(faction_id, status, pal_status)
    local row = {
        factionId = faction_id,
        kind = status.kind,
        reputation = status.reputation,
        relation = status.relation,
        joined = status.joined == true,
        rankId = status.rankId,
        guardAccess = status.guardAccess == true,
        joinEligible = status.joinEligible == true,
        diplomacyHostilitySources =
            copy(status.diplomacyHostilitySources or {}),
    }
    if type(pal_status) == "table" then
        row.reconciliation = {
            configured = pal_status.configured == true,
            tokenQuota = pal_status.tokenQuota,
            tokensAwarded = pal_status.tokensAwarded,
            tokensConsumed = pal_status.tokensConsumed,
            technicalRefunds = pal_status.technicalRefunds,
            locked = pal_status.locked == true,
            reconciled = pal_status.reconciled == true,
            remainingAwardCapacity = pal_status.remainingAwardCapacity,
            availableQuestTokens = pal_status.availableQuestTokens,
            completedQuestTokens = pal_status.completedQuestTokens,
        }
    end
    return row
end

function MultiplayerReadModel.create(registry, options)
    assert(type(registry) == "table"
            and type(registry.progression) == "table",
        "multiplayer read-model registry is required")
    options = options or {}
    assert(type(options.contextResolver) == "function",
        "multiplayer read-model context resolver is required")
    assert(options.localIdentityResolver == nil
            or type(options.localIdentityResolver) == "function",
        "multiplayer local identity resolver must be a function")
    return setmetatable({
        version = API_VERSION,
        registry = registry,
        contextResolver = options.contextResolver,
        localIdentityResolver = options.localIdentityResolver,
        sequenceByPlayer = {},
        clientViewsByPlayer = {},
        publishedCount = 0,
        acceptedCount = 0,
        rejectedCount = 0,
        staleCount = 0,
        lastError = nil,
        capabilities = {
            exactPlayerReadModels = true,
            worldGenerationFencing = true,
            monotonicSequence = true,
            crossPlayerSnapshotRejected = true,
            mutationFieldsExcluded = true,
            serverStateMutation = false,
            modelAuthority = false,
            nativeTransportBound = false,
            directPalworldSaveMutation = false,
        },
    }, { __index = MultiplayerReadModel })
end

function MultiplayerReadModel:publish(player_uid, world_generation)
    local normalized = ProgressionIdentity.normalize_guid(player_uid)
    if normalized == nil or type(world_generation) ~= "number"
        or world_generation < 1
        or world_generation ~= math.floor(world_generation) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-read-model-request-invalid")
    end
    local called, resolved, resolve_error = pcall(
        self.contextResolver, normalized)
    local context = called and player_context(resolved) or nil
    if context == nil
        or type(context.identity) ~= "table"
        or context.identity.playerUid ~= normalized
        or context.identity.serverAuthoritative ~= true
        or type(context.factionProgression) ~= "table"
        or type(context.factionProgression.status) ~= "function" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-read-model-player-context-unavailable", {
                contextError = tostring(called
                    and resolve_error or resolved),
            })
    end
    local rows = {}
    local faction_ids = {}
    for _, faction_id in ipairs(
        self.registry.progression.humanFactionIds or {}) do
        faction_ids[#faction_ids + 1] = faction_id
    end
    for _, faction_id in ipairs(
        self.registry.progression.palFactionIds or {}) do
        faction_ids[#faction_ids + 1] = faction_id
    end
    for _, faction_id in ipairs(faction_ids) do
        local status = context.factionProgression:status(faction_id)
        if type(status) ~= "table" then
            self.rejectedCount = self.rejectedCount + 1
            return result(false,
                "multiplayer-read-model-faction-status-unavailable", {
                    factionId = faction_id,
                })
        end
        local pal_status = nil
        if status.kind == "Pal"
            and type(context.palReconciliation) == "table"
            and type(context.palReconciliation.status) == "function" then
            pal_status = context.palReconciliation:status(faction_id)
        end
        rows[#rows + 1] = safe_faction_row(
            faction_id, status, pal_status)
    end
    local root_status = context.factionProgression:status()
    local sequence = (self.sequenceByPlayer[normalized] or 0) + 1
    self.sequenceByPlayer[normalized] = sequence
    self.publishedCount = self.publishedCount + 1
    return result(true, "multiplayer-read-model-published", {
        envelope = {
            schemaVersion = SCHEMA_VERSION,
            authority = AUTHORITY,
            readOnly = true,
            mutationAllowed = false,
            playerUid = normalized,
            profileKey = context.identity.profileKey,
            worldDirectory = context.identity.worldDirectory,
            worldGeneration = world_generation,
            sequence = sequence,
            progressionRevision = root_status.revision,
            gates = {
                palReconciliationUnlocked =
                    root_status.palReconciliationUnlocked == true,
                ending3Unlocked = root_status.ending3Unlocked == true,
            },
            factions = rows,
        },
    })
end

function MultiplayerReadModel:accept(envelope)
    if type(envelope) ~= "table" or not safe_value(envelope, 0)
        or envelope.schemaVersion ~= SCHEMA_VERSION
        or envelope.authority ~= AUTHORITY
        or envelope.readOnly ~= true
        or envelope.mutationAllowed ~= false
        or not non_negative_integer(envelope.progressionRevision)
        or type(envelope.sequence) ~= "number"
        or envelope.sequence < 1
        or envelope.sequence ~= math.floor(envelope.sequence)
        or type(envelope.worldGeneration) ~= "number"
        or envelope.worldGeneration < 1
        or envelope.worldGeneration
            ~= math.floor(envelope.worldGeneration)
        or type(envelope.factions) ~= "table" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "multiplayer-read-model-envelope-invalid")
    end
    local player_uid = ProgressionIdentity.normalize_guid(
        envelope.playerUid)
    local expected_profile = ProgressionIdentity.build_profile_key(
        envelope.worldDirectory,
        player_uid
    )
    if player_uid == nil or expected_profile == nil
        or envelope.profileKey ~= expected_profile then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-read-model-profile-mismatch")
    end
    if self.localIdentityResolver ~= nil then
        local called, identity = pcall(self.localIdentityResolver)
        if not called or type(identity) ~= "table"
            or identity.playerUid ~= player_uid
            or identity.profileKey ~= expected_profile then
            self.rejectedCount = self.rejectedCount + 1
            return result(false,
                "multiplayer-read-model-cross-player-rejected")
        end
    end
    local previous = self.clientViewsByPlayer[player_uid]
    if previous ~= nil
        and (envelope.worldGeneration < previous.worldGeneration
            or (envelope.worldGeneration == previous.worldGeneration
                and envelope.sequence <= previous.sequence)) then
        self.rejectedCount = self.rejectedCount + 1
        self.staleCount = self.staleCount + 1
        return result(false,
            "multiplayer-read-model-stale-snapshot")
    end
    self.clientViewsByPlayer[player_uid] = copy(envelope)
    self.acceptedCount = self.acceptedCount + 1
    return result(true, "multiplayer-read-model-accepted", {
        playerUid = player_uid,
        worldGeneration = envelope.worldGeneration,
        sequence = envelope.sequence,
    })
end

function MultiplayerReadModel:current(player_uid)
    local normalized = ProgressionIdentity.normalize_guid(player_uid)
    return normalized and copy(self.clientViewsByPlayer[normalized]) or nil
end

function MultiplayerReadModel:status()
    return {
        apiVersion = self.version,
        publishedCount = self.publishedCount,
        acceptedCount = self.acceptedCount,
        rejectedCount = self.rejectedCount,
        staleCount = self.staleCount,
        lastError = self.lastError,
        capabilities = copy(self.capabilities),
    }
end

return MultiplayerReadModel
