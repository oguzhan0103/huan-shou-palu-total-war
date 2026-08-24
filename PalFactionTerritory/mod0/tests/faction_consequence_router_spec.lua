package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local FactionApi = require("pwft.faction_api")
local FactionConsequenceRouter =
    require("pwft.faction_consequence_router")

local rayne = "pwft.faction.rayne_syndicate"
local pal_faction = "pwft.faction.dark_nocturnal_pal_tribe"
local changes = {}
local progression = Progression.create(Registry.progression)
local api = FactionApi.create(progression)
local router = FactionConsequenceRouter.create(api, {
    onChange = function(faction_id, event, status)
        changes[#changes + 1] = {
            factionId = faction_id,
            event = event,
            status = status,
        }
    end,
})

local status = router:status()
assert(status.apiVersion == "1.0.0")
assert(status.providerCount == 3 and status.reasonRouteCount == 5)
assert(status.maximumPenaltyPerEvent == 300)
assert(status.nextEventSequence == 0)
assert(status.modelMayDispatch == false)
assert(status.PalworldSaveMutation == false)

local allocated_one = router:allocate_event_identity("spec.native")
local allocated_two = router:allocate_event_identity("spec.native")
assert(allocated_one.eventId == "spec.native:000000000001")
assert(allocated_one.operationId
    == "consequence:spec.native:000000000001")
assert(allocated_two.nativeEventId
    == "native:spec.native:000000000002")
assert(router:status().nextEventSequence == 2)

assert(api:join_human(rayne, "spec.consequence.join").ok)
assert(api:award_task(rayne, 300, "spec.consequence.rank.1").ok)
assert(api:award_task(rayne, 300, "spec.consequence.rank.2").ok)
assert(api:award_task(rayne, 100, "spec.consequence.rank.3").ok)
assert(api:faction_status(rayne).rankId == "Leader")

local generation = router:status().worldGeneration
local binding = {
    schemaVersion = "1.0.0",
    bindingId = "spec.consequence.binding.guard.1",
    providerId = "pwft.consequence.native-actor.v1",
    reasonCode = "friendly-fire",
    factionId = rayne,
    actorRole = "faction-member",
    actorKey = "BP_Guard_C_1",
    actorClassKey = "BP_Guard_C",
    worldGeneration = generation,
    actorRef = { transient = true },
}
assert(router:bind_actor(binding).ok)
assert(router:bind_actor(binding).reason
    == "faction-consequence-actor-binding-ready")

local friendly_fire = {
    schemaVersion = "1.0.0",
    authoritative = true,
    eventId = "spec.consequence.event.friendly-fire.1",
    operationId = "consequence:spec.friendly-fire.1",
    providerId = "pwft.consequence.native-actor.v1",
    authoritySource = "pwft.native-faction-consequence.v1",
    reasonCode = "friendly-fire",
    factionId = rayne,
    penalty = 150,
    contextId = "spec.damage.context.1",
    nativeConfirmed = true,
    playerInitiated = true,
    worldGeneration = generation,
    bindingId = binding.bindingId,
    actorRef = binding.actorRef,
    actorKey = binding.actorKey,
    actorClassKey = binding.actorClassKey,
    nativeEventId = "spec.native.damage.1",
}
local applied = router:dispatch(friendly_fire)
assert(applied.ok and applied.applied == -150)
assert(applied.demoted == true and applied.rankId == "CoreMember")
assert(api:faction_status(rayne).reputation == 550)
assert(#changes == 1)
assert(changes[1].event.type == "faction-consequence-recorded")

local duplicate = router:dispatch(friendly_fire)
assert(duplicate.ok and duplicate.reason
    == "duplicate-faction-consequence-event")
assert(duplicate.applied == 0 and duplicate.originalApplied == -150)
assert(api:faction_status(rayne).reputation == 550)

local conflicting = {}
for key, value in pairs(friendly_fire) do conflicting[key] = value end
conflicting.penalty = 151
local conflict = router:dispatch(conflicting)
assert(not conflict.ok and conflict.reason
    == "faction-consequence-event-id-conflict")

local wrong_class = {}
for key, value in pairs(friendly_fire) do wrong_class[key] = value end
wrong_class.eventId = "spec.consequence.event.wrong-class"
wrong_class.operationId = "consequence:spec.wrong-class"
wrong_class.actorClassKey = "BP_Unrelated_C"
local rejected_class = router:dispatch(wrong_class)
assert(not rejected_class.ok and rejected_class.reason
    == "invalid-faction-consequence-event")

local wrong_actor_ref = {}
for key, value in pairs(friendly_fire) do wrong_actor_ref[key] = value end
wrong_actor_ref.eventId = "spec.consequence.event.wrong-actor-ref"
wrong_actor_ref.operationId = "consequence:spec.wrong-actor-ref"
wrong_actor_ref.actorRef = { transient = true }
local rejected_actor_ref = router:dispatch(wrong_actor_ref)
assert(not rejected_actor_ref.ok and rejected_actor_ref.reason
    == "invalid-faction-consequence-event")

assert(not router:unbind_actor(binding.bindingId, {}).ok)
assert(router:unbind_actor(binding.bindingId, binding.actorRef).ok)
assert(router:unbind_actor(binding.bindingId, binding.actorRef).reason
    == "faction-consequence-actor-already-unbound")
assert(router:bind_actor(binding).ok)

local model_event = {}
for key, value in pairs(friendly_fire) do model_event[key] = value end
model_event.eventId = "spec.consequence.event.model"
model_event.operationId = "consequence:spec.model"
model_event.modelGenerated = true
local rejected_model = router:dispatch(model_event)
assert(not rejected_model.ok and rejected_model.reason
    == "invalid-faction-consequence-event")

local content_event = {
    schemaVersion = "1.0.0",
    authoritative = true,
    eventId = "spec.consequence.event.mission.1",
    operationId = "consequence:spec.mission.1",
    providerId = "pwft.consequence.content-action.v1",
    authoritySource = "pwft.content-action-runtime.v1",
    reasonCode = "mission-failure",
    factionId = rayne,
    penalty = 100,
    contextId = "spec.quest.failure.1",
    contentPackId = "spec.pack.consequence",
    actionId = "spec.action.mission-failure",
}
local mission = router:dispatch(content_event)
assert(mission.ok and mission.applied == -100)
assert(api:faction_status(rayne).reputation == 450)

local war_event = {
    schemaVersion = "1.0.0",
    authoritative = true,
    eventId = "spec.consequence.event.war.1",
    operationId = "consequence:spec.war.1",
    providerId = "pwft.consequence.economy-war.v1",
    authoritySource = "pwft.faction-economy-war.v1",
    reasonCode = "war-consequence",
    factionId = rayne,
    penalty = 200,
    contextId = "spec.war.resolution.1",
    warId = "spec.war.1",
    resolutionId = "spec.war.resolution.1",
}
local war = router:dispatch(war_event)
assert(war.ok and war.applied == -200)
assert(api:faction_status(rayne).reputation == 250)

local pal_event = {}
for key, value in pairs(content_event) do pal_event[key] = value end
pal_event.eventId = "spec.consequence.event.pal"
pal_event.operationId = "consequence:spec.pal"
pal_event.factionId = pal_faction
local rejected_pal = router:dispatch(pal_event)
assert(not rejected_pal.ok and rejected_pal.reason
    == "invalid-faction-consequence-event")

local before_unbind_generation = router:status().worldGeneration
local unbound = router:unbind_world("spec-world-unload")
assert(unbound.ok and unbound.removedBindingCount == 1)
assert(unbound.worldGeneration == before_unbind_generation + 1)
local stale = {}
for key, value in pairs(friendly_fire) do stale[key] = value end
stale.eventId = "spec.consequence.event.stale"
stale.operationId = "consequence:spec.stale"
local rejected_stale = router:dispatch(stale)
assert(not rejected_stale.ok and rejected_stale.reason
    == "invalid-faction-consequence-event")

local snapshot = progression:export_snapshot()
assert(snapshot.factionConsequences.processedEvents
    [friendly_fire.eventId] ~= nil)
local restored = progression:restore_snapshot(snapshot)
assert(restored.ok)
assert(router:status().activeBindingCount == 0)
assert(router:status().nextEventSequence == 2)
assert(router:event_status(content_event.eventId).outcome.applied == -100)
local restored_duplicate = router:dispatch(content_event)
assert(restored_duplicate.ok and restored_duplicate.reason
    == "duplicate-faction-consequence-event")

print("PASS faction consequence router enforces trusted provider routes, exact actor/class and generation binding, native confirmation, human-only penalties, content and war consequences, conflict-safe idempotency, restore, and no model authority")
