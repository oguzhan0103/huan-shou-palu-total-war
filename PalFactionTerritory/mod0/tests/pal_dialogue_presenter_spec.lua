package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local PalDialoguePresenter =
    require("pwft.pal_dialogue_presenter")

local function make_controller()
    local controller = {
        state = "active",
        node = {
            nodeId = "opening",
            speakerRole = "pal-representative",
            textKey = "fan.guide.opening",
            choices = {
                {
                    choiceId = "continue",
                    textKey = "fan.guide.choice.continue",
                },
                {
                    choiceId = "leave",
                    textKey = "fan.guide.choice.leave",
                },
            },
        },
        agent = nil,
        calls = {},
    }
    function controller:session_view(session_id)
        if session_id ~= "session-1" then
            return { ok = false, reason = "unknown-pal-discourse-session" }
        end
        return {
            ok = true,
            reason = "pal-dialogue-session-view-ready",
            session = {
                sessionId = session_id,
                representativeId = "fan.guide.v1",
                representativeNameKey = "fan.guide.name",
                factionId = "pwft.faction.desert_pal_tribe",
                state = self.state,
                node = self.node,
            },
            agent = self.agent,
        }
    end
    function controller:choose_authored(
        session_id,
        choice_id,
        action_id
    )
        self.calls[#self.calls + 1] = {
            kind = "choice",
            sessionId = session_id,
            choiceId = choice_id,
            actionId = action_id,
        }
        if choice_id == "leave" then
            self.state = "resolved"
            self.node = nil
            return {
                ok = true,
                reason = "pal-discourse-terminal-resolved",
            }
        end
        self.node = {
            nodeId = "reply",
            speakerRole = "player",
            textKey = "fan.guide.reply",
            choices = {
                {
                    choiceId = "leave",
                    textKey = "fan.guide.choice.leave",
                },
            },
        }
        self.agent = nil
        return {
            ok = true,
            reason = "pal-discourse-node-ready",
            node = self.node,
        }
    end
    function controller:submit_agent_turn(
        session_id,
        player_text,
        context
    )
        self.calls[#self.calls + 1] = {
            kind = "submit",
            sessionId = session_id,
            playerText = player_text,
            context = context,
        }
        self.agent = {
            requestId = "agent-request-1",
            state = "pending",
            response = nil,
        }
        return {
            ok = true,
            reason = "agent-request-submitted",
            requestId = "agent-request-1",
            stateMutationApplied = false,
        }
    end
    function controller:poll_agent_turn(request_id)
        self.calls[#self.calls + 1] = {
            kind = "poll",
            requestId = request_id,
        }
        self.agent = {
            requestId = request_id,
            state = "ready",
            response = {
                dialogue = "我听见了。",
                proposedChoice = "continue",
                resultTags = {},
            },
        }
        return {
            ok = true,
            reason = "agent-response-ready",
            response = self.agent.response,
            stateMutationApplied = false,
        }
    end
    function controller:confirm_agent_proposal(
        request_id,
        action_id
    )
        self.calls[#self.calls + 1] = {
            kind = "confirm",
            requestId = request_id,
            actionId = action_id,
        }
        self.node = {
            nodeId = "reply",
            speakerRole = "player",
            textKey = "fan.guide.reply",
            choices = {
                {
                    choiceId = "leave",
                    textKey = "fan.guide.choice.leave",
                },
            },
        }
        self.agent = nil
        return {
            ok = true,
            reason = "agent-proposal-committed-by-player",
            stateMutationAppliedBy =
                "deterministic-pal-discourse-runtime-after-player-confirmation",
        }
    end
    function controller:player_abort(session_id, abort_id)
        self.calls[#self.calls + 1] = {
            kind = "abort",
            sessionId = session_id,
            abortId = abort_id,
        }
        self.state = "resolved"
        self.node = nil
        self.agent = nil
        return {
            ok = true,
            reason = "pal-discourse-player-abort-consumed",
        }
    end
    function controller:technical_failure(
        session_id,
        failure_id,
        technical_reason
    )
        self.calls[#self.calls + 1] = {
            kind = "technical-failure",
            sessionId = session_id,
            failureId = failure_id,
            technicalReason = technical_reason,
        }
        self.state = "technical-refund"
        self.node = nil
        self.agent = nil
        return {
            ok = true,
            reason = "pal-discourse-technical-failure-refunded",
        }
    end
    return controller
end

local function config()
    return {
        dialoguePresenterRouterEnabled = true,
        nativeDialoguePresenterEnabled = false,
    }
end

-- A missing cooked/native backend does not change dialogue state. The Core
-- still returns a complete localization-key-only presentation view so a later
-- backend can attach without rebuilding the deterministic rule engine.
local headless_controller = make_controller()
local headless = PalDialoguePresenter.create(
    headless_controller,
    config(),
    { resolveBackend = function() return nil end }
)
local headless_open = headless:open("session-1")
assert(not headless_open.ok)
assert(headless_open.reason == "dialogue-presenter-backend-unavailable")
assert(headless_open.presentationReady == true)
assert(headless_open.view.textKey == "fan.guide.opening")
assert(#headless_open.view.choices == 2)
assert(headless_open.view.storyContentIncluded == false)
assert(headless_open.view.stateMutationApplied == false)
assert(#headless_controller.calls == 0)

local backend = {
    showCount = 0,
    updateCount = 0,
    hideCount = 0,
    last = nil,
}
function backend:show(view)
    self.showCount = self.showCount + 1
    self.last = view
    return true
end
function backend:update(view)
    self.updateCount = self.updateCount + 1
    self.last = view
    return true
end
function backend:hide(view)
    self.hideCount = self.hideCount + 1
    self.lastHide = view
    return true
end

local controller = make_controller()
local presenter = PalDialoguePresenter.create(
    controller,
    config(),
    { resolveBackend = function() return backend end }
)
local opened = presenter:open("session-1")
assert(opened.ok and opened.reason == "pal-dialogue-presentation-opened")
assert(opened.presentationId == "pal-dialogue-presentation:00000001")
assert(backend.showCount == 1)
assert(backend.last.representativeId == "fan.guide.v1")
assert(backend.last.representativeNameKey == "fan.guide.name")
assert(backend.last.textKey == "fan.guide.opening")
assert(backend.last.actions.submitAgentText == true)
assert(backend.last.deterministicRuleEngineOwnsOutcome == true)

-- Closing an active presentation cannot silently preserve or consume an
-- irreversible token. The UI must route an explicit player-abort action.
local hidden_active = presenter:hide_without_abort(
    opened.presentationId
)
assert(not hidden_active.ok)
assert(
    hidden_active.reason
        == "explicit-player-abort-required-active-token-would-be-consumed"
)
assert(backend.hideCount == 0)

local submitted = presenter:submit_agent_turn(
    opened.presentationId,
    "我们谈谈。",
    {
        worldKey = "world-1",
        playerKey = "player-1",
        locale = "zh-CN",
    }
)
assert(submitted.ok and submitted.requestId == "agent-request-1")
assert(backend.updateCount == 1)
assert(backend.last.agent.state == "pending")
assert(#controller.calls == 1 and controller.calls[1].kind == "submit")

local polled = presenter:poll_agent_turn(
    opened.presentationId,
    submitted.requestId
)
assert(polled.ok and polled.reason == "agent-response-ready")
assert(backend.updateCount == 2)
assert(backend.last.agent.dialogue == "我听见了。")
assert(backend.last.agent.proposedChoice == "continue")
assert(backend.last.agent.requiresPlayerConfirmation == true)
assert(#controller.calls == 2 and controller.calls[2].kind == "poll")

local confirmed = presenter:confirm_agent_proposal(
    opened.presentationId,
    submitted.requestId,
    "player-confirmed-agent-1"
)
assert(confirmed.ok)
assert(
    confirmed.reason
        == "agent-proposal-committed-by-player"
)
assert(backend.updateCount == 3)
assert(backend.last.nodeId == "reply")
assert(backend.last.agent == nil)
assert(#controller.calls == 3 and controller.calls[3].kind == "confirm")

local terminal = presenter:choose_authored(
    opened.presentationId,
    "leave",
    "player-authored-leave-1"
)
assert(terminal.ok)
assert(terminal.reason == "pal-dialogue-authored-choice-routed")
assert(terminal.stateMutationAppliedBy == "deterministic-pal-discourse-runtime")
assert(backend.updateCount == 4)
assert(backend.hideCount == 1)
assert(presenter:presentation_status(opened.presentationId).state == "resolved")

local dismissed = presenter:hide_without_abort(
    opened.presentationId
)
assert(dismissed.ok)
assert(backend.hideCount == 2)

-- Explicit abort is a separate tested route and is the only UI-close action
-- allowed to consume an active discourse attempt.
local abort_controller = make_controller()
local abort_backend = {
    show = backend.show,
    update = backend.update,
    hide = backend.hide,
    showCount = 0,
    updateCount = 0,
    hideCount = 0,
}
local abort_presenter = PalDialoguePresenter.create(
    abort_controller,
    config(),
    { resolveBackend = function() return abort_backend end }
)
local abort_open = abort_presenter:open("session-1")
local aborted = abort_presenter:player_abort(
    abort_open.presentationId,
    "player-abort-1"
)
assert(aborted.ok)
assert(aborted.reason == "pal-discourse-player-abort-consumed")
assert(abort_backend.hideCount == 1)
assert(#abort_controller.calls == 1)
assert(abort_controller.calls[1].kind == "abort")

local failure_controller = make_controller()
local failure_backend = {
    show = backend.show,
    update = backend.update,
    hide = backend.hide,
    showCount = 0,
    updateCount = 0,
    hideCount = 0,
}
local failure_presenter = PalDialoguePresenter.create(
    failure_controller,
    config(),
    { resolveBackend = function() return failure_backend end }
)
local failure_open = failure_presenter:open("session-1")
local technical = failure_presenter:technical_failure(
    failure_open.presentationId,
    "presenter-failure-1",
    "native-widget-disconnected"
)
assert(technical.ok)
assert(
    technical.reason
        == "pal-discourse-technical-failure-refunded"
)
assert(failure_backend.hideCount == 1)
assert(#failure_controller.calls == 1)
assert(failure_controller.calls[1].kind == "technical-failure")
assert(
    failure_controller.calls[1].technicalReason
        == "native-widget-disconnected"
)

local status = presenter:status()
assert(status.enabled == true)
assert(status.backendAvailable == true)
assert(status.nativePresenterEnabled == false)
assert(status.presentationCount == 1)
assert(status.activePresentationCount == 0)
assert(status.openCount == 1)
assert(status.updateCount == 4)
assert(status.closeCount == 1)
assert(status.explicitAbortRequired == true)
assert(status.directPresenterStateMutation == false)
assert(status.storyContentIncluded == false)

print("PASS dialogue presenter routes localization keys, Agent text, authored choices, explicit confirmation, and abort without taking state authority")
