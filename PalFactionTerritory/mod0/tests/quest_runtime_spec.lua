package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ContentPackRegistry = require("pwft.content_pack_registry")
local QuestRuntime = require("pwft.quest_runtime")

local pack_manifest = {
    schemaVersion = "1.0.0",
    contentPackId = "fan.quest.sample",
    contentVersion = "1.0.0",
    namespace = "fan.quest",
    localizationNamespace = "fan.quest.l10n",
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = { "pwft.quest.templates" },
    localizationKeys = {
        "fan.quest.l10n.title",
        "fan.quest.l10n.summary",
        "fan.quest.l10n.objective.start",
        "fan.quest.l10n.objective.investigate",
        "fan.quest.l10n.objective.report",
        "fan.quest.l10n.objective.withdraw",
        "fan.quest.l10n.choice.report",
        "fan.quest.l10n.choice.withdraw",
    },
}

local template = {
    schemaVersion = "1.0.0",
    contentPackId = pack_manifest.contentPackId,
    contentVersion = pack_manifest.contentVersion,
    templateId = "fan.quest.sample-investigation",
    titleKey = "fan.quest.l10n.title",
    summaryKey = "fan.quest.l10n.summary",
    startStageId = "start",
    stages = {
        {
            stageId = "start",
            objectiveKey = "fan.quest.l10n.objective.start",
            nextStageIds = { "investigate" },
            branches = {},
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "investigate",
            objectiveKey = "fan.quest.l10n.objective.investigate",
            nextStageIds = {},
            branches = {
                {
                    branchId = "report",
                    choiceKey = "fan.quest.l10n.choice.report",
                    nextStageId = "report",
                },
                {
                    branchId = "withdraw",
                    choiceKey = "fan.quest.l10n.choice.withdraw",
                    nextStageId = "withdraw",
                },
            },
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "report",
            objectiveKey = "fan.quest.l10n.objective.report",
            nextStageIds = {},
            branches = {},
            completionAllowed = true,
            abortAllowed = false,
        },
        {
            stageId = "withdraw",
            objectiveKey = "fan.quest.l10n.objective.withdraw",
            nextStageIds = {},
            branches = {},
            completionAllowed = true,
            abortAllowed = true,
        },
    },
}

local content = ContentPackRegistry.create()
assert(content:register(pack_manifest).ok)
local progression = Progression.create(Registry.progression)
local quests = QuestRuntime.create(progression, content)
assert(quests:status().snapshotOwnedByProgression)
assert(quests.capabilities.authoredStoryContent == false)

local inline_template = {}
for key, value in pairs(template) do inline_template[key] = value end
inline_template.stages = {
    {
        stageId = "bad",
        objectiveKey = "fan.quest.l10n.objective.start",
        text = "forbidden inline story prose",
        completionAllowed = true,
    },
}
inline_template.startStageId = "bad"
local invalid_inline = quests:register_template(inline_template)
assert(not invalid_inline.ok and invalid_inline.reason == "invalid-quest-template")
assert(quests:status().templateCount == 0)

local undeclared_key_template = {}
for key, value in pairs(template) do undeclared_key_template[key] = value end
undeclared_key_template.titleKey = "fan.quest.l10n.not-declared"
local invalid_key = quests:register_template(undeclared_key_template)
assert(not invalid_key.ok and invalid_key.reason == "invalid-quest-template")
assert(quests:status().templateCount == 0)

local registered = quests:register_template(template)
assert(registered.ok and registered.reason == "quest-template-registered")
assert(registered.stageCount == 4)
assert(quests:register_template(template).reason == "quest-template-already-registered")

local started = quests:start(
    template.templateId,
    "quest:sample:001",
    "event:quest:start:001",
    { sourceId = "token:sample:001", flags = { "eligible" } }
)
assert(started.ok and started.reason == "quest-started")
assert(started.quest.stage.stageId == "start")
assert(started.quest.stage.objectiveKey == "fan.quest.l10n.objective.start")
local start_replay = quests:start(
    template.templateId,
    "quest:sample:001",
    "event:quest:start:001",
    { sourceId = "token:sample:001", flags = { "eligible" } }
)
assert(start_replay.ok and start_replay.replayed)
assert(start_replay.reason == "quest-start-already-processed")
local start_conflict = quests:start(
    template.templateId,
    "quest:sample:other",
    "event:quest:start:001",
    { sourceId = "token:sample:001" }
)
assert(not start_conflict.ok and start_conflict.reason == "quest-event-id-conflict")

assert(
    quests:advance(
        "quest:sample:001",
        "report",
        "event:quest:invalid-transition",
        nil
    ).reason
        == "quest-transition-not-allowed"
)
local advanced = quests:advance(
    "quest:sample:001",
    "investigate",
    "event:quest:advance:001",
    { flags = { "clue-found" }, score = 1 }
)
assert(advanced.ok and advanced.reason == "quest-advanced")
assert(advanced.quest.currentStageId == "investigate")
assert(
    quests:branch(
        "quest:sample:001",
        "unknown",
        "event:quest:unknown-branch",
        nil
    ).reason
        == "unknown-quest-branch"
)
local branched = quests:branch(
    "quest:sample:001",
    "report",
    "event:quest:branch:001",
    { viewpoint = "protect-city" }
)
assert(branched.ok and branched.reason == "quest-branched")
assert(branched.quest.currentStageId == "report")
assert(
    quests:abort(
        "quest:sample:001",
        "event:quest:abort-denied",
        { reasonTag = "player-choice" }
    ).reason
        == "quest-abort-not-allowed"
)
local completed = quests:complete(
    "quest:sample:001",
    "event:quest:complete:001",
    {
        resultTags = { "understanding-earned", "city-protected" },
        flags = { promiseKept = true },
    }
)
assert(completed.ok and completed.reason == "quest-completed")
assert(completed.quest.state == "completed")
assert(completed.resolution.structuredResult.flags.promiseKept == true)
local complete_replay = quests:complete(
    "quest:sample:001",
    "event:quest:complete:001",
    {
        resultTags = { "understanding-earned", "city-protected" },
        flags = { promiseKept = true },
    }
)
assert(complete_replay.ok and complete_replay.replayed)
assert(complete_replay.reason == "quest-complete-already-processed")

local second = quests:start(
    template.templateId,
    "quest:sample:002",
    "event:quest:start:002",
    nil
)
assert(second.ok)
local aborted = quests:abort(
    "quest:sample:002",
    "event:quest:abort:002",
    { reasonTag = "player-withdrew" }
)
assert(aborted.ok and aborted.reason == "quest-aborted")
assert(aborted.quest.state == "aborted")

local inline_result_ok = pcall(function()
    quests:start(
        template.templateId,
        "quest:sample:003",
        "event:quest:start:003",
        { text = "forbidden inline story prose" }
    )
end)
assert(not inline_result_ok)

local status = quests:status()
assert(status.templateCount == 1)
assert(status.questInstanceCount == 2)
assert(status.completedQuestCount == 1)
assert(status.abortedQuestCount == 1)
assert(status.processedEventCount == 6)
assert(status.localizationKeysOnly and status.structuredResultsOnly)
assert(progression.state.contentQuests == quests.state)
assert(progression:export_snapshot().contentQuests.instances["quest:sample:001"].state == "completed")

-- The quest ledger survives through the existing progression snapshot. A
-- fresh runtime may register the same content/template and continue querying
-- completed or aborted instances without touching Palworld's save payload.
local restored_progression = Progression.create(
    Registry.progression,
    progression:export_snapshot()
)
local restored_content = ContentPackRegistry.create()
assert(restored_content:register(pack_manifest).ok)
local restored_quests = QuestRuntime.create(restored_progression, restored_content)
assert(restored_quests:register_template(template).ok)
assert(restored_quests:quest_status("quest:sample:001").state == "completed")
assert(restored_quests:quest_status("quest:sample:002").state == "aborted")
assert(restored_quests:status().snapshotOwnedByProgression)

print("PASS localization-key-only quest templates, start/advance/branch/complete/abort, idempotent events, structured results, and progression-owned snapshot restore")
