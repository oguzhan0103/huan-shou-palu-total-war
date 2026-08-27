package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local MultiplayerReadModel = require("pwft.multiplayer_read_model")

local WORLD = "E0D5ECDC46B379829F8F31A729ACFD92"
local HOST_UID = "11111111222222223333333344444444"
local REMOTE_UID = "AAAAAAAA222222223333333344444444"
local function profile(uid) return "world-" .. WORLD .. ".player-" .. uid end

local registry = {
    progression = {
        humanFactionIds = { "human.a" },
        palFactionIds = { "pal.a" },
    },
}
local function progression(revision)
    local object = {}
    function object:status(faction_id)
        if faction_id == nil then
            return {
                revision = revision,
                palReconciliationUnlocked = true,
                ending3Unlocked = false,
            }
        end
        return {
            factionId = faction_id,
            kind = faction_id == "human.a" and "Human" or "Pal",
            reputation = faction_id == "human.a" and 120 or -10,
            relation = faction_id == "human.a" and "Friendly" or "Hostile",
            joined = faction_id == "human.a",
            rankId = faction_id == "human.a" and "member" or nil,
            guardAccess = false,
            joinEligible = false,
            diplomacyHostilitySources = {},
        }
    end
    return object
end
local function context(uid, revision)
    return {
        identity = {
            playerUid = uid,
            profileKey = profile(uid),
            worldDirectory = WORLD,
            serverAuthoritative = true,
        },
        factionProgression = progression(revision),
        palReconciliation = {
            status = function()
                return {
                    configured = true,
                    tokenQuota = 3,
                    tokensAwarded = 1,
                    tokensConsumed = 0,
                    technicalRefunds = 0,
                    locked = false,
                    reconciled = false,
                    remainingAwardCapacity = 2,
                }
            end,
        },
    }
end

local contexts = {
    [HOST_UID] = context(HOST_UID, 3),
    [REMOTE_UID] = context(REMOTE_UID, 8),
}
local local_identity = {
    playerUid = REMOTE_UID,
    profileKey = profile(REMOTE_UID),
}
local model = MultiplayerReadModel.create(registry, {
    contextResolver = function(uid) return contexts[uid] end,
    localIdentityResolver = function() return local_identity end,
})

local published = model:publish(REMOTE_UID, 5)
assert(published.ok)
local envelope = published.envelope
assert(envelope.playerUid == REMOTE_UID)
assert(envelope.profileKey == profile(REMOTE_UID))
assert(envelope.progressionRevision == 8)
assert(envelope.sequence == 1)
assert(envelope.readOnly == true and envelope.mutationAllowed == false)
assert(#envelope.factions == 2)
assert(envelope.factions[2].reconciliation.tokensAwarded == 1)
assert(model:accept(envelope).ok)
assert(model:current(REMOTE_UID).sequence == 1)

local stale = model:accept(envelope)
assert(not stale.ok)
assert(stale.reason == "multiplayer-read-model-stale-snapshot")

local host_envelope = model:publish(HOST_UID, 5).envelope
assert(model:accept(host_envelope).reason
    == "multiplayer-read-model-cross-player-rejected")

local writable = {}
for key, value in pairs(envelope) do writable[key] = value end
writable.sequence = 2
writable.mutationAllowed = true
assert(model:accept(writable).reason
    == "multiplayer-read-model-envelope-invalid")

local newer = model:publish(REMOTE_UID, 5).envelope
assert(newer.sequence == 2)
assert(model:accept(newer).ok)
local status = model:status()
assert(status.publishedCount == 3)
assert(status.acceptedCount == 2)
assert(status.staleCount == 1)
assert(status.capabilities.nativeTransportBound == false)
assert(status.capabilities.serverStateMutation == false)

print("PASS multiplayer read model publishes exact-player read-only snapshots and rejects stale, cross-player, or writable envelopes")
