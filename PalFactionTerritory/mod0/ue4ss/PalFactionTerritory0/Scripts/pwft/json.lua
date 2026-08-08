local Json = {}

Json.null = {}

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function encode_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        return ESCAPES[character]
            or string.format("\\u%04x", string.byte(character))
    end) .. '"'
end

local function array_length(value)
    local count = 0
    local maximum = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil
        end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    if maximum ~= count then
        return nil
    end
    return maximum
end

local function encode_value(value, stack)
    if value == Json.null or value == nil then
        return "null"
    end
    local value_type = type(value)
    if value_type == "boolean" then
        return value and "true" or "false"
    end
    if value_type == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "JSON cannot encode non-finite numbers")
        return tostring(value)
    end
    if value_type == "string" then
        return encode_string(value)
    end
    assert(value_type == "table", "JSON cannot encode " .. value_type)
    assert(stack[value] == nil, "JSON cannot encode cyclic tables")
    stack[value] = true

    local length = array_length(value)
    local parts = {}
    if length ~= nil then
        for index = 1, length do
            table.insert(parts, encode_value(value[index], stack))
        end
        stack[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key, _ in pairs(value) do
        assert(type(key) == "string", "JSON object keys must be strings")
        table.insert(keys, key)
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        table.insert(
            parts,
            encode_string(key) .. ":" .. encode_value(value[key], stack)
        )
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function Json.encode(value)
    return encode_value(value, {})
end

local function utf8_character(codepoint)
    if codepoint <= 0x7f then
        return string.char(codepoint)
    end
    if codepoint <= 0x7ff then
        return string.char(
            0xc0 + math.floor(codepoint / 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    if codepoint <= 0xffff then
        return string.char(
            0xe0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    assert(codepoint <= 0x10ffff, "invalid Unicode codepoint")
    return string.char(
        0xf0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local function parser(text)
    return {
        text = text,
        position = 1,
        length = #text,
    }
end

local function skip_whitespace(state)
    while state.position <= state.length do
        local character = string.sub(state.text, state.position, state.position)
        if character ~= " " and character ~= "\t"
            and character ~= "\r" and character ~= "\n" then
            break
        end
        state.position = state.position + 1
    end
end

local function parse_error(state, message)
    error(string.format("JSON parse error at byte %d: %s", state.position, message))
end

local parse_value

local function parse_hex4(state)
    local value = string.sub(state.text, state.position, state.position + 3)
    if #value ~= 4 or string.find(value, "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") == nil then
        parse_error(state, "invalid Unicode escape")
    end
    state.position = state.position + 4
    return tonumber(value, 16)
end

local function parse_string(state)
    if string.sub(state.text, state.position, state.position) ~= '"' then
        parse_error(state, "expected string")
    end
    state.position = state.position + 1
    local parts = {}
    local chunk_start = state.position
    while state.position <= state.length do
        local character = string.sub(state.text, state.position, state.position)
        if character == '"' then
            table.insert(parts, string.sub(state.text, chunk_start, state.position - 1))
            state.position = state.position + 1
            return table.concat(parts)
        end
        if character == "\\" then
            table.insert(parts, string.sub(state.text, chunk_start, state.position - 1))
            state.position = state.position + 1
            local escaped = string.sub(state.text, state.position, state.position)
            local replacements = {
                ['"'] = '"',
                ["\\"] = "\\",
                ["/"] = "/",
                b = "\b",
                f = "\f",
                n = "\n",
                r = "\r",
                t = "\t",
            }
            if escaped == "u" then
                state.position = state.position + 1
                local codepoint = parse_hex4(state)
                if codepoint >= 0xd800 and codepoint <= 0xdbff then
                    if string.sub(state.text, state.position, state.position + 1) ~= "\\u" then
                        parse_error(state, "missing low Unicode surrogate")
                    end
                    state.position = state.position + 2
                    local low = parse_hex4(state)
                    if low < 0xdc00 or low > 0xdfff then
                        parse_error(state, "invalid low Unicode surrogate")
                    end
                    codepoint = 0x10000
                        + (codepoint - 0xd800) * 0x400
                        + (low - 0xdc00)
                elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
                    parse_error(state, "unexpected low Unicode surrogate")
                end
                table.insert(parts, utf8_character(codepoint))
                chunk_start = state.position
            else
                local replacement = replacements[escaped]
                if replacement == nil then
                    parse_error(state, "invalid string escape")
                end
                table.insert(parts, replacement)
                state.position = state.position + 1
                chunk_start = state.position
            end
        else
            if string.byte(character) < 0x20 then
                parse_error(state, "unescaped control character")
            end
            state.position = state.position + 1
        end
    end
    parse_error(state, "unterminated string")
end

local function parse_number(state)
    local start = state.position
    while state.position <= state.length do
        local character = string.sub(state.text, state.position, state.position)
        if string.find(character, "[0-9eE+%-%.]") == nil then
            break
        end
        state.position = state.position + 1
    end
    local token = string.sub(state.text, start, state.position - 1)
    local value = tonumber(token)
    if value == nil then
        parse_error(state, "invalid number")
    end
    return value
end

local function parse_array(state)
    state.position = state.position + 1
    local result = {}
    skip_whitespace(state)
    if string.sub(state.text, state.position, state.position) == "]" then
        state.position = state.position + 1
        return result
    end
    while true do
        table.insert(result, parse_value(state))
        skip_whitespace(state)
        local character = string.sub(state.text, state.position, state.position)
        if character == "]" then
            state.position = state.position + 1
            return result
        end
        if character ~= "," then
            parse_error(state, "expected ',' or ']'")
        end
        state.position = state.position + 1
        skip_whitespace(state)
    end
end

local function parse_object(state)
    state.position = state.position + 1
    local result = {}
    skip_whitespace(state)
    if string.sub(state.text, state.position, state.position) == "}" then
        state.position = state.position + 1
        return result
    end
    while true do
        local key = parse_string(state)
        skip_whitespace(state)
        if string.sub(state.text, state.position, state.position) ~= ":" then
            parse_error(state, "expected ':'")
        end
        state.position = state.position + 1
        result[key] = parse_value(state)
        skip_whitespace(state)
        local character = string.sub(state.text, state.position, state.position)
        if character == "}" then
            state.position = state.position + 1
            return result
        end
        if character ~= "," then
            parse_error(state, "expected ',' or '}'")
        end
        state.position = state.position + 1
        skip_whitespace(state)
    end
end

parse_value = function(state)
    skip_whitespace(state)
    local character = string.sub(state.text, state.position, state.position)
    if character == '"' then
        return parse_string(state)
    end
    if character == "{" then
        return parse_object(state)
    end
    if character == "[" then
        return parse_array(state)
    end
    if string.sub(state.text, state.position, state.position + 3) == "true" then
        state.position = state.position + 4
        return true
    end
    if string.sub(state.text, state.position, state.position + 4) == "false" then
        state.position = state.position + 5
        return false
    end
    if string.sub(state.text, state.position, state.position + 3) == "null" then
        state.position = state.position + 4
        return Json.null
    end
    if character == "-" or string.find(character, "[0-9]") ~= nil then
        return parse_number(state)
    end
    parse_error(state, "unexpected token")
end

function Json.decode(text)
    assert(type(text) == "string", "JSON input must be a string")
    local state = parser(text)
    local value = parse_value(state)
    skip_whitespace(state)
    if state.position <= state.length then
        parse_error(state, "trailing content")
    end
    return value
end

return Json
