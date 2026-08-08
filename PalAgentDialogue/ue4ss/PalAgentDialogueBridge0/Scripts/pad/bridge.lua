local json = require("pad.json")

local M = {}
local Bridge = {}
Bridge.__index = Bridge

local SCHEMA_VERSION = "1.0.0"
local MAX_DIALOGUE_CHARS = 4000

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

local temporary_counter = 0

local function file_write_atomic(path, content)
    temporary_counter = temporary_counter + 1
    local temporary = string.format("%s.tmp-%d-%d", path, os.time(), temporary_counter)
    local handle, open_error = io.open(temporary, "wb")
    if not handle then
        return false, "open-temporary-failed:" .. tostring(open_error)
    end
    local written, write_error = handle:write(content)
    handle:flush()
    handle:close()
    if not written then
        os.remove(temporary)
        return false, "write-temporary-failed:" .. tostring(write_error)
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
    assert(type(configuration.root) == "string" and configuration.root ~= "", "bridge root is required")
    return setmetatable({
        root = configuration.root,
        filesystem = configuration.filesystem or default_filesystem,
        allow_mock_provider = configuration.allowMockProvider == true,
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
        or type(request.worldKey) ~= "string" or request.worldKey == "" or #request.worldKey > 256
        or type(request.playerKey) ~= "string" or request.playerKey == "" or #request.playerKey > 256
        or type(request.locale) ~= "string" or request.locale == "" or #request.locale > 32
        or type(request.playerText) ~= "string" or request.playerText == "" or #request.playerText > 24000
    then
        return result(false, "request-contract-invalid")
    end

    local seen_context = {}
    local context_keys = json.array()
    for index, key in ipairs(request.contextKeys or {}) do
        if index > 64 or not safe_key(key) or seen_context[key] then
            return result(false, "context-keys-invalid")
        end
        seen_context[key] = true
        context_keys[index] = key
    end

    local seen_choices = {}
    local choices = json.array()
    for index, choice in ipairs(request.allowedChoices or {}) do
        if index > 32
            or not reject_unknown_fields(choice, { choiceId = true, textKey = true })
            or not safe_id(choice.choiceId)
            or not safe_key(choice.textKey)
            or seen_choices[choice.choiceId]
        then
            return result(false, "allowed-choices-invalid")
        end
        seen_choices[choice.choiceId] = true
        choices[index] = { choiceId = choice.choiceId, textKey = choice.textKey }
    end

    local seen_tags = {}
    local tags = json.array()
    for index, tag in ipairs(request.allowedResultTags or {}) do
        if index > 64 or not safe_key(tag) or seen_tags[tag] then
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
    local existing = self.filesystem.read(path)
    if existing ~= nil then
        return result(false, "request-already-exists")
    end
    local encoded_ok, encoded = pcall(json.encode, payload)
    if not encoded_ok then
        return result(false, "request-json-encode-failed")
    end
    local written, write_error = self.filesystem.write_atomic(path, encoded)
    if not written then
        return result(false, "request-write-failed", { detail = tostring(write_error) })
    end
    return result(true, "request-submitted", { requestId = request.requestId })
end

function Bridge:poll_response(authorization)
    if not reject_unknown_fields(authorization, authorization_fields)
        or not safe_id(authorization.requestId)
        or not safe_id(authorization.characterId)
    then
        return result(false, "authorization-contract-invalid")
    end
    local allowed_choices = {}
    for index, choice_id in ipairs(authorization.allowedChoiceIds or {}) do
        if index > 32 or not safe_id(choice_id) or allowed_choices[choice_id] then
            return result(false, "authorization-choices-invalid")
        end
        allowed_choices[choice_id] = true
    end
    local allowed_tags = {}
    for index, tag in ipairs(authorization.allowedResultTags or {}) do
        if index > 64 or not safe_key(tag) or allowed_tags[tag] then
            return result(false, "authorization-tags-invalid")
        end
        allowed_tags[tag] = true
    end

    local path = join(self.root, "outbox/" .. authorization.requestId .. ".json")
    local content = self.filesystem.read(path)
    if content == nil then
        return result(false, "response-pending")
    end
    if #content > 65536 then
        return result(false, "response-too-large")
    end
    local decoded_ok, response = pcall(json.decode, content)
    if not decoded_ok or not reject_unknown_fields(response, response_fields) then
        return result(false, "response-json-invalid")
    end
    if response.schemaVersion ~= SCHEMA_VERSION
        or response.requestId ~= authorization.requestId
        or response.characterId ~= authorization.characterId
        or type(response.createdAt) ~= "string"
        or type(response.provider) ~= "string"
        or type(response.dialogue) ~= "string"
        or response.dialogue == ""
        or #response.dialogue > MAX_DIALOGUE_CHARS * 4
        or type(response.resultTags) ~= "table"
    then
        return result(false, "response-contract-invalid")
    end
    if response.provider ~= "ollama"
        and response.provider ~= "openai-compatible"
        and not (response.provider == "mock" and self.allow_mock_provider)
    then
        return result(false, "response-provider-not-allowed")
    end

    local proposed_choice = response.proposedChoice
    if proposed_choice == json.null then
        proposed_choice = nil
    elseif not safe_id(proposed_choice) or not allowed_choices[proposed_choice] then
        return result(false, "response-choice-not-authorized")
    end
    local result_tags = json.array()
    local seen_tags = {}
    for index, tag in ipairs(response.resultTags) do
        if index > 64 or not safe_key(tag) or not allowed_tags[tag] or seen_tags[tag] then
            return result(false, "response-tag-not-authorized")
        end
        seen_tags[tag] = true
        result_tags[index] = tag
    end

    -- The adapter deliberately returns presentation/proposal data only. It has
    -- no methods for affinity, quests, inventory, currency, saves, or world state.
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
    }
end

return M
