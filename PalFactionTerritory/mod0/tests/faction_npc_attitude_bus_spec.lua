package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local AttitudeBus = require("pwft.faction_npc_attitude_bus")
local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local FactionApi = require("pwft.faction_api")

local factions = {
    ["spec.faction.alpha"] = { id = "spec.faction.alpha", kind = "Human", relation = "Friendly" },
    ["spec.faction.beta"] = { id = "spec.faction.beta", kind = "Pal", relation = "Hostile" },
}
local faction_api = {}
function faction_api:faction_status(faction_id) return factions[faction_id] end

local policy = {
    completed = false,
    worldDisposition = "conditional",
    factionDispositionById = {},
}
local ending_runtime = {}
function ending_runtime:post_ending_policy()
    local copied = { factionDispositionById = {} }
    for key, value in pairs(policy) do copied[key] = value end
    for key, value in pairs(policy.factionDispositionById) do
        copied.factionDispositionById[key] = value
    end
    return copied
end

local provider_id = "spec.attitude.provider.v1"
local authority = "spec.attitude.authority.v1"
local whitelist = { [provider_id] = authority }
local applied = {}
local fail_next = false
local function apply_intent(intent, actor_ref)
    if fail_next then
        fail_next = false
        return { ok = false, reason = "simulated-failure" }
    end
    table.insert(applied, { intent = intent, actorRef = actor_ref })
    return { ok = true, nativeHandle = actor_ref }
end

local bus = AttitudeBus.create(faction_api, ending_runtime, {
    providerWhitelist = whitelist,
})
assert(bus.capabilities.contentNeutralFactionAttitudes)
assert(bus.capabilities.PalworldSaveMutation == false)
assert(bus:register_provider({
    providerId = "not-whitelisted",
    authoritySource = authority,
    applyIntent = apply_intent,
}).ok == false)
local definition = {
    providerId = provider_id,
    authoritySource = authority,
    applyIntent = apply_intent,
}
assert(bus:register_provider(definition).ok)
assert(bus:register_provider(definition).reason == "NPC-attitude-provider-ready")

local alpha_ref = { transientNativeHandle = "alpha" }
local alpha = {
    bindingId = "spec.attitude.binding.alpha",
    providerId = provider_id,
    factionId = "spec.faction.alpha",
    actorKey = "Actor:alpha:001",
    actorClassKey = "BP_AlphaNPC_C",
    actorRef = alpha_ref,
}
local beta = {
    bindingId = "spec.attitude.binding.beta",
    providerId = provider_id,
    factionId = "spec.faction.beta",
    actorKey = "Actor:beta:001",
    actorClassKey = "BP_BetaNPC_C",
    actorRef = { transientNativeHandle = "beta" },
}
assert(bus:bind_actor(alpha).ok)
assert(bus:bind_actor(beta).ok)

local function event(binding, id, operation, trigger, aggression)
    return {
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = provider_id,
        authoritySource = authority,
        trigger = trigger,
        eventId = id,
        operationId = operation,
        bindingId = binding.bindingId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        playerInitiatedAggression = aggression,
    }
end

local loaded_event = event(alpha, "spec.attitude.loaded", "spec.attitude.op.loaded", "actor-loaded")
local loaded = bus:refresh(loaded_event)
assert(loaded.ok and loaded.disposition == "friendly")
assert(loaded.basis == "faction-relation")
assert(applied[1].actorRef == alpha_ref)
local unchanged_refresh = bus:refresh_faction("spec.faction.alpha", {
    trigger = "relation-changed",
})
assert(unchanged_refresh.ok and unchanged_refresh.bindingCount == 1)
assert(unchanged_refresh.appliedCount == 0)
local duplicate = bus:refresh(loaded_event)
assert(duplicate.ok and duplicate.reason == "duplicate-NPC-attitude-event")
assert(duplicate.idempotent and duplicate.stateChanged == false)

local conflict = event(alpha, "spec.attitude.conflict", "spec.attitude.op.loaded", "manual-refresh")
assert(bus:refresh(conflict).reason == "NPC-attitude-operation-id-conflict")
local event_conflict = event(alpha, "spec.attitude.loaded", "spec.attitude.op.changed", "manual-refresh")
assert(bus:refresh(event_conflict).reason == "NPC-attitude-event-id-conflict")

factions["spec.faction.alpha"].relation = "Hostile"
local hostile = bus:refresh(event(
    alpha, "spec.attitude.relation", "spec.attitude.op.relation", "relation-changed"
))
assert(hostile.ok and hostile.disposition == "hostile")

policy.completed = true
policy.worldDisposition = "pacified"
policy.factionDispositionById["spec.faction.alpha"] = "friendly"
local faction_override = bus:refresh(event(
    alpha, "spec.attitude.ending.faction", "spec.attitude.op.ending.faction", "ending-changed"
))
assert(faction_override.disposition == "friendly")
assert(faction_override.basis == "ending-faction-override")
local world_override = bus:refresh(event(
    beta, "spec.attitude.ending.world", "spec.attitude.op.ending.world", "ending-changed"
))
assert(world_override.disposition == "non-hostile")
assert(world_override.basis == "ending-world-override")
local aggression = bus:refresh(event(
    alpha, "spec.attitude.aggression", "spec.attitude.op.aggression", "manual-refresh", true
))
assert(aggression.disposition == "hostile")
assert(aggression.basis == "player-initiated-aggression")
policy.factionDispositionById["spec.faction.alpha"] = "friendly"
local aggression_sticks = bus:refresh_faction("spec.faction.alpha", {
    trigger = "ending-changed",
    force = true,
})
assert(aggression_sticks.ok)
assert(aggression_sticks.responses[1].disposition == "hostile")

local wrong_actor = event(alpha, "spec.attitude.wrong", "spec.attitude.op.wrong", "manual-refresh")
wrong_actor.actorClassKey = "BP_Forged_C"
assert(bus:refresh(wrong_actor).reason == "invalid-NPC-attitude-event")

fail_next = true
local retry_event = event(alpha, "spec.attitude.retry", "spec.attitude.op.retry", "manual-refresh")
local failed = bus:refresh(retry_event)
assert(failed.ok == false and failed.reason == "NPC-attitude-provider-failed")
assert(failed.retryable and bus:refresh(retry_event).ok)

assert(bus:unbind_actor({
    bindingId = alpha.bindingId,
    providerId = provider_id,
    actorKey = alpha.actorKey,
    actorClassKey = "BP_Forged_C",
}).ok == false)
assert(bus:unbind_actor({
    bindingId = alpha.bindingId,
    providerId = provider_id,
    actorKey = alpha.actorKey,
    actorClassKey = alpha.actorClassKey,
}).ok)
assert(bus:bind_actor(alpha).ok)

local snapshot = bus:export_snapshot()
assert(snapshot.bindings == nil)
assert(snapshot.providers[1].applyIntent == nil)
assert(snapshot.results["spec.attitude.loaded"].outcome.providerResult == nil)
local restored = AttitudeBus.create(faction_api, ending_runtime, {
    providerWhitelist = whitelist,
    snapshot = snapshot,
})
assert(restored:status().bindingCount == 0)
assert(restored:status().readyProviderCount == 0)
assert(restored:register_provider(definition).ok)
assert(restored:bind_actor(alpha).ok)
local replay = restored:refresh(loaded_event)
assert(replay.ok and replay.reason == "duplicate-NPC-attitude-event")
local cleared = restored:clear_world()
assert(cleared.removedBindingCount == 1)
assert(restored:status().serializableStateOnly)

-- Real progression sidecar retains only data/idempotency and forces all
-- world-lifetime actor bindings to be rediscovered after restore.
local persisted_progression = Progression.create(Registry.progression)
local persisted_api = FactionApi.create(persisted_progression)
local persisted_bus = AttitudeBus.create(persisted_api, nil, {
    providerWhitelist = whitelist,
})
assert(persisted_bus:register_provider(definition).ok)
local persisted_binding = {
    bindingId = "spec.attitude.binding.persisted",
    providerId = provider_id,
    factionId = "pwft.faction.rayne_syndicate",
    actorKey = "Actor:persisted:001",
    actorClassKey = "BP_PersistedNPC_C",
    actorRef = { native = "must-not-persist" },
}
assert(persisted_bus:bind_actor(persisted_binding).ok)
local persisted_event = event(
    persisted_binding,
    "spec.attitude.persisted",
    "spec.attitude.op.persisted",
    "actor-loaded"
)
assert(persisted_bus:refresh(persisted_event).ok)
local progression_snapshot = persisted_progression:export_snapshot()
assert(type(progression_snapshot.factionNpcAttitudes) == "table")
assert(progression_snapshot.factionNpcAttitudes.results
    ["spec.attitude.persisted"].outcome.providerResult == nil)
persisted_progression:restore_snapshot(progression_snapshot)
assert(persisted_bus:status().bindingCount == 0)
assert(persisted_bus:status().resultCount == 1)
assert(persisted_bus:status().progressionSidecarIdempotency)

print("PASS faction NPC attitude bus exact-binds actors, applies relation/ending/aggression policy, retries failures, and snapshots without UObjects")
