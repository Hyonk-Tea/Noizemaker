local M = {}

local function decode_error(pos, message)
    error(string.format("JSON decode error at %d: %s", pos, message))
end

local function skip_ws(text, index)
    local len = #text
    while index <= len do
        local byte = text:byte(index)
        if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            break
        end
        index = index + 1
    end
    return index
end

local function utf8_char(codepoint)
    if codepoint <= 0x7F then
        return string.char(codepoint)
    end
    if codepoint <= 0x7FF then
        local b1 = 0xC0 + math.floor(codepoint / 0x40)
        local b2 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2)
    end
    if codepoint <= 0xFFFF then
        local b1 = 0xE0 + math.floor(codepoint / 0x1000)
        local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
        local b3 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2, b3)
    end
    local b1 = 0xF0 + math.floor(codepoint / 0x40000)
    local b2 = 0x80 + (math.floor(codepoint / 0x1000) % 0x40)
    local b3 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
    local b4 = 0x80 + (codepoint % 0x40)
    return string.char(b1, b2, b3, b4)
end

local parse_value

local function parse_string(text, index)
    index = index + 1
    local parts = {}
    local len = #text

    while index <= len do
        local byte = text:byte(index)
        if byte == 34 then
            return table.concat(parts), index + 1
        end
        if byte == 92 then
            index = index + 1
            if index > len then
                decode_error(index, "unfinished escape sequence")
            end

            local esc = text:sub(index, index)
            if esc == '"' or esc == "\\" or esc == "/" then
                parts[#parts + 1] = esc
                index = index + 1
            elseif esc == "b" then
                parts[#parts + 1] = "\b"
                index = index + 1
            elseif esc == "f" then
                parts[#parts + 1] = "\f"
                index = index + 1
            elseif esc == "n" then
                parts[#parts + 1] = "\n"
                index = index + 1
            elseif esc == "r" then
                parts[#parts + 1] = "\r"
                index = index + 1
            elseif esc == "t" then
                parts[#parts + 1] = "\t"
                index = index + 1
            elseif esc == "u" then
                local hex = text:sub(index + 1, index + 4)
                if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
                    decode_error(index, "invalid unicode escape")
                end
                local codepoint = tonumber(hex, 16)
                parts[#parts + 1] = utf8_char(codepoint)
                index = index + 5
            else
                decode_error(index, "unsupported escape sequence \\" .. esc)
            end
        else
            parts[#parts + 1] = string.char(byte)
            index = index + 1
        end
    end

    decode_error(index, "unterminated string")
end

local function parse_number(text, index)
    local chunk = text:sub(index)
    local number_text = chunk:match("^-?%d+%.?%d*[eE][%+%-]?%d+") or chunk:match("^-?%d+%.%d+") or chunk:match("^-?%d+")
    if not number_text then
        decode_error(index, "invalid number")
    end
    local value = tonumber(number_text)
    if value == nil then
        decode_error(index, "invalid number value")
    end
    return value, index + #number_text
end

local function parse_array(text, index)
    index = index + 1
    local out = {}
    index = skip_ws(text, index)
    if text:sub(index, index) == "]" then
        return out, index + 1
    end

    local item_index = 1
    while true do
        local value
        value, index = parse_value(text, index)
        out[item_index] = value
        item_index = item_index + 1

        index = skip_ws(text, index)
        local ch = text:sub(index, index)
        if ch == "]" then
            return out, index + 1
        end
        if ch ~= "," then
            decode_error(index, "expected ',' or ']'")
        end
        index = skip_ws(text, index + 1)
    end
end

local function parse_object(text, index)
    index = index + 1
    local out = {}
    index = skip_ws(text, index)
    if text:sub(index, index) == "}" then
        return out, index + 1
    end

    while true do
        if text:sub(index, index) ~= '"' then
            decode_error(index, "expected string key")
        end
        local key
        key, index = parse_string(text, index)
        index = skip_ws(text, index)
        if text:sub(index, index) ~= ":" then
            decode_error(index, "expected ':' after key")
        end
        index = skip_ws(text, index + 1)

        local value
        value, index = parse_value(text, index)
        out[key] = value

        index = skip_ws(text, index)
        local ch = text:sub(index, index)
        if ch == "}" then
            return out, index + 1
        end
        if ch ~= "," then
            decode_error(index, "expected ',' or '}'")
        end
        index = skip_ws(text, index + 1)
    end
end

parse_value = function(text, index)
    index = skip_ws(text, index)
    local ch = text:sub(index, index)
    if ch == "" then
        decode_error(index, "unexpected end of input")
    end
    if ch == '"' then
        return parse_string(text, index)
    end
    if ch == "{" then
        return parse_object(text, index)
    end
    if ch == "[" then
        return parse_array(text, index)
    end
    if ch == "-" or ch:match("%d") then
        return parse_number(text, index)
    end
    if text:sub(index, index + 3) == "true" then
        return true, index + 4
    end
    if text:sub(index, index + 4) == "false" then
        return false, index + 5
    end
    if text:sub(index, index + 3) == "null" then
        return nil, index + 4
    end
    decode_error(index, "unexpected token")
end

function M.decode(text)
    local value, index = parse_value(tostring(text or ""), 1)
    index = skip_ws(text, index)
    if index <= #text then
        decode_error(index, "trailing data")
    end
    return value
end

return M
