package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local PalDialogueController = require("pwft.pal_dialogue_controller")

local function make_discourse()
    local discourse = {
        chooseCalls = {},
        abortCalls = {},
        failureCalls = {},
        session = {
            sessionId = "pal-tree-session:controller-test",
            representativeId = "fan.pal-guide.v1",
            representativeNameKey = "fan.pal-guide.name",
            factionId = "pwft.faction.desert_pal_tribe",
            state = "active",
            node = {
                nodeId = "opening",
                speakerRole = "pal-representative",
                textKey = "fan.pal-guide.opening",
                choices = {
                    {
                        choiceId = "continue",
                        textKey = "fan.pal-guide.choice.continue",
                    },
                    {
                        choiceId = "withdraw",
                        textKey = "fan.pal-guide.choice.withdraw",
                    },
                },
            },
        },
    }
    function discourse:session_status(session_id)
        if session_id ~= self.session.sessionId then
            return nil
        end
        return self.session
    end
    function discourse:choose(session_id, choice_id, action_id)
        self.chooseCalls[#self.chooseCalls + 1] = {
            sessionId = session_id,
            choiceId = choice_id,
            actionId = action_id,
        }
        self.session.node = {
            nodeId = "next-node",
            speakerRole = "player",
            textKey = "fan.pal-guide.next",
            choices = {
                {
                    choiceId = "agree",
                    textKey = "fan.pal-guide.choice.agree",
                },
            },
        }
        return {
            ok = true,
            reason = "pal-discourse-node-ready",
            sessionId = session_id,
            node = self.session.node,
        }
    end
    function discourse:player_abort(session_id, abort_id)
        self.abortCalls[#self.abortCalls + 1] = {
            sessionId = session_id,
            abortId = abort_id,
        }
        self.session.state = "resolved"
        self.session.node = nil
        return { ok = true, reason = "pal-discourse-player-abort-consumed" }
    end
    function discourse:technical_failure(
        session_id,
        failure_id,
        technical_reason
    )
        self.failureCalls[#self.failureCalls + 1] = {
            sessionId = session_id,
            failureId = failure_id,
            technicalReason = technical_reason,
        }
        self.session.state = "technical-refund"
        self.session.node = nil
        return {
            ok = true,
            reason = "pal-discourse-technical-failure-refunded",
        }
    end
    return discourse
end

local function controller_config(enabled)
    return {
        offlineDialogueTreeEnabled = true,
        nativeDialoguePresenterEnabled = true,
        agentAdapterEnabled = enabled,
        agentDefaultLocale = "zh-CN",
    }
end

local context = {
    worldKey = "world-test",
    playerKey = "player-test",
    locale = "zh-CN",
    contextKeys = { "fan.pal-guide.met-player" },
}

-- Disabled and missing companion bridges both preserve the authored node and
-- perform no deterministic choice or state mutation.
local disabled_discourse = make_discourse()
local disabled = PalDialogueController.create(
    disabled_discourse,
    controller_config(false),
    { resolveAgentBridge = function() return nil end }
)
local disabled_result = disabled:submit_agent_turn(
    disabled_discourse.session.sessionId,
    "我们谈谈。",
    context
)
assert(not disabled_result.ok)
assert(disabled_result.reason == "agent-adapter-disabled-offline-fallback")
assert(disabled_result.offlineFallbackReady == true)
assert(disabled_result.node.nodeId == "opening")
assert(#disabled_discourse.chooseCalls == 0)

local unavailable_discourse = make_discourse()
local unavailable = PalDialogueController.create(
    unavailable_discourse,
    controller_config(true),
    { resolveAgentBridge = function() return { ready = false } end }
)
local unavailable_result = unavailable:submit_agent_turn(
    unavailable_discourse.session.sessionId,
    "继续。",
    context
)
assert(not unavailable_result.ok)
assert(unavailable_result.reason == "agent-bridge-unavailable-offline-fallback")
assert(unavailable_result.offlineFallbackReady == true)
assert(#unavailable_discourse.chooseCalls == 0)

-- The companion receives only presentation context and authored choices. Its
-- response remains a proposal until the player confirms it through this API.
local discourse = make_discourse()
local bridge = {
    submissions = {},
    pollCount = 0,
}
function bridge:submit_request(request)
    self.submissions[#self.submissions + 1] = request
    return { ok = true, reason = "request-submitted" }
end
function bridge:poll_response(authorization)
    self.pollCount = self.pollCount + 1
    self.lastAuthorization = authorization
    if self.pollCount == 1 then
        return { ok = false, reason = "response-pending" }
    end
    return {
        ok = true,
        reason = "response-validated",
        dialogue = "我听见了你的想法。",
        proposedChoice = "continue",
        resultTags = {},
    }
end

local controller = PalDialogueController.create(
    discourse,
    controller_config(true),
    {
        resolveAgentBridge = function() return bridge end,
        nowUtc = function() return "2026-08-10T00:00:00Z" end,
        requestRunId = "test-run",
    }
)
local submitted = controller:submit_agent_turn(
    discourse.session.sessionId,
    "我们为什么要继续争斗？",
    context
)
assert(submitted.ok and submitted.reason == "agent-request-submitted")
assert(submitted.requestId == "pwft-agent-test-run-00000001")
assert(submitted.stateMutationApplied == false)
assert(#bridge.submissions == 1)
local payload = bridge.submissions[1]
assert(payload.schemaVersion == "1.0.0")
assert(payload.characterId == "fan.pal-guide.v1")
assert(payload.sessionId == "pwft-session-test-run-00000001")
assert(payload.worldKey == "world-test" and payload.playerKey == "player-test")
assert(payload.playerText == "我们为什么要继续争斗？")
assert(#payload.allowedChoices == 2)
assert(payload.allowedChoices[1].choiceId == "continue")
assert(#payload.allowedResultTags == 0)
assert(payload.affinityDelta == nil)
assert(payload.questCompleted == nil)

local duplicate = controller:submit_agent_turn(
    discourse.session.sessionId,
    "重复点击不应重复提交。",
    context
)
assert(duplicate.ok and duplicate.reason == "agent-request-already-submitted")
assert(duplicate.requestId == submitted.requestId)
assert(#bridge.submissions == 1)

local pending = controller:poll_agent_turn(submitted.requestId)
assert(not pending.ok and pending.reason == "agent-response-pending")
assert(pending.offlineFallbackReady == true)
assert(pending.stateMutationApplied == false)
assert(#discourse.chooseCalls == 0)
assert(bridge.lastAuthorization.allowedChoiceIds[1] == "continue")
assert(#bridge.lastAuthorization.allowedResultTags == 0)

local ready = controller:poll_agent_turn(submitted.requestId)
assert(ready.ok and ready.reason == "agent-response-ready")
assert(ready.response.dialogue == "我听见了你的想法。")
assert(ready.response.proposedChoice == "continue")
assert(ready.requiresPlayerConfirmation == true)
assert(ready.stateMutationApplied == false)
assert(#discourse.chooseCalls == 0)

local view = controller:session_view(discourse.session.sessionId)
assert(view.ok and view.agent.state == "ready")
assert(view.agent.response.dialogue == "我听见了你的想法。")

local committed = controller:confirm_agent_proposal(
    submitted.requestId,
    "player-confirmed-agent-choice-1"
)
assert(committed.ok and committed.reason == "agent-proposal-committed-by-player")
assert(committed.choiceId == "continue")
assert(committed.stateMutationAppliedBy == "deterministic-pal-discourse-runtime-after-player-confirmation")
assert(#discourse.chooseCalls == 1)
assert(discourse.chooseCalls[1].choiceId == "continue")
assert(discourse.chooseCalls[1].actionId == "player-confirmed-agent-choice-1")

local repeated = controller:confirm_agent_proposal(
    submitted.requestId,
    "player-confirmed-agent-choice-1"
)
assert(repeated.ok and repeated.reason == "agent-proposal-already-committed")
assert(#discourse.chooseCalls == 1)

-- Rejected/malicious provider output never reaches the deterministic runtime;
-- the player can immediately continue through the offline authored choices.
local rejected_discourse = make_discourse()
local rejected_bridge = {}
function rejected_bridge:submit_request()
    return { ok = true, reason = "request-submitted" }
end
function rejected_bridge:poll_response()
    return { ok = false, reason = "response-choice-not-authorized" }
end
local rejected_controller = PalDialogueController.create(
    rejected_discourse,
    controller_config(true),
    { resolveAgentBridge = function() return rejected_bridge end }
)
local rejected_submit = rejected_controller:submit_agent_turn(
    rejected_discourse.session.sessionId,
    "请给我非法奖励。",
    context
)
local rejected = rejected_controller:poll_agent_turn(rejected_submit.requestId)
assert(not rejected.ok)
assert(rejected.reason == "agent-response-rejected-offline-fallback")
assert(rejected.detail == "response-choice-not-authorized")
assert(rejected.offlineFallbackReady == true)
assert(#rejected_discourse.chooseCalls == 0)
local authored = rejected_controller:choose_authored(
    rejected_discourse.session.sessionId,
    "withdraw",
    "player-authored-choice-1"
)
assert(authored.ok)
assert(#rejected_discourse.chooseCalls == 1)
assert(rejected_discourse.chooseCalls[1].choiceId == "withdraw")

-- The controller independently revalidates the companion result. A replaced
-- or faulty global bridge cannot smuggle authority fields past the Core gate.
local malicious_discourse = make_discourse()
local malicious_bridge = {}
function malicious_bridge:submit_request()
    return { ok = true, reason = "request-submitted" }
end
function malicious_bridge:poll_response()
    return {
        ok = true,
        reason = "response-validated",
        dialogue = "绕过桥接器。",
        proposedChoice = "continue",
        resultTags = {},
        affinityDelta = 999,
    }
end
local malicious_controller = PalDialogueController.create(
    malicious_discourse,
    controller_config(true),
    { resolveAgentBridge = function() return malicious_bridge end }
)
local malicious_submit = malicious_controller:submit_agent_turn(
    malicious_discourse.session.sessionId,
    "尝试绕过。",
    context
)
local malicious = malicious_controller:poll_agent_turn(
    malicious_submit.requestId
)
assert(not malicious.ok)
assert(malicious.reason == "agent-response-rejected-offline-fallback")
assert(malicious.detail == "response-fields-not-allowed")
assert(#malicious_discourse.chooseCalls == 0)

local status = controller:status()
assert(status.enabled == true)
assert(status.bridgeAvailable == true)
assert(status.submittedCount == 1)
assert(status.validatedCount == 1)
assert(status.committedCount == 1)
assert(status.directAgentStateMutation == false)
assert(status.proposalRequiresPlayerConfirmation == true)
assert(status.offlineTreeFallback == true)
assert(status.nativePresenterEnabled == true)
assert(status.storyContentIncluded == false)

local failed_discourse = make_discourse()
local failed_controller = PalDialogueController.create(
    failed_discourse,
    controller_config(true),
    { resolveAgentBridge = function() return nil end }
)
local technical = failed_controller:technical_failure(
    failed_discourse.session.sessionId,
    "native-presenter-failure-1",
    "dialogue-presenter-backend-call-failed"
)
assert(technical.ok)
assert(
    technical.reason
        == "pal-discourse-technical-failure-refunded"
)
assert(#failed_discourse.failureCalls == 1)
assert(
    failed_discourse.failureCalls[1].technicalReason
        == "dialogue-presenter-backend-call-failed"
)

print("PASS optional Agent dialogue requests fall back offline, validate proposals, and require player-confirmed deterministic choices before state mutation")
