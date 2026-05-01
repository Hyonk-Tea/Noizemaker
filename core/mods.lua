local M = {}
local platform = require("core.platform")

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_slashes(path)
    local normalized = tostring(path or ""):gsub("\\", "/")
    normalized = normalized:gsub("/+", "/")
    return normalized
end

local function join_path(a, b)
    if not a or a == "" then
        return b
    end
    if not b or b == "" then
        return a
    end
    if a:match("[/\\]$") then
        return a .. b
    end
    return a .. "/" .. b
end

local function dirname(path)
    return path:match("^(.*)[/\\][^/\\]+$") or ""
end

local function basename(path)
    local cleaned = tostring(path or ""):gsub("[/\\]+$", "")
    return cleaned:match("([^/\\]+)$") or cleaned
end

local function basename_no_ext(path)
    return basename(path):gsub("%.[^.]+$", "")
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
    fh:write(data)
    fh:close()
    return true
end

local function directory_exists(path)
    return platform.directory_exists(path)
end

local function ensure_dir(path)
    return platform.ensure_dir(path)
end

local function remove_dir(path)
    return platform.remove_dir(path)
end

local function remove_file(path)
    return platform.remove_file(path)
end

local function list_directories(path)
    return platform.list_directories(path)
end

local function list_files_recursive(path)
    return platform.list_files_recursive(path)
end

local function copy_file(src, dst)
    local data = read_all(src)
    if data == nil then
        return false, "Could not read file: " .. src
    end
    local parent = dirname(dst)
    if parent ~= "" and not ensure_dir(parent) then
        return false, "Could not create directory: " .. parent
    end
    if not write_all(dst, data) then
        return false, "Could not write file: " .. dst
    end
    return true
end

local function copy_tree(src_root, dst_root)
    local files = list_files_recursive(src_root)
    for i = 1, #files do
        local rel = files[i]
        local ok, err = copy_file(join_path(src_root, rel), join_path(dst_root, rel))
        if not ok then
            return false, err
        end
    end
    return true
end

local function split_lines(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("([^\r\n]*)[\r\n]?") do
        if line == "" and #lines > 0 and lines[#lines] == "" then
            break
        end
        lines[#lines + 1] = line
    end
    return lines
end

local function unquote(value)
    local first = value:sub(1, 1)
    local last = value:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        return value:sub(2, -2)
    end
    return value
end

local function is_safe_relative_path(path)
    local value = normalize_slashes(trim(path))
    if value == "" then
        return false
    end
    if value:match("^[A-Za-z]:") or value:match("^/") then
        return false
    end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return false
        end
    end
    return true
end

local function sanitize_folder_name(name)
    local value = trim(name):lower()
    value = value:gsub("%s+", "_")
    value = value:gsub("[<>:\"/\\|%?%*]", "")
    value = value:gsub("[^%w%._-]", "")
    value = value:gsub("_+", "_")
    value = value:gsub("^_+", ""):gsub("_+$", "")
    if value == "" then
        return "mod"
    end
    return value
end

local function unique_folder_name(mods_dir, preferred)
    local base = sanitize_folder_name(preferred)
    local candidate = base
    local index = 2
    local existing = {}
    local dirs = list_directories(mods_dir)
    for i = 1, #dirs do
        existing[dirs[i]:lower()] = true
    end
    while existing[candidate:lower()] do
        candidate = string.format("%s_%d", base, index)
        index = index + 1
    end
    return candidate
end

local function valid_game_root(path)
    if not path or path == "" then
        return false
    end
    return file_exists(join_path(path, "R1.BIN")) or file_exists(join_path(path, "r1.bin"))
end

local function parse_ini(text)
    local data = { enabled = {} }
    local current = "default"
    for _, raw_line in ipairs(split_lines(text or "")) do
        local line = trim(raw_line)
        if line ~= "" and not line:match("^[;#]") then
            local section = line:match("^%[(.-)%]$")
            if section then
                current = trim(section):lower()
                if not data[current] then
                    data[current] = {}
                end
            else
                local key, value = line:match("^([^=]+)=(.*)$")
                if key and value and not data[current] then
                    data[current] = {}
                end
                if key and value then
                    data[current][trim(key):lower()] = trim(value)
                end
            end
        end
    end
    return data
end

local function load_state(path)
    local raw = read_all(path)
    local state = { enabled = {} }
    if raw == nil then
        return state
    end
    local parsed = parse_ini(raw)
    for key, value in pairs(parsed.enabled or {}) do
        if value ~= "0" and value:lower() ~= "false" then
            state.enabled[key] = true
        end
    end
    return state
end

local function save_state(path, state)
    local names = {}
    for name in pairs((state or {}).enabled or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    local lines = { "[enabled]" }
    for i = 1, #names do
        lines[#lines + 1] = names[i] .. " = 1"
    end
    return write_all(path, table.concat(lines, "\n") .. "\n")
end

local function normalize_changed_file(path)
    return normalize_slashes(trim(path)):lower()
end

local function changed_file_set(list)
    local set = {}
    for i = 1, #(list or {}) do
        set[normalize_changed_file(list[i])] = true
    end
    return set
end

local function detect_conflicts_for_mod(target_mod, installed_mods)
    local conflicts = {}
    local target_files = changed_file_set(target_mod.changed_files)
    for i = 1, #installed_mods do
        local other = installed_mods[i]
        if other.enabled and other.folder_name ~= target_mod.folder_name then
            for j = 1, #(other.changed_files or {}) do
                if target_files[normalize_changed_file(other.changed_files[j])] then
                    conflicts[#conflicts + 1] = other
                    break
                end
            end
        end
    end
    return conflicts
end

local function archive_entries(zip_path)
    return platform.archive_entries(zip_path)
end

local function archive_root_prefix(entries)
    local roots = {}
    local root_count = 0
    local has_root_manifest = false
    local entries_map = {}

    for i = 1, #entries do
        local entry = normalize_slashes(entries[i]):gsub("/+$", "")
        if entry ~= "" then
            entries_map[entry:lower()] = true
            if entry:lower() == "noizemaker.yaml" then
                has_root_manifest = true
            end
            local first = entry:match("^([^/]+)/")
            if first then
                if not roots[first] then
                    roots[first] = true
                    root_count = root_count + 1
                end
            else
                roots[""] = true
            end
        end
    end

    if has_root_manifest then
        return ""
    end

    local only_root
    if root_count == 1 then
        for name in pairs(roots) do
            if name ~= "" then
                only_root = name
            end
        end
    end

    if only_root and entries_map[(only_root .. "/noizemaker.yaml"):lower()] then
        return only_root
    end

    return nil
end

local function expand_archive(zip_path, destination)
    return platform.extract_archive(zip_path, destination)
end

local function temp_path(base_dir, stem, ext)
    local suffix = tostring(os.time()) .. "_" .. tostring(math.random(1000, 999999))
    ext = ext or ""
    return join_path(base_dir, stem .. "_" .. suffix .. ext)
end

local function paths(base_dir)
    local root = normalize_slashes(base_dir or ".")
    return {
        root = root,
        mods_dir = join_path(root, "mods"),
        backups_dir = join_path(root, "backups"),
        backups_original_dir = join_path(join_path(root, "backups"), "original"),
        state_path = join_path(join_path(root, "mods"), "mods_state.ini"),
    }
end

local function manifest_from_directory(root_dir, state)
    local manifest_path = join_path(root_dir, "noizemaker.yaml")
    local raw = read_all(manifest_path)
    if raw == nil then
        return nil, "missing noizemaker.yaml"
    end
    local manifest, err = M.parse_manifest(raw)
    if not manifest then
        return nil, err
    end
    manifest.folder_name = basename(root_dir)
    manifest.root_path = root_dir
    manifest.files_path = join_path(root_dir, "files")
    manifest.manifest_path = manifest_path
    manifest.enabled = (state.enabled or {})[manifest.folder_name:lower()] == true or (state.enabled or {})[manifest.folder_name] == true
    return manifest
end

function M.parse_manifest(text)
    local manifest = { changed_files = {} }
    local current_list

    for _, raw_line in ipairs(split_lines(text or "")) do
        local line = raw_line:gsub("\t", "    ")
        local stripped = trim(line)
        if stripped ~= "" and not stripped:match("^#") then
            local list_item = stripped:match("^%-%s*(.+)$")
            if current_list == "changed_files" and list_item then
                manifest.changed_files[#manifest.changed_files + 1] = normalize_slashes(unquote(trim(list_item)))
            else
                current_list = nil
                local key, value = stripped:match("^([%w_]+)%s*:%s*(.*)$")
                if key then
                    if key == "changed_files" then
                        manifest.changed_files = manifest.changed_files or {}
                        if trim(value) ~= "" then
                            return nil, "changed_files must be written as a YAML list."
                        end
                        current_list = "changed_files"
                    else
                        manifest[key] = unquote(trim(value))
                    end
                end
            end
        end
    end

    if trim(manifest.name or "") == "" then
        return nil, "Manifest is missing required field: name"
    end
    if trim(manifest.version or "") == "" then
        return nil, "Manifest is missing required field: version"
    end
    if trim(manifest.description or "") == "" then
        return nil, "Manifest is missing required field: description"
    end
    if not manifest.changed_files or #manifest.changed_files == 0 then
        return nil, "Manifest is missing required field: changed_files"
    end

    for i = 1, #manifest.changed_files do
        local rel = manifest.changed_files[i]
        if not is_safe_relative_path(rel) then
            return nil, "Manifest changed_files contains an invalid path: " .. tostring(rel)
        end
    end

    return manifest
end

function M.paths(base_dir)
    return paths(base_dir)
end

function M.ensure_environment(base_dir)
    local p = paths(base_dir)
    return ensure_dir(p.mods_dir) and ensure_dir(p.backups_dir) and ensure_dir(p.backups_original_dir)
end

function M.list_installed_mods(base_dir)
    local p = paths(base_dir)
    M.ensure_environment(base_dir)
    local state = load_state(p.state_path)
    local items = {}
    local dirs = list_directories(p.mods_dir)
    for i = 1, #dirs do
        local folder_name = dirs[i]
        local mod_root = join_path(p.mods_dir, folder_name)
        local manifest, err = manifest_from_directory(mod_root, state)
        if manifest then
            items[#items + 1] = manifest
        else
            items[#items + 1] = {
                folder_name = folder_name,
                root_path = mod_root,
                files_path = join_path(mod_root, "files"),
                enabled = false,
                invalid = true,
                invalid_reason = err,
                name = folder_name,
                version = "?",
                description = "Invalid mod install.",
                changed_files = {},
            }
        end
    end
    table.sort(items, function(a, b)
        return (a.name or a.folder_name or ""):lower() < (b.name or b.folder_name or ""):lower()
    end)
    return items
end

function M.install_zip(zip_path, base_dir)
    local p = paths(base_dir)
    if not M.ensure_environment(base_dir) then
        return nil, "Could not create mods/backups directories."
    end
    if not zip_path or zip_path == "" or not file_exists(zip_path) then
        return nil, "Zip file not found."
    end
    if basename(zip_path):lower():sub(-4) ~= ".zip" then
        return nil, "Only .zip mod packages are supported."
    end

    local entries = archive_entries(zip_path)
    if #entries == 0 then
        return nil, "Zip archive is empty or could not be read."
    end

    for i = 1, #entries do
        if not is_safe_relative_path(entries[i]) then
            return nil, "Zip archive contains an unsafe path: " .. entries[i]
        end
    end

    local prefix = archive_root_prefix(entries)
    if prefix == nil then
        return nil, "Zip must contain noizemaker.yaml at the root or inside a single top-level folder."
    end

    local temp_dir = temp_path(p.mods_dir, "__install_tmp")
    local temp_zip_dir = temp_dir
    if not expand_archive(zip_path, temp_zip_dir) then
        remove_dir(temp_zip_dir)
        return nil, "Failed to extract zip archive."
    end

    local base_root = prefix == "" and temp_zip_dir or join_path(temp_zip_dir, prefix)
    local manifest_path = join_path(base_root, "noizemaker.yaml")
    local manifest_raw = read_all(manifest_path)
    if manifest_raw == nil then
        remove_dir(temp_zip_dir)
        return nil, "Missing noizemaker.yaml in extracted mod."
    end

    local manifest, err = M.parse_manifest(manifest_raw)
    if not manifest then
        remove_dir(temp_zip_dir)
        return nil, err
    end

    local files_root = join_path(base_root, "files")
    if not directory_exists(files_root) then
        remove_dir(temp_zip_dir)
        return nil, "Mod is missing the required files/ directory."
    end

    for i = 1, #manifest.changed_files do
        local rel = manifest.changed_files[i]
        if not file_exists(join_path(files_root, rel)) then
            remove_dir(temp_zip_dir)
            return nil, "Mod lists a changed file that is missing from files/: " .. rel
        end
    end

    local folder_name = unique_folder_name(p.mods_dir, manifest.name ~= "" and manifest.name or basename_no_ext(zip_path))
    local final_root = join_path(p.mods_dir, folder_name)
    if not ensure_dir(final_root) then
        remove_dir(temp_zip_dir)
        return nil, "Could not create mod install directory."
    end

    local ok, copy_err = copy_tree(base_root, final_root)
    remove_dir(temp_zip_dir)
    if not ok then
        remove_dir(final_root)
        return nil, copy_err
    end

    local state = load_state(p.state_path)
    local installed, load_err = manifest_from_directory(final_root, state)
    if not installed then
        remove_dir(final_root)
        return nil, load_err
    end
    return installed
end

function M.install_zip_bytes(filename, data, base_dir)
    local p = paths(base_dir)
    if not M.ensure_environment(base_dir) then
        return nil, "Could not create mods/backups directories."
    end

    local temp_zip = temp_path(p.mods_dir, basename_no_ext(filename or "dropped_mod"), ".zip")
    if not write_all(temp_zip, data or "") then
        return nil, "Could not store dropped zip file."
    end

    local installed, err = M.install_zip(temp_zip, base_dir)
    remove_file(temp_zip)
    return installed, err
end

function M.enable_mod(mod_name, game_root, base_dir)
    local p = paths(base_dir)
    if not valid_game_root(game_root) then
        return nil, "Invalid game root."
    end

    local mods = M.list_installed_mods(base_dir)
    local target
    for i = 1, #mods do
        if mods[i].folder_name == mod_name then
            target = mods[i]
            break
        end
    end
    if not target then
        return nil, "Mod not found."
    end
    if target.invalid then
        return nil, "Cannot enable an invalid mod install."
    end
    if target.enabled then
        return target
    end

    local conflicts = detect_conflicts_for_mod(target, mods)
    if #conflicts > 0 then
        local names = {}
        for i = 1, #conflicts do
            names[#names + 1] = conflicts[i].name
        end
        table.sort(names)
        return nil, "Mod conflicts with enabled mod(s): " .. table.concat(names, ", ")
    end

    for i = 1, #target.changed_files do
        local rel = target.changed_files[i]
        local src = join_path(target.files_path, rel)
        local dst = join_path(game_root, rel)
        local backup = join_path(p.backups_original_dir, rel)
        if file_exists(dst) and not file_exists(backup) then
            local ok, err = copy_file(dst, backup)
            if not ok then
                return nil, "Backup failed for " .. rel .. ": " .. err
            end
        end
        local ok, err = copy_file(src, dst)
        if not ok then
            return nil, "File copy failed for " .. rel .. ": " .. err
        end
    end

    local state = load_state(p.state_path)
    state.enabled[target.folder_name] = true
    if not save_state(p.state_path, state) then
        return nil, "Could not update mods state."
    end
    target.enabled = true
    return target
end

function M.disable_mod(mod_name, game_root, base_dir)
    local p = paths(base_dir)
    if not valid_game_root(game_root) then
        return nil, "Invalid game root."
    end

    local mods = M.list_installed_mods(base_dir)
    local target
    for i = 1, #mods do
        if mods[i].folder_name == mod_name then
            target = mods[i]
            break
        end
    end
    if not target then
        return nil, "Mod not found."
    end

    for i = 1, #target.changed_files do
        local rel = target.changed_files[i]
        local backup = join_path(p.backups_original_dir, rel)
        local dst = join_path(game_root, rel)
        if file_exists(backup) then
            local ok, err = copy_file(backup, dst)
            if not ok then
                return nil, "Failed to restore backup for " .. rel .. ": " .. err
            end
        else
            local ok = remove_file(dst)
            if not ok then
                return nil, "Failed to remove modded file without backup: " .. rel
            end
        end
    end

    local state = load_state(p.state_path)
    state.enabled[target.folder_name] = nil
    if not save_state(p.state_path, state) then
        return nil, "Could not update mods state."
    end
    target.enabled = false
    return target
end

function M.uninstall_mod(mod_name, game_root, base_dir)
    local p = paths(base_dir)
    local mods = M.list_installed_mods(base_dir)
    local target
    for i = 1, #mods do
        if mods[i].folder_name == mod_name then
            target = mods[i]
            break
        end
    end
    if not target then
        return nil, "Mod not found."
    end

    if target.enabled then
        local _, err = M.disable_mod(mod_name, game_root, base_dir)
        if err then
            return nil, err
        end
    end

    if not remove_dir(target.root_path) then
        return nil, "Could not remove mod folder."
    end

    local state = load_state(p.state_path)
    state.enabled[mod_name] = nil
    if not save_state(p.state_path, state) then
        return nil, "Could not update mods state."
    end

    return true
end

function M.restore_originals(game_root, base_dir)
    local p = paths(base_dir)
    if not valid_game_root(game_root) then
        return nil, "Invalid game root."
    end

    local mods = M.list_installed_mods(base_dir)
    for i = 1, #mods do
        local mod = mods[i]
        if mod.enabled then
            for j = 1, #mod.changed_files do
                local rel = mod.changed_files[j]
                local backup = join_path(p.backups_original_dir, rel)
                if not file_exists(backup) then
                    local dst = join_path(game_root, rel)
                    local ok = remove_file(dst)
                    if not ok then
                        return nil, "Failed to remove generated mod file: " .. rel
                    end
                end
            end
        end
    end

    local backups = list_files_recursive(p.backups_original_dir)
    for i = 1, #backups do
        local rel = backups[i]
        local ok, err = copy_file(join_path(p.backups_original_dir, rel), join_path(game_root, rel))
        if not ok then
            return nil, "Failed to restore original file " .. rel .. ": " .. err
        end
    end

    if not save_state(p.state_path, { enabled = {} }) then
        return nil, "Could not reset mods state."
    end

    return true
end

function M.conflicts_for_mod(mod_name, base_dir)
    local mods = M.list_installed_mods(base_dir)
    local target
    for i = 1, #mods do
        if mods[i].folder_name == mod_name then
            target = mods[i]
            break
        end
    end
    if not target then
        return nil, "Mod not found."
    end
    return detect_conflicts_for_mod(target, mods)
end

return M
