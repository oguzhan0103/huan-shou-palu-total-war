local TEMPLATE_ID = "pwft.foundation.b5.quest.small-settlement-defense"
local INSTANCE_ID =
    "pwft.foundation.b5.quest.small-settlement-defense.instance"
local START_EVENT_ID =
    "pwft.foundation.b5.quest.small-settlement-defense.start"

local function activate(context)
    assert(type(context) == "table"
        and type(context.questRuntime) == "table",
        "B5 acceptance content requires the quest runtime")
    local started = context.questRuntime:start(
        TEMPLATE_ID,
        INSTANCE_ID,
        START_EVENT_ID,
        {
            sourceId = "pwft.foundation.b5-acceptance",
            purpose = "mechanics-only-live-acceptance",
        }
    )
    if not started.ok and started.reason == "quest-instance-already-exists" then
        local existing = context.questRuntime:quest_status(INSTANCE_ID)
        if existing ~= nil and existing.templateId == TEMPLATE_ID then
            return {
                ok = true,
                reason = "b5-acceptance-quest-already-exists",
                questInstanceId = INSTANCE_ID,
                questState = existing.state,
                storyContentIncluded = false,
            }
        end
    end
    if not started.ok then return started end
    return {
        ok = true,
        reason = started.reason == "quest-started"
                and "b5-acceptance-quest-started"
            or "b5-acceptance-quest-start-replayed",
        questInstanceId = INSTANCE_ID,
        questState = started.quest and started.quest.state,
        storyContentIncluded = false,
    }
end

return {
    bundle = require("pwft_b5_acceptance.bundle"),
    activate = activate,
    identifiers = {
        templateId = TEMPLATE_ID,
        questInstanceId = INSTANCE_ID,
        startEventId = START_EVENT_ID,
    },
    storyContentIncluded = false,
    defaultEnabled = false,
}
