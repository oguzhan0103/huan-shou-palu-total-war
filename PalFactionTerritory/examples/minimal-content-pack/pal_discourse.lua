local Keys = require("minimal-content-pack.localization_keys").byName

return {
    schemaVersion = "1.0.0",
    contentPackId = "example.minimal.foundation",
    contentVersion = "1.0.0",
    factions = {
        {
            factionId = "pwft.faction.desert_pal_tribe",
            tokenQuota = 1,
            maximumAffinityPerDiscourse = 10,
            representative = {
                representativeId = "example.minimal.pal.representative.primary",
                nameKey = Keys.palRepresentativeName,
                interactionPromptKey = Keys.palRepresentativePrompt,
            },
            trees = {
                {
                    treeId = "example.minimal.pal.tree.generic",
                    cityStateId = "*",
                    rootNodeId = "example.minimal.pal.node.opening",
                    nodes = {
                        {
                            nodeId = "example.minimal.pal.node.opening",
                            speakerRole = "pal-representative",
                            textKey = Keys.palOpening,
                            choices = {
                                {
                                    choiceId = "example.minimal.pal.choice.complete",
                                    textKey = Keys.palCompleteChoice,
                                    nextNodeId = "example.minimal.pal.node.complete",
                                },
                                {
                                    choiceId = "example.minimal.pal.choice.abort",
                                    textKey = Keys.palAbortChoice,
                                    nextNodeId = "example.minimal.pal.node.abort",
                                },
                            },
                        },
                        {
                            nodeId = "example.minimal.pal.node.complete",
                            speakerRole = "pal-representative",
                            textKey = Keys.palComplete,
                            terminal = {
                                outcome = "completed",
                                affinityAward = 10,
                                resultTags = { "example.minimal.result.complete" },
                            },
                        },
                        {
                            nodeId = "example.minimal.pal.node.abort",
                            speakerRole = "player",
                            textKey = Keys.palAbort,
                            terminal = {
                                outcome = "player_abort",
                                affinityAward = 0,
                                resultTags = { "example.minimal.result.abort" },
                            },
                        },
                    },
                },
            },
        },
    },
}
