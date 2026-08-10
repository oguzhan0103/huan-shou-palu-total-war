local PalDialoguePresenter = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local output = {}
    for key, item in pairs(value) do
        output[copy(key)] = copy(item)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty_string(value, maximum)
    return type(value) == "string"
        and value ~= ""
        and (maximum == nil or #value <= maximum)
end

local function default_backend_resolver()
    return rawget(
        _G,
        "PWFT_PAL_DIALOGUE_PRESENTER_BRIDGE_V1"
    )
end

local function call_backend(backend, method_name, payload)
    if type(backend) ~= "table"
        or type(backend[method_name]) ~= "function" then
        return false, "dialogue-presenter-backend-method-unavailable"
    end
    local called, first, second = pcall(function()
        return backend[method_name](backend, copy(payload))
    end)
    if not called then
        return false, "dialogue-presenter-backend-call-failed:"
            .. tostring(first)
    end
    if first == true then
        return true, second
    end
    if type(first) == "table" and first.ok == true then
        return true, first.reason
    end
    return false,
        second
        or (type(first) == "table" and first.reason)
        or "dialogue-presenter-backend-rejected"
end

function PalDialoguePresenter.create(
    dialogue_controller,
    configuration,
    options
)
    assert(
        type(dialogue_controller) == "table",
        "Pal dialogue controller is required"
    )
    assert(
        type(dialogue_controller.session_view) == "function",
        "Pal dialogue session-view API is required"
    )
    assert(
        type(dialogue_controller.choose_authored) == "function",
        "Pal dialogue authored-choice API is required"
    )
    assert(
        type(dialogue_controller.submit_agent_turn) == "function",
        "Pal Agent submit API is required"
    )
    assert(
        type(dialogue_controller.poll_agent_turn) == "function",
        "Pal Agent poll API is required"
    )
    assert(
        type(dialogue_controller.confirm_agent_proposal) == "function",
        "Pal Agent confirmation API is required"
    )
    assert(
        type(dialogue_controller.player_abort) == "function",
        "Pal dialogue abort API is required"
    )
    assert(
        type(dialogue_controller.technical_failure) == "function",
        "Pal dialogue technical-failure API is required"
    )
    assert(
        type(configuration) == "table",
        "Pal dialogue presenter configuration is required"
    )
    assert(
        type(configuration.dialoguePresenterRouterEnabled)
            == "boolean",
        "Pal dialogue presenter-router flag is required"
    )
    assert(
        type(configuration.nativeDialoguePresenterEnabled)
            == "boolean",
        "native Pal dialogue presenter flag is required"
    )
    options = options or {}
    assert(
        options.resolveBackend == nil
            or type(options.resolveBackend) == "function",
        "dialogue presenter backend resolver must be a function"
    )
    return setmetatable({
        version = API_VERSION,
        controller = dialogue_controller,
        enabled = configuration.dialoguePresenterRouterEnabled,
        nativePresenterEnabled =
            configuration.nativeDialoguePresenterEnabled,
        resolveBackend = options.resolveBackend
            or default_backend_resolver,
        nextPresentationOrdinal = 0,
        presentations = {},
        presentationBySession = {},
        openCount = 0,
        updateCount = 0,
        closeCount = 0,
        backendFailureCount = 0,
        capabilities = {
            localizationKeyPresentation = true,
            generatedDialoguePresentation = true,
            authoredChoiceRouting = true,
            agentProposalConfirmationRouting = true,
            explicitAbortRouting = true,
            implicitCloseMayConsumeToken = false,
            deterministicRuleEngineOwnsOutcome = true,
            directPresenterStateMutation = false,
            PalworldSaveMutation = false,
            nativePresenter =
                configuration.nativeDialoguePresenterEnabled,
            storyContentIncluded = false,
        },
    }, { __index = PalDialoguePresenter })
end

function PalDialoguePresenter:_backend()
    local resolved, backend = pcall(self.resolveBackend)
    if not resolved
        or type(backend) ~= "table"
        or type(backend.show) ~= "function"
        or type(backend.update) ~= "function"
        or type(backend.hide) ~= "function" then
        return nil
    end
    return backend
end

function PalDialoguePresenter:_view(session_id)
    local controller_view = self.controller:session_view(session_id)
    if type(controller_view) ~= "table"
        or controller_view.ok ~= true
        or type(controller_view.session) ~= "table" then
        return nil,
            type(controller_view) == "table"
                and controller_view.reason
                or "pal-dialogue-session-view-failed"
    end
    local session = controller_view.session
    local node = session.node
    local choices = {}
    if type(node) == "table" then
        for _, choice in ipairs(node.choices or {}) do
            choices[#choices + 1] = {
                choiceId = choice.choiceId,
                textKey = choice.textKey,
            }
        end
    end
    local agent = controller_view.agent
    local agent_response =
        type(agent) == "table" and agent.response or nil
    return {
        schemaVersion = API_VERSION,
        sessionId = session.sessionId,
        representativeId = session.representativeId,
        representativeNameKey = session.representativeNameKey,
        factionId = session.factionId,
        state = session.state,
        nodeId = type(node) == "table" and node.nodeId or nil,
        speakerRole =
            type(node) == "table" and node.speakerRole or nil,
        textKey = type(node) == "table" and node.textKey or nil,
        choices = choices,
        agent = type(agent) == "table" and {
            requestId = agent.requestId,
            state = agent.state,
            dialogue = type(agent_response) == "table"
                    and agent_response.dialogue
                or nil,
            proposedChoice = type(agent_response) == "table"
                    and agent_response.proposedChoice
                or nil,
            requiresPlayerConfirmation =
                type(agent_response) == "table"
                and agent_response.proposedChoice ~= nil,
        } or nil,
        actions = {
            chooseAuthored = session.state == "active"
                and #choices > 0,
            submitAgentText = session.state == "active",
            confirmAgentProposal = session.state == "active"
                and type(agent_response) == "table"
                and agent_response.proposedChoice ~= nil,
            abort = session.state == "active",
        },
        deterministicRuleEngineOwnsOutcome = true,
        stateMutationApplied = false,
        storyContentIncluded = false,
    }, nil
end

function PalDialoguePresenter:_record(presentation_id)
    if not non_empty_string(presentation_id, 256) then
        return nil, "pal-dialogue-presentation-id-invalid"
    end
    local record = self.presentations[presentation_id]
    if record == nil then
        return nil, "unknown-pal-dialogue-presentation"
    end
    return record, nil
end

function PalDialoguePresenter:_sync(record, first_show)
    local view, view_error = self:_view(record.sessionId)
    if view == nil then
        return result(false, view_error, {
            presentationId = record.presentationId,
            stateMutationApplied = false,
        })
    end
    view.presentationId = record.presentationId
    record.lastView = copy(view)
    record.state = view.state == "active"
            and "active"
        or "resolved"
    local backend = self:_backend()
    if backend == nil then
        self.backendFailureCount = self.backendFailureCount + 1
        return result(
            false,
            "dialogue-presenter-backend-unavailable",
            {
                presentationId = record.presentationId,
                view = copy(view),
                presentationReady = true,
                stateMutationApplied = false,
            }
        )
    end
    local method_name = first_show and "show" or "update"
    local shown, backend_error = call_backend(
        backend,
        method_name,
        view
    )
    if not shown then
        self.backendFailureCount = self.backendFailureCount + 1
        return result(false, backend_error, {
            presentationId = record.presentationId,
            view = copy(view),
            presentationReady = true,
            stateMutationApplied = false,
        })
    end
    if first_show then
        self.openCount = self.openCount + 1
    else
        self.updateCount = self.updateCount + 1
    end
    if view.state ~= "active" then
        call_backend(backend, "hide", {
            presentationId = record.presentationId,
            sessionId = record.sessionId,
            reason = "pal-dialogue-session-resolved",
        })
        self.closeCount = self.closeCount + 1
    end
    return result(true,
        first_show
            and "pal-dialogue-presentation-opened"
            or "pal-dialogue-presentation-updated",
        {
            presentationId = record.presentationId,
            view = copy(view),
            stateMutationApplied = false,
        }
    )
end

function PalDialoguePresenter:open(session_id)
    if not self.enabled then
        return result(false, "pal-dialogue-presenter-router-disabled")
    end
    if not non_empty_string(session_id, 256) then
        return result(false, "pal-dialogue-session-id-invalid")
    end
    local existing_id = self.presentationBySession[session_id]
    if existing_id ~= nil then
        local existing = self.presentations[existing_id]
        if existing ~= nil and existing.state == "active" then
            return self:_sync(existing, false)
        end
    end
    local view, view_error = self:_view(session_id)
    if view == nil then
        return result(false, view_error)
    end
    if view.state ~= "active" then
        return result(false, "pal-dialogue-session-not-active")
    end
    self.nextPresentationOrdinal =
        self.nextPresentationOrdinal + 1
    local presentation_id = string.format(
        "pal-dialogue-presentation:%08d",
        self.nextPresentationOrdinal
    )
    local record = {
        presentationId = presentation_id,
        sessionId = session_id,
        state = "active",
        lastView = nil,
    }
    self.presentations[presentation_id] = record
    self.presentationBySession[session_id] = presentation_id
    return self:_sync(record, true)
end

function PalDialoguePresenter:refresh(presentation_id)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    return self:_sync(record, false)
end

function PalDialoguePresenter:choose_authored(
    presentation_id,
    choice_id,
    action_id
)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state ~= "active" then
        return result(false, "pal-dialogue-presentation-not-active")
    end
    local selected = self.controller:choose_authored(
        record.sessionId,
        choice_id,
        action_id
    )
    if not selected.ok then
        return result(false, "pal-dialogue-authored-choice-failed", {
            choiceResult = copy(selected),
        })
    end
    local synced = self:_sync(record, false)
    return result(synced.ok == true,
        synced.ok
            and "pal-dialogue-authored-choice-routed"
            or synced.reason,
        {
            presentationId = presentation_id,
            choiceResult = copy(selected),
            view = copy(synced.view),
            stateMutationAppliedBy =
                "deterministic-pal-discourse-runtime",
        }
    )
end

function PalDialoguePresenter:submit_agent_turn(
    presentation_id,
    player_text,
    context
)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state ~= "active" then
        return result(false, "pal-dialogue-presentation-not-active")
    end
    local submitted = self.controller:submit_agent_turn(
        record.sessionId,
        player_text,
        context
    )
    self:_sync(record, false)
    return copy(submitted)
end

function PalDialoguePresenter:poll_agent_turn(
    presentation_id,
    request_id
)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state ~= "active" then
        return result(false, "pal-dialogue-presentation-not-active")
    end
    local polled = self.controller:poll_agent_turn(request_id)
    self:_sync(record, false)
    return copy(polled)
end

function PalDialoguePresenter:confirm_agent_proposal(
    presentation_id,
    request_id,
    action_id
)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state ~= "active" then
        return result(false, "pal-dialogue-presentation-not-active")
    end
    local confirmed = self.controller:confirm_agent_proposal(
        request_id,
        action_id
    )
    if not confirmed.ok then
        return copy(confirmed)
    end
    local synced = self:_sync(record, false)
    confirmed.presentationId = presentation_id
    confirmed.view = copy(synced.view)
    return copy(confirmed)
end

function PalDialoguePresenter:player_abort(
    presentation_id,
    abort_id
)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state ~= "active" then
        return result(false, "pal-dialogue-presentation-not-active")
    end
    local aborted = self.controller:player_abort(
        record.sessionId,
        abort_id
    )
    if not aborted.ok then
        return copy(aborted)
    end
    local synced = self:_sync(record, false)
    aborted.presentationId = presentation_id
    aborted.view = copy(synced.view)
    return copy(aborted)
end

function PalDialoguePresenter:technical_failure(
    presentation_id,
    failure_id,
    technical_reason
)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state ~= "active" then
        return result(false, "pal-dialogue-presentation-not-active")
    end
    local failed = self.controller:technical_failure(
        record.sessionId,
        failure_id,
        technical_reason
    )
    if not failed.ok then
        return copy(failed)
    end
    local synced = self:_sync(record, false)
    failed.presentationId = presentation_id
    failed.view = copy(synced.view)
    return copy(failed)
end

function PalDialoguePresenter:hide_without_abort(presentation_id)
    local record, record_error = self:_record(presentation_id)
    if record == nil then
        return result(false, record_error)
    end
    if record.state == "active" then
        return result(
            false,
            "explicit-player-abort-required-active-token-would-be-consumed"
        )
    end
    local backend = self:_backend()
    if backend ~= nil then
        call_backend(backend, "hide", {
            presentationId = presentation_id,
            sessionId = record.sessionId,
            reason = "resolved-presentation-dismissed",
        })
    end
    return result(true, "resolved-pal-dialogue-presentation-hidden")
end

function PalDialoguePresenter:presentation_status(presentation_id)
    local record = self.presentations[presentation_id]
    return record and copy(record) or nil
end

function PalDialoguePresenter:status()
    local active_count = 0
    for _, record in pairs(self.presentations) do
        if record.state == "active" then
            active_count = active_count + 1
        end
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        backendAvailable = self:_backend() ~= nil,
        nativePresenterEnabled = self.nativePresenterEnabled,
        presentationCount = self.nextPresentationOrdinal,
        activePresentationCount = active_count,
        openCount = self.openCount,
        updateCount = self.updateCount,
        closeCount = self.closeCount,
        backendFailureCount = self.backendFailureCount,
        localizationKeyPresentation = true,
        generatedDialoguePresentation = true,
        explicitAbortRequired = true,
        deterministicRuleEngineOwnsOutcome = true,
        directPresenterStateMutation = false,
        storyContentIncluded = false,
    }
end

return PalDialoguePresenter
