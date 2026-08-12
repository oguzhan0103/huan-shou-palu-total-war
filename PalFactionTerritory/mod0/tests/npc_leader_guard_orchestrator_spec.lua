package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local GuardOrchestrator = require("pwft.npc_leader_guard_orchestrator")
local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local FactionApi = require("pwft.faction_api")

local factions = {
    alpha = { id = "alpha", kind = "Human", relation = "Friendly" },
    beta = { id = "beta", kind = "Human", relation = "Friendly" },
}
local faction_api = {}
function faction_api:faction_status(faction_id) return factions[faction_id] end

local provider_id = "spec.guard.provider.v1"
local authority = "spec.guard.authority.v1"
local options = {
    providerWhitelist = { [provider_id] = authority },
    maxPerLeader = 1,
    maxPerFaction = 2,
    maxPerScene = 2,
    maximumMembersPerFormation = 4,
}
local orchestrator = GuardOrchestrator.create(faction_api, options)
assert(orchestrator.capabilities.storyContentIncluded == false)
assert(orchestrator.capabilities.PalworldSaveMutation == false)

local function formation(id)
    return {
        formationId = id,
        members = {
            { archetypeId = "content.guard.melee", count = 1 },
            { archetypeId = "content.guard.ranged", count = 1 },
        },
        allowedSceneKinds = { "city", "field" },
    }
end
local pack = {
    schemaVersion = "1.0.0",
    contentPackId = "spec.guard.content-pack",
    contentVersion = "1.0.0",
    leaders = {
        { leaderId = "leader.alpha.1", factionId = "alpha", actorClassKey = "BP_LeaderAlpha1_C", formations = { formation("formation.alpha.1") } },
        { leaderId = "leader.alpha.2", factionId = "alpha", actorClassKey = "BP_LeaderAlpha2_C", formations = { formation("formation.alpha.2") } },
        { leaderId = "leader.alpha.3", factionId = "alpha", actorClassKey = "BP_LeaderAlpha3_C", formations = { formation("formation.alpha.3") } },
        { leaderId = "leader.beta.1", factionId = "beta", actorClassKey = "BP_LeaderBeta1_C", formations = { formation("formation.beta.1") } },
    },
}
assert(orchestrator:register_content_pack(pack).ok)
assert(orchestrator:register_content_pack(pack).reason
    == "leader-guard-content-pack-already-registered")

local fail_next = false
local applied = {}
local function execute_intent(intent, leader_ref)
    if fail_next then
        fail_next = false
        return { ok = false, reason = "simulated-provider-failure" }
    end
    table.insert(applied, { intent = intent, leaderRef = leader_ref })
    return { ok = true, nativeHandle = leader_ref }
end
assert(orchestrator:register_provider({
    providerId = "forged-provider",
    authoritySource = authority,
    executeIntent = execute_intent,
}).ok == false)
local provider = {
    providerId = provider_id,
    authoritySource = authority,
    executeIntent = execute_intent,
}
assert(orchestrator:register_provider(provider).ok)

local bindings = {}
for index, leader in ipairs(pack.leaders) do
    local binding = {
        bindingId = "spec.guard.binding." .. tostring(index),
        providerId = provider_id,
        leaderId = leader.leaderId,
        actorKey = "Actor:leader:" .. tostring(index),
        actorClassKey = leader.actorClassKey,
        leaderRef = { nativeLeader = index },
    }
    assert(orchestrator:bind_leader(binding).ok)
    table.insert(bindings, binding)
end
local forged_binding = {}
for key, value in pairs(bindings[1]) do forged_binding[key] = value end
forged_binding.bindingId = "spec.guard.binding.forged"
forged_binding.actorClassKey = "BP_Forged_C"
assert(orchestrator:bind_leader(forged_binding).ok == false)

local serial = 0
local function event(binding, kind, deployment_id, formation_id, scene_id, scene_kind)
    serial = serial + 1
    return {
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = provider_id,
        authoritySource = authority,
        eventKind = kind,
        eventId = "spec.guard.event." .. tostring(serial),
        operationId = "spec.guard.operation." .. tostring(serial),
        bindingId = binding.bindingId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        deploymentId = deployment_id,
        formationId = formation_id,
        sceneId = scene_id,
        sceneKind = scene_kind,
    }
end
local function deploy(binding_index, deployment_id, scene_id)
    return event(
        bindings[binding_index],
        "deploy",
        deployment_id,
        pack.leaders[binding_index].formations[1].formationId,
        scene_id,
        "city"
    )
end

local d1 = deploy(1, "deployment.1", "scene.A")
assert(orchestrator:ingest(d1).ok)
local same_leader_limit = deploy(1, "deployment.1b", "scene.B")
assert(orchestrator:ingest(same_leader_limit).reason == "leader-guard-per-leader-limit")
assert(orchestrator:ingest(deploy(2, "deployment.2", "scene.A")).ok)
assert(orchestrator:ingest(deploy(3, "deployment.3", "scene.B")).reason
    == "leader-guard-per-faction-limit")
assert(orchestrator:ingest(deploy(4, "deployment.4", "scene.A")).reason
    == "leader-guard-per-scene-limit")

local function lifecycle(binding, kind, deployment_id)
    return event(binding, kind, deployment_id)
end
local follow = lifecycle(bindings[1], "follow", "deployment.1")
fail_next = true
local failed = orchestrator:ingest(follow)
assert(failed.ok == false and failed.reason == "leader-guard-provider-failed")
assert(failed.retryable)
local followed = orchestrator:ingest(follow)
assert(followed.ok and followed.intent.kind == "follow-leader")
local duplicate = orchestrator:ingest(follow)
assert(duplicate.reason == "duplicate-leader-guard-event" and duplicate.idempotent)

local operation_conflict = lifecycle(bindings[1], "combat", "deployment.1")
operation_conflict.operationId = follow.operationId
assert(orchestrator:ingest(operation_conflict).reason
    == "leader-guard-operation-id-conflict")
local combat = orchestrator:ingest(lifecycle(bindings[1], "combat", "deployment.1"))
assert(combat.ok and combat.intent.kind == "enter-combat")
assert(orchestrator:ingest(lifecycle(bindings[2], "recall", "deployment.2")).ok)
assert(orchestrator:ingest(lifecycle(bindings[1], "leader-death", "deployment.1")).ok)
assert(orchestrator:status().bindingCount == 3)

assert(orchestrator:bind_leader(bindings[1]).ok)
assert(orchestrator:ingest(deploy(1, "deployment.unload", "scene.C")).ok)
local unloaded = orchestrator:ingest(lifecycle(
    bindings[1], "actor-unloaded", "deployment.unload"
))
assert(unloaded.ok and unloaded.intent.kind == "despawn-guards")

assert(orchestrator:bind_leader(bindings[1]).ok)
assert(orchestrator:ingest(deploy(1, "deployment.snapshot", "scene.D")).ok)
local snapshot = orchestrator:export_snapshot()
assert(snapshot.bindings == nil)
assert(snapshot.providers[1].executeIntent == nil)
for _, record in pairs(snapshot.results) do assert(record.outcome.providerResult == nil) end
local restored = GuardOrchestrator.create(faction_api, {
    providerWhitelist = options.providerWhitelist,
    maxPerLeader = options.maxPerLeader,
    maxPerFaction = options.maxPerFaction,
    maxPerScene = options.maxPerScene,
    maximumMembersPerFormation = options.maximumMembersPerFormation,
    snapshot = snapshot,
})
assert(restored:status().bindingCount == 0)
assert(restored:status().activeDeploymentCount == 0)
assert(restored:status().readyProviderCount == 0)
assert(restored:register_provider(provider).ok)
assert(restored:bind_leader(bindings[1]).ok)
local restored_deploy = deploy(1, "deployment.restored", "scene.E")
assert(restored:ingest(restored_deploy).ok)
local recall = restored:ingest(lifecycle(
    bindings[1], "recall", "deployment.restored"
))
assert(recall.ok and recall.intent.kind == "recall-guards")
assert(restored:status().activeDeploymentCount == 0)
local cleared = restored:clear_world()
assert(cleared.removedBindingCount == 1)
assert(restored:status().serializableStateOnly)

local kinds = {}
for _, call in ipairs(applied) do kinds[call.intent.kind] = true end
for _, expected in ipairs({
    "deploy-guards", "follow-leader", "enter-combat", "retire-guards",
    "despawn-guards", "recall-guards",
}) do assert(kinds[expected], "missing guard intent kind: " .. expected) end

-- Real progression sidecar persists the successful operation ledger only;
-- actor references, bindings and active world deployments are discarded.
local persisted_progression = Progression.create(Registry.progression)
local persisted_orchestrator = GuardOrchestrator.create(
    FactionApi.create(persisted_progression),
    {
        providerWhitelist = options.providerWhitelist,
        maxPerLeader = 1,
        maxPerFaction = 1,
        maxPerScene = 1,
    }
)
local persisted_pack = {
    schemaVersion = "1.0.0",
    contentPackId = "spec.guard.persisted-pack",
    contentVersion = "1.0.0",
    leaders = {
        {
            leaderId = "spec.guard.persisted-leader",
            factionId = "pwft.faction.rayne_syndicate",
            actorClassKey = "BP_PersistedLeader_C",
            formations = {
                {
                    formationId = "spec.guard.persisted-formation",
                    members = { { archetypeId = "spec.guard.unit", count = 1 } },
                    allowedSceneKinds = { "city" },
                },
            },
        },
    },
}
assert(persisted_orchestrator:register_content_pack(persisted_pack).ok)
assert(persisted_orchestrator:register_provider(provider).ok)
local persisted_binding = {
    bindingId = "spec.guard.persisted-binding",
    providerId = provider_id,
    leaderId = "spec.guard.persisted-leader",
    actorKey = "Actor:persisted-leader:001",
    actorClassKey = "BP_PersistedLeader_C",
    leaderRef = { native = "must-not-persist" },
}
assert(persisted_orchestrator:bind_leader(persisted_binding).ok)
local persisted_deploy = {
    schemaVersion = "1.0.0",
    authoritative = true,
    providerId = provider_id,
    authoritySource = authority,
    eventKind = "deploy",
    eventId = "spec.guard.persisted-event",
    operationId = "spec.guard.persisted-operation",
    bindingId = persisted_binding.bindingId,
    actorKey = persisted_binding.actorKey,
    actorClassKey = persisted_binding.actorClassKey,
    deploymentId = "spec.guard.persisted-deployment",
    formationId = "spec.guard.persisted-formation",
    sceneId = "spec.guard.persisted-scene",
    sceneKind = "city",
}
assert(persisted_orchestrator:ingest(persisted_deploy).ok)
local persisted_snapshot = persisted_progression:export_snapshot()
assert(type(persisted_snapshot.npcLeaderGuards) == "table")
assert(persisted_snapshot.npcLeaderGuards.results
    ["spec.guard.persisted-event"].outcome.providerResult == nil)
assert(persisted_snapshot.npcLeaderGuards.activeDeployments == nil)
persisted_progression:restore_snapshot(persisted_snapshot)
assert(persisted_orchestrator:status().bindingCount == 0)
assert(persisted_orchestrator:status().activeDeploymentCount == 0)
assert(persisted_orchestrator:status().resultCount == 1)
assert(persisted_orchestrator:status().progressionSidecarIdempotency)

print("PASS NPC leader guard orchestrator content-defines leaders/formations, enforces caps, emits lifecycle intents, retries provider failure, and snapshots without UObjects")
