local Json = require("pwft.json")

local AgentDialogueFileBridge = {}
local Bridge = {}
Bridge.__index = Bridge

local SCHEMA_VERSION = "1.0.0"
local MAX_REQUEST_BYTES = 256 * 1024
local MAX_RESPONSE_BYTES = 64 * 1024
local MAX_PLAYER_TEXT_CHARACTERS = 8000
local MAX_DIALOGUE_CHARACTERS = 4000

local REQUEST_FIELDS = {
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

local RESPONSE_FIELDS = {
    schemaVersion = true,
    requestId = true,
    createdAt = true,
    characterId = true,
    provider = true,
    dialogue = true,
    proposedChoice = true,
    resultTags = true,
}

local AUTHORIZATION_FIELDS = {
    requestId = true,
    characterId = true,
    allowedChoiceIds = true,
    allowedResultTags = true,
}

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function exact_fields(value, allowed)
    if type(value) ~= "table" then
        return false
    end
    for key in pairs(value) do
        if allowed[key] ~= true then
            return false
        end
    end
    return true
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
        local second = width > 1 and value:byte(index + 1) or nil
        if (first == 0xe0 and second < 0xa0)
            or (first == 0xed and second > 0x9f)
            or (first == 0xf0 and second < 0x90)
            or (first == 0xf4 and second > 0x8f) then
            return nil
        end
        index = index + width
        length = length + 1
    end
    return length
end

local function bounded_text(value, maximum)
    local length = utf8_length(value)
    return length ~= nil and length >= 1 and length <= maximum
end

local function array_length(value, maximum)
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
    if type(root) ~= "string" or root == ""
        or root:find("[%z\1-\31]") ~= nil then
        return nil
    end
    local normalized = root:gsub("\\", "/"):gsub("/+$", "")
    if normalized:match("^%a:/") == nil
        and normalized:match("^//[^/]+/[^/]+") == nil
        and normalized:match("^/") == nil then
        return nil
    end
    for component in normalized:gmatch("[^/]+") do
        if component == "." or component == ".." then
            return nil
        end
    end
    return normalized
end

local function join(root, child)
    return root .. "/" .. child
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
        exists = function(path)
            local handle = io.open(path, "rb")
            if handle == nil then
                return false
            end
            handle:close()
            return true
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
                return false, "temporary-open-failed:" .. tostring(open_error)
            end
            local written, write_error = handle:write(content)
            local flushed, flush_error = handle:flush()
            handle:close()
            if not written or not flushed then
                os.remove(temporary)
                return false, "temporary-write-failed:"
                    .. tostring(write_error or flush_error)
            end
            local renamed, rename_error = os.rename(temporary, path)
            if not renamed then
                os.remove(temporary)
                return false, "atomic-rename-failed:" .. tostring(rename_error)
            end
            return true, nil
        end,
    }
end

function AgentDialogueFileBridge.create(configuration, filesystem)
    assert(type(configuration) == "table", "Agent bridge configuration is required")
    local root = normalize_root(configuration.rootPath)
    assert(root ~= nil, "Agent bridge root must be absolute and traversal-free")
    local ttl = configuration.requestTtlSeconds or 600
    assert(type(ttl) == "number" and ttl >= 10 and ttl <= 3600,
        "Agent bridge request TTL must be 10..3600 seconds")
    local fs = filesystem or default_filesystem()
    for _, name in ipairs({ "read_limited", "exists", "write_atomic" }) do
        assert(type(fs[name]) == "function", "Agent bridge filesystem missing " .. name)
    end
    return setmetatable({
        version = SCHEMA_VERSION,
        ready = configuration.enabled == true,
        root = root,
        requestTtlSeconds = ttl,
        nowEpoch = configuration.nowEpoch or os.time,
        filesystem = fs,
        requests = {},
        submittedCount = 0,
        validatedCount = 0,
        rejectedCount = 0,
    }, Bridge)
end

function Bridge:submit_request(request)
    if not self.ready then
        return result(false, "agent-file-bridge-disabled")
    end
    if not exact_fields(request, REQUEST_FIELDS)
        or request.schemaVersion ~= SCHEMA_VERSION
        or not safe_id(request.requestId)
        or not safe_id(request.characterId)
        or not safe_id(request.sessionId)
        or type(request.createdAt) ~= "string"
        or type(request.worldKey) ~= "string" or request.worldKey == "" or #request.worldKey > 256
        or type(request.playerKey) ~= "string" or request.playerKey == "" or #request.playerKey > 256
        or type(request.locale) ~= "string" or request.locale == "" or #request.locale > 32
        or not bounded_text(request.playerText, MAX_PLAYER_TEXT_CHARACTERS) then
        return result(false, "request-contract-invalid")
    end
    local context_length = array_length(request.contextKeys, 64)
    local choice_length = array_length(request.allowedChoices, 32)
    local tag_length = array_length(request.allowedResultTags, 64)
    if context_length == nil or choice_length == nil or tag_length == nil then
        return result(false, "request-array-invalid")
    end
    local seen_context = {}
    for index = 1, context_length do
        local key = request.contextKeys[index]
        if not safe_key(key) or seen_context[key] then
            return result(false, "context-keys-invalid")
        end
        seen_context[key] = true
    end
    local seen_choices = {}
    for index = 1, choice_length do
        local choice = request.allowedChoices[index]
        if not exact_fields(choice, { choiceId = true, textKey = true })
            or not safe_id(choice.choiceId)
            or not safe_key(choice.textKey)
            or seen_choices[choice.choiceId] then
            return result(false, "allowed-choices-invalid")
        end
        seen_choices[choice.choiceId] = true
    end
    local seen_tags = {}
    for index = 1, tag_length do
        local tag = request.allowedResultTags[index]
        if not safe_key(tag) or seen_tags[tag] then
            return result(false, "allowed-result-tags-invalid")
        end
        seen_tags[tag] = true
    end
    local encoded_ok, encoded = pcall(Json.encode, request)
    if not encoded_ok or #encoded > MAX_REQUEST_BYTES then
        return result(false, "request-json-invalid-or-too-large")
    end
    local path = join(self.root, "inbox/" .. request.requestId .. ".json")
    if self.filesystem.exists(path) then
        return result(false, "request-already-exists")
    end
    local written, write_error = self.filesystem.write_atomic(path, encoded)
    if not written then
        return result(false, "request-write-failed", { detail = tostring(write_error) })
    end
    self.requests[request.requestId] = {
        characterId = request.characterId,
        expiresAt = self.nowEpoch() + self.requestTtlSeconds,
        state = "pending",
    }
    self.submittedCount = self.submittedCount + 1
    return result(true, "request-submitted", {
        requestId = request.requestId,
        requestState = "pending",
    })
end

function Bridge:poll_response(authorization)
    if not exact_fields(authorization, AUTHORIZATION_FIELDS)
        or not safe_id(authorization.requestId)
        or not safe_id(authorization.characterId) then
        return result(false, "authorization-contract-invalid")
    end
    local choice_length = array_length(authorization.allowedChoiceIds, 32)
    local tag_length = array_length(authorization.allowedResultTags, 64)
    if choice_length == nil or tag_length == nil then
        return result(false, "authorization-array-invalid")
    end
    local allowed_choices = {}
    for index = 1, choice_length do
        local value = authorization.allowedChoiceIds[index]
        if not safe_id(value) or allowed_choices[value] then
            return result(false, "authorization-choices-invalid")
        end
        allowed_choices[value] = true
    end
    local allowed_tags = {}
    for index = 1, tag_length do
        local value = authorization.allowedResultTags[index]
        if not safe_key(value) or allowed_tags[value] then
            return result(false, "authorization-tags-invalid")
        end
        allowed_tags[value] = true
    end
    local record = self.requests[authorization.requestId]
    if record ~= nil then
        if record.characterId ~= authorization.characterId then
            return result(false, "authorization-character-mismatch")
        end
        if record.state ~= "pending" then
            return result(false, "request-" .. record.state)
        end
        if self.nowEpoch() > record.expiresAt then
            record.state = "expired"
            return result(false, "request-expired")
        end
    end
    local path = join(self.root, "outbox/" .. authorization.requestId .. ".json")
    local content, read_error = self.filesystem.read_limited(path, MAX_RESPONSE_BYTES)
    if content == nil then
        if read_error == "too-large" then
            if record ~= nil then record.state = "rejected" end
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "response-too-large")
        end
        return result(false, "response-pending")
    end
    local decoded_ok, response = pcall(Json.decode, content)
    if not decoded_ok or not exact_fields(response, RESPONSE_FIELDS)
        or response.schemaVersion ~= SCHEMA_VERSION
        or response.requestId ~= authorization.requestId
        or response.characterId ~= authorization.characterId
        or type(response.createdAt) ~= "string"
        or (response.provider ~= "ollama" and response.provider ~= "openai-compatible")
        or not bounded_text(response.dialogue, MAX_DIALOGUE_CHARACTERS)
        or array_length(response.resultTags, 64) == nil then
        if record ~= nil then record.state = "rejected" end
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "response-contract-invalid")
    end
    local proposed_choice = response.proposedChoice
    if proposed_choice == Json.null then
        proposed_choice = nil
    elseif not safe_id(proposed_choice) or not allowed_choices[proposed_choice] then
        if record ~= nil then record.state = "rejected" end
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "response-choice-not-authorized")
    end
    local result_tags = {}
    local seen_tags = {}
    for index = 1, #response.resultTags do
        local tag = response.resultTags[index]
        if not safe_key(tag) or not allowed_tags[tag] or seen_tags[tag] then
            if record ~= nil then record.state = "rejected" end
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "response-tag-not-authorized")
        end
        seen_tags[tag] = true
        result_tags[index] = tag
    end
    if record ~= nil then record.state = "ready" end
    self.validatedCount = self.validatedCount + 1
    return result(true, "response-validated", {
        requestId = authorization.requestId,
        dialogue = response.dialogue,
        proposedChoice = proposed_choice,
        resultTags = result_tags,
    })
end

function Bridge:status()
    return {
        apiVersion = self.version,
        ready = self.ready,
        root = self.root,
        submittedCount = self.submittedCount,
        validatedCount = self.validatedCount,
        rejectedCount = self.rejectedCount,
        requestTtlSeconds = self.requestTtlSeconds,
        authority = "presentation-and-proposals-only",
        directStateMutation = false,
        PalworldSaveMutation = false,
    }
end

return AgentDialogueFileBridge
