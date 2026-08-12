local json = require("pad.json")

local M = {}
local Bridge = {}
Bridge.__index = Bridge

local SCHEMA_VERSION = "1.0.0"
local MAX_REQUEST_BYTES = 256 * 1024
local MAX_RESPONSE_BYTES = 64 * 1024
local MAX_PLAYER_TEXT_CHARS = 8000
local MAX_DIALOGUE_CHARS = 4000
local DEFAULT_REQUEST_TTL_SECONDS = 600

local function result(ok, reason, payload)
    payload = payload or {}
    payload.ok = ok
    payload.reason = reason
    return payload
end

local function safe_id(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 128
        and value:match("^[A-Za-z0-9._-]+$") ~= nil
end

local function safe_key(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 256
        and value:match("^[A-Za-z0-9._:/-]+$") ~= nil
end

local function utf8_length(value)
    if type(value) ~= "string" then
        return nil
    end
    if type(utf8) == "table" and type(utf8.len) == "function" then
        local ok, length = pcall(utf8.len, value)
        if ok then
            return length
        end
        return nil
    end

    -- UE4SS currently exposes Lua's utf8 library. Keep a strict fallback for
    -- test hosts or future runtimes where it is unavailable.
    local index = 1
    local length = 0
    while index <= #value do
        local first = value:byte(index)
        local width = nil
        if first <= 0x7f then
            width = 1
        elseif first >= 0xc2 and first <= 0xdf then
            width = 2
        elseif first >= 0xe0 and first <= 0xef then
            width = 3
        elseif first >= 0xf0 and first <= 0xf4 then
            width = 4
        else
            return nil
        end
        if index + width - 1 > #value then
            return nil
        end
        for offset = 1, width - 1 do
            local continuation = value:byte(index + offset)
            if continuation < 0x80 or continuation > 0xbf then
                return nil
            end
        end
        local second = width > 1 and value:byte(index + 1) or nil
        if (first == 0xe0 and second < 0xa0)
            or (first == 0xed and second > 0x9f)
            or (first == 0xf0 and second < 0x90)
            or (first == 0xf4 and second > 0x8f)
        then
            return nil
        end
        length = length + 1
        index = index + width
    end
    return length
end

local function bounded_utf8(value, maximum)
    local length = utf8_length(value)
    return length ~= nil and length >= 1 and length <= maximum
end

local function array_length(value, maximum)
    if value == nil then
        return 0
    end
    if type(value) ~= "table" then
        return nil
    end
    local count = 0
    local highest = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil
        end
        count = count + 1
        highest = math.max(highest, key)
    end
    if count ~= highest or count > maximum then
        return nil
    end
    return count
end

local function normalize_root(root)
    if type(root) ~= "string"
        or root == ""
        or root:find("[%z\1-\31]") ~= nil
        or root:match("^%s") ~= nil
        or root:match("%s$") ~= nil
    then
        return nil
    end
    local normalized = root:gsub("\\", "/"):gsub("/+$", "")
    if normalized == ""
        or (normalized:match("^%a:/") == nil
            and normalized:match("^//[^/]+/[^/]+") == nil
            and normalized:match("^/") == nil)
    then
        return nil
    end
    for component in normalized:gmatch("[^/]+") do
        if component == "." or component == ".." then
            return nil
        end
    end
    return normalized
end

local function reject_unknown_fields(value, allowed)
    if type(value) ~= "table" then
        return false
    end
    for key in pairs(value) do
        if not allowed[key] then
            return false
        end
    end
    return true
end

local function array_copy(values)
    local output = json.array()
    for index, value in ipairs(values or {}) do
        output[index] = value
    end
    return output
end

local function file_read(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil, "not-found"
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function file_read_limited(path, maximum)
    local handle = io.open(path, "rb")
    if not handle then
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
    return content or ""
end

local function file_exists(path)
    local handle = io.open(path, "rb")
    if not handle then
        return false
    end
    handle:close()
    return true
end

local temporary_counter = 0

local function file_write_atomic(path, content)
    temporary_counter = temporary_counter + 1
    local bridge_root = path:match("^(.*)/inbox/[^/]+$")
    local file_name = path:match("([^/]+)$") or "request.json"
    local temporary = string.format(
        "%s/.%s.tmp-%d-%d",
        bridge_root or path,
        file_name,
        os.time(),
        temporary_counter
    )
    local handle, open_error = io.open(temporary, "wb")
    if not handle then
        return false, "open-temporary-failed:" .. tostring(open_error)
    end
    local written, write_error = handle:write(content)
    local flushed, flush_error = handle:flush()
    handle:close()
    if not written or not flushed then
        os.remove(temporary)
        return false, "write-temporary-failed:"
            .. tostring(write_error or flush_error)
    end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return false, "atomic-rename-failed:" .. tostring(rename_error)
    end
    return true
end

local default_filesystem = {
    read = file_read,
    read_limited = file_read_limited,
    exists = file_exists,
    write_atomic = file_write_atomic,
}

local function join(root, child)
    local normalized = root:gsub("[\\/]+$", "")
    return normalized .. "/" .. child
end

local request_fields = {
    schemaVersion = true,
    requestId = true,
    createdAt = true,
    characterId = true,
    sessionId = true,
    worldKey = true,
    playerKey = true,
    locale = true,
    playerText = true,
    contextKeys = true,
    allowedChoices = true,
    allowedResultTags = true,
}

local response_fields = {
    schemaVersion = true,
    requestId = true,
    createdAt = true,
    characterId = true,
    provider = true,
    dialogue = true,
    proposedChoice = true,
    resultTags = true,
}

local authorization_fields = {
    requestId = true,
    characterId = true,
    allowedChoiceIds = true,
    allowedResultTags = true,
}

function M.create(configuration)
    assert(type(configuration) == "table", "bridge configuration is required")
    local root = normalize_root(configuration.root)
    assert(root ~= nil, "bridge root must be an absolute traversal-free path")
    local filesystem = configuration.filesystem or default_filesystem
    assert(type(filesystem.read) == "function", "bridge filesystem read is required")
    assert(type(filesystem.write_atomic) == "function", "bridge filesystem atomic write is required")
    local ttl = configuration.requestTtlSeconds or DEFAULT_REQUEST_TTL_SECONDS
    assert(type(ttl) == "number" and ttl >= 1 and ttl <= 3600,
        "bridge request TTL must be between 1 and 3600 seconds")
    assert(configuration.nowEpoch == nil or type(configuration.nowEpoch) == "function",
        "bridge epoch clock must be a function")
    return setmetatable({
        root = root,
        filesystem = filesystem,
        allow_mock_provider = configuration.allowMockProvider == true,
        request_ttl_seconds = ttl,
        now_epoch = configuration.nowEpoch or os.time,
        requests = {},
    }, Bridge)
end

function Bridge:submit_request(request)
    if not reject_unknown_fields(request, request_fields) then
        return result(false, "request-fields-not-allowed")
    end
    if request.schemaVersion ~= SCHEMA_VERSION
        or not safe_id(request.requestId)
        or not safe_id(request.characterId)
        or not safe_id(request.sessionId)
        or type(request.createdAt) ~= "string"
        or not bounded_utf8(request.worldKey, 256)
        or not bounded_utf8(request.playerKey, 256)
        or not bounded_utf8(request.locale, 32)
        or not bounded_utf8(request.playerText, MAX_PLAYER_TEXT_CHARS)
    then
        return result(false, "request-contract-invalid")
    end

    local context_length = array_length(request.contextKeys, 64)
    if context_length == nil then
        return result(false, "context-keys-invalid")
    end
    local seen_context = {}
    local context_keys = json.array()
    for index = 1, context_length do
        local key = request.contextKeys[index]
        if not safe_key(key) or seen_context[key] then
            return result(false, "context-keys-invalid")
        end
        seen_context[key] = true
        context_keys[index] = key
    end

    local choice_length = array_length(request.allowedChoices, 32)
    if choice_length == nil then
        return result(false, "allowed-choices-invalid")
    end
    local seen_choices = {}
    local choices = json.array()
    for index = 1, choice_length do
        local choice = request.allowedChoices[index]
        if not reject_unknown_fields(choice, { choiceId = true, textKey = true })
            or not safe_id(choice.choiceId)
            or not safe_key(choice.textKey)
            or seen_choices[choice.choiceId]
        then
            return result(false, "allowed-choices-invalid")
        end
        seen_choices[choice.choiceId] = true
        choices[index] = { choiceId = choice.choiceId, textKey = choice.textKey }
    end

    local tag_length = array_length(request.allowedResultTags, 64)
    if tag_length == nil then
        return result(false, "allowed-result-tags-invalid")
    end
    local seen_tags = {}
    local tags = json.array()
    for index = 1, tag_length do
        local tag = request.allowedResultTags[index]
        if not safe_key(tag) or seen_tags[tag] then
            return result(false, "allowed-result-tags-invalid")
        end
        seen_tags[tag] = true
        tags[index] = tag
    end

    local payload = {
        schemaVersion = SCHEMA_VERSION,
        requestId = request.requestId,
        createdAt = request.createdAt,
        characterId = request.characterId,
        sessionId = request.sessionId,
        worldKey = request.worldKey,
        playerKey = request.playerKey,
        locale = request.locale,
        playerText = request.playerText,
        contextKeys = context_keys,
        allowedChoices = choices,
        allowedResultTags = tags,
    }
    local path = join(self.root, "inbox/" .. request.requestId .. ".json")
    local exists = self.filesystem.exists
        and self.filesystem.exists(path)
        or self.filesystem.read(path) ~= nil
    if exists then
        return result(false, "request-already-exists")
    end
    local encoded_ok, encoded = pcall(json.encode, payload)
    if not encoded_ok then
        return result(false, "request-json-encode-failed")
    end
    if #encoded > MAX_REQUEST_BYTES then
        return result(false, "request-too-large")
    end
    local written, write_error = self.filesystem.write_atomic(path, encoded)
    if not written then
        return result(false, "request-write-failed", { detail = tostring(write_error) })
    end
    self.requests[request.requestId] = {
        characterId = request.characterId,
        state = "pending",
        expiresAt = self.now_epoch() + self.request_ttl_seconds,
        rejectionReason = nil,
    }
    return result(true, "request-submitted", {
        requestId = request.requestId,
        requestState = "pending",
    })
end

function Bridge:poll_response(authorization)
    if not reject_unknown_fields(authorization, authorization_fields)
        or not safe_id(authorization.requestId)
        or not safe_id(authorization.characterId)
    then
        return result(false, "authorization-contract-invalid")
    end
    local choice_length = array_length(authorization.allowedChoiceIds, 32)
    if choice_length == nil then
        return result(false, "authorization-choices-invalid")
    end
    local allowed_choices = {}
    for index = 1, choice_length do
        local choice_id = authorization.allowedChoiceIds[index]
        if not safe_id(choice_id) or allowed_choices[choice_id] then
            return result(false, "authorization-choices-invalid")
        end
        allowed_choices[choice_id] = true
    end
    local tag_length = array_length(authorization.allowedResultTags, 64)
    if tag_length == nil then
        return result(false, "authorization-tags-invalid")
    end
    local allowed_tags = {}
    for index = 1, tag_length do
        local tag = authorization.allowedResultTags[index]
        if not safe_key(tag) or allowed_tags[tag] then
            return result(false, "authorization-tags-invalid")
        end
        allowed_tags[tag] = true
    end

    local record = self.requests[authorization.requestId]
    if record ~= nil then
        if record.characterId ~= authorization.characterId then
            return result(false, "authorization-character-mismatch", {
                requestState = "rejected",
            })
        end
        if record.state == "expired" then
            return result(false, "request-expired", { requestState = "expired" })
        end
        if record.state == "rejected" then
            return result(false, "response-rejected", {
                requestState = "rejected",
                detail = record.rejectionReason,
            })
        end
        if record.state == "pending" and self.now_epoch() > record.expiresAt then
            record.state = "expired"
            return result(false, "request-expired", { requestState = "expired" })
        end
    end

    local function reject_response(reason)
        if record ~= nil then
            record.state = "rejected"
            record.rejectionReason = reason
        end
        return result(false, reason, { requestState = "rejected" })
    end

    local path = join(self.root, "outbox/" .. authorization.requestId .. ".json")
    local content, read_error
    if type(self.filesystem.read_limited) == "function" then
        content, read_error = self.filesystem.read_limited(path, MAX_RESPONSE_BYTES)
    else
        content, read_error = self.filesystem.read(path)
        if content ~= nil and #content > MAX_RESPONSE_BYTES then
            content, read_error = nil, "too-large"
        end
    end
    if content == nil then
        if read_error == "too-large" then
            return reject_response("response-too-large")
        end
        return result(false, "response-pending", { requestState = "pending" })
    end
    local decoded_ok, response = pcall(json.decode, content)
    if not decoded_ok or not reject_unknown_fields(response, response_fields) then
        return reject_response("response-json-invalid")
    end
    if response.schemaVersion ~= SCHEMA_VERSION
        or response.requestId ~= authorization.requestId
        or response.characterId ~= authorization.characterId
        or type(response.createdAt) ~= "string"
        or type(response.provider) ~= "string"
        or not bounded_utf8(response.dialogue, MAX_DIALOGUE_CHARS)
        or array_length(response.resultTags, 64) == nil
    then
        return reject_response("response-contract-invalid")
    end
    if response.provider ~= "ollama"
        and response.provider ~= "openai-compatible"
        and not (response.provider == "mock" and self.allow_mock_provider)
    then
        return reject_response("response-provider-not-allowed")
    end

    local proposed_choice = response.proposedChoice
    if proposed_choice == json.null then
        proposed_choice = nil
    elseif not safe_id(proposed_choice) or not allowed_choices[proposed_choice] then
        return reject_response("response-choice-not-authorized")
    end
    local result_tags = json.array()
    local seen_tags = {}
    for index = 1, array_length(response.resultTags, 64) do
        local tag = response.resultTags[index]
        if not safe_key(tag) or not allowed_tags[tag] or seen_tags[tag] then
            return reject_response("response-tag-not-authorized")
        end
        seen_tags[tag] = true
        result_tags[index] = tag
    end

    -- The adapter deliberately returns presentation/proposal data only. It has
    -- no methods for affinity, quests, inventory, currency, saves, or world state.
    if record ~= nil then
        record.state = "ready"
    end
    return result(true, "response-validated", {
        requestId = response.requestId,
        dialogue = response.dialogue,
        proposedChoice = proposed_choice,
        resultTags = result_tags,
    })
end

function Bridge:status()
    return {
        apiVersion = SCHEMA_VERSION,
        root = self.root,
        authority = "presentation-and-proposals-only",
        directStateMutation = false,
        maximumRequestBytes = MAX_REQUEST_BYTES,
        maximumPlayerTextCharacters = MAX_PLAYER_TEXT_CHARS,
        maximumDialogueCharacters = MAX_DIALOGUE_CHARS,
        requestTtlSeconds = self.request_ttl_seconds,
        directoryOwner = "pal-agent-dialogue-sidecar",
    }
end

return M
