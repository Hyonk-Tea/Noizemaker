local M = {}

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_last_comma(text, before_index)
    local last
    local start = 1
    local limit = before_index or #text
    while true do
        local found = text:find(",", start, true)
        if not found or found > limit then
            break
        end
        last = found
        start = found + 1
    end
    return last
end

local function parse_http_url(text)
    local value = trim(text)
    if value:match("^https?://") then
        return value
    end
    return nil
end

local function url_host(url)
    return tostring(url or ""):match("^https?://([^/%?#]+)")
end

local function basename_from_url(url)
    local path = tostring(url or ""):match("^https?://[^/%?#]+([^?#]*)") or ""
    local name = path:match("([^/]+)$") or ""
    if name == "" then
        return nil
    end
    return name
end

function M.supports_uri(text)
    local value = trim(text):lower()
    return value:sub(1, 6) == "noize:" or value:sub(1, 8) == "noize://"
end

function M.parse(uri)
    local value = trim(uri)
    if value == "" then
        return nil, "No protocol URI was provided."
    end
    if not M.supports_uri(value) then
        return nil, "URI does not use the noize protocol."
    end

    local lower = value:lower()
    local payload
    if lower:sub(1, 8) == "noize://" then
        payload = value:sub(9)
    else
        payload = value:sub(7)
    end
    payload = trim(payload)
    if payload:sub(1, 2) == "//" then
        payload = payload:sub(3)
    end
    if payload == "" then
        return nil, "Noize URI is missing its archive URL."
    end

    local archive_url = payload
    local item_type
    local item_id

    local last_comma = find_last_comma(payload)
    if last_comma then
        local second_last = find_last_comma(payload, last_comma - 1)
        if second_last then
            local tail_id = trim(payload:sub(last_comma + 1))
            local middle_type = trim(payload:sub(second_last + 1, last_comma - 1))
            local candidate_url = trim(payload:sub(1, second_last - 1))
            if tail_id:match("^%d+$") and middle_type:match("^%a+$") and parse_http_url(candidate_url) then
                archive_url = candidate_url
                item_type = middle_type
                item_id = tonumber(tail_id)
            end
        end
    end

    archive_url = parse_http_url(archive_url)
    if not archive_url then
        return nil, "Noize URI is missing a valid http/https archive URL."
    end

    if item_type then
        if item_type:lower() ~= "mod" then
            return nil, "Unsupported GameBanana item type: " .. item_type
        end
        item_type = "Mod"
    end

    if item_id and item_id < 1 then
        return nil, "GameBanana item ID must be a positive integer."
    end

    local filename = basename_from_url(archive_url)
    if not filename or filename == "" then
        filename = item_id and ("gamebanana_mod_" .. tostring(item_id) .. ".zip") or "downloaded_mod.zip"
    end
    if not filename:lower():match("%.zip$") then
        filename = filename .. ".zip"
    end

    return {
        raw_uri = value,
        archive_url = archive_url,
        item_type = item_type,
        item_id = item_id,
        source = "gamebanana",
        host = url_host(archive_url),
        suggested_filename = filename,
    }
end

return M
