local Json = require("pwft.json")

local AgentDialogueOperator = {}
local Operator = {}
Operator.__index = Operator

local SCHEMA_VERSION = "1.0.0"
local MAX_COMMAND_BYTES = 64 * 1024
local MAX_PLAYER_TEXT_CHARACTERS = 8000

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

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

local function safe_id(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 128
        and value:match("^[A-Za-z0-9._:-]+$") ~= nil
end

local function utf8_length(value)
    if type(value) ~= "string" then
        return nil
    end
    if type(utf8) == "table" and type(utf8.len) == "function" then
        local ok, length = pcall(utf8.len, value)
        return ok and length or nil
    end
    local index = 1
    local length = 0
    while index <= #value do
        local first = value:byte(index)
        local width = first <= 0x7f and 1
            or (first >= 0xc2 and first <= 0xdf and 2)
            or (first >= 0xe0 and first <= 0xef and 3)
            or (first >= 0xf0 and first <= 0xf4 and 4)
            or nil
        if width == nil or index + width - 1 > #value then
            return nil
        end
        for offset = 1, width - 1 do
            local continuation = value:byte(index + offset)
            if continuation < 0x80 or continuation > 0xbf then
                return nil
            end
        end
        index = index + width
        length = length + 1
    end
    return length
end

local function default_filesystem()
    return {
        read_limited = function(path, maximum)
            local handle = io.open(path, "rb")
            if handle == nil then
                return nil, "not-found"
            end
            local size = handle:seek("end")
            if size ~= nil and size > maximum then
                handle:close()
                return nil, "too-large"
            end
            handle:seek("set", 0)
            local content = handle:read(maximum + 1)
            handle:close()
            if content ~= nil and #content > maximum then
                return nil, "too-large"
            end
            return content or "", nil
        end,
        write_atomic = function(path, content)
            local temporary = string.format(
                "%s.tmp-%d-%06d",
                path,
                os.time(),
                math.random(0, 999999)
            )
            local handle, open_error = io.open(temporary, "wb")
            if handle == nil then
                return false, open_error
            end
            local written, write_error = handle:write(content)
            local flushed, flush_error = handle:flush()
            handle:close()
            if not written or not flushed then
                os.remove(temporary)
                return false, write_error or flush_error
            end
            local renamed, rename_error = os.rename(temporary, path)
            if not renamed then
                -- Lua's os.rename cannot replace an existing file on Windows.
                -- The status file is refreshed continuously, so remove the
                -- previous complete snapshot and retry the final rename.
                os.remove(path)
                renamed, rename_error = os.rename(temporary, path)
            end
            if not renamed then
                os.remove(temporary)
                return false, rename_error
            end
            return true, nil
        end,
        remove = function(path)
            return os.remove(path)
        end,
    }
end

function AgentDialogueOperator.create(
    presenter,
    native_router,
    configuration,
    options
)
    assert(type(presenter) == "table"
        and type(presenter.submit_agent_turn) == "function"
        and type(presenter.poll_agent_turn) == "function",
        "Agent dialogue presenter is required")
    assert(type(native_router) == "table"
        and type(native_router.status) == "function",
        "native representative router is required")
    assert(type(configuration) == "table", "Agent operator configuration is required")
    assert(configuration.enabled == true, "Agent operator must be enabled")
    assert(type(configuration.operatorInputPath) == "string"
        and configuration.operatorInputPath ~= "",
        "Agent operator input path is required")
    assert(type(configuration.operatorStatusPath) == "string"
        and configuration.operatorStatusPath ~= "",
        "Agent operator status path is required")
    assert(type(configuration.operatorCommandTtlSeconds) == "number"
        and configuration.operatorCommandTtlSeconds >= 10
        and configuration.operatorCommandTtlSeconds <= 3600,
        "Agent operator command TTL must be 10..3600 seconds")
    options = options or {}
    assert(type(options.identityResolver) == "function",
        "Agent operator identity resolver is required")
    local filesystem = options.filesystem or default_filesystem()
    return setmetatable({
        version = SCHEMA_VERSION,
        enabled = true,
        presenter = presenter,
        nativeRouter = native_router,
        inputPath = configuration.operatorInputPath,
        statusPath = configuration.operatorStatusPath,
        commandTtlSeconds = configuration.operatorCommandTtlSeconds,
        identityResolver = options.identityResolver,
        filesystem = filesystem,
        nowEpoch = options.nowEpoch or os.time,
        generation = 0,
        pending = nil,
        lastCommandId = nil,
        lastCommandReadError = nil,
        observedPresentationId = nil,
        lastReason = "waiting-for-active-dialogue",
        lastError = nil,
        submissionCount = 0,
        readyCount = 0,
        rejectedCount = 0,
        worldReady = false,
    }, Operator)
end

function Operator:_active_presentation()
    if not self.worldReady then
        return nil, nil
    end
    local router_status = self.nativeRouter:status()
    local presentation_id = router_status.activePresentationId
    if type(presentation_id) ~= "string" or presentation_id == "" then
        return nil, nil
    end
    local record = self.presenter:presentation_status(presentation_id)
    if type(record) ~= "table" or record.state ~= "active" then
        return nil, nil
    end
    return presentation_id, record
end

function Operator:_public_status()
    local presentation_id, record = self:_active_presentation()
    local identity = self.identityResolver()
    return {
        schemaVersion = SCHEMA_VERSION,
        updatedAtEpoch = self.nowEpoch(),
        ready = self.enabled,
        reason = self.lastReason,
        error = self.lastError,
        generation = self.generation,
        activePresentationId = presentation_id or Json.null,
        activeSessionId = record and record.sessionId or Json.null,
        identityReady = type(identity) == "table"
            and type(identity.profileKey) == "string",
        canSubmit = presentation_id ~= nil
            and self.pending == nil
            and type(identity) == "table"
            and type(identity.profileKey) == "string",
        requestId = self.pending and self.pending.requestId or Json.null,
        requestState = self.pending and self.pending.state or "idle",
        lastCommandId = self.lastCommandId or Json.null,
        submissionCount = self.submissionCount,
        readyCount = self.readyCount,
        rejectedCount = self.rejectedCount,
        directStateMutation = false,
        proposalRequiresPlayerConfirmation = true,
        worldReady = self.worldReady,
    }
end

function Operator:publish_status(reason)
    if reason ~= nil then
        self.lastReason = reason
    end
    local encoded_ok, encoded = pcall(Json.encode, self:_public_status())
    if not encoded_ok then
        self.lastError = "operator-status-json-failed"
        return false, self.lastError
    end
    local called, written, write_error = pcall(
        self.filesystem.write_atomic,
        self.statusPath,
        encoded
    )
    if not called or not written then
        self.lastError = "operator-status-write-failed:" .. tostring(write_error)
        return false, self.lastError
    end
    return true, nil
end

function Operator:submit_text(player_text, command_id, presentation_id)
    local text_length = utf8_length(player_text)
    if text_length == nil or text_length < 1
        or text_length > MAX_PLAYER_TEXT_CHARACTERS then
        return result(false, "operator-player-text-invalid")
    end
    if command_id ~= nil and not safe_id(command_id) then
        return result(false, "operator-command-id-invalid")
    end
    if self.pending ~= nil then
        return result(false, "agent-request-already-pending", {
            requestId = self.pending.requestId,
        })
    end
    local active_id = self:_active_presentation()
    if active_id == nil then
        return result(false, "no-active-pal-dialogue-presentation")
    end
    if presentation_id ~= nil and presentation_id ~= active_id then
        return result(false, "operator-presentation-stale")
    end
    local identity = self.identityResolver()
    if type(identity) ~= "table"
        or type(identity.profileKey) ~= "string" then
        return result(false, "operator-world-player-identity-not-ready")
    end
    local submitted = self.presenter:submit_agent_turn(
        active_id,
        player_text,
        {
            worldKey = identity.worldDirectory or identity.profileKey,
            playerKey = identity.playerUid or identity.profileKey,
            locale = "zh-CN",
            contextKeys = {},
        }
    )
    if not submitted.ok then
        self.lastError = submitted.reason
        self.lastReason = "agent-submit-failed"
        self:publish_status()
        return copy(submitted)
    end
    self.pending = {
        requestId = submitted.requestId,
        presentationId = active_id,
        state = "pending",
        generation = self.generation,
    }
    self.submissionCount = self.submissionCount + 1
    self.lastCommandId = command_id or self.lastCommandId
    self.lastError = nil
    self:publish_status("agent-request-submitted")
    return result(true, "agent-request-submitted", {
        requestId = submitted.requestId,
        presentationId = active_id,
        stateMutationApplied = false,
    })
end

function Operator:_read_command()
    local called, encoded, read_error = pcall(
        self.filesystem.read_limited,
        self.inputPath,
        MAX_COMMAND_BYTES
    )
    if not called then
        return nil, "operator-command-read-failed"
    end
    if encoded == nil then
        return nil, read_error
    end
    local decoded_ok, command = pcall(Json.decode, encoded)
    if not decoded_ok or type(command) ~= "table" then
        return nil, "operator-command-json-invalid"
    end
    local allowed = {
        schemaVersion = true,
        commandId = true,
        createdAtEpoch = true,
        action = true,
        presentationId = true,
        playerText = true,
    }
    for key in pairs(command) do
        if allowed[key] ~= true then
            return nil, "operator-command-field-not-allowed"
        end
    end
    if command.schemaVersion ~= SCHEMA_VERSION
        or not safe_id(command.commandId)
        or type(command.createdAtEpoch) ~= "number"
        or command.action ~= "submit-agent-text"
        or (command.presentationId ~= nil
            and command.presentationId ~= Json.null
            and type(command.presentationId) ~= "string") then
        return nil, "operator-command-contract-invalid"
    end
    local age = self.nowEpoch() - command.createdAtEpoch
    if age < -30 or age > self.commandTtlSeconds then
        return nil, "operator-command-expired"
    end
    return command, nil
end

function Operator:tick()
    if not self.worldReady then
        return result(true, "operator-world-not-ready")
    end
    local active_presentation_id = self:_active_presentation()
    if active_presentation_id ~= self.observedPresentationId then
        self.observedPresentationId = active_presentation_id
        self:publish_status(
            active_presentation_id ~= nil
                and "waiting-for-agent-text"
                or "waiting-for-active-dialogue"
        )
    end
    local command, command_error = self:_read_command()
    if command ~= nil and command.commandId ~= self.lastCommandId then
        if type(self.filesystem.remove) == "function" then
            pcall(self.filesystem.remove, self.inputPath)
        end
        self.lastCommandReadError = nil
        local presentation_id = command.presentationId
        if presentation_id == Json.null then
            presentation_id = nil
        end
        self.lastCommandId = command.commandId
        local submitted = self:submit_text(
            command.playerText,
            command.commandId,
            presentation_id
        )
        if not submitted.ok then
            self.lastError = submitted.reason
            self.rejectedCount = self.rejectedCount + 1
            self:publish_status("operator-command-rejected")
            return submitted
        end
    elseif command == nil and command_error ~= "not-found"
        and command_error ~= self.lastCommandReadError then
        self.lastCommandReadError = command_error
        self.lastError = command_error
        self.rejectedCount = self.rejectedCount + 1
        self:publish_status("operator-command-rejected")
    end

    if self.pending == nil then
        return result(true, "operator-idle")
    end
    if self.pending.generation ~= self.generation then
        self.pending = nil
        self:publish_status("operator-world-changed")
        return result(false, "operator-request-world-stale")
    end
    local active_id = self:_active_presentation()
    if active_id ~= self.pending.presentationId then
        self.pending = nil
        self:publish_status("operator-presentation-ended")
        return result(false, "operator-presentation-ended")
    end
    local polled = self.presenter:poll_agent_turn(
        self.pending.presentationId,
        self.pending.requestId
    )
    if polled.ok then
        local request_id = self.pending.requestId
        self.pending = nil
        self.readyCount = self.readyCount + 1
        self.lastError = nil
        self:publish_status("agent-response-ready")
        return result(true, "agent-response-ready", {
            requestId = request_id,
            requiresPlayerConfirmation = polled.requiresPlayerConfirmation == true,
            stateMutationApplied = false,
        })
    end
    if polled.reason == "agent-response-pending" then
        self:publish_status("agent-response-pending")
        return copy(polled)
    end
    self.pending = nil
    self.observedPresentationId = nil
    self.rejectedCount = self.rejectedCount + 1
    self.lastError = polled.reason
    self:publish_status("agent-response-rejected-offline-fallback")
    return copy(polled)
end

function Operator:on_world_loaded()
    self.generation = self.generation + 1
    self.worldReady = true
    self.pending = nil
    self.observedPresentationId = nil
    self.lastError = nil
    self:publish_status("waiting-for-active-dialogue")
    return self.generation
end

function Operator:on_world_unloading()
    self.generation = self.generation + 1
    self.worldReady = false
    self.pending = nil
    self:publish_status("world-unloading")
    return self.generation
end

function Operator:status()
    return copy(self:_public_status())
end

return AgentDialogueOperator
