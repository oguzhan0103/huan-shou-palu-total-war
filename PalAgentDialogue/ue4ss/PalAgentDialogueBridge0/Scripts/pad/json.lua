local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local array_metatable = { __json_array = true }

function M.array(values)
    return setmetatable(values or {}, array_metatable)
end

local escapes = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function encode_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        return escapes[character] or string.format('\\u%04x', string.byte(character))
    end) .. '"'
end

local function table_is_array(value)
    local metatable = getmetatable(value)
    if metatable and metatable.__json_array == true then
        return true
    end
    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    return count > 0 and count == maximum
end

local function encode_value(value, seen)
    local kind = type(value)
    if value == M.null or kind == "nil" then
        return "null"
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "non-finite JSON number")
        return tostring(value)
    elseif kind == "string" then
        return encode_string(value)
    elseif kind ~= "table" then
        error("unsupported JSON value type: " .. kind)
    end

    assert(not seen[value], "cyclic JSON table")
    seen[value] = true
    local output = {}
    if table_is_array(value) then
        for index = 1, #value do
            output[#output + 1] = encode_value(value[index], seen)
        end
        seen[value] = nil
        return "[" .. table.concat(output, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
        assert(type(key) == "string", "JSON object keys must be strings")
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        output[#output + 1] = encode_string(key) .. ":" .. encode_value(value[key], seen)
    end
    seen[value] = nil
    return "{" .. table.concat(output, ",") .. "}"
end

function M.encode(value)
    return encode_value(value, {})
end

local function decode_error(index, message)
    error(string.format("invalid JSON at byte %d: %s", index, message), 0)
end

local function utf8_character(codepoint)
    if utf8 and utf8.char then
        return utf8.char(codepoint)
    end
    if codepoint <= 0x7f then
        return string.char(codepoint)
    elseif codepoint <= 0x7ff then
        return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    end
    return string.char(
        0xe0 + math.floor(codepoint / 0x1000),
        0x80 + math.floor(codepoint / 0x40) % 0x40,
        0x80 + codepoint % 0x40
    )
end

function M.decode(text)
    assert(type(text) == "string", "JSON input must be a string")
    local index = 1
    local length = #text

    local function skip_whitespace()
        while index <= length and text:sub(index, index):match("%s") do
            index = index + 1
        end
    end

    local parse_value

    local function parse_string()
        if text:sub(index, index) ~= '"' then
            decode_error(index, "expected string")
        end
        index = index + 1
        local output = {}
        local start = index
        while index <= length do
            local character = text:sub(index, index)
            if character == '"' then
                output[#output + 1] = text:sub(start, index - 1)
                index = index + 1
                return table.concat(output)
            elseif character == "\\" then
                output[#output + 1] = text:sub(start, index - 1)
                index = index + 1
                local escape = text:sub(index, index)
                local replacements = {
                    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'
                }
                if replacements[escape] then
                    output[#output + 1] = replacements[escape]
                    index = index + 1
                elseif escape == "u" then
                    local hex = text:sub(index + 1, index + 4)
                    if not hex:match("^%x%x%x%x$") then
                        decode_error(index, "invalid unicode escape")
                    end
                    local codepoint = tonumber(hex, 16)
                    if codepoint >= 0xd800 and codepoint <= 0xdfff then
                        decode_error(index, "surrogate unicode escapes are not supported")
                    end
                    output[#output + 1] = utf8_character(codepoint)
                    index = index + 5
                else
                    decode_error(index, "invalid escape")
                end
                start = index
            elseif string.byte(character) < 32 then
                decode_error(index, "unescaped control character")
            else
                index = index + 1
            end
        end
        decode_error(index, "unterminated string")
    end

    local function parse_number()
        local start = index
        local token = text:sub(index):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if not token or token == "" then
            decode_error(index, "invalid number")
        end
        index = index + #token
        local value = tonumber(token)
        if not value then
            decode_error(start, "invalid number")
        end
        return value
    end

    local function parse_array()
        index = index + 1
        skip_whitespace()
        local values = M.array()
        if text:sub(index, index) == "]" then
            index = index + 1
            return values
        end
        while true do
            values[#values + 1] = parse_value()
            skip_whitespace()
            local character = text:sub(index, index)
            if character == "]" then
                index = index + 1
                return values
            elseif character ~= "," then
                decode_error(index, "expected comma or closing bracket")
            end
            index = index + 1
            skip_whitespace()
        end
    end

    local function parse_object()
        index = index + 1
        skip_whitespace()
        local value = {}
        if text:sub(index, index) == "}" then
            index = index + 1
            return value
        end
        while true do
            local key = parse_string()
            if value[key] ~= nil then
                decode_error(index, "duplicate object key")
            end
            skip_whitespace()
            if text:sub(index, index) ~= ":" then
                decode_error(index, "expected colon")
            end
            index = index + 1
            skip_whitespace()
            value[key] = parse_value()
            skip_whitespace()
            local character = text:sub(index, index)
            if character == "}" then
                index = index + 1
                return value
            elseif character ~= "," then
                decode_error(index, "expected comma or closing brace")
            end
            index = index + 1
            skip_whitespace()
        end
    end

    parse_value = function()
        skip_whitespace()
        local character = text:sub(index, index)
        if character == '"' then
            return parse_string()
        elseif character == "{" then
            return parse_object()
        elseif character == "[" then
            return parse_array()
        elseif text:sub(index, index + 3) == "true" then
            index = index + 4
            return true
        elseif text:sub(index, index + 4) == "false" then
            index = index + 5
            return false
        elseif text:sub(index, index + 3) == "null" then
            index = index + 4
            return M.null
        elseif character == "-" or character:match("%d") then
            return parse_number()
        end
        decode_error(index, "unexpected token")
    end

    local value = parse_value()
    skip_whitespace()
    if index <= length then
        decode_error(index, "trailing content")
    end
    return value
end

return M
