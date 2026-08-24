package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Orchestrator = require("pwft.npc_leader_guard_orchestrator")
local Production = require("pwft.npc_leader_guard_native_production")

local faction_api = {}
function faction_api:faction_status(faction_id)
    if faction_id == "faction.alpha" then
        return { id = faction_id, kind = "Human", relation = "Friendly" }
    end
    return nil
end

local provider_id = "pwft.native.NPC-leader-guard.production"
local authority = "pwft.native.NPC-leader-guard.authority"
local orchestrator = Orchestrator.create(faction_api, {
    providerWhitelist = { [provider_id] = authority },
    maxPerLeader = 2,
    maxPerFaction = 4,
    maxPerScene = 4,
    maximumMembersPerFormation = 6,
})

local pack = {
    schemaVersion = "1.0.0",
    contentPackId = "spec.native-leader-guards",
    contentVersion = "1.0.0",
    leaders = {
        {
            leaderId = "spec.leader.alpha",
            factionId = "faction.alpha",
            actorClassKey = "BP_SpecLeader_C",
            formations = {
                {
                    formationId = "spec.formation.alpha",
                    members = {
                        { archetypeId = "spec.guard.melee", count = 1 },
                        { archetypeId = "spec.guard.ranged", count = 1 },
                    },
                    allowedSceneKinds = { "city" },
                },
                {
                    formationId = "spec.formation.rollback",
                    members = {
                        { archetypeId = "spec.guard.melee", count = 1 },
                        { archetypeId = "spec.guard.failure", count = 1 },
                    },
                    allowedSceneKinds = { "city" },
                },
                {
                    formationId = "spec.formation.missing",
                    members = {
                        { archetypeId = "spec.guard.unregistered", count = 1 },
                    },
                    allowedSceneKinds = { "city" },
                },
            },
        },
    },
}
assert(orchestrator:register_content_pack(pack).ok)

local spawn_calls = {}
local recall_calls = {}
local callbacks = {}
local provider_options = {}
local fake_adapter = {}
function fake_adapter:create_guard_provider(character_id, class_path, options)
    provider_options[#provider_options + 1] = options
    return {
        deploy = function(faction_id, request_id, context)
            if character_id == "NPC_Failure" then
                error("simulated-native-spawn-failure")
            end
            local handle = {
                runtimeId = request_id,
                actor = { id = request_id },
            }
            spawn_calls[#spawn_calls + 1] = {
                factionId = faction_id,
                requestId = request_id,
                characterId = character_id,
                classPath = class_path,
                context = context,
                handle = handle,
            }
            callbacks[request_id] = context.onTerminated
            return handle
        end,
        recall = function(handle, reason)
            recall_calls[#recall_calls + 1] = {
                handle = handle,
                reason = reason,
            }
            return true
        end,
    }
end

local destroyed = false
local production = Production.create(orchestrator, fake_adapter, {
    enabled = true,
    providerId = provider_id,
    authoritySource = authority,
    spawnRadius = 200,
    spawnVerticalOffset = 5,
}, {
    spawnPolicyResolver = function(faction_id, spawn_kind)
        assert(faction_id == "faction.alpha")
        assert(spawn_kind == "NPC-leader-guard")
        return {
            ok = true,
            suppressSpawn = destroyed,
            reason = destroyed and "faction-destroyed" or "faction-active",
        }
    end,
})

assert(production:activate({
    {
        archetypeId = "spec.guard.melee",
        characterId = "NPC_Melee",
        characterClassPath = "/Game/Spec/BP_NPC_Melee.BP_NPC_Melee_C",
    },
    {
        archetypeId = "spec.guard.ranged",
        characterId = "NPC_Ranged",
        characterClassPath = "/Game/Spec/BP_NPC_Ranged.BP_NPC_Ranged_C",
    },
    {
        archetypeId = "spec.guard.failure",
        characterId = "NPC_Failure",
        characterClassPath = "/Game/Spec/BP_NPC_Failure.BP_NPC_Failure_C",
    },
}).ok)
assert(production:status().archetypeCount == 3)
assert(production:register_archetype({
    archetypeId = "spec.guard.melee",
    characterId = "NPC_Melee",
    characterClassPath = "/Game/Spec/BP_NPC_Melee.BP_NPC_Melee_C",
}).reason == "native-NPC-leader-guard-archetype-already-registered")

local leader = {
    location = { X = 1000, Y = 2000, Z = 100 },
}
function leader:IsValid() return true end
function leader:GetFullName()
    return "BP_SpecLeader_C /Game/Maps/Test.BP_SpecLeader_C_1"
end
function leader:K2_GetActorLocation() return self.location end
function leader:K2_GetActorRotation()
    return { Pitch = 0, Yaw = 90, Roll = 0 }
end

local mismatch = {
    location = leader.location,
}
function mismatch:IsValid() return true end
function mismatch:GetFullName() return "BP_OtherLeader_C Other_1" end
assert(production:bind_leader({
    bindingId = "spec.binding.bad",
    leaderId = "spec.leader.alpha",
    actorRef = mismatch,
}).reason == "native-NPC-leader-guard-class-mismatch")

local binding = {
    bindingId = "spec.binding.alpha",
    leaderId = "spec.leader.alpha",
    actorKey = leader:GetFullName(),
    actorClassKey = "BP_SpecLeader_C",
    actorRef = leader,
}
assert(production:bind_leader(binding).ok)

local sequence = 0
local function event(kind, deployment_id, formation_id)
    sequence = sequence + 1
    return {
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = provider_id,
        authoritySource = authority,
        eventKind = kind,
        eventId = "spec.native.guard.event." .. tostring(sequence),
        operationId = "spec.native.guard.operation." .. tostring(sequence),
        bindingId = binding.bindingId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        deploymentId = deployment_id,
        formationId = formation_id,
        sceneId = "spec.scene.city",
        sceneKind = "city",
    }
end

local deployed = orchestrator:ingest(event(
    "deploy", "deployment.alpha", "spec.formation.alpha"))
assert(deployed.ok)
assert(deployed.providerResult.memberCount == 2)
assert(#spawn_calls == 2)
assert(spawn_calls[1].context.followTarget == leader)
assert(spawn_calls[1].context.location.X == 1200)
assert(spawn_calls[1].context.location.Z == 105)
assert(provider_options[1].runtimePrefix == "NPC-leader-guard")
assert(provider_options[1].mode == "NPC-leader-guard")
assert(production:status().deploymentCount == 1)
assert(production:status().activeMemberCount == 2)
assert(orchestrator:ingest(event("follow", "deployment.alpha")).ok)
assert(orchestrator:ingest(event("combat", "deployment.alpha")).ok)
local recalled = orchestrator:ingest(event("recall", "deployment.alpha"))
assert(recalled.ok)
assert(#recall_calls == 2)
assert(production:status().deploymentCount == 0)

-- A partial native spawn is rolled back and never becomes an active
-- orchestrator deployment.
local rollback = orchestrator:ingest(event(
    "deploy", "deployment.rollback", "spec.formation.rollback"))
assert(not rollback.ok and rollback.reason == "leader-guard-provider-failed")
assert(rollback.retryable)
assert(production:status().rollbackCount == 1)
assert(#recall_calls == 3)
assert(orchestrator:status().activeDeploymentCount == 0)

local missing = orchestrator:ingest(event(
    "deploy", "deployment.missing", "spec.formation.missing"))
assert(not missing.ok and missing.reason == "leader-guard-provider-failed")
assert(production:status().deploymentCount == 0)

destroyed = true
local suppressed = orchestrator:ingest(event(
    "deploy", "deployment.destroyed", "spec.formation.alpha"))
assert(not suppressed.ok and suppressed.reason == "leader-guard-provider-failed")
assert(production:status().suppressedCount == 1)
destroyed = false

-- When every native member reports termination, production submits one
-- authoritative recall so the orchestrator does not retain a ghost slot.
assert(orchestrator:ingest(event(
    "deploy", "deployment.downed", "spec.formation.alpha")).ok)
callbacks["deployment.downed:01"]({ reason = "guard-downed" })
assert(orchestrator:status().activeDeploymentCount == 1)
callbacks["deployment.downed:02"]({ reason = "guard-downed" })
assert(orchestrator:status().activeDeploymentCount == 0)
assert(production:status().deploymentCount == 0)

-- Exact unbinding first recalls an active group through the orchestrator,
-- then removes only the matching leader Actor binding.
assert(orchestrator:ingest(event(
    "deploy", "deployment.unbind", "spec.formation.alpha")).ok)
local unbound = production:unbind_leader(binding.bindingId)
assert(unbound.ok)
assert(production:status().bindingCount == 0)
assert(orchestrator:status().bindingCount == 0)
assert(orchestrator:status().activeDeploymentCount == 0)
assert(production:bind_leader(binding).ok)

local forged_unbind = orchestrator:unbind_leader({
    bindingId = binding.bindingId,
    providerId = "forged-provider",
})
assert(not forged_unbind.ok)
local world = production:unbind_world("spec-world-unload")
assert(world.ok and world.removedBindingCount == 1)
orchestrator:clear_world()
assert(production:status().broadActorScan == false)
assert(production:status().PalworldSaveMutation == false)

print("PASS native NPC leader guards map content archetypes to proven native followers, exact-bind leaders, atomically deploy and recall groups, suppress destroyed factions, and clear world UObjects")
