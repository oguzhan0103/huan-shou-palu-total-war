local Manifest = require("pwft_b5_acceptance.manifest")
local QuestTemplate = require("pwft_b5_acceptance.quest_template")

return {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = Manifest,
    questTemplates = {
        QuestTemplate,
    },
}
