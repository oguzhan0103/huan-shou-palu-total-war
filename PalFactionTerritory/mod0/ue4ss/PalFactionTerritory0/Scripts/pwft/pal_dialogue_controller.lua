local PalDialogueController = {}

local API_VERSION = "1.0.0"
local BRIDGE_SCHEMA_VERSION = "1.0.0"

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

local function safe_id(value)
    return non_empty_string(value, 128)
        and value:match("^[A-Za-z0-9._-]+$") ~= nil
end

local function safe_key(value)
    return non_empty_string(value, 256)
        and value:match("^[A-Za-z0-9._:/-]+$") ~= nil
end

local function default_now_utc()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function default_request_run_id()
    local address = tostring({}):match("0x(%x+)") or "lua"
    return string.format("%08x-%s", os.time(), address)
end

local function default_bridge_resolver()
    return rawget(_G, "PAL_AGENT_DIALOGUE_BRIDGE_V1")
end

local function node_key(session_id, node_id)
    return tostring(session_id) .. "\n" .. tostring(node_id)
end

local function append_unique(values, seen, value, maximum)
    if value == nil or seen[value] or #values >= maximum then
        return
    end
    seen[value] = true
    values[#values + 1] = value
end

local bridge_response_fields = {
    ok = true,
    reason = true,
    requestId = true,
    dialogue = true,
    proposedChoice = true,
    resultTags = true,
}

function PalDialogueController.create(discourse, configuration, options)
    assert(type(discourse) == "table", "Pal discourse runtime is required")
    assert(type(discourse.session_status) == "function", "Pal discourse session status API is required")
    assert(type(discourse.choose) == "function", "Pal discourse choice API is required")
    assert(type(discourse.player_abort) == "function", "Pal discourse abort API is required")
    assert(type(discourse.technical_failure) == "function", "Pal discourse technical-failure API is required")
    assert(type(configuration) == "table", "Pal dialogue controller configuration is required")
    assert(configuration.offlineDialogueTreeEnabled == true, "offline Pal dialogue fallback must remain enabled")
    assert(type(configuration.agentAdapterEnabled) == "boolean", "Pal Agent adapter flag is required")
    options = options or {}
    assert(options.resolveAgentBridge == nil or type(options.resolveAgentBridge) == "function", "Agent bridge resolver must be a function")
    assert(options.nowUtc == nil or type(options.nowUtc) == "function", "UTC clock must be a function")
    assert(options.requestRunId == nil or safe_id(options.requestRunId), "Agent request run ID must be safe")
    return setmetatable({
        version = API_VERSION,
        discourse = discourse,
        enabled = configuration.agentAdapterEnabled,
        nativePresenterEnabled =
            configuration.nativeDialoguePresenterEnabled == true,
        defaultLocale = configuration.agentDefaultLocale or "zh-CN",
        resolveAgentBridge = options.resolveAgentBridge or default_bridge_resolver,
        nowUtc = options.nowUtc or default_now_utc,
        nextRequestOrdinal = 0,
        requestRunId = options.requestRunId or default_request_run_id(),
        requests = {},
        activeByNode = {},
        submittedCount = 0,
        validatedCount = 0,
        committedCount = 0,
        fallbackCount = 0,
        capabilities = {
            optionalAgentDialogue = true,
            offlineTreeFallback = true,
            generatedDialoguePresentation = true,
            proposalRequiresPlayerConfirmation = true,
            deterministicRuleEngineOwnsOutcome = true,
            directAgentStateMutation = false,
            PalworldSaveMutation = false,
            nativePresenter =
                configuration.nativeDialoguePresenterEnabled == true,
            authoredStoryContent = false,
        },
    }, { __index = PalDialogueController })
end

function PalDialogueController:_session(session_id)
    if not non_empty_string(session_id, 256) then
        return nil, "pal-dialogue-session-id-invalid"
    end
    local session = self.discourse:session_status(session_id)
    if session == nil then
        return nil, "unknown-pal-discourse-session"
    end
    if session.state ~= "active" or type(session.node) ~= "table" then
        return nil, "pal-discourse-session-not-active"
    end
    return session
end

function PalDialogueController:_bridge()
    local resolved, bridge = pcall(self.resolveAgentBridge)
    if not resolved
        or type(bridge) ~= "table"
        or bridge.ready == false
        or type(bridge.submit_request) ~= "function"
        or type(bridge.poll_response) ~= "function"
    then
        return nil
    end
    return bridge
end

function PalDialogueController:_fallback(reason, session, extra)
    self.fallbackCount = self.fallbackCount + 1
    local value = extra or {}
    value.offlineFallbackReady = session ~= nil and session.node ~= nil
    value.node = session and copy(session.node) or nil
    value.stateMutationApplied = false
    return result(false, reason, value)
end

function PalDialogueController:_make_request(session, player_text, context)
    local representative_id = session.representativeId
    if not safe_id(representative_id) then
        return nil, "agent-character-id-invalid"
    end
    if not non_empty_string(player_text, 24000) then
        return nil, "agent-player-text-invalid"
    end
    if type(context) ~= "table"
        or not non_empty_string(context.worldKey, 256)
        or not non_empty_string(context.playerKey, 256)
        or not non_empty_string(context.locale or self.defaultLocale, 32)
    then
        return nil, "agent-player-context-invalid"
    end

    local allowed_choices = {}
    local allowed_choice_ids = {}
    for index, choice in ipairs(session.node.choices or {}) do
        if index > 32 or not safe_id(choice.choiceId) or not safe_key(choice.textKey) then
            return nil, "agent-authored-choices-invalid"
        end
        allowed_choices[index] = {
            choiceId = choice.choiceId,
            textKey = choice.textKey,
        }
        allowed_choice_ids[index] = choice.choiceId
    end

    local context_keys = {}
    local seen_context = {}
    if safe_key(session.node.textKey) then
        append_unique(context_keys, seen_context, session.node.textKey, 64)
    end
    if safe_key(session.factionId) then
        append_unique(context_keys, seen_context, session.factionId, 64)
    end
    for _, value in ipairs(context.contextKeys or {}) do
        if not safe_key(value) then
            return nil, "agent-context-keys-invalid"
        end
        append_unique(context_keys, seen_context, value, 64)
    end

    self.nextRequestOrdinal = self.nextRequestOrdinal + 1
    local ordinal = self.nextRequestOrdinal
    local request_id = string.format(
        "pwft-agent-%s-%08d",
        self.requestRunId,
        ordinal
    )
    local external_session_id = string.format(
        "pwft-session-%s-%08d",
        self.requestRunId,
        ordinal
    )
    return {
        payload = {
            schemaVersion = BRIDGE_SCHEMA_VERSION,
            requestId = request_id,
            createdAt = self.nowUtc(),
            characterId = representative_id,
            sessionId = external_session_id,
            worldKey = context.worldKey,
            playerKey = context.playerKey,
            locale = context.locale or self.defaultLocale,
            playerText = player_text,
            contextKeys = context_keys,
            allowedChoices = allowed_choices,
            allowedResultTags = {},
        },
        record = {
            requestId = request_id,
            sessionId = session.sessionId,
            nodeId = session.node.nodeId,
            characterId = representative_id,
            allowedChoiceIds = allowed_choice_ids,
            allowedResultTags = {},
            state = "pending",
            response = nil,
        },
    }
end

function PalDialogueController:_validate_bridge_response(record, response)
    for key, _ in pairs(response) do
        if not bridge_response_fields[key] then
            return false, "response-fields-not-allowed"
        end
    end
    if response.requestId ~= nil and response.requestId ~= record.requestId then
        return false, "response-request-id-mismatch"
    end
    if not non_empty_string(response.dialogue, 16000)
        or type(response.resultTags) ~= "table"
    then
        return false, "response-contract-invalid"
    end
    local allowed_choices = {}
    for _, choice_id in ipairs(record.allowedChoiceIds) do
        allowed_choices[choice_id] = true
    end
    if response.proposedChoice ~= nil
        and (not safe_id(response.proposedChoice)
            or not allowed_choices[response.proposedChoice])
    then
        return false, "response-choice-not-authorized"
    end
    local allowed_tags = {}
    for _, tag in ipairs(record.allowedResultTags) do
        allowed_tags[tag] = true
    end
    local seen_tags = {}
    for index, tag in ipairs(response.resultTags) do
        if index > 64
            or not safe_key(tag)
            or not allowed_tags[tag]
            or seen_tags[tag]
        then
            return false, "response-tag-not-authorized"
        end
        seen_tags[tag] = true
    end
    return true
end

function PalDialogueController:submit_agent_turn(session_id, player_text, context)
    local session, session_error = self:_session(session_id)
    if session == nil then
        return self:_fallback(session_error, nil)
    end
    if not self.enabled then
        return self:_fallback("agent-adapter-disabled-offline-fallback", session)
    end
    local bridge = self:_bridge()
    if bridge == nil then
        return self:_fallback("agent-bridge-unavailable-offline-fallback", session)
    end
    local key = node_key(session.sessionId, session.node.nodeId)
    local existing_id = self.activeByNode[key]
    if existing_id ~= nil then
        local existing = self.requests[existing_id]
        return result(true, "agent-request-already-submitted", {
            requestId = existing_id,
            requestState = existing and existing.state or "unknown",
            node = copy(session.node),
            stateMutationApplied = false,
        })
    end
    local built, build_error = self:_make_request(session, player_text, context)
    if built == nil then
        return self:_fallback(build_error, session)
    end
    local called, submitted = pcall(function()
        return bridge:submit_request(built.payload)
    end)
    if not called or type(submitted) ~= "table" or submitted.ok ~= true then
        return self:_fallback("agent-request-submit-failed-offline-fallback", session, {
            detail = called and submitted and submitted.reason or "bridge-call-failed",
        })
    end
    self.requests[built.record.requestId] = built.record
    self.activeByNode[key] = built.record.requestId
    self.submittedCount = self.submittedCount + 1
    return result(true, "agent-request-submitted", {
        requestId = built.record.requestId,
        requestState = "pending",
        node = copy(session.node),
        stateMutationApplied = false,
    })
end

function PalDialogueController:poll_agent_turn(request_id)
    local record = self.requests[request_id]
    if record == nil then
        return result(false, "unknown-agent-dialogue-request", { stateMutationApplied = false })
    end
    if record.state == "ready" then
        return result(true, "agent-response-already-validated", {
            requestId = request_id,
            response = copy(record.response),
            requiresPlayerConfirmation = record.response.proposedChoice ~= nil,
            stateMutationApplied = false,
        })
    end
    if record.state ~= "pending" then
        return result(false, "agent-dialogue-request-not-pending", {
            requestId = request_id,
            requestState = record.state,
            stateMutationApplied = false,
        })
    end
    local session, session_error = self:_session(record.sessionId)
    if session == nil or session.node.nodeId ~= record.nodeId then
        record.state = "stale"
        self.activeByNode[node_key(record.sessionId, record.nodeId)] = nil
        return self:_fallback(session_error or "agent-dialogue-node-stale", session, {
            requestId = request_id,
        })
    end
    local bridge = self:_bridge()
    if bridge == nil then
        return self:_fallback("agent-bridge-unavailable-offline-fallback", session, {
            requestId = request_id,
        })
    end
    local called, response = pcall(function()
        return bridge:poll_response({
            requestId = record.requestId,
            characterId = record.characterId,
            allowedChoiceIds = copy(record.allowedChoiceIds),
            allowedResultTags = copy(record.allowedResultTags),
        })
    end)
    if not called or type(response) ~= "table" then
        return self:_fallback("agent-response-read-failed-offline-fallback", session, {
            requestId = request_id,
        })
    end
    if response.ok ~= true then
        if response.reason == "response-pending" then
            return result(false, "agent-response-pending", {
                requestId = request_id,
                node = copy(session.node),
                offlineFallbackReady = true,
                stateMutationApplied = false,
            })
        end
        record.state = "rejected"
        self.activeByNode[node_key(record.sessionId, record.nodeId)] = nil
        return self:_fallback("agent-response-rejected-offline-fallback", session, {
            requestId = request_id,
            detail = response.reason,
        })
    end
    local valid, validation_error =
        self:_validate_bridge_response(record, response)
    if not valid then
        record.state = "rejected"
        self.activeByNode[node_key(record.sessionId, record.nodeId)] = nil
        return self:_fallback("agent-response-rejected-offline-fallback", session, {
            requestId = request_id,
            detail = validation_error,
        })
    end
    record.state = "ready"
    record.response = {
        dialogue = response.dialogue,
        proposedChoice = response.proposedChoice,
        resultTags = copy(response.resultTags or {}),
    }
    self.validatedCount = self.validatedCount + 1
    return result(true, "agent-response-ready", {
        requestId = request_id,
        response = copy(record.response),
        node = copy(session.node),
        requiresPlayerConfirmation = response.proposedChoice ~= nil,
        stateMutationApplied = false,
    })
end

function PalDialogueController:confirm_agent_proposal(request_id, action_id)
    local record = self.requests[request_id]
    if record == nil then
        return result(false, "unknown-agent-dialogue-request")
    end
    if record.state == "committed" then
        return result(true, "agent-proposal-already-committed", copy(record.commitResult))
    end
    if record.state ~= "ready" then
        return result(false, "agent-proposal-not-ready", { requestState = record.state })
    end
    if record.response.proposedChoice == nil then
        return result(false, "agent-response-has-no-proposed-choice")
    end
    if not non_empty_string(action_id, 256) then
        return result(false, "agent-proposal-action-id-invalid")
    end
    local session, session_error = self:_session(record.sessionId)
    if session == nil or session.node.nodeId ~= record.nodeId then
        record.state = "stale"
        self.activeByNode[node_key(record.sessionId, record.nodeId)] = nil
        return result(false, session_error or "agent-dialogue-node-stale")
    end
    local selected = self.discourse:choose(
        record.sessionId,
        record.response.proposedChoice,
        action_id
    )
    if not selected.ok then
        return result(false, "agent-proposal-deterministic-choice-failed", {
            choiceResult = copy(selected),
        })
    end
    record.state = "committed"
    record.commitResult = copy(selected)
    self.activeByNode[node_key(record.sessionId, record.nodeId)] = nil
    self.committedCount = self.committedCount + 1
    return result(true, "agent-proposal-committed-by-player", {
        requestId = request_id,
        choiceId = record.response.proposedChoice,
        choiceResult = copy(selected),
        stateMutationAppliedBy = "deterministic-pal-discourse-runtime-after-player-confirmation",
    })
end

function PalDialogueController:choose_authored(session_id, choice_id, action_id)
    local session, session_error = self:_session(session_id)
    if session == nil then
        return result(false, session_error)
    end
    local previous_node_id = session.node.nodeId
    local selected = self.discourse:choose(session_id, choice_id, action_id)
    if selected.ok then
        local key = node_key(session_id, previous_node_id)
        local request_id = self.activeByNode[key]
        if request_id ~= nil and self.requests[request_id] ~= nil then
            self.requests[request_id].state = "stale"
        end
        self.activeByNode[key] = nil
    end
    return selected
end

function PalDialogueController:player_abort(session_id, abort_id)
    local session, session_error = self:_session(session_id)
    if session == nil then
        return result(false, session_error)
    end
    local previous_node_id = session.node.nodeId
    local aborted = self.discourse:player_abort(session_id, abort_id)
    if aborted.ok then
        local key = node_key(session_id, previous_node_id)
        local request_id = self.activeByNode[key]
        if request_id ~= nil and self.requests[request_id] ~= nil then
            self.requests[request_id].state = "stale"
        end
        self.activeByNode[key] = nil
    end
    return aborted
end

function PalDialogueController:technical_failure(
    session_id,
    failure_id,
    technical_reason
)
    local session, session_error = self:_session(session_id)
    if session == nil then
        return result(false, session_error)
    end
    local previous_node_id = session.node.nodeId
    local failed = self.discourse:technical_failure(
        session_id,
        failure_id,
        technical_reason
    )
    if failed.ok then
        local key = node_key(session_id, previous_node_id)
        local request_id = self.activeByNode[key]
        if request_id ~= nil and self.requests[request_id] ~= nil then
            self.requests[request_id].state = "stale"
        end
        self.activeByNode[key] = nil
    end
    return failed
end

function PalDialogueController:session_view(session_id)
    local session = self.discourse:session_status(session_id)
    if session == nil then
        return result(false, "unknown-pal-discourse-session")
    end
    local agent = nil
    if session.state == "active" and session.node ~= nil then
        local request_id = self.activeByNode[node_key(session_id, session.node.nodeId)]
        local record = request_id and self.requests[request_id]
        if record ~= nil then
            agent = {
                requestId = record.requestId,
                state = record.state,
                response = copy(record.response),
            }
        end
    end
    return result(true, "pal-dialogue-session-view-ready", {
        session = copy(session),
        agent = agent,
    })
end

function PalDialogueController:status()
    local pending = 0
    local ready = 0
    for _, request in pairs(self.requests) do
        if request.state == "pending" then
            pending = pending + 1
        elseif request.state == "ready" then
            ready = ready + 1
        end
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        bridgeAvailable = self:_bridge() ~= nil,
        submittedCount = self.submittedCount,
        pendingCount = pending,
        readyCount = ready,
        validatedCount = self.validatedCount,
        committedCount = self.committedCount,
        fallbackCount = self.fallbackCount,
        offlineTreeFallback = true,
        proposalRequiresPlayerConfirmation = true,
        deterministicRuleEngineOwnsOutcome = true,
        directAgentStateMutation = false,
        nativePresenterEnabled = self.nativePresenterEnabled,
        storyContentIncluded = false,
    }
end

return PalDialogueController
