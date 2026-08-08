local Keys = require("minimal-content-pack.localization_keys").byName

return {
    schemaVersion = "1.0.0",
    contentPackId = "example.minimal.foundation",
    contentVersion = "1.0.0",
    templateId = "example.minimal.quest.generic-resolution",
    titleKey = Keys.questTitle,
    summaryKey = Keys.questSummary,
    startStageId = "example.minimal.quest.stage.begin",
    stages = {
        {
            stageId = "example.minimal.quest.stage.begin",
            objectiveKey = Keys.questBeginObjective,
            nextStageIds = { "example.minimal.quest.stage.choose" },
            completionAllowed = false,
            abortAllowed = false,
        },
        {
            stageId = "example.minimal.quest.stage.choose",
            objectiveKey = Keys.questChooseObjective,
            branches = {
                {
                    branchId = "example.minimal.quest.branch.preserve",
                    choiceKey = Keys.questPreserveChoice,
                    nextStageId = "example.minimal.quest.stage.resolve",
                },
                {
                    branchId = "example.minimal.quest.branch.transfer",
                    choiceKey = Keys.questTransferChoice,
                    nextStageId = "example.minimal.quest.stage.resolve",
                },
            },
            completionAllowed = false,
            abortAllowed = true,
        },
        {
            stageId = "example.minimal.quest.stage.resolve",
            objectiveKey = Keys.questResolveObjective,
            completionAllowed = true,
            abortAllowed = true,
        },
    },
}
