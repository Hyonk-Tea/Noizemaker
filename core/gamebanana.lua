local json = require("core.json")
local platform = require("core.platform")

local M = {}

local GAME_IDS = { 16787, 20948 }
local CACHE_TTL_SECONDS = 60 * 60
local FEED_PROPERTIES = table.concat({
    "_idRow",
    "_sName",
    "_aFiles",
    "_aSubmitter",
    "_sDescription",
    "_sText",
    "_tsDateAdded",
    "_tsDateUpdated",
    "_aPreviewMedia",
    "_sProfileUrl",
    "_bIsNsfw",
}, ",")

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_slashes(path)
    return (tostring(path or ""):gsub("\\", "/"):gsub("/+", "/"))
end

local function join_path(a, b)
    if not a or a == "" then
        return b
    end
    if a:match("[/\\]$") then
        return a .. b
    end
    return a .. "/" .. b
end

local function ensure_dir(path)
    return platform.ensure_dir(path)
end

local function file_exists(path)
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

local function read_all(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function write_all(path, data)
    local fh = io.open(path, "wb")
    if not fh then
        return false
    end
    fh:write(data or "")
    fh:close()
    return true
end

local function basename_from_url(url)
    local path = tostring(url or ""):match("^https?://[^/%?#]+([^?#]*)") or ""
    return path:match("([^/]+)$") or ""
end

local function read_stamp(path)
    local raw = read_all(path)
    if not raw then
        return nil
    end
    return tonumber(trim(raw))
end

local function write_stamp(path, timestamp)
    return write_all(path, tostring(tonumber(timestamp) or os.time()))
end

local function cache_is_fresh(stamp_path)
    local stamp = read_stamp(stamp_path)
    if not stamp then
        return false
    end
    return (os.time() - stamp) < CACHE_TTL_SECONDS
end

local function endpoint_url(game_id, per_page)
    return string.format(
        "https://gamebanana.com/apiv8/Mod/ByGame?_aGameRowIds[]=%d&_csvProperties=%s&_nPage=1&_nPerpage=%d",
        tonumber(game_id),
        FEED_PROPERTIES,
        tonumber(per_page) or 8
    )
end

local function item_url(item_id)
    return string.format(
        "https://api.gamebanana.com/Core/Item/Data?itemtype=Mod&itemid=%d&fields=name,Owner().name,Preview().sSubFeedImageUrl(),description,text,Files().aFiles(),Url().sProfileUrl()&return_keys=1&format=json_min",
        tonumber(item_id)
    )
end

local function html_decode(text)
    local value = tostring(text or "")
    value = value:gsub("&nbsp;", " ")
    value = value:gsub("&amp;", "&")
    value = value:gsub("&quot;", '"')
    value = value:gsub("&#39;", "'")
    value = value:gsub("&lt;", "<")
    value = value:gsub("&gt;", ">")
    return value
end

local function strip_html(text)
    local value = tostring(text or "")
    value = value:gsub("<[bB][rR]%s*/?>", "\n")
    value = value:gsub("</[pP]>", "\n")
    value = value:gsub("<[^>]+>", "")
    value = html_decode(value)
    value = value:gsub("[\r\n]+", "\n")
    value = value:gsub("[ \t]+", " ")
    value = value:gsub(" *\n *", "\n")
    return trim(value)
end

local function collapse_summary(text)
    local value = strip_html(text):gsub("\n", " ")
    value = value:gsub("%s+", " ")
    return trim(value)
end

local function truncate_text(text, limit)
    local value = trim(text)
    if #value <= limit then
        return value
    end
    local shortened = value:sub(1, limit - 3):gsub("%s+%S*$", "")
    if shortened == "" then
        shortened = value:sub(1, limit - 3)
    end
    return shortened .. "..."
end

local function choose_preview_url(media)
    local images = media and media._aImages
    if type(images) ~= "table" or not images[1] then
        return nil
    end
    local image = images[1]
    local base = trim(image._sBaseUrl or "")
    if base == "" then
        return nil
    end
    local filename = image._sFile220 or image._sFile530 or image._sFile100 or image._sFile
    if not filename or filename == "" then
        return nil
    end
    return base .. "/" .. filename
end

local function choose_download_file(files)
    if type(files) ~= "table" then
        return nil
    end

    local best = nil
    for i = 1, #files do
        local file = files[i]
        if type(file) == "table" and file._bHasContents then
            if not best then
                best = file
            else
                local file_active = not file._bIsArchived
                local best_active = not best._bIsArchived
                if file_active and not best_active then
                    best = file
                elseif file_active == best_active and tonumber(file._tsDateAdded or 0) > tonumber(best._tsDateAdded or 0) then
                    best = file
                end
            end
        end
    end

    return best
end

local function mod_from_api(item)
    local file = choose_download_file(item._aFiles)
    if not file or not file._idRow then
        return nil
    end

    local description = trim(item._sDescription or "")
    if description == "" then
        description = collapse_summary(item._sText or "")
    end
    if description == "" then
        description = "No description provided."
    end

    local submitter = item._aSubmitter or {}
    local file_id = tonumber(file._idRow)
    local mod_id = tonumber(item._idRow)

    return {
        id = mod_id,
        name = trim(item._sName or "Unnamed Mod"),
        description = truncate_text(description, 180),
        submitter_name = trim(submitter._sName or ""),
        profile_url = trim(item._sProfileUrl or ""),
        preview_url = choose_preview_url(item._aPreviewMedia),
        download_url = trim(file._sDownloadUrl or ""),
        download_file_id = file_id,
        ts_date_added = tonumber(item._tsDateAdded or 0),
        ts_date_updated = tonumber(item._tsDateUpdated or 0),
        noize_uri = string.format("noize:https://gamebanana.com/mmdl/%d,Mod,%d", file_id, mod_id),
        file_name = trim(file._sFile or ""),
        version = trim(file._sVersion or ""),
    }
end

local function sort_recent(items)
    table.sort(items, function(a, b)
        if a.ts_date_added == b.ts_date_added then
            return (a.id or 0) > (b.id or 0)
        end
        return (a.ts_date_added or 0) > (b.ts_date_added or 0)
    end)
end

function M.fetch_recent_mods(cache_dir, limit)
    local count = math.max(tonumber(limit) or 3, 1)
    ensure_dir(cache_dir)

    local last_error = nil
    for i = 1, #GAME_IDS do
        local game_id = GAME_IDS[i]
        local cache_path = join_path(cache_dir, string.format("gamebanana_recent_%d.json", game_id))
        local stamp_path = cache_path .. ".stamp"
        local url = endpoint_url(game_id, math.max(count * 3, 8))
        local downloaded = false
        if not (file_exists(cache_path) and cache_is_fresh(stamp_path)) then
            downloaded = platform.download_file(url, cache_path)
            if downloaded then
                write_stamp(stamp_path, os.time())
            end
        end
        local raw = read_all(cache_path)

        if raw and raw ~= "" then
            local ok, payload = pcall(json.decode, raw)
            if ok and type(payload) == "table" then
                local items = {}
                for j = 1, #payload do
                    if type(payload[j]) == "table" and not payload[j]._bIsNsfw then
                        local mapped = mod_from_api(payload[j])
                        if mapped then
                            items[#items + 1] = mapped
                        end
                    end
                end
                if #items > 0 then
                    sort_recent(items)
                    local result = {}
                    for j = 1, math.min(count, #items) do
                        result[j] = items[j]
                    end
                    return {
                        items = result,
                        game_id = game_id,
                        from_cache = not downloaded,
                    }
                end
                last_error = "GameBanana returned no usable recent mods."
            else
                last_error = ok and "GameBanana returned an unexpected response." or payload
            end
        else
            last_error = "No GameBanana response was available."
        end
    end

    return nil, last_error or "GameBanana releases could not be loaded."
end

function M.fetch_mod_details(cache_dir, item_id)
    local numeric_id = tonumber(item_id)
    if not numeric_id then
        return nil, "Missing GameBanana item id."
    end

    ensure_dir(cache_dir)
    local cache_path = join_path(cache_dir, string.format("gamebanana_mod_%d.json", numeric_id))
    local stamp_path = cache_path .. ".stamp"

    local downloaded = false
    if not (file_exists(cache_path) and cache_is_fresh(stamp_path)) then
        downloaded = platform.download_file(item_url(numeric_id), cache_path)
        if downloaded then
            write_stamp(stamp_path, os.time())
        end
    end

    local raw = read_all(cache_path)
    if not raw or raw == "" then
        return nil, "No GameBanana metadata was available."
    end

    local ok, payload = pcall(json.decode, raw)
    if not ok or type(payload) ~= "table" then
        return nil, ok and "GameBanana returned an unexpected metadata response." or payload
    end

    local description = trim(payload.description or "")
    if description == "" then
        description = collapse_summary(payload.text or "")
    end
    if description == "" then
        description = "No description provided."
    end

    return {
        id = numeric_id,
        name = trim(payload.name or ("Mod #" .. tostring(numeric_id))),
        author = trim(payload["Owner().name"] or ""),
        preview_url = trim(payload["Preview().sSubFeedImageUrl()"] or ""),
        description = truncate_text(description, 220),
        profile_url = trim(payload["Url().sProfileUrl()"] or ""),
        from_cache = not downloaded,
    }
end

function M.cache_preview_image(item, cache_dir)
    local url = item and item.preview_url
    if not url or url == "" then
        return nil
    end

    ensure_dir(cache_dir)
    local filename = basename_from_url(url)
    if filename == "" then
        filename = string.format("mod_%d_preview.jpg", tonumber(item.id or 0))
    end
    local path = join_path(cache_dir, normalize_slashes(filename))
    if file_exists(path) then
        return path
    end
    if platform.download_file(url, path) then
        return path
    end
    return nil
end

return M
