package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ContentPackRegistry = require("pwft.content_pack_registry")
local QuestRuntime = require("pwft.quest_runtime")
local QuestObjectiveRouter = require("pwft.quest_objective_router")

local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local copied = {}
    for key, item in pairs(value) do
        copied[deep_copy(key)] = deep_copy(item)
    end
    return copied
end

local manifest = {
    schemaVersion = "1.0.0",
    contentPackId = "fan.objective.sample",
    contentVersion = "1.0.0",
    namespace = "fan.objective",
    localizationNamespace = "fan.objective.l10n",
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = { "pwft.quest.templates" },
    localizationKeys = {
        "fan.objective.l10n.title",
        "fan.objective.l10n.summary",
        "fan.objective.l10n.await-content",
        "fan.objective.l10n.defend",
        "fan.objective.l10n.raid",
        "fan.objective.l10n.trade",
        "fan.objective.l10n.report",
        "fan.objective.l10n.report-choice",
    },
}

local rayne = "pwft.faction.rayne_syndicate"
local template = {
    schemaVersion = "1.0.0",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    templateId = "fan.objective.cross-source",
    titleKey = "fan.objective.l10n.title",
    summaryKey = "fan.objective.l10n.summary",
    startStageId = "await-content",
    stages = {
        {
            stageId = "await-content",
            objectiveKey = "fan.objective.l10n.await-content",
            objectiveRules = {
                {
                    schemaVersion = "pwft.quest-objective-rule.v1",
                    objectiveId = "fan.objective.rule.content-ready",
                    eventSource = "content",
                    eventKind = "signal",
                    match = {
                        signalId = "fan.objective.signal.ready",
                    },
                    requiredCount = 1,
                    incrementBy = "event",
                    action = {
                        kind = "advance",
                        targetStageId = "defend",
                    },
                },
            },
            nextStageIds = { "defend" },
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "defend",
            objectiveKey = "fan.objective.l10n.defend",
            objectiveRules = {
                {
                    schemaVersion = "pwft.quest-objective-rule.v1",
                    objectiveId = "fan.objective.rule.defend-twice",
                    eventSource = "defense",
                    eventKind = "completed",
                    match = {
                        factionId = rayne,
                        outcome = "victory",
                        playerParticipated = true,
                    },
                    requiredCount = 2,
                    action = {
                        kind = "advance",
                        targetStageId = "raid",
                    },
                },
            },
            nextStageIds = { "raid" },
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "raid",
            objectiveKey = "fan.objective.l10n.raid",
            objectiveRules = {
                {
                    schemaVersion = "pwft.quest-objective-rule.v1",
                    objectiveId = "fan.objective.rule.raid-leader",
                    eventSource = "raid",
                    eventKind = "completed",
                    match = {
                        outcome = "victory",
                        playerParticipated = true,
                        playerSideWon = true,
                        leaderKillCredited = true,
                    },
                    action = {
                        kind = "advance",
                        targetStageId = "trade",
                    },
                },
            },
            nextStageIds = { "trade" },
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "trade",
            objectiveKey = "fan.objective.l10n.trade",
            objectiveRules = {
                {
                    schemaVersion = "pwft.quest-objective-rule.v1",
                    objectiveId = "fan.objective.rule.sell-five",
                    eventSource = "commerce",
                    eventKind = "transaction",
                    match = {
                        factionId = rayne,
                        productId = "IronIngot",
                        direction = "sell",
                        confirmed = true,
                    },
                    requiredCount = 5,
                    incrementBy = "quantity",
                    action = {
                        kind = "branch",
                        branchId = "report",
                    },
                },
            },
            branches = {
                {
                    branchId = "report",
                    choiceKey = "fan.objective.l10n.report-choice",
                    nextStageId = "report",
                },
            },
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "report",
            objectiveKey = "fan.objective.l10n.report",
            objectiveRules = {
                {
                    schemaVersion = "pwft.quest-objective-rule.v1",
                    objectiveId = "fan.objective.rule.return-location",
                    eventSource = "native",
                    eventKind = "location_entered",
                    match = {
                        locationId = "fan.objective.location.representative",
                    },
                    action = { kind = "complete" },
                },
            },
            completionAllowed = true,
            abortAllowed = true,
        },
    },
}

local content = ContentPackRegistry.create()
assert(content:register(manifest).ok)
local progression = Progression.create(Registry.progression)
local quests = QuestRuntime.create(progression, content)
local router = QuestObjectiveRouter.create(quests, progression)

local invalid_inline = deep_copy(template)
invalid_inline.templateId = "fan.objective.invalid-inline"
invalid_inline.stages[1].objectiveRules[1].text = "forbidden prose"
local inline_result = quests:register_template(invalid_inline)
assert(not inline_result.ok and inline_result.reason == "invalid-quest-template")

local invalid_model = deep_copy(template)
invalid_model.templateId = "fan.objective.invalid-model"
invalid_model.stages[1].objectiveRules[1].eventSource = "model"
local model_rule = quests:register_template(invalid_model)
assert(not model_rule.ok and model_rule.reason == "invalid-quest-template")

local invalid_action = deep_copy(template)
invalid_action.templateId = "fan.objective.invalid-action"
invalid_action.stages[1].objectiveRules[1].action.targetStageId = "raid"
local action_result = quests:register_template(invalid_action)
assert(not action_result.ok and action_result.reason == "invalid-quest-template")

local registered = quests:register_template(template)
assert(registered.ok and registered.objectiveRuleCount == 5)
assert(quests:template_status(template.templateId).objectiveRuleCount == 5)
assert(quests.capabilities.objectiveRules == true)

assert(quests:start(
    template.templateId,
    "fan.objective.instance.001",
    "fan.objective.start.001",
    { sourceId = "fan.objective.fixture" }
).ok)
local active = quests:active_objective_stages()
assert(#active == 1 and active[1].currentStageId == "await-content")
assert(#active[1].objectiveRules == 1)

local bad_authority = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.bad-authority",
    authority = "pwft.model.v1",
    source = "content",
    kind = "signal",
    signalId = "fan.objective.signal.ready",
})
assert(not bad_authority.ok and bad_authority.reason == "invalid-quest-objective-event")

local model_event = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.model",
    authority = "pwft.model.v1",
    source = "model",
    kind = "signal",
    signalId = "fan.objective.signal.ready",
})
assert(not model_event.ok and model_event.reason == "invalid-quest-objective-event")
assert(router.capabilities.modelMayDispatch == false)
assert(router.capabilities.modelMayMutateState == false)

local inline_event = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.inline",
    authority = "pwft.content.v1",
    source = "content",
    kind = "signal",
    signalId = "fan.objective.signal.ready",
    dialogue = "forbidden prose",
})
assert(not inline_event.ok and inline_event.reason == "invalid-quest-objective-event")

local content_event = {
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.content-ready",
    authority = "pwft.content.v1",
    source = "content",
    kind = "signal",
    signalId = "fan.objective.signal.ready",
}
local content_applied = router:dispatch(content_event)
assert(content_applied.ok and content_applied.transitionCount == 1)
assert(quests:quest_status("fan.objective.instance.001").currentStageId == "defend")
local content_replay = router:dispatch(content_event)
assert(content_replay.ok and content_replay.replayed)
assert(content_replay.reason == "quest-objective-event-already-processed")
local content_conflict = deep_copy(content_event)
content_conflict.signalId = "fan.objective.signal.other"
local conflict = router:dispatch(content_conflict)
assert(not conflict.ok and conflict.reason == "quest-objective-event-id-conflict")

local defeat = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.defense-defeat",
    authority = "pwft.defense.v1",
    source = "defense",
    kind = "completed",
    factionId = rayne,
    outcome = "defeat",
    playerParticipated = true,
})
assert(defeat.ok and defeat.reason == "quest-objective-event-ignored")

local wrong_faction = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.defense-wrong",
    authority = "pwft.defense.v1",
    source = "defense",
    kind = "completed",
    factionId = "pwft.faction.pidf",
    outcome = "victory",
    playerParticipated = true,
})
assert(wrong_faction.ok and wrong_faction.transitionCount == 0)

local defense_one = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.defense-001",
    authority = "pwft.defense.v1",
    source = "defense",
    kind = "completed",
    factionId = rayne,
    territoryId = "T-A",
    outcome = "victory",
    playerParticipated = true,
})
assert(defense_one.ok and defense_one.progressedObjectiveCount == 1)
assert(defense_one.transitionCount == 0)
assert(
    router:objective_status("fan.objective.instance.001")
        .defend["fan.objective.rule.defend-twice"].count == 1
)

-- Partial objective counters and processed event IDs live in the same Mod
-- sidecar snapshot. The restore listener must rebind both quest and router
-- state before a later event resumes the objective.
local partial_snapshot = progression:export_snapshot()
assert(progression:restore_snapshot(partial_snapshot).ok)
assert(router:status().snapshotOwnedByProgression)
assert(quests:status().snapshotOwnedByProgression)
assert(
    router:objective_status("fan.objective.instance.001")
        .defend["fan.objective.rule.defend-twice"].count == 1
)

local defense_two = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.defense-002",
    authority = "pwft.defense.v1",
    source = "defense",
    kind = "completed",
    factionId = rayne,
    territoryId = "T-A",
    outcome = "victory",
    playerParticipated = true,
})
assert(defense_two.ok and defense_two.transitionCount == 1)
assert(quests:quest_status("fan.objective.instance.001").currentStageId == "raid")

local raid_without_credit = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.raid-no-credit",
    authority = "pwft.raid.v1",
    source = "raid",
    kind = "completed",
    outcome = "victory",
    playerParticipated = true,
    playerSideWon = true,
    leaderKillCredited = false,
})
assert(raid_without_credit.ok and raid_without_credit.transitionCount == 0)

local raid_victory = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.raid-victory",
    authority = "pwft.raid.v1",
    source = "raid",
    kind = "completed",
    outcome = "victory",
    playerParticipated = true,
    playerSideWon = true,
    leaderKillCredited = true,
})
assert(raid_victory.ok and raid_victory.transitionCount == 1)
assert(quests:quest_status("fan.objective.instance.001").currentStageId == "trade")

local unconfirmed = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.sale-unconfirmed",
    authority = "pwft.commerce.v1",
    source = "commerce",
    kind = "transaction",
    factionId = rayne,
    productId = "IronIngot",
    direction = "sell",
    quantity = 100,
    confirmed = false,
})
assert(not unconfirmed.ok and unconfirmed.reason == "invalid-quest-objective-event")

local sale_two = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.sale-002",
    authority = "pwft.commerce.v1",
    source = "commerce",
    kind = "transaction",
    factionId = rayne,
    productId = "IronIngot",
    direction = "sell",
    quantity = 2,
    amount = 200,
    confirmed = true,
})
assert(sale_two.ok and sale_two.transitionCount == 0)
local sale_three = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.sale-003",
    authority = "pwft.commerce.v1",
    source = "commerce",
    kind = "transaction",
    factionId = rayne,
    productId = "IronIngot",
    direction = "sell",
    quantity = 3,
    amount = 300,
    confirmed = true,
})
assert(sale_three.ok and sale_three.transitionCount == 1)
assert(sale_three.outcomes[1].action == "branch")
assert(quests:quest_status("fan.objective.instance.001").currentStageId == "report")

local wrong_location = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.location-wrong",
    authority = "pwft.native.v1",
    source = "native",
    kind = "location_entered",
    locationId = "fan.objective.location.other",
})
assert(wrong_location.ok and wrong_location.transitionCount == 0)
local returned = router:dispatch({
    schemaVersion = "pwft.quest-objective-event.v1",
    eventId = "fan.objective.event.location-return",
    authority = "pwft.native.v1",
    source = "native",
    kind = "location_entered",
    locationId = "fan.objective.location.representative",
})
assert(returned.ok and returned.transitionCount == 1)
assert(quests:quest_status("fan.objective.instance.001").state == "completed")

local status = router:status()
assert(status.supportedSources == 5)
assert(status.supportedEventKinds == 8)
assert(status.processedEventCount == 11)
assert(status.trackedQuestCount == 1)
assert(status.inlineNarrativeAllowed == false)
assert(status.modelMayDispatch == false and status.modelMayMutateState == false)
assert(status.palworldSaveMutation == false)

print("PASS strict defense/raid/commerce/native/content quest-objective events, automatic advance/branch/complete, idempotency, sidecar restore, and no model authority")
