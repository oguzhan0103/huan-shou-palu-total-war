package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local FactionApi = require("pwft.faction_api")
local FactionDefense = require("pwft.faction_defense")
local HumanDefenseResultBridge =
    require("pwft.human_defense_result_bridge")
local ContentPackRegistry = require("pwft.content_pack_registry")
local ContentRuntime = require("pwft.content_runtime")
local ContentModuleLoader = require("pwft.content_module_loader")
local QuestRuntime = require("pwft.quest_runtime")
local QuestObjectiveRouter = require("pwft.quest_objective_router")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")
local TaskDefenseClosure = require("pwft.task_defense_closure")

local RAYNE = "pwft.faction.rayne_syndicate"
local TERRITORY = "pwft.island.central_southeast_archipelago"
local SETTLEMENT = "pwft.settlement.small_settlement"
local QUEST_TEMPLATE =
    "pwft.foundation.b5.quest.small-settlement-defense"
local QUEST_INSTANCE =
    "pwft.foundation.b5.quest.small-settlement-defense.instance"
local AUTHORITY = "pwft.attendance-human-defense.v1"

local initial = Progression.create(Registry.progression):export_snapshot()
initial.factions[RAYNE].reputation = -100
local progression = Progression.create(Registry.progression, initial)
local content_registry = ContentPackRegistry.create({ coreVersion = "1.0.0" })
local quests = QuestRuntime.create(progression, content_registry)
local world = StrategicWorld.create(progression, {
    contentPackRegistry = content_registry,
})
local endings = EndingRuntime.create(
    progression,
    world,
    { contentPackRegistry = content_registry }
)
local content_runtime = ContentRuntime.create(
    progression,
    content_registry,
    quests,
    world,
    endings
)
local module_loader = ContentModuleLoader.create(
    content_runtime,
    {
        enabled = true,
        modules = { "pwft_b5_acceptance.content_module" },
    },
    { questRuntime = quests }
)
local loaded = module_loader:load()
assert(loaded.ok and loaded.reason == "content-modules-loaded")
assert(loaded.registeredCount == 1 and loaded.activatedCount == 1)
assert(module_loader:status().baseStoryContentIncluded == false)
local initial_quest = quests:quest_status(QUEST_INSTANCE)
assert(initial_quest ~= nil and initial_quest.state == "active")
assert(initial_quest.templateId == QUEST_TEMPLATE)

-- Re-activation is generation-safe. The stable start event replays instead of
-- manufacturing another quest instance after a map load.
local reactivated = module_loader:reactivate("b5-spec-world-rebind")
assert(reactivated.ok and reactivated.reactivationFailureCount == 0)
assert(quests:status().activeQuestCount == 1)

local api = FactionApi.create(progression)
local defense = FactionDefense.create(api)
local human_bridge = HumanDefenseResultBridge.create(defense, {
    authoritySource = AUTHORITY,
    reputationAward = 50,
})
local router = QuestObjectiveRouter.create(quests, progression)
local observed = {}
local closure = TaskDefenseClosure.create(human_bridge, router, {
    onChange = function(event) observed[#observed + 1] = event end,
})

local function input(event_id, resolution_id, participated, won)
    return {
        schemaVersion = "1.0.0",
        routeKind = "human-settlement-defense",
        authoritative = true,
        authoritySource = AUTHORITY,
        eventId = event_id,
        resolutionId = resolution_id,
        factionId = RAYNE,
        settlementId = SETTLEMENT,
        territoryId = TERRITORY,
        playerParticipated = participated,
        playerSideWon = won,
    }
end

local event_id = "pwft.b5.spec.defense.victory"
local opened = closure:open(input(
    event_id,
    "pwft.b5.spec.unused-open-resolution",
    true,
    true
))
assert(opened.ok and opened.temporaryTruce == true)
assert(api:faction_status(RAYNE).reputation == -100)

local victory_input = input(
    event_id,
    "pwft.b5.spec.defense.victory.result",
    true,
    true
)
local victory = closure:settle(victory_input)
assert(victory.ok and victory.reason == "task-defense-closed")
assert(victory.applied == 50 and victory.credited == true)
assert(victory.defenseReason == "human-defense-reputation-awarded")
assert(victory.quest.ok and victory.questTransitionCount == 1)
assert(victory.palTokenAwarded == false)
assert(api:faction_status(RAYNE).reputation == -50)
assert(quests:quest_status(QUEST_INSTANCE).state == "completed")

local duplicate = closure:settle(victory_input)
assert(duplicate.ok and duplicate.reason == "task-defense-closed")
assert(duplicate.applied == 0 and duplicate.questTransitionCount == 0)
assert(duplicate.questReplayed == true and duplicate.idempotent == true)
assert(api:faction_status(RAYNE).reputation == -50)

-- Rebuilding the in-memory bridge cannot award the persisted operation again.
-- The quest router also retains the processed objective event in the sidecar.
local replay_closure = TaskDefenseClosure.create(
    HumanDefenseResultBridge.create(FactionDefense.create(api), {
        authoritySource = AUTHORITY,
        reputationAward = 50,
    }),
    router
)
local persisted_replay = replay_closure:settle(victory_input)
assert(persisted_replay.ok and persisted_replay.applied == 0)
assert(persisted_replay.defenseReason
    == "persisted-human-defense-result-already-applied")
assert(persisted_replay.questReplayed == true)
assert(api:faction_status(RAYNE).reputation == -50)

local function start_extra(suffix)
    local instance_id = QUEST_INSTANCE .. "." .. suffix
    local started = quests:start(
        QUEST_TEMPLATE,
        instance_id,
        "pwft.b5.spec.quest.start." .. suffix,
        { sourceId = "pwft.b5.spec", branch = suffix }
    )
    assert(started.ok)
    return instance_id
end

local absent_quest = start_extra("absent")
local reputation_before_absence = api:faction_status(RAYNE).reputation
local absent = closure:settle(input(
    "pwft.b5.spec.defense.absent",
    "pwft.b5.spec.defense.absent.result",
    false,
    true
))
assert(absent.ok and absent.applied == 0 and absent.credited == false)
assert(absent.defenseReason == "human-defense-no-player-participation")
assert(absent.questTransitionCount == 0)
assert(quests:quest_status(absent_quest).state == "active")
assert(api:faction_status(RAYNE).reputation == reputation_before_absence)

local defeated_quest = start_extra("defeated")
local defeated = closure:settle(input(
    "pwft.b5.spec.defense.defeated",
    "pwft.b5.spec.defense.defeated.result",
    true,
    false
))
assert(defeated.ok and defeated.applied == 0 and defeated.credited == false)
assert(defeated.defenseReason == "human-defense-failed-no-award")
assert(defeated.questTransitionCount == 0)
assert(quests:quest_status(defeated_quest).state == "active")
assert(api:faction_status(RAYNE).reputation == reputation_before_absence)

local missing_territory = input(
    "pwft.b5.spec.defense.no-territory",
    "pwft.b5.spec.defense.no-territory.result",
    true,
    true
)
missing_territory.territoryId = nil
local rejected = closure:settle(missing_territory)
assert(not rejected.ok and rejected.reason
    == "task-defense-territory-required")
assert(rejected.applied == 0)

local status = closure:status()
assert(status.settlementCount == 4)
assert(status.objectiveDispatchCount == 4)
assert(status.objectiveTransitionCount == 1)
assert(status.objectiveFailureCount == 0)
assert(status.storyContentIncluded == false)
assert(status.palTokenAuthority == false)
assert(status.PalworldSaveMutation == false)
assert(#observed == 5)

print("PASS B5 mechanics-only quest content and authoritative defense closure: one participated victory completes one objective and awards reputation once; replay, absence, and defeat award zero")
