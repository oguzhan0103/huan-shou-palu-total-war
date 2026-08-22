local Keys = require("pwft_b5_acceptance.localization_keys").byName

return {
    schemaVersion = "1.0.0",
    contentPackId = "pwft.foundation.b5-acceptance",
    contentVersion = "1.0.0",
    templateId = "pwft.foundation.b5.quest.small-settlement-defense",
    titleKey = Keys.questTitle,
    summaryKey = Keys.questSummary,
    startStageId = "defend-small-settlement",
    stages = {
        {
            stageId = "defend-small-settlement",
            objectiveKey = Keys.defendObjective,
            objectiveRules = {
                {
                    schemaVersion = "pwft.quest-objective-rule.v1",
                    objectiveId =
                        "pwft.foundation.b5.objective.defend-small-settlement",
                    eventSource = "defense",
                    eventKind = "completed",
                    match = {
                        factionId = "pwft.faction.rayne_syndicate",
                        territoryId =
                            "pwft.island.central_southeast_archipelago",
                        outcome = "victory",
                        playerParticipated = true,
                    },
                    requiredCount = 1,
                    incrementBy = "event",
                    action = { kind = "complete" },
                },
            },
            completionAllowed = true,
            abortAllowed = true,
        },
    },
}
