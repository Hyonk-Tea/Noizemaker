local format = require("core.format")
local rebuild = require("core.rebuild")
local rules = require("core.rules")
local modcore = require("core.mods")
local noize = require("core.noize")
local platform = require("core.platform")
local gamebanana = require("core.gamebanana")
local theme = require("ui.theme")
local widgets = require("ui.widgets")
local tree = require("ui.tree")
local timeline = require("ui.timeline")
local mods_tab = require("ui.mods_tab")

local App = {}
App.__index = App

local SNAP_MODES = { 1, 2, 6, 24 }
local VIEW_TRANSITION_DURATION = 0.18
local VIEW_TRANSITION_SLIDE = 28
local MODAL_ANIM_DURATION = 0.14
local MODAL_ANIM_OFFSET = 12
local MENU_BUTTON_W = 248
local MENU_BUTTON_H = 48
local MENU_BUTTON_GAP = 14
local RECENT_FILE_LIMIT = 8
local RECENT_RELEASE_LIMIT = 2

local MOVE_BUTTONS = {
    { label = "UP", code = format.GAME_TO_INTERNAL.UP },
    { label = "DOWN", code = format.GAME_TO_INTERNAL.DOWN },
    { label = "LEFT", code = format.GAME_TO_INTERNAL.LEFT },
    { label = "RIGHT", code = format.GAME_TO_INTERNAL.RIGHT },
    { label = "CHU", code = format.INV.CHU },
    { label = "HEY", code = format.INV.HEY },
    { label = "REST", code = format.INV.REST },
    { label = "HOLDUP", code = format.INV.HOLDUP },
    { label = "HOLDDOWN", code = format.INV.HOLDDOWN },
    { label = "HOLDLEFT", code = format.INV.HOLDLEFT },
    { label = "HOLDRIGHT", code = format.INV.HOLDRIGHT },
    { label = "HOLDCHU", code = format.INV.HOLDCHU },
    { label = "HOLDHEY", code = format.INV.HOLDHEY },
    { label = "SPECIAL", special = true },
}

local MOVE_BUTTON_ROWS_WIDE = {
    { "UP", "DOWN", "LEFT", "RIGHT", "CHU", "HEY", "REST" },
    { "HOLDUP", "HOLDDOWN", "HOLDLEFT", "HOLDRIGHT", "HOLDCHU", "HOLDHEY", "SPECIAL" },
}

local MOVE_BUTTON_ROWS_COMPACT = {
    { "UP", "DOWN", "LEFT", "RIGHT" },
    { "CHU", "HEY", "HOLDCHU", "HOLDHEY" },
    { "HOLDUP", "HOLDDOWN", "HOLDLEFT", "HOLDRIGHT" },
    { "REST", "SPECIAL" },
}

local SPECIAL_MOVE_CHOICES = {
    { id = "raw", label = "RAW", code = nil, preview_label = nil, color = nil },
    { id = "special_up", label = "Special UP", code = 0x83, preview_label = "Special UP", color = nil },
    { id = "special_down", label = "Special DOWN", code = 0x85, preview_label = "Special DOWN", color = nil },
    { id = "special_right", label = "Special RIGHT", code = 0x84, preview_label = "Special RIGHT", color = nil },
    { id = "special_left", label = "Special LEFT", code = 0x86, preview_label = "Special LEFT", color = nil },
}

local MOVE_CYCLE = {
    format.GAME_TO_INTERNAL.UP,
    format.GAME_TO_INTERNAL.DOWN,
    format.GAME_TO_INTERNAL.LEFT,
    format.GAME_TO_INTERNAL.RIGHT,
    format.INV.CHU,
    format.INV.HEY,
    format.INV.REST,
    format.INV.HOLDUP,
    format.INV.HOLDDOWN,
    format.INV.HOLDLEFT,
    format.INV.HOLDRIGHT,
    format.INV.HOLDCHU,
    format.INV.HOLDHEY,
}

local MOVE_BUTTON_BY_LABEL = {}
for i = 1, #MOVE_BUTTONS do
    MOVE_BUTTON_BY_LABEL[MOVE_BUTTONS[i].label] = MOVE_BUTTONS[i]
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function basename(path)
    return widgets.basename(path or "")
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

local function normalize_slashes(path)
    return (path or ""):gsub("\\", "/")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)[/\\][^/\\]+$") or ""
end

local function filesystem_path_exists(path)
    local fh = io.open(path or "", "rb")
    if fh then
        fh:close()
        return true
    end
    return platform.directory_exists(path or "")
end

local function app_root_path()
    local source = nil
    if love and love.filesystem and love.filesystem.getSource then
        local raw_source = love.filesystem.getSource()
        if raw_source and raw_source ~= "" then
            source = normalize_slashes(raw_source)
            if not source:match("^[A-Za-z]:[/\\]") and source:sub(1, 1) ~= "/" then
                local base_dir = love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory() or ""
                if base_dir ~= "" then
                    source = normalize_slashes(join_path(base_dir, source))
                end
            end
        end
    end

    if source and source ~= "" then
        if platform.directory_exists(source) then
            return source
        end
        local source_dir = dirname(source)
        if source_dir ~= "" and platform.directory_exists(source_dir) then
            return normalize_slashes(source_dir)
        end
    end

    if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
        local base_dir = normalize_slashes(love.filesystem.getSourceBaseDirectory() or "")
        if base_dir ~= "" and platform.directory_exists(base_dir) then
            return base_dir
        end
    end

    return normalize_slashes(".")
end

local function parse_ini(path)
    local fh = io.open(path, "r")
    if not fh then
        return nil
    end

    local data = {}
    local current_section = "default"
    data[current_section] = {}

    for line in fh:lines() do
        local stripped = trim(line)
        if stripped ~= "" and not stripped:match("^[;#]") then
            local section = stripped:match("^%[(.-)%]$")
            if section then
                current_section = section:lower()
                if not data[current_section] then
                    data[current_section] = {}
                end
            else
                local key, value = stripped:match("^([^=]+)=(.*)$")
                if key and value then
                    data[current_section][trim(key):lower()] = trim(value)
                end
            end
        end
    end

    fh:close()
    return data
end

local function write_config(path, game_root, noize_prompt_preference, recent_files, gamebanana_previews_preference)
    local fh = io.open(path, "w")
    if not fh then
        return false
    end
    if game_root and game_root ~= "" then
        fh:write("[paths]\n")
        fh:write("game_root = ", normalize_slashes(game_root), "\n\n")
    end
    fh:write("[noize]\n")
    fh:write("prompt = ", trim(noize_prompt_preference or "ask"), "\n")
    fh:write("\n[gamebanana]\n")
    fh:write("previews = ", trim(gamebanana_previews_preference or "ask"), "\n")
    if recent_files and #recent_files > 0 then
        fh:write("\n[recent_files]\n")
        for i = 1, #recent_files do
            fh:write("file", i, " = ", normalize_slashes(recent_files[i]), "\n")
        end
    end
    fh:close()
    return true
end

local function choose_folder(initial_path)
    return platform.choose_folder(initial_path)
end

local function choose_file(initial_dir)
    return platform.choose_open_file("Open DGSH rhythm file", "DGSH binaries (*.bin)|*.bin|All files (*.*)|*.*", initial_dir)
end

local function choose_zip_file(initial_dir)
    return platform.choose_open_file("Install Noizemaker Mod", "Zip archives (*.zip)|*.zip|All files (*.*)|*.*", initial_dir)
end

local function choose_save_file(initial_dir, suggested_name)
    return platform.choose_save_file("Patch Copy", "DGSH binaries (*.bin)|*.bin|All files (*.*)|*.*", initial_dir, suggested_name)
end

local function valid_game_root(path)
    if not path or path == "" then
        return false
    end
    local file = io.open(join_path(path, "R1.BIN"), "rb")
    if file then
        file:close()
        return true
    end
    file = io.open(join_path(path, "r1.bin"), "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function read_binary(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function write_binary(path, data)
    local fh = io.open(path, "wb")
    if not fh then
        return false
    end
    fh:write(data)
    fh:close()
    return true
end

local function clone_list(list)
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    return out
end

local function clone_steps(steps)
    local out = {}
    for i = 1, #steps do
        out[i] = format.Step.new(steps[i].code, steps[i].gap)
    end
    return out
end

local function snapshot_from_work(work)
    return {
        steps = clone_steps(work.steps),
        anim_indices = clone_list(work.anim_indices),
        start_delay = work.start_delay,
        timing = work.timing,
    }
end

local function step_cycle_index(code)
    for i = 1, #MOVE_CYCLE do
        if MOVE_CYCLE[i] == code then
            return i
        end
    end
    return nil
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function snap_scale(value, step, min_value)
    local unit = step or 0.5
    local snapped = math.floor((value / unit) + 0.5) * unit
    if min_value and snapped < min_value then
        return min_value
    end
    return snapped
end

local function clamp_text_lines(font, text, width, max_lines)
    local value = trim(tostring(text or ""))
    if value == "" or width <= 0 or max_lines <= 0 then
        return value
    end

    local _, wrapped = font:getWrap(value, width)
    if #wrapped <= max_lines then
        return value
    end

    local words = {}
    for word in value:gmatch("%S+") do
        words[#words + 1] = word
    end
    if #words == 0 then
        return value
    end

    local best = ""
    for i = 1, #words do
        local candidate = table.concat(words, " ", 1, i)
        local _, lines = font:getWrap(candidate, width)
        if #lines > max_lines then
            break
        end
        best = candidate
    end

    if best == "" then
        best = words[1]
        while #best > 1 do
            local candidate = best:sub(1, -2) .. "..."
            local _, lines = font:getWrap(candidate, width)
            if #lines <= max_lines then
                return candidate
            end
            best = best:sub(1, -2)
        end
        return "..."
    end

    local ellipsized = best .. "..."
    local _, lines = font:getWrap(ellipsized, width)
    if #lines <= max_lines then
        return ellipsized
    end

    while #best > 1 do
        best = best:gsub("%s*%S+$", "")
        if best == "" then
            break
        end
        ellipsized = best .. "..."
        _, lines = font:getWrap(ellipsized, width)
        if #lines <= max_lines then
            return ellipsized
        end
    end

    best = value
    while #best > 1 do
        best = best:sub(1, -2)
        ellipsized = best .. "..."
        _, lines = font:getWrap(ellipsized, width)
        if #lines <= max_lines then
            return ellipsized
        end
    end

    return "..."
end

local function ease_out_cubic(t)
    t = clamp(t or 0, 0, 1)
    local inv = 1 - t
    return 1 - inv * inv * inv
end

local function has_base_family(entry)
    return entry and entry.base and entry.base ~= ""
end

local function file_exists(path)
    local fh = io.open(path or "", "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

local function path_exists(path)
    return file_exists(path) or platform.directory_exists(path or "")
end

local function first_existing_path(paths)
    for i = 1, #paths do
        local candidate = normalize_slashes(paths[i] or "")
        if candidate ~= "" and file_exists(candidate) then
            return candidate
        end
    end
    return nil
end

local function first_step_fixed_message(start_delay)
    if (start_delay or 0) > 0 then
        return "The first step is anchored at Start delay on the timeline. Change Start delay to move it."
    end
    return "The first step is anchored at 0t. Add Start delay if you want space before it."
end

local function resolve_move_rows(layout_rows)
    local rows = {}
    for row_index = 1, #layout_rows do
        rows[row_index] = {}
        for col_index = 1, #layout_rows[row_index] do
            rows[row_index][col_index] = MOVE_BUTTON_BY_LABEL[layout_rows[row_index][col_index]]
        end
    end
    return rows
end

local function style_for_move_button(move, is_armed)
    local style = {
        font = theme.font("tiny"),
    }

    if move.raw or move.special then
        style.fill = theme.colors.amber_soft
        style.hover_fill = { 0.35, 0.24, 0.08, 1.0 }
        style.border = theme.colors.amber
        style.text_color = theme.colors.amber
    elseif move.label == "CHU" or move.label == "HEY" or move.label == "HOLDCHU" or move.label == "HOLDHEY" then
        style.fill = theme.colors.move_pink_fill
        style.hover_fill = theme.colors.move_pink_hover
        style.border = theme.colors.move_pink_border
        style.text_color = { 1.0, 0.82, 0.92, 1.0 }
    elseif move.label:match("^HOLD") then
        style.fill = theme.colors.move_blue_fill
        style.hover_fill = theme.colors.move_blue_hover
        style.border = theme.colors.move_blue_border
        style.text_color = { 0.62, 0.83, 1.0, 1.0 }
    end

    if is_armed then
        style.border = theme.colors.selection
    end

    return style
end

function App.new()
    local root = app_root_path()
    return setmetatable({
        tree = tree.new_state(),
        mods_tab = mods_tab.new_state(),
        timeline_render = nil,
        hovered_button = nil,
        hovered_menu_button = nil,
        status_text = "Ready.",
        active_view = "menu",
        app_root = root,
        config_path = join_path(root, "config.ini"),
        mod_base_dir = root,
        reports_paths = {
            join_path(root, "reports.ini"),
            join_path(root, "legacy_python/reports.ini"),
        },
        current_buffer = nil,
        entries = {},
        entry_lookup = {},
        selected_entry = nil,
        selected_step_index = nil,
        current_work = nil,
        current_validation = { ok = true, warnings = {}, errors = {} },
        current_dirty = false,
        current_file_path = nil,
        current_file_name = "(no file)",
        current_file_dir = root,
        current_patch_path = nil,
        game_root = nil,
        title_font_renderer = nil,
        layout = {},
        installed_mods = {},
        mods = {},
        drafts = {},
        undo_stack = {},
        redo_stack = {},
        drag = nil,
        pending_insert = nil,
        inspector_hits = {},
        controls_hits = {},
        modal_hits = {},
        menu_hits = {},
        header_hits = {},
        recent_hits = {},
        release_hits = {},
        modal = nil,
        modal_anim = nil,
        snap_index = 1,
        launch_args = {},
        view_transition = nil,
        view_canvases = {},
        toolbar_visible = false,
        noize_protocol_prompt_preference = "ask",
        noize_protocol_prompt_shown = false,
        noize_protocol_registration_attempted = false,
        gamebanana_previews_preference = "ask",
        recent_files = {},
        ui_images = {},
        release_feed = { status = "idle", items = {}, error = nil, from_cache = false },
        release_images = {},
        release_cache_dir = join_path(root, "cache/gamebanana"),
    }, App)
end

function App:load(args)
    theme.init()
    self.launch_args = args or {}
    self:load_config()
    self:load_ui_assets()
    self:refresh_optional_assets()
    modcore.ensure_environment(self.mod_base_dir)
    self:refresh_installed_mods()
    if not valid_game_root(self.game_root) then
        self:prompt_for_game_root()
    end
    self:resize(love.graphics.getWidth(), love.graphics.getHeight())
    self:handle_launch_args(self.launch_args)
    if self.active_view == "menu" then
        self:ensure_recent_releases_loaded()
    end
end

function App:update(dt)
    self:update_animations(dt or 0)
    self:update_hover_state()
end

function App:update_animations(dt)
    if self.view_transition then
        local transition = self.view_transition
        transition.t = math.min(transition.duration, transition.t + dt)
        if transition.t >= transition.duration then
            self.view_transition = nil
        end
    end

    if self.modal and self.modal_anim then
        self.modal_anim.t = math.min(self.modal_anim.duration, self.modal_anim.t + dt)
    end
end

function App:update_hover_state()
    self.hovered_button = nil
    self.hovered_menu_button = nil
    local mx, my = love.mouse.getPosition()
    if self.active_view == "menu" then
        for i = 1, #self.header_hits do
            local hit = self.header_hits[i]
            if widgets.point_in_rect(mx, my, hit.rect) then
                self.hovered_button = hit.kind == "back" and "header_back" or ("header_" .. hit.id)
                return
            end
        end
        for i = 1, #self.menu_hits do
            local hit = self.menu_hits[i]
            if widgets.point_in_rect(mx, my, hit.rect) then
                self.hovered_menu_button = hit.id
                return
            end
        end
        for i = 1, #self.recent_hits do
            local hit = self.recent_hits[i]
            if widgets.point_in_rect(mx, my, hit.rect) then
                self.hovered_button = "recent_" .. i
                return
            end
        end
        for i = 1, #self.release_hits do
            local hit = self.release_hits[i]
            if widgets.point_in_rect(mx, my, hit.rect) then
                self.hovered_button = hit.id
                return
            end
        end
        return
    end
    for i = 1, #self.header_hits do
        local hit = self.header_hits[i]
        if widgets.point_in_rect(mx, my, hit.rect) then
            self.hovered_button = hit.kind == "back" and "header_back" or ("header_" .. hit.id)
            return
        end
    end
    if self.active_view ~= "editor" then
        return
    end
    local buttons = self:buttons()
    for key, rect in pairs(buttons) do
        if widgets.point_in_rect(mx, my, rect) then
            self.hovered_button = key
            break
        end
    end
end

function App:refresh_installed_mods()
    self.installed_mods = modcore.list_installed_mods(self.mod_base_dir)
    mods_tab.sync_selection(self.mods_tab, self.installed_mods)
end

function App:add_recent_file(path)
    local normalized = normalize_slashes(path or "")
    if normalized == "" then
        return
    end

    local updated = { normalized }
    for i = 1, #self.recent_files do
        if self.recent_files[i] ~= normalized then
            updated[#updated + 1] = self.recent_files[i]
        end
        if #updated >= RECENT_FILE_LIMIT then
            break
        end
    end
    self.recent_files = updated
    self:save_config()
end

function App:load_config()
    local cfg = parse_ini(self.config_path)
    if cfg and cfg.paths and cfg.paths.game_root then
        self.game_root = normalize_slashes(cfg.paths.game_root)
    end
    if cfg and cfg.noize and cfg.noize.prompt and cfg.noize.prompt ~= "" then
        self.noize_protocol_prompt_preference = trim(cfg.noize.prompt):lower()
    end
    if cfg and cfg.gamebanana and cfg.gamebanana.previews and cfg.gamebanana.previews ~= "" then
        self.gamebanana_previews_preference = trim(cfg.gamebanana.previews):lower()
    end
    self.recent_files = {}
    if cfg and cfg.recent_files then
        local indexed = {}
        for key, value in pairs(cfg.recent_files) do
            local index = tonumber(key:match("^file(%d+)$"))
            if index and value and value ~= "" then
                indexed[#indexed + 1] = {
                    index = index,
                    value = normalize_slashes(value),
                }
            end
        end
        table.sort(indexed, function(a, b)
            return a.index < b.index
        end)
        for i = 1, #indexed do
            self.recent_files[#self.recent_files + 1] = indexed[i].value
        end
    end
end

function App:save_config()
    write_config(self.config_path, self.game_root, self.noize_protocol_prompt_preference, self.recent_files, self.gamebanana_previews_preference)
end

function App:refresh_optional_assets()
    self.title_font_renderer = nil
    if self.game_root and valid_game_root(self.game_root) then
        self.title_font_renderer = widgets.try_load_bitmap_title(join_path(self.game_root, "font/font_ulala_blue.tga"))
    end
end

function App:load_ui_assets()
    self.ui_images = {}
    local names = {
        "noizemaker.png",
        "sc5logo.png",
        "sc5gear.png",
        "noizemaker_icon.png",
    }
    for i = 1, #names do
        local path = "assets/" .. names[i]
        if love.filesystem.getInfo(path) then
            local ok, image = pcall(love.graphics.newImage, path)
            if ok and image then
                image:setFilter("nearest", "nearest")
                self.ui_images[names[i]] = image
            end
        end
    end
end

function App:load_release_image(path, key)
    local bytes = read_binary(path)
    if not bytes or bytes == "" then
        return nil
    end

    local ok, image = pcall(function()
        local filedata = love.filesystem.newFileData(bytes, basename(path))
        local imagedata = love.image.newImageData(filedata)
        local loaded = love.graphics.newImage(imagedata)
        loaded:setFilter("linear", "linear")
        return loaded
    end)
    if ok and image then
        self.release_images[key] = image
        return image
    end
    return nil
end

function App:load_modal_image(path)
    local bytes = read_binary(path)
    if not bytes or bytes == "" then
        return nil
    end

    local ok, image = pcall(function()
        local filedata = love.filesystem.newFileData(bytes, basename(path))
        local imagedata = love.image.newImageData(filedata)
        local loaded = love.graphics.newImage(imagedata)
        loaded:setFilter("linear", "linear")
        return loaded
    end)
    if ok and image then
        return image
    end
    return nil
end

function App:refresh_recent_releases(force)
    if self.gamebanana_previews_preference ~= "enabled" then
        self.release_feed = {
            status = "disabled",
            items = {},
            error = nil,
            from_cache = false,
        }
        self.release_images = {}
        return
    end
    if self.release_feed.status == "loading" then
        return
    end
    if not force and self.release_feed.status == "ready" and #self.release_feed.items > 0 then
        return
    end

    self.release_feed.status = "loading"
    self.release_feed.error = nil

    local feed, err = gamebanana.fetch_recent_mods(self.release_cache_dir, RECENT_RELEASE_LIMIT)
    if not feed then
        self.release_feed = {
            status = "error",
            items = {},
            error = err or "Recent GameBanana releases could not be loaded.",
            from_cache = false,
        }
        return
    end

    self.release_feed = {
        status = "ready",
        items = feed.items or {},
        error = nil,
        from_cache = feed.from_cache or false,
    }
    self.release_images = {}
    for i = 1, #self.release_feed.items do
        local item = self.release_feed.items[i]
        local path = gamebanana.cache_preview_image(item, self.release_cache_dir)
        if path then
            self:load_release_image(path, tostring(item.id))
        end
    end
end

function App:ensure_recent_releases_loaded()
    if self.gamebanana_previews_preference ~= "enabled" then
        return
    end
    if self.release_feed.status == "idle" then
        self:refresh_recent_releases(false)
    end
end

function App:prompt_gamebanana_previews()
    self:show_modal({
        title = "Enable GameBanana previews?",
        message = table.concat({
            "Noizemaker can show recent Space Channel 5 Part 2 mod releases from GameBanana on the main menu.",
            "",
            "This downloads a small feed and preview images, then caches them for 60 minutes.",
        }, "\n"),
        kind = "info",
        dismiss_id = "later",
        buttons = {
            { id = "later", label = "Not now" },
            { id = "never", label = "Never" },
            { id = "enable", label = "Enable", primary = true },
        },
        on_result = function(result_id)
            if result_id == "enable" then
                self.gamebanana_previews_preference = "enabled"
                self:save_config()
                self.status_text = "Enabled GameBanana previews."
                self:refresh_recent_releases(true)
            elseif result_id == "never" then
                self.gamebanana_previews_preference = "never"
                self:save_config()
                self.status_text = "GameBanana previews disabled."
            else
                self.status_text = "GameBanana previews skipped for now."
            end
        end,
    })
end

function App:prompt_for_game_root()
    local chosen = choose_folder(self.game_root)
    if chosen and valid_game_root(chosen) then
        self.game_root = normalize_slashes(chosen)
        self:save_config()
        self:refresh_optional_assets()
        self.status_text = "Game root set."
    else
        self.status_text = "Game root not set. Optional assets may be unavailable."
    end
end

function App:protocol_launch_target()
    local source = self.app_root

    local executable
    if love and love.filesystem and love.filesystem.getExecutablePath then
        local raw_executable = love.filesystem.getExecutablePath()
        if raw_executable and raw_executable ~= "" then
            executable = raw_executable
        end
    end
    if not executable or executable == "" then
        executable = os.getenv("APPIMAGE")
    end
    if not executable or executable == "" then
        executable = (arg and arg[0]) or nil
    end
    executable = normalize_slashes(executable or "")

    if executable == "" or not file_exists(executable) then
        local fallback = platform.find_command_path("love")
        if not fallback and package.config:sub(1, 1) == "\\" then
            fallback = first_existing_path({
                "C:/Program Files/LOVE/love.exe",
                "C:/Program Files (x86)/LOVE/love.exe",
            })
        end
        executable = fallback or ""
    end

    if executable == "" then
        return nil, "Noizemaker could not find a launchable executable for noize:// registration."
    end
    if not file_exists(executable) then
        return nil, "Noizemaker resolved a launch command, but the executable path does not exist: " .. executable
    end

    if source and source ~= "" and not filesystem_path_exists(source) then
        source = nil
    end

    local lower_exe = executable:lower()
    if source and source ~= "" and filesystem_path_exists(source) and source:lower() ~= lower_exe and (lower_exe:match("love%.exe$") or lower_exe:match("/love$")) then
        return {
            executable = executable,
            source = source,
        }
    end

    return {
        executable = executable,
    }
end

function App:find_game_executable()
    if not valid_game_root(self.game_root) then
        return nil
    end

    local candidates = {
        "Space Channel 5 Part 2.exe",
        "AppLauncher.exe",
    }
    for i = 1, #candidates do
        local candidate = join_path(self.game_root, candidates[i])
        if file_exists(candidate) then
            return candidate
        end
    end
    return nil
end

function App:launch_game()
    self:show_info("Launch", "Whoops, this feature is not implemented yet. Sorry about that.")
    return false
end

function App:ensure_noize_protocol_registration()
    local launch, err = self:protocol_launch_target()
    if not launch then
        return false, err or "Noizemaker could not determine how to relaunch itself."
    end
    local ok = platform.register_url_protocol("noize", launch, "Noizemaker")
    if not ok then
        return false, "Noizemaker could not write the noize:// protocol association."
    end
    return true
end

function App:ensure_noize_protocol_registration_once()
    if self.noize_protocol_registration_attempted then
        return true
    end
    local ok, err = self:ensure_noize_protocol_registration()
    if ok then
        self.noize_protocol_registration_attempted = true
    end
    return ok, err
end

function App:build_work_from_entry(entry)
    return {
        steps = clone_steps(entry:as_step_list()),
        anim_indices = clone_list(entry:get_anim_indices()),
        start_delay = entry.start_delay,
        timing = entry.timing,
    }
end

function App:build_work_from_mod(mod)
    return {
        steps = clone_steps(mod.steps),
        anim_indices = clone_list(mod.anim_indices or {}),
        start_delay = mod.start_delay,
        timing = mod.timing,
    }
end

function App:build_preview_entry(entry, work)
    local preview = {
        name = entry.name,
        base = entry.base,
        sc = #work.steps,
        steps = {},
        hits = {},
        timing = work.timing,
        start_delay = work.start_delay,
        ff_prefix_count = entry.ff_prefix_count,
        rest_body = entry.rest_body,
    }

    for i = 1, #work.steps do
        preview.steps[i] = work.steps[i].code
        if i < #work.steps then
            preview.hits[i] = work.steps[i].gap
        end
    end

    return preview
end

function App:entries_with_base(base_name)
    local matches = {}
    for i = 1, #self.entries do
        local entry = self.entries[i]
        if entry.base == base_name then
            matches[#matches + 1] = entry
        end
    end
    return matches
end

function App:selected_root_variants()
    if not has_base_family(self.selected_entry) then
        return {}
    end

    local variants = {}
    local siblings = self:entries_with_base(self.selected_entry.base)
    for i = 1, #siblings do
        if siblings[i].name ~= self.selected_entry.name then
            variants[#variants + 1] = siblings[i]
        end
    end
    return variants
end

function App:work_equals_original(entry, work)
    local original_steps = entry:as_step_list()
    if #original_steps ~= #work.steps then
        return false
    end
    if entry.start_delay ~= work.start_delay then
        return false
    end
    if entry.timing ~= work.timing then
        return false
    end

    local original_anim = entry:get_anim_indices()
    if #original_anim ~= #work.anim_indices then
        return false
    end
    for i = 1, #original_anim do
        if original_anim[i] ~= work.anim_indices[i] then
            return false
        end
    end

    for i = 1, #original_steps do
        if original_steps[i].code ~= work.steps[i].code then
            return false
        end
        if original_steps[i].gap ~= work.steps[i].gap then
            return false
        end
    end

    return true
end

function App:validate_work(entry, work)
    return rules.validate_mod(entry, work.steps, {
        anim_indices = work.anim_indices,
        start_delay = work.start_delay,
        timing = work.timing,
    })
end

function App:update_draft_from_current()
    if not self.selected_entry or not self.current_work then
        return
    end

    local name = self.selected_entry.name
    local validation = self.current_validation or self:validate_work(self.selected_entry, self.current_work)
    self.current_validation = validation
    self.current_dirty = not self:work_equals_original(self.selected_entry, self.current_work)

    self.drafts[name] = {
        steps = clone_steps(self.current_work.steps),
        anim_indices = clone_list(self.current_work.anim_indices),
        start_delay = self.current_work.start_delay,
        timing = self.current_work.timing,
        validation = validation,
        modified = self.current_dirty,
    }
end

function App:load_work_for_entry(entry)
    self.selected_entry = entry
    self.selected_step_index = nil
    self.undo_stack = {}
    self.redo_stack = {}
    self.drag = nil
    self.pending_insert = nil

    local name = entry.name
    if self.drafts[name] then
        self.current_work = self:build_work_from_mod(self.drafts[name])
        self.current_validation = self.drafts[name].validation or self:validate_work(entry, self.current_work)
    elseif self.mods[name] then
        self.current_work = self:build_work_from_mod(self.mods[name])
        self.current_validation = self:validate_work(entry, self.current_work)
    else
        self.current_work = self:build_work_from_entry(entry)
        self.current_validation = self:validate_work(entry, self.current_work)
    end

    if self.current_work.timing == nil then
        self.current_work.timing = entry.timing
    end

    self.current_dirty = not self:work_equals_original(entry, self.current_work)
    self:update_draft_from_current()
end

function App:rebuild_tree_groups()
    local groups = tree.build_groups(self.entries, self.current_file_path, self.reports_paths, self.tree.collapse_state)
    tree.set_groups(self.tree, groups)
end

function App:open_file(path)
    if not path or path == "" then
        return
    end

    local data = read_binary(path)
    if not data then
        self.status_text = "Failed to read file: " .. basename(path)
        return
    end

    local ok, parsed = pcall(format.parse, data)
    if not ok then
        self:show_error("Open failed", tostring(parsed))
        self.status_text = "Open failed."
        return
    end

    self.current_buffer = data
    self.entries = parsed
    self.entry_lookup = {}
    for _, entry in ipairs(parsed) do
        self.entry_lookup[entry.name] = entry
    end

    self.mods = {}
    self.drafts = {}
    self.undo_stack = {}
    self.redo_stack = {}
    self.drag = nil
    self.pending_insert = nil
    self.current_file_path = normalize_slashes(path)
    self.current_file_name = basename(path)
    self.current_file_dir = normalize_slashes(path:match("^(.*)[/\\][^/\\]+$") or ".")
    self.current_patch_path = nil
    self:add_recent_file(path)
    self:rebuild_tree_groups()
    if self.entries[1] then
        self:load_work_for_entry(self.entries[1])
    else
        self.selected_entry = nil
        self.current_work = nil
        self.current_validation = { ok = true, warnings = {}, errors = {} }
        self.current_dirty = false
    end
    self.status_text = string.format("Loaded %s (%d entries).", self.current_file_name, #self.entries)
end

function App:select_entry(entry)
    self:load_work_for_entry(entry)
end

function App:open_file_dialog()
    local start_dir = self.game_root or self.current_file_dir or "."
    local chosen = choose_file(start_dir)
    if chosen then
        self:open_file(chosen)
    end
end

function App:selected_installed_mod()
    return mods_tab.selected_mod(self.mods_tab, self.installed_mods)
end

function App:switch_view(view_name)
    local target = view_name or "editor"
    if target == self.active_view and not self.view_transition then
        return
    end

    local previous = self.active_view or "editor"
    self.active_view = target
    if previous ~= target then
        self.view_transition = {
            from = previous,
            to = target,
            t = 0,
            duration = VIEW_TRANSITION_DURATION,
        }
    else
        self.view_transition = nil
    end
    if target == "menu" then
        self:ensure_recent_releases_loaded()
    end
    self.pending_insert = nil
end

function App:prompt_noize_protocol_registration()
    if self.noize_protocol_prompt_preference == "never" or self.noize_protocol_prompt_preference == "registered" then
        self:switch_view("mods")
        return
    end

    if self.noize_protocol_prompt_shown then
        self:switch_view("mods")
        return
    end

    self.noize_protocol_prompt_shown = true
    self:show_modal({
        title = "Register `noize://` links for GameBanana One-Click support?",
        message = table.concat({
            "Noizemaker can register the noize:// link so GameBanana one-click installs open directly in the app.",
            "",
            "Register it now?",
        }, "\n"),
        kind = "info",
        dismiss_id = "later",
        buttons = {
            { id = "later", label = "Ask Later" },
            { id = "never", label = "Never" },
            { id = "register", label = "Register Now", primary = true },
        },
        on_result = function(result_id)
            if result_id == "register" then
                local ok, err = self:ensure_noize_protocol_registration_once()
                if ok then
                    self.noize_protocol_prompt_preference = "registered"
                    self:save_config()
                    self.status_text = "Registered noize:// links."
                else
                    local details = err or "Noizemaker could not register the noize:// link on this system."
                    self.status_text = details
                    self:show_error("Register noize://", details)
                end
            elseif result_id == "never" then
                self.noize_protocol_prompt_preference = "never"
                self:save_config()
                self.status_text = "Noize link registration prompt disabled."
            end
            self:switch_view("mods")
        end,
    })
end

function App:show_error(title, message)
    self.status_text = message
    self:show_modal({
        title = title or "Error",
        message = tostring(message),
        kind = "error",
        buttons = {
            { id = "ok", label = "OK", primary = true },
        },
    })
end

function App:show_info(title, message)
    self.status_text = message
    self:show_modal({
        title = title or "Info",
        message = tostring(message),
        kind = "info",
        buttons = {
            { id = "ok", label = "OK", primary = true },
        },
    })
end

function App:show_modal(spec)
    self.modal = {
        title = spec.title or "Notice",
        message = tostring(spec.message or ""),
        kind = spec.kind or "info",
        image = spec.image or nil,
        buttons = spec.buttons or {
            { id = "ok", label = "OK", primary = true },
        },
        on_result = spec.on_result,
        dismiss_id = spec.dismiss_id,
        input = spec.input and {
            text = tostring(spec.input.text or ""),
            placeholder = tostring(spec.input.placeholder or ""),
            error = nil,
            replace_on_type = spec.input.replace_on_type ~= false,
        } or nil,
    }
    self.modal_anim = {
        t = 0,
        duration = MODAL_ANIM_DURATION,
    }
    self.modal_hits = {}
end

function App:dismiss_modal(result_id)
    local modal = self.modal
    if modal and modal.on_result then
        local ok_to_close = modal.on_result(result_id, modal)
        if ok_to_close == false then
            return
        end
    end
    if self.modal == modal then
        self.modal = nil
        self.modal_anim = nil
        self.modal_hits = {}
    end
end

function App:request_confirm(title, message, ok_label, on_confirm, on_cancel)
    self:show_modal({
        title = title or "Confirm",
        message = tostring(message or ""),
        kind = "warning",
        dismiss_id = "cancel",
        buttons = {
            { id = "cancel", label = "Cancel" },
            { id = "confirm", label = ok_label or "OK", primary = true },
        },
        on_result = function(result_id)
            if result_id == "confirm" then
                if on_confirm then
                    on_confirm()
                end
            elseif on_cancel then
                on_cancel()
            end
        end,
    })
end

function App:request_confirm_with_image(title, message, image, ok_label, on_confirm, on_cancel)
    self:show_modal({
        title = title or "Confirm",
        message = tostring(message or ""),
        kind = "warning",
        image = image,
        dismiss_id = "cancel",
        buttons = {
            { id = "cancel", label = "Cancel" },
            { id = "confirm", label = ok_label or "OK", primary = true },
        },
        on_result = function(result_id)
            if result_id == "confirm" then
                if on_confirm then
                    on_confirm()
                end
            elseif on_cancel then
                on_cancel()
            end
        end,
    })
end

function App:request_integer(title, prompt, default_value, on_submit)
    self:show_modal({
        title = title or "Input",
        message = tostring(prompt or ""),
        kind = "info",
        dismiss_id = "cancel",
        input = {
            text = tostring(default_value or ""),
            replace_on_type = true,
        },
        buttons = {
            { id = "cancel", label = "Cancel" },
            { id = "confirm", label = "OK", primary = true },
        },
        on_result = function(result_id, modal)
            if result_id ~= "confirm" then
                return true
            end

            local text = modal and modal.input and modal.input.text or ""
            local value = tonumber(text)
            if value == nil then
                if modal and modal.input then
                    modal.input.error = "'" .. text .. "' is not a valid number."
                end
                return false
            end

            if on_submit then
                on_submit(value)
            end
            return true
        end,
    })
end

function App:modal_color(kind)
    if kind == "error" then
        return theme.colors.danger, theme.colors.danger_soft
    end
    if kind == "warning" then
        return theme.colors.amber, theme.colors.amber_soft
    end
    return theme.colors.accent, theme.colors.selection_soft
end

function App:modal_progress()
    if not self.modal or not self.modal_anim then
        return 1
    end
    return ease_out_cubic(self.modal_anim.t / math.max(self.modal_anim.duration, 0.001))
end

function App:draw_view_content(view_name)
    if view_name == "menu" then
        self:draw_main_menu()
        return
    end
    if view_name == "mods" then
        mods_tab.draw(self.mods_tab, self.layout.mods, self.installed_mods, {
            game_root = self.game_root,
            valid_game_root = valid_game_root(self.game_root),
        })
        return
    end

    tree.draw(self.tree, self.layout.left, self.selected_entry, self:entry_marker_map())
    self:draw_controls()
    self.timeline_render = timeline.draw(self.layout.timeline, self:current_preview_entry(), self.selected_step_index, {
        validation = self.current_validation,
        drag_index = self.drag and self.drag.index or nil,
        insert_preview = self:insert_preview_info(),
    })
    self:draw_inspector()
end

function App:render_view_canvas(view_name)
    local canvas = self.view_canvases and self.view_canvases[view_name]
    if not canvas then
        return nil
    end

    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.origin()
    self:draw_view_content(view_name)
    love.graphics.setCanvas()
    love.graphics.pop()
    return canvas
end

function App:draw_view_transition()
    local transition = self.view_transition
    if not transition then
        self:draw_view_content(self.active_view)
        return
    end

    local from_canvas = self:render_view_canvas(transition.from)
    local to_canvas = self:render_view_canvas(transition.to)
    if not from_canvas or not to_canvas then
        self:draw_view_content(self.active_view)
        return
    end

    local progress = ease_out_cubic(transition.t / math.max(transition.duration, 0.001))
    local sign = (transition.to == "mods") and 1 or -1

    love.graphics.setColor(1, 1, 1, 1 - progress)
    love.graphics.draw(from_canvas, -sign * VIEW_TRANSITION_SLIDE * progress, 0)

    love.graphics.setColor(1, 1, 1, progress)
    love.graphics.draw(to_canvas, sign * VIEW_TRANSITION_SLIDE * (1 - progress), 0)

    love.graphics.setColor(1, 1, 1, 1)
end

function App:draw_modal()
    if not self.modal then
        return
    end

    local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()
    local progress = self:modal_progress()
    love.graphics.setColor(0.02, 0.03, 0.05, 0.74 * progress)
    love.graphics.rectangle("fill", 0, 0, sw, sh)

    local accent, soft = self:modal_color(self.modal.kind)
    local has_input = self.modal.input ~= nil
    local has_image = self.modal.image ~= nil
    local panel = {
        x = math.floor((sw - 560) * 0.5),
        y = math.floor((sh - 300) * 0.5 + (1 - progress) * MODAL_ANIM_OFFSET),
        w = 560,
        h = has_input and 340 or (has_image and 360 or 300),
    }
    if panel.w > sw - 40 then
        panel.x = 20
        panel.w = sw - 40
    end
    if panel.h > sh - 40 then
        panel.y = 20
        panel.h = sh - 40
    end

    widgets.draw_panel(panel, {
        fill = theme.colors.panel_elevated,
        border = accent,
        radius = 14,
    })

    local title_bar = {
        x = panel.x + 14,
        y = panel.y + 14,
        w = panel.w - 28,
        h = 36,
    }
    widgets.draw_panel(title_bar, {
        fill = soft,
        border = accent,
        radius = 10,
    })
    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(accent[1], accent[2], accent[3], 1)
    love.graphics.print(self.modal.title, title_bar.x + 12, title_bar.y + 10)

    love.graphics.setFont(theme.font("body"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    local content_bottom = panel.y + 64
    if has_image then
        local image_rect = {
            x = panel.x + 18,
            y = panel.y + 64,
            w = 160,
            h = 96,
        }
        widgets.draw_panel(image_rect, {
            fill = theme.colors.panel_alt,
            border = theme.colors.border_soft,
            radius = 10,
        })
        local image = self.modal.image
        local scale = math.min(image_rect.w / image:getWidth(), image_rect.h / image:getHeight())
        local draw_w = image:getWidth() * scale
        local draw_h = image:getHeight() * scale
        local draw_x = image_rect.x + math.floor((image_rect.w - draw_w) * 0.5)
        local draw_y = image_rect.y + math.floor((image_rect.h - draw_h) * 0.5)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(image, draw_x, draw_y, 0, scale, scale)

        love.graphics.setFont(theme.font("body"))
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.printf(self.modal.message, image_rect.x + image_rect.w + 14, image_rect.y, panel.w - image_rect.w - 50, "left")
        content_bottom = image_rect.y + image_rect.h + 18
    else
        love.graphics.printf(self.modal.message, panel.x + 18, panel.y + 64, panel.w - 36, "left")
        content_bottom = panel.y + 170
    end

    local input_bottom = math.max(content_bottom, panel.y + panel.h - 70)
    if self.modal.input then
        local input_rect = {
            x = panel.x + 18,
            y = math.max(content_bottom, panel.y + 170),
            w = panel.w - 36,
            h = 38,
        }
        widgets.draw_panel(input_rect, {
            fill = theme.colors.panel,
            border = accent,
            radius = 10,
        })

        local input_text = self.modal.input.text
        local placeholder = self.modal.input.placeholder
        love.graphics.setFont(theme.font("body"))
        if input_text == "" and placeholder ~= "" then
            love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
            love.graphics.print(placeholder, input_rect.x + 12, input_rect.y + 10)
        else
            love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
            love.graphics.print(input_text, input_rect.x + 12, input_rect.y + 10)

            local cursor_x = input_rect.x + 12 + love.graphics.getFont():getWidth(input_text)
            love.graphics.setColor(accent[1], accent[2], accent[3], 1)
            love.graphics.line(cursor_x + 2, input_rect.y + 8, cursor_x + 2, input_rect.y + input_rect.h - 8)
        end

        if self.modal.input.error then
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.danger[1], theme.colors.danger[2], theme.colors.danger[3], 1)
            love.graphics.printf(self.modal.input.error, input_rect.x, input_rect.y + input_rect.h + 8, input_rect.w, "left")
        end
        input_bottom = input_rect.y + input_rect.h + (self.modal.input.error and 34 or 18)
    end

    self.modal_hits = {}
    local buttons = self.modal.buttons or {}
    local button_h = 30
    local gap = 10
    local max_footer_w = panel.w - 36
    local button_w = 118
    if #buttons > 0 then
        button_w = math.floor((max_footer_w - math.max(0, (#buttons - 1) * gap)) / #buttons)
        button_w = clamp(button_w, 84, 118)
    end
    local total_w = (#buttons * button_w) + math.max(0, (#buttons - 1) * gap)
    local start_x = panel.x + math.floor((panel.w - total_w) * 0.5)
    local y = math.max(panel.y + panel.h - button_h - 18, input_bottom)
    for i = 1, #buttons do
        local button = buttons[i]
        local rect = {
            x = start_x + (i - 1) * (button_w + gap),
            y = y,
            w = button_w,
            h = button_h,
        }
        widgets.draw_button(rect, button.label, {
            font = theme.font("tiny"),
            fill = button.primary and theme.colors.selection_soft or theme.colors.button,
            hover_fill = button.primary and theme.colors.accent_soft or theme.colors.button_hover,
            border = button.primary and theme.colors.selection or theme.colors.border,
        })
        self.modal_hits[#self.modal_hits + 1] = {
            id = button.id,
            rect = rect,
        }
    end
end

function App:install_mod_zip_path(path)
    local installed, err = modcore.install_zip(path, self.mod_base_dir)
    if not installed then
        self:show_error("Install Mod", err or "Mod install failed.")
        return false
    end
    self:refresh_installed_mods()
    self.mods_tab.selected_name = installed.folder_name
    self.active_view = "mods"
    self.status_text = "Installed mod: " .. installed.name
    return true
end

function App:install_mod_dialog()
    local start_dir = self.game_root or self.current_file_dir or "."
    local chosen = choose_zip_file(start_dir)
    if chosen then
        self:install_mod_zip_path(chosen)
    end
end

function App:enable_selected_mod()
    local mod = self:selected_installed_mod()
    if not mod then
        self:show_info("Enable Mod", "Select a mod first.")
        return
    end
    local updated, err = modcore.enable_mod(mod.folder_name, self.game_root, self.mod_base_dir)
    if not updated then
        self:show_error("Enable Mod", err or "Failed to enable mod.")
        return
    end
    self:refresh_installed_mods()
    self.mods_tab.selected_name = mod.folder_name
    self.status_text = "Enabled mod: " .. mod.name
end

function App:disable_selected_mod()
    local mod = self:selected_installed_mod()
    if not mod then
        self:show_info("Disable Mod", "Select a mod first.")
        return
    end
    local updated, err = modcore.disable_mod(mod.folder_name, self.game_root, self.mod_base_dir)
    if not updated then
        self:show_error("Disable Mod", err or "Failed to disable mod.")
        return
    end
    self:refresh_installed_mods()
    self.mods_tab.selected_name = mod.folder_name
    self.status_text = "Disabled mod: " .. mod.name
end

function App:uninstall_selected_mod()
    local mod = self:selected_installed_mod()
    if not mod then
        self:show_info("Uninstall Mod", "Select a mod first.")
        return
    end
    self:request_confirm(
        "Uninstall Mod",
        "Uninstall '" .. (mod.name or mod.folder_name) .. "'?",
        "Uninstall",
        function()
            local ok, err = modcore.uninstall_mod(mod.folder_name, self.game_root, self.mod_base_dir)
            if not ok then
                self:show_error("Uninstall Mod", err or "Failed to uninstall mod.")
                return
            end
            self:refresh_installed_mods()
            self.status_text = "Uninstalled mod: " .. (mod.name or mod.folder_name)
        end,
        function()
            self.status_text = "Uninstall canceled."
        end
    )
end

function App:restore_original_files()
    self:request_confirm(
        "Restore Original Files",
        "Restore all backed up original files into the game root?",
        "Restore",
        function()
            local ok, err = modcore.restore_originals(self.game_root, self.mod_base_dir)
            if not ok then
                self:show_error("Restore Original Files", err or "Restore failed.")
                return
            end
            self:refresh_installed_mods()
            self.status_text = "Original files restored."
        end,
        function()
            self.status_text = "Restore canceled."
        end
    )
end

function App:buttons()
    local top = self.layout.toolbar
    return {
        open = { x = top.x + 16, y = top.y + 7, w = 82, h = 26, label = "Open" },
        apply = { x = top.x + 106, y = top.y + 7, w = 82, h = 26, label = "Apply" },
        patch = { x = top.x + 196, y = top.y + 7, w = 82, h = 26, label = "Patch" },
        settings = { x = top.x + 286, y = top.y + 7, w = 100, h = 26, label = "Settings" },
    }
end

function App:use_compact_move_grid(width)
    return (width or 0) < 860
end

function App:ensure_view_canvases(w, h)
    if not love.graphics or not love.graphics.newCanvas then
        self.view_canvases = {}
        return
    end

    local current = self.view_canvases
    if current.editor and current.editor:getWidth() == w and current.editor:getHeight() == h then
        return
    end

    local ok_menu, menu_canvas = pcall(love.graphics.newCanvas, w, h)
    local ok_editor, editor_canvas = pcall(love.graphics.newCanvas, w, h)
    local ok_mods, mods_canvas = pcall(love.graphics.newCanvas, w, h)
    if ok_menu and ok_editor and ok_mods then
        self.view_canvases = {
            menu = menu_canvas,
            editor = editor_canvas,
            mods = mods_canvas,
        }
    else
        self.view_canvases = {}
    end
end

function App:resize(w, h)
    self.layout.topbar = { x = 0, y = 0, w = w, h = 44 }
    self.layout.toolbar = { x = 0, y = 44, w = w, h = 40 }
    self.layout.menu = { x = 0, y = self.layout.topbar.h, w = w, h = h - self.layout.topbar.h }
    local content_y = self.layout.toolbar.y + self.layout.toolbar.h + 10
    self.layout.left = { x = 16, y = content_y, w = 300, h = h - content_y - 16 }
    self.layout.right = { x = w - 356, y = content_y, w = 340, h = h - content_y - 16 }
    self.layout.center = {
        x = self.layout.left.x + self.layout.left.w + 16,
        y = content_y,
        w = w - self.layout.left.w - self.layout.right.w - 48,
        h = h - content_y - 16,
    }
    local controls_h = self:use_compact_move_grid(self.layout.center.w) and 182 or 150
    self.layout.controls = {
        x = self.layout.center.x,
        y = self.layout.center.y,
        w = self.layout.center.w,
        h = controls_h,
    }
    self.layout.timeline = {
        x = self.layout.center.x,
        y = self.layout.center.y + controls_h + 8,
        w = self.layout.center.w,
        h = self.layout.center.h - controls_h - 8,
    }
    self.layout.mods = {
        x = 16,
        y = content_y,
        w = w - 32,
        h = h - content_y - 16,
    }
    self:ensure_view_canvases(w, h)
end

function App:draw_background()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local grad_steps = 18
    for i = 0, grad_steps - 1 do
        local t = i / (grad_steps - 1)
        local r = theme.colors.bg_top[1] * (1 - t) + theme.colors.bg_bottom[1] * t
        local g = theme.colors.bg_top[2] * (1 - t) + theme.colors.bg_bottom[2] * t
        local b = theme.colors.bg_top[3] * (1 - t) + theme.colors.bg_bottom[3] * t
        love.graphics.setColor(r, g, b, 1)
        love.graphics.rectangle("fill", 0, h * t, w, h / grad_steps + 2)
    end
end

function App:header_items()
    if self.active_view == "editor" then
        return {
            { id = "main_menu", label = "Main Menu" },
            { id = "editor", label = "Noizemaker" },
        }
    end
    if self.active_view == "mods" then
        return {
            { id = "main_menu", label = "Main Menu" },
            { id = "mods", label = "Mods" },
        }
    end
    return {
        { id = "main_menu", label = "Main Menu" },
    }
end

function App:draw_topbar()
    local top = self.layout.topbar
    widgets.draw_panel(top, { fill = theme.colors.panel_soft, border = theme.colors.border, radius = 0 })
    self.header_hits = {}

    local back_rect = { x = top.x + 14, y = top.y + 8, w = 30, h = 26 }
    local back_disabled = self.active_view == "menu"
    widgets.draw_button(back_rect, "<", {
        font = theme.font("small"),
        disabled = back_disabled,
        hovered = self.hovered_button == "header_back",
        radius = 7,
    })
    self.header_hits[#self.header_hits + 1] = { kind = "back", rect = back_rect, disabled = back_disabled }

    local cursor_x = back_rect.x + back_rect.w + 10
    local items = self:header_items()
    love.graphics.setFont(theme.font("small"))
    for i = 1, #items do
        local item = items[i]
        local text_w = love.graphics.getFont():getWidth(item.label) + 18
        local rect_item = {
            x = cursor_x,
            y = top.y + 8,
            w = text_w,
            h = 26,
        }
        widgets.draw_button(rect_item, item.label, {
            font = theme.font("small"),
            fill = i == #items and theme.colors.selection_soft or theme.colors.panel_alt,
            hover_fill = theme.colors.button_hover,
            border = i == #items and theme.colors.selection or theme.colors.border_soft,
            hovered = self.hovered_button == ("header_" .. item.id),
            radius = 7,
        })
        self.header_hits[#self.header_hits + 1] = {
            kind = "crumb",
            id = item.id,
            rect = rect_item,
        }
        cursor_x = rect_item.x + rect_item.w + 8
        if i < #items then
            love.graphics.setColor(theme.colors.border_soft[1], theme.colors.border_soft[2], theme.colors.border_soft[3], 1)
            love.graphics.rectangle("fill", cursor_x, top.y + 13, 1, 18)
            cursor_x = cursor_x + 8
        end
    end
end

function App:draw_editor_toolbar()
    if self.active_view ~= "editor" then
        return
    end
    local top = self.layout.toolbar
    widgets.draw_panel(top, { fill = theme.colors.panel_alt, border = theme.colors.border_soft, radius = 0 })

    local buttons = self:buttons()
    widgets.draw_button(buttons.open, buttons.open.label, { hovered = self.hovered_button == "open" })
    widgets.draw_button(buttons.apply, buttons.apply.label, {
        hovered = self.hovered_button == "apply",
        disabled = self.active_view ~= "editor" or not self.selected_entry,
    })
    widgets.draw_button(buttons.patch, buttons.patch.label, {
        hovered = self.hovered_button == "patch",
        disabled = self.active_view ~= "editor" or not self.current_buffer,
    })
    widgets.draw_button(buttons.settings, buttons.settings.label, { hovered = self.hovered_button == "settings" })

    local file_x = buttons.settings.x + buttons.settings.w + 12
    local file_rect = {
        x = file_x,
        y = top.y + 7,
        w = math.max(120, top.w - file_x - 16),
        h = 26,
    }
    widgets.draw_panel(file_rect, {
        fill = theme.colors.panel,
        border = theme.colors.border_soft,
        radius = 10,
    })
    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text_dim[1], theme.colors.text_dim[2], theme.colors.text_dim[3], 1)
    love.graphics.printf(self.current_file_name, file_rect.x + 12, file_rect.y + 6, file_rect.w - 24, "left")
end

function App:draw_main_menu()
    local rect = self.layout.menu
    self.menu_hits = {}
    self.recent_hits = {}
    self.release_hits = {}

    local title_x = rect.x + 44
    local title_y = rect.y + 30

    if self.title_font_renderer then
        local text = "NOIZEMAKER"
        local base_w, base_h = self.title_font_renderer:measure(text, 1.0)
        local scale = math.min(1.65, (rect.w * 0.42) / math.max(base_w, 1))
        scale = snap_scale(scale, 0.25, 1.0)
        self.title_font_renderer:draw(text, title_x, title_y, scale, theme.colors.text)
    else
        love.graphics.setFont(theme.font("title"))
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.print("Noizemaker", title_x, title_y + 10)
    end

    local margin_x = 40
    local panel_y = rect.y + 132
    local panel_h = math.min(rect.h - 184, 430)
    local feed_w = math.min(320, rect.w * 0.28)
    local gap = 24
    local shell_rect = {
        x = rect.x + margin_x,
        y = panel_y,
        w = rect.w - margin_x * 2 - feed_w - gap,
        h = panel_h,
    }
    local feed_rect = {
        x = shell_rect.x + shell_rect.w + gap,
        y = panel_y,
        w = feed_w,
        h = panel_h,
    }

    widgets.draw_panel(shell_rect, {
        fill = theme.colors.panel_elevated,
        border = theme.colors.border,
        radius = 28,
    })
    love.graphics.setColor(theme.colors.selection_soft[1], theme.colors.selection_soft[2], theme.colors.selection_soft[3], 0.55)
    love.graphics.polygon("fill",
        shell_rect.x + 28, shell_rect.y + shell_rect.h - 26,
        shell_rect.x + shell_rect.w * 0.55, shell_rect.y + 58,
        shell_rect.x + shell_rect.w - 42, shell_rect.y + 96,
        shell_rect.x + shell_rect.w - 24, shell_rect.y + shell_rect.h - 34
    )
    love.graphics.setColor(theme.colors.panel_soft[1], theme.colors.panel_soft[2], theme.colors.panel_soft[3], 0.85)
    love.graphics.rectangle("fill", shell_rect.x + 330, shell_rect.y + 26, 1, shell_rect.h - 52)

    local recent_rect = {
        x = shell_rect.x + 18,
        y = shell_rect.y + 18,
        w = 292,
        h = shell_rect.h - 36,
    }
    widgets.draw_panel(recent_rect, {
        fill = { theme.colors.panel[1], theme.colors.panel[2], theme.colors.panel[3], 0.92 },
        border = { theme.colors.border_soft[1], theme.colors.border_soft[2], theme.colors.border_soft[3], 0.7 },
        radius = 22,
    })

    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Recent Files", recent_rect.x + 18, recent_rect.y + 16)

    local recent_y = recent_rect.y + 58
    if #self.recent_files == 0 then
        love.graphics.setFont(theme.font("body"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("No files yet. Open a DGSH file in the editor and it will show up here.", recent_rect.x + 18, recent_y + 10, recent_rect.w - 36, "left")
    else
        for i = 1, math.min(#self.recent_files, RECENT_FILE_LIMIT) do
            local path = self.recent_files[i]
            local row_rect = {
                x = recent_rect.x + 14,
                y = recent_y,
                w = recent_rect.w - 28,
                h = 42,
            }
            local exists = file_exists(path)
            widgets.draw_panel(row_rect, {
                fill = self.hovered_button == ("recent_" .. i) and theme.colors.button_hover or theme.colors.panel,
                border = exists and theme.colors.border_soft or theme.colors.danger,
                radius = 12,
            })
            love.graphics.setFont(theme.font("small"))
            love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
            love.graphics.print(basename(path), row_rect.x + 12, row_rect.y + 8)
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
            love.graphics.printf(path, row_rect.x + 12, row_rect.y + 24, row_rect.w - 24, "left")
            self.recent_hits[#self.recent_hits + 1] = {
                rect = row_rect,
                path = path,
            }
            recent_y = recent_y + 50
        end
    end

    local center_rect = {
        x = recent_rect.x + recent_rect.w + 26,
        y = shell_rect.y + 18,
        w = shell_rect.w - recent_rect.w - 44,
        h = shell_rect.h - 36,
    }
    widgets.draw_panel(center_rect, {
        fill = { theme.colors.panel_soft[1], theme.colors.panel_soft[2], theme.colors.panel_soft[3], 0.88 },
        border = { theme.colors.border_soft[1], theme.colors.border_soft[2], theme.colors.border_soft[3], 0.72 },
        radius = 24,
    })

    local function draw_icon_button(button)
        widgets.draw_panel(button.rect, {
            fill = self.hovered_menu_button == button.id and (button.hover_fill or theme.colors.button_hover) or button.fill,
            border = button.border,
            radius = 16,
        })

        local icon = self.ui_images[button.icon]
        local text_x = button.rect.x + 18
        if icon then
            local icon_box = 32
            local scale = math.min(icon_box / icon:getHeight(), icon_box / icon:getWidth())
            local scaled_w = icon:getWidth() * scale
            local scaled_h = icon:getHeight() * scale
            local draw_x = button.rect.x + 14
            local draw_y = button.rect.y + math.floor((button.rect.h - scaled_h) * 0.5)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(icon, draw_x, draw_y, 0, scale, scale)
            text_x = draw_x + scaled_w + 12
        end

        if self.title_font_renderer then
            local text = button.label:upper()
            local base_w, base_h = self.title_font_renderer:measure(text, 1.0)
            local scale = math.min((button.rect.w - (text_x - button.rect.x) - 18) / math.max(base_w, 1), 22 / math.max(base_h, 1))
            scale = snap_scale(scale, 0.25, 1.0)
            local draw_y = button.rect.y + math.floor((button.rect.h - (base_h * scale)) * 0.5)
            self.title_font_renderer:draw(text, text_x, draw_y, scale, theme.colors.text)
        else
            love.graphics.setFont(theme.font("small"))
            love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
            love.graphics.print(button.label, text_x, button.rect.y + 12)
        end

        self.menu_hits[#self.menu_hits + 1] = {
            id = button.id,
            rect = button.rect,
        }
    end

    local left_x = center_rect.x + 34
    local top_y = center_rect.y + 28
    local half_w = math.floor((center_rect.w - 68 - 14) * 0.5)
    local full_w = center_rect.w - 68

    local menu_buttons = {
        {
            id = "mods",
            label = "Mods",
            icon = "noizemaker_icon.png",
            fill = theme.colors.selection_soft,
            hover_fill = theme.colors.accent_soft,
            border = theme.colors.selection,
            rect = { x = left_x, y = top_y, w = half_w, h = 58 },
        },
        {
            id = "launch",
            label = "Launch",
            icon = "sc5logo.png",
            fill = theme.colors.button,
            hover_fill = theme.colors.button_hover,
            border = theme.colors.border_soft,
            rect = { x = left_x + half_w + 14, y = top_y, w = half_w, h = 58 },
        },
        {
            id = "editor",
            label = "Noizemaker",
            icon = "noizemaker.png",
            fill = theme.colors.button,
            hover_fill = theme.colors.button_hover,
            border = theme.colors.border_soft,
            rect = { x = left_x, y = top_y + 78, w = full_w, h = 66 },
        },
        {
            id = "settings",
            label = "Settings",
            icon = "sc5gear.png",
            fill = theme.colors.button,
            hover_fill = theme.colors.button_hover,
            border = theme.colors.border_soft,
            rect = { x = left_x, y = top_y + 162, w = full_w, h = 58 },
        },
    }

    for i = 1, #menu_buttons do
        draw_icon_button(menu_buttons[i])
    end

    widgets.draw_panel(feed_rect, {
        fill = { theme.colors.panel_elevated[1], theme.colors.panel_elevated[2], theme.colors.panel_elevated[3], 0.94 },
        border = theme.colors.border,
        radius = 24,
    })

    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Latest Mods", feed_rect.x + 18, feed_rect.y + 16)

    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    local subtitle
    if self.gamebanana_previews_preference == "enabled" then
        subtitle = self.release_feed.from_cache and "GameBanana feed (cached)" or "Recent releases from GameBanana"
    elseif self.gamebanana_previews_preference == "never" then
        subtitle = "GameBanana previews are disabled"
    else
        subtitle = "Optional GameBanana menu panel"
    end
    love.graphics.print(subtitle, feed_rect.x + 18, feed_rect.y + 38)

    local list_y = feed_rect.y + 62
    if self.gamebanana_previews_preference ~= "enabled" then
        local message = self.gamebanana_previews_preference == "never"
            and "You can re-enable previews later from the menu code path or config if you change your mind."
            or "Enable this panel to see the latest released mods for Space Channel 5 Part 2 right on the main menu."
        love.graphics.setFont(theme.font("body"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf(message, feed_rect.x + 18, list_y + 20, feed_rect.w - 36, "left")

        local button_rect = {
            x = feed_rect.x + 18,
            y = feed_rect.y + feed_rect.h - 58,
            w = feed_rect.w - 36,
            h = 38,
        }
        widgets.draw_button(button_rect, "Do you want to enable GameBanana previews?", {
            font = theme.font("small"),
            fill = self.gamebanana_previews_preference == "never" and theme.colors.button_disabled or theme.colors.selection_soft,
            hover_fill = theme.colors.accent_soft,
            border = self.gamebanana_previews_preference == "never" and theme.colors.border_soft or theme.colors.selection,
            disabled = self.gamebanana_previews_preference == "never",
            hovered = self.hovered_button == "release_enable_prompt",
            radius = 10,
        })
        if self.gamebanana_previews_preference ~= "never" then
            self.release_hits[#self.release_hits + 1] = {
                id = "release_enable_prompt",
                rect = button_rect,
                action = "prompt_enable",
            }
        end
        return
    end
    if self.release_feed.status == "loading" then
        love.graphics.setFont(theme.font("body"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("Loading recent releases...", feed_rect.x + 18, list_y + 16, feed_rect.w - 36, "left")
        return
    end
    if self.release_feed.status == "error" then
        love.graphics.setFont(theme.font("body"))
        love.graphics.setColor(theme.colors.danger[1], theme.colors.danger[2], theme.colors.danger[3], 1)
        love.graphics.printf(self.release_feed.error or "Recent releases are unavailable right now.", feed_rect.x + 18, list_y + 12, feed_rect.w - 36, "left")
        return
    end
    if #self.release_feed.items == 0 then
        love.graphics.setFont(theme.font("body"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("No recent releases were found for Space Channel 5 Part 2.", feed_rect.x + 18, list_y + 12, feed_rect.w - 36, "left")
        return
    end

    local card_gap = 12
    local card_h = math.floor((feed_rect.h - 84 - card_gap * (#self.release_feed.items - 1)) / #self.release_feed.items)
    for i = 1, #self.release_feed.items do
        local item = self.release_feed.items[i]
        local card = {
            x = feed_rect.x + 14,
            y = list_y + (i - 1) * (card_h + card_gap),
            w = feed_rect.w - 28,
            h = card_h,
        }
        widgets.draw_panel(card, {
            fill = self.hovered_button == ("release_download_" .. i) and theme.colors.button_hover or theme.colors.panel,
            border = theme.colors.border_soft,
            radius = 16,
        })

        local thumb = {
            x = card.x + 10,
            y = card.y + 10,
            w = 96,
            h = card.h - 20,
        }
        widgets.draw_panel(thumb, {
            fill = theme.colors.panel_alt,
            border = theme.colors.border_soft,
            radius = 12,
        })

        local image = self.release_images[tostring(item.id)]
        if image then
            local scale = math.min(thumb.w / image:getWidth(), thumb.h / image:getHeight())
            local draw_w = image:getWidth() * scale
            local draw_h = image:getHeight() * scale
            local draw_x = thumb.x + math.floor((thumb.w - draw_w) * 0.5)
            local draw_y = thumb.y + math.floor((thumb.h - draw_h) * 0.5)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(image, draw_x, draw_y, 0, scale, scale)
        else
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
            love.graphics.printf("No image", thumb.x, thumb.y + math.floor((thumb.h - theme.font("tiny"):getHeight()) * 0.5), thumb.w, "center")
        end

        local text_x = thumb.x + thumb.w + 12
        local text_w = card.x + card.w - text_x - 12
        love.graphics.setFont(theme.font("small"))
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.printf(item.name, text_x, card.y + 10, text_w, "left")

        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text_dim[1], theme.colors.text_dim[2], theme.colors.text_dim[3], 1)
        local byline = item.submitter_name ~= "" and ("by " .. item.submitter_name) or "GameBanana"
        love.graphics.printf(byline, text_x, card.y + 30, text_w, "left")

        local desc_font = theme.font("tiny")
        love.graphics.setFont(desc_font)
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf(clamp_text_lines(desc_font, item.description, text_w, 4), text_x, card.y + 48, text_w, "left")

        local button_rect = {
            x = card.x + card.w - 104,
            y = card.y + card.h - 36,
            w = 92,
            h = 24,
        }
        widgets.draw_button(button_rect, "Download", {
            font = theme.font("tiny"),
            fill = theme.colors.selection_soft,
            hover_fill = theme.colors.accent_soft,
            border = theme.colors.selection,
            hovered = self.hovered_button == ("release_download_" .. i),
            radius = 8,
        })
        self.release_hits[#self.release_hits + 1] = {
            id = "release_download_" .. i,
            rect = button_rect,
            uri = item.noize_uri,
            action = "download",
        }
    end
end

function App:draw_entry_header(x, y, entry, max_width)
    if not entry then
        love.graphics.setFont(theme.font("title"))
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.print("No sequence loaded", x, y)
        return y + 28
    end

    if self.title_font_renderer then
        local text = entry.name:upper()
        local width_limit = math.max(max_width or 1, 1)
        local base_w, base_h = self.title_font_renderer:measure(text, 1.0)
        local target_h = 56
        local scale = math.min(width_limit / math.max(base_w, 1), target_h / math.max(base_h, 1))
        local scaled_h = base_h * scale
        local draw_x = x + math.floor((width_limit - (base_w * scale)) * 0.5)
        local draw_y = y + math.floor((target_h - scaled_h) * 0.5)
        self.title_font_renderer:draw(text, draw_x, draw_y, scale, theme.colors.text)
        return y + target_h
    end

    love.graphics.setFont(theme.font("title"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.printf(entry.name, x, y + 8, math.max(max_width or 1, 1), "center")
    return y + 44
end

function App:entry_marker_map()
    local markers = {}
    for name, draft in pairs(self.drafts) do
        markers[name] = {
            dirty = draft.modified or self.mods[name] ~= nil,
            invalid = draft.validation and not draft.validation.ok or false,
        }
    end
    for name in pairs(self.mods) do
        if not markers[name] then
            markers[name] = { dirty = true, invalid = false }
        else
            markers[name].dirty = true
        end
    end
    return markers
end

function App:current_preview_entry()
    if not self.selected_entry or not self.current_work then
        return nil
    end
    return self:build_preview_entry(self.selected_entry, self.current_work)
end

function App:current_nodes()
    local preview = self:current_preview_entry()
    return timeline.build_nodes(preview), preview
end

function App:set_status_from_validation(prefix)
    prefix = prefix or ""
    if self.current_validation and #self.current_validation.errors > 0 then
        self.status_text = prefix .. self.current_validation.errors[1]
    elseif self.current_validation and #self.current_validation.warnings > 0 then
        self.status_text = prefix .. self.current_validation.warnings[1]
    end
end

function App:show_validation_errors(validation, title)
    if validation and not validation.ok then
        self:show_modal({
            title = title or "Validation error",
            message = table.concat(validation.errors, "\n"),
            kind = "warning",
            buttons = {
                { id = "ok", label = "OK", primary = true },
            },
        })
    end
end

function App:push_undo_snapshot(snapshot)
    self.undo_stack[#self.undo_stack + 1] = snapshot
    self.redo_stack = {}
end

function App:accept_candidate(candidate, new_selected_step, options)
    options = options or {}
    local validation = self:validate_work(self.selected_entry, candidate)
    if not validation.ok then
        self.status_text = validation.errors[1]
        if options.show_dialog ~= false then
            self:show_validation_errors(validation, "Edit blocked")
        end
        return false
    end

    if options.push_undo then
        self:push_undo_snapshot(snapshot_from_work(self.current_work))
    end

    self.current_work = candidate
    self.current_validation = validation
    if new_selected_step ~= nil then
        self.selected_step_index = new_selected_step
    end
    self:update_draft_from_current()
    self:set_status_from_validation(options.status_prefix or "")
    if self.status_text == "Ready." or self.status_text == "" then
        self.status_text = options.success_message or "Updated entry."
    elseif options.success_message and (#validation.warnings == 0 and #validation.errors == 0) then
        self.status_text = options.success_message
    end
    return true
end

function App:apply_current_entry()
    if not self.selected_entry or not self.current_work then
        return false
    end

    local validation = self:validate_work(self.selected_entry, self.current_work)
    self.current_validation = validation
    if not validation.ok then
        self:show_validation_errors(validation, "Apply blocked")
        self.status_text = validation.errors[1]
        return false
    end

    local name = self.selected_entry.name
    local modified = not self:work_equals_original(self.selected_entry, self.current_work)
    if modified then
        self.mods[name] = snapshot_from_work(self.current_work)
        self.status_text = "Applied " .. name .. "."
    else
        self.mods[name] = nil
        self.status_text = "Cleared modifications for " .. name .. "."
    end

    self:update_draft_from_current()
    if #validation.warnings > 0 then
        self.status_text = validation.warnings[1]
    end
    return true
end

function App:clone_root_to_variants()
    if not self.selected_entry or not self.current_work then
        return false
    end
    if not has_base_family(self.selected_entry) then
        self.status_text = "Select an entry with related variants before cloning."
        return false
    end

    local variants = self:selected_root_variants()
    if #variants == 0 then
        self.status_text = "This entry has no related variants to clone into."
        return false
    end

    local source_validation = self:validate_work(self.selected_entry, self.current_work)
    self.current_validation = source_validation
    if not source_validation.ok then
        self.status_text = source_validation.errors[1] or "Root entry is invalid."
        self:show_validation_errors(source_validation, "Clone blocked")
        return false
    end

    local cloned = snapshot_from_work(self.current_work)
    local applied = {}
    local blocked = {}

    for i = 1, #variants do
        local target = variants[i]
        local candidate = {
            steps = clone_steps(cloned.steps),
            anim_indices = clone_list(cloned.anim_indices),
            start_delay = cloned.start_delay,
            timing = cloned.timing,
        }
        local validation = rules.validate_mod(target, candidate.steps, {
            anim_indices = candidate.anim_indices,
            start_delay = candidate.start_delay,
            timing = candidate.timing,
        })

        if validation.ok then
            local modified = not self:work_equals_original(target, candidate)
            self.drafts[target.name] = {
                steps = clone_steps(candidate.steps),
                anim_indices = clone_list(candidate.anim_indices),
                start_delay = candidate.start_delay,
                timing = candidate.timing,
                validation = validation,
                modified = modified,
            }
            if modified then
                self.mods[target.name] = snapshot_from_work(candidate)
            else
                self.mods[target.name] = nil
            end
            applied[#applied + 1] = target.name
        else
            blocked[#blocked + 1] = string.format("%s: %s", target.name, validation.errors[1] or "validation failed")
        end
    end

    self:update_draft_from_current()

    if #applied == 0 then
        self.status_text = blocked[1] or "Clone to variants failed."
        self:show_modal({
            title = "Clone blocked",
            message = table.concat(blocked, "\n"),
            kind = "warning",
            buttons = {
                { id = "ok", label = "OK", primary = true },
            },
        })
        return false
    end

    if #blocked > 0 then
        self.status_text = string.format("Cloned to %d variants; %d blocked.", #applied, #blocked)
        self:show_modal({
            title = "Clone to variants",
            message = table.concat(blocked, "\n"),
            kind = "warning",
            buttons = {
                { id = "ok", label = "OK", primary = true },
            },
        })
    else
        self.status_text = string.format("Cloned %s into %d sibling entries.", self.selected_entry.name, #applied)
    end
    return true
end

function App:noize_install_message(spec)
    local lines = {
        "Install this mod from GameBanana?",
        "",
        "Archive: " .. (spec.suggested_filename or "(unknown)"),
        "Host: " .. (spec.host or "(unknown)"),
    }
    if spec.item_type and spec.item_id then
        lines[#lines + 1] = string.format("Item: %s #%d", spec.item_type, spec.item_id)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Noizemaker will download the archive and install it into your local mods library."
    return table.concat(lines, "\n")
end

function App:fetch_noize_metadata(spec)
    if not spec or spec.source ~= "gamebanana" or not spec.item_id then
        return nil
    end

    local item_cache_dir = join_path(self.release_cache_dir, "items")
    local details, err = gamebanana.fetch_mod_details(item_cache_dir, spec.item_id)
    if not details then
        return nil, err
    end

    local preview_image = nil
    if details.preview_url and details.preview_url ~= "" then
        local preview_path = gamebanana.cache_preview_image({
            id = details.id,
            preview_url = details.preview_url,
        }, item_cache_dir)
        if preview_path then
            preview_image = self:load_modal_image(preview_path)
        end
    end

    return {
        title = details.name ~= "" and details.name or nil,
        author = details.author ~= "" and details.author or nil,
        description = details.description ~= "" and details.description or nil,
        image = preview_image,
    }
end

function App:handle_noize_uri(uri)
    local spec, err = noize.parse(uri)
    if not spec then
        self:show_error("Noize Install", err or "Invalid noize URI.")
        return false
    end

    local meta = self:fetch_noize_metadata(spec)
    local title = "Install Mod"
    local message = self:noize_install_message(spec)
    local image = nil
    if meta then
        local lines = {
            meta.title or (spec.suggested_filename or "GameBanana Mod"),
        }
        if meta.author then
            lines[#lines + 1] = "by " .. meta.author
        end
        if meta.description then
            lines[#lines + 1] = ""
            lines[#lines + 1] = meta.description
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Noizemaker will download the archive and install it into your local mods library."
        message = table.concat(lines, "\n")
        image = meta.image
    end

    self:switch_view("mods")
    self:request_confirm_with_image(
        title,
        message,
        image,
        "Install",
        function()
            local installed, install_err = modcore.install_remote_archive(spec.archive_url, self.mod_base_dir, spec.suggested_filename)
            if not installed then
                self:show_error("Install Mod", install_err or "Failed to install downloaded mod.")
                return
            end

            self:refresh_installed_mods()
            self.mods_tab.selected_name = installed.folder_name
            self.active_view = "mods"
            self.status_text = "Installed mod: " .. installed.name

            if valid_game_root(self.game_root) then
                self:request_confirm(
                    "Enable Mod",
                    "Enable '" .. installed.name .. "' now?",
                    "Enable",
                    function()
                        local updated, enable_err = modcore.enable_mod(installed.folder_name, self.game_root, self.mod_base_dir)
                        if not updated then
                            self:show_error("Enable Mod", enable_err or "Failed to enable mod.")
                            return
                        end
                        self:refresh_installed_mods()
                        self.mods_tab.selected_name = installed.folder_name
                        self.status_text = "Enabled mod: " .. installed.name
                    end
                )
            end
        end,
        function()
            self.status_text = "Noize install canceled."
        end
    )
    return true
end

function App:handle_launch_args(args)
    for _, value in ipairs(args or {}) do
        if type(value) == "string" and noize.supports_uri(value) then
            self:handle_noize_uri(value)
            return
        end
    end
end

function App:patch_copy()
    if not self.current_buffer then
        self.status_text = "No file loaded."
        return
    end

    if self.selected_entry and self.current_work and not self:apply_current_entry() then
        return
    end

    local has_mods = next(self.mods) ~= nil
    if not has_mods then
        self.status_text = "No modifications to patch."
        self:show_info("Patch", "No modifications to patch yet. Use Apply first or edit the selected entry.")
        return
    end

    local suggested = self.current_file_name:gsub("%.bin$", "") .. "_patched.bin"
    local save_path = choose_save_file(self.current_file_dir, suggested)
    if not save_path then
        self.status_text = "Patch canceled."
        return
    end

    -- Binary rebuilding stays in the backend to mirror the Python reference.
    local patched = rebuild.apply_mods(self.current_buffer, self.entries, self.mods)
    if write_binary(save_path, patched) then
        self.current_patch_path = normalize_slashes(save_path)
        self.status_text = "Patched copy written to " .. basename(save_path) .. "."
    else
        self.status_text = "Failed to write patched file."
    end
end

function App:move_button_rows()
    local compact = self:use_compact_move_grid(self.layout.controls and self.layout.controls.w or 0)
    return resolve_move_rows(compact and MOVE_BUTTON_ROWS_COMPACT or MOVE_BUTTON_ROWS_WIDE)
end

function App:move_grid_metrics()
    if self:use_compact_move_grid(self.layout.controls and self.layout.controls.w or 0) then
        return {
            start_y = 38,
            button_w = 74,
            button_h = 24,
            gap_x = 8,
            gap_y = 6,
        }
    end

    return {
        start_y = 40,
        button_w = 82,
        button_h = 28,
        gap_x = 8,
        gap_y = 8,
    }
end

function App:snap_tick(raw_tick)
    local snap = SNAP_MODES[self.snap_index]
    return math.floor(raw_tick / snap + 0.5) * snap
end

function App:display_to_raw_tick(display_tick)
    local start_delay = (self.current_work and self.current_work.start_delay) or 0
    return math.max(0, display_tick - start_delay)
end

function App:raw_to_display_tick(raw_tick)
    local start_delay = (self.current_work and self.current_work.start_delay) or 0
    return raw_tick + start_delay
end

function App:insert_preview_info()
    if not self.pending_insert or not self.selected_entry or not self.current_work then
        return nil
    end

    local mx, my = love.mouse.getPosition()
    if not widgets.point_in_rect(mx, my, self.layout.timeline) then
        return nil
    end

    local preview = self:current_preview_entry()
    if not preview then
        return nil
    end

    local plot = {
        x = self.layout.timeline.x + 28,
        w = self.layout.timeline.w - 56,
    }
    local total_ticks = math.max(format.total_ticks(preview.timing), 1)
    local scale = plot.w / total_ticks
    local clamped_x = math.max(plot.x, math.min(mx, plot.x + plot.w))
    local display_tick = (clamped_x - plot.x) / scale
    local raw_tick = self:display_to_raw_tick(display_tick)
    local snapped_raw_tick = self:snap_tick(raw_tick)

    return {
        tick = self:raw_to_display_tick(snapped_raw_tick),
        label = self.pending_insert.preview_label,
        color = self.pending_insert.color,
    }
end

function App:clear_pending_insert()
    self.pending_insert = nil
end

function App:set_pending_insert(code, preview_label, source_label, color)
    self.pending_insert = {
        code = code,
        preview_label = preview_label,
        source_label = source_label,
        color = color or theme.colors.move,
    }
    self.status_text = string.format("Placement mode: click the timeline to place %s.", preview_label)
end

function App:prompt_special_move(move)
    local lines = {
        "Choose a special move.",
        "",
        "Press Escape to cancel.",
    }
    local buttons = {}
    for i = 1, #SPECIAL_MOVE_CHOICES do
        local choice = SPECIAL_MOVE_CHOICES[i]
        buttons[#buttons + 1] = {
            id = choice.id,
            label = choice.label,
            primary = choice.id == "raw",
        }
    end

    self:show_modal({
        title = "Special Move",
        message = table.concat(lines, "\n"),
        kind = "warning",
        dismiss_id = "cancel",
        buttons = buttons,
        on_result = function(result_id)
            if result_id == "cancel" then
                return
            end

            local choice
            for i = 1, #SPECIAL_MOVE_CHOICES do
                if SPECIAL_MOVE_CHOICES[i].id == result_id then
                    choice = SPECIAL_MOVE_CHOICES[i]
                    break
                end
            end
            if not choice then
                return
            end

            if choice.id == "raw" then
                self:request_integer("Raw byte", "Enter raw byte value (0-255):", 0x41, function(raw)
                    if raw < 0 or raw > 255 or raw % 1 ~= 0 then
                        self:show_modal({
                            title = "Invalid byte",
                            message = "Raw byte must be an integer from 0 to 255.",
                            kind = "warning",
                            buttons = {
                                { id = "ok", label = "OK", primary = true },
                            },
                        })
                        return
                    end

                    self:set_pending_insert(raw, string.format("RAW %02X", raw), move.label, theme.colors.raw)
                end)
                return
            end

            self:set_pending_insert(choice.code, choice.preview_label, move.label, theme.colors.raw)
        end,
    })
end

function App:arm_insert_move(move)
    if not self.selected_entry or not self.current_work then
        self.status_text = "Select an entry before placing a move."
        return
    end

    local code = move.code
    local preview_label = move.label
    local color = theme.colors.move

    if move.special then
        self:prompt_special_move(move)
        return
    elseif move.label == "CHU" or move.label == "HEY" or move.label == "HOLDCHU" or move.label == "HOLDHEY" then
        color = theme.colors.chu
    elseif move.label:match("^HOLD") then
        color = theme.colors.accent
    end

    self:set_pending_insert(code, preview_label, move.label, color)
end

function App:insert_step_at_tick(code, target_tick)
    if not self.selected_entry or not self.current_work then
        return false
    end

    local candidate = snapshot_from_work(self.current_work)
    if #candidate.steps == 0 then
        candidate.steps[1] = format.Step.new(code, 0)
        return self:accept_candidate(candidate, 1, { push_undo = true, success_message = "Placed step." })
    end

    local preview = self:build_preview_entry(self.selected_entry, candidate)
    local nodes = timeline.build_nodes(preview)
    local total_ticks = format.total_ticks(preview.timing)
    local snapped_tick = math.max(0, math.min(self:snap_tick(target_tick - preview.start_delay), total_ticks))
    local insert_after = #nodes

    for i = 1, #nodes do
        local next_tick = (i < #nodes) and nodes[i + 1].raw_tick or total_ticks
        if snapped_tick <= next_tick then
            insert_after = i
            break
        end
    end

    local current_tick = nodes[insert_after].raw_tick
    local next_tick = (insert_after < #nodes) and nodes[insert_after + 1].raw_tick or total_ticks
    local clamped_tick = math.max(current_tick, math.min(snapped_tick, next_tick))
    local lead_gap = clamped_tick - current_tick
    local trailing_gap = next_tick - clamped_tick

    candidate.steps[insert_after].gap = lead_gap
    if insert_after < #candidate.steps then
        table.insert(candidate.steps, insert_after + 1, format.Step.new(code, trailing_gap))
    else
        table.insert(candidate.steps, insert_after + 1, format.Step.new(code, 0))
    end

    return self:accept_candidate(candidate, insert_after + 1, { push_undo = true, success_message = "Placed step." })
end

function App:draw_controls()
    local rect = self.layout.controls
    widgets.draw_panel(rect, { fill = theme.colors.panel_alt, border = theme.colors.border })
    self.controls_hits = {}

    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Place Move", rect.x + 18, rect.y + 14)
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.printf("Arm a move, then click the timeline to place it. Hold Shift to keep that move armed.", rect.x + 108, rect.y + 17, math.max(80, rect.w - 360), "left")

    local rows = self:move_button_rows()
    local metrics = self:move_grid_metrics()
    local start_x = rect.x + 18
    local start_y = rect.y + metrics.start_y
    local button_w = metrics.button_w
    local button_h = metrics.button_h
    local gap_x = metrics.gap_x
    local gap_y = metrics.gap_y

    for row_index = 1, #rows do
        local row = rows[row_index]
        for col_index = 1, #row do
            local move = row[col_index]
            local rect_button = {
                x = start_x + (col_index - 1) * (button_w + gap_x),
                y = start_y + (row_index - 1) * (button_h + gap_y),
                w = button_w,
                h = button_h,
            }
            local button_style = style_for_move_button(move, self.pending_insert and self.pending_insert.source_label == move.label)
            widgets.draw_button(rect_button, move.label, button_style)
            self.controls_hits[#self.controls_hits + 1] = {
                kind = "insert_move",
                move = move,
                rect = rect_button,
            }
        end
    end

    local snap_y = rect.y + 14
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.print("Snap", rect.x + rect.w - 236, snap_y + 4)
    for i = 1, #SNAP_MODES do
        local snap_rect = {
            x = rect.x + rect.w - 192 + (i - 1) * 46,
            y = snap_y,
            w = 40,
            h = 24,
        }
        widgets.draw_button(snap_rect, tostring(SNAP_MODES[i]) .. "t", {
            font = theme.font("tiny"),
            fill = self.snap_index == i and theme.colors.selection_soft or theme.colors.button,
            border = self.snap_index == i and theme.colors.accent or theme.colors.border,
        })
        self.controls_hits[#self.controls_hits + 1] = {
            kind = "snap",
            index = i,
            rect = snap_rect,
        }
    end

    local info_rect = {
        x = rect.x + rect.w - 258,
        y = rect.y + 44,
        w = 240,
        h = 92,
    }
    widgets.draw_panel(info_rect, {
        fill = theme.colors.panel,
        border = theme.colors.border_soft,
        radius = 10,
    })
    local info_x = info_rect.x + 12
    local info_y = info_rect.y + 10
    if self.pending_insert then
        widgets.draw_tag("Placing " .. self.pending_insert.preview_label, rect.x + 18, rect.y + rect.h - 34, {
            fill = theme.colors.selection_soft,
            border = theme.colors.selection,
            text_color = theme.colors.text,
            radius = 6,
            padding_x = 8,
            padding_y = 3,
        })
    end
    local preview = self:current_preview_entry()
    if preview then
        local nodes = timeline.build_nodes(preview)
        local final_gap = timeline.display_final_gap(preview)
        local info_color = final_gap < 0 and theme.colors.danger or (final_gap == 0 and theme.colors.amber or theme.colors.text_dim)
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.print("Current", info_x, info_y)
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.printf(string.format("%dt Total", format.total_ticks(preview.timing)), info_x, info_y + 18, info_rect.w - 24, "right")
        love.graphics.printf(string.format("%dt Start delay", preview.start_delay), info_x, info_y + 34, info_rect.w - 24, "right")
        love.graphics.setColor(info_color[1], info_color[2], info_color[3], 1)
        love.graphics.printf(string.format("%dt Final gap", final_gap), info_x, info_y + 50, info_rect.w - 24, "right")
        if self.selected_step_index and nodes[self.selected_step_index] then
            love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
            love.graphics.printf(string.format("%dt Selected tick", nodes[self.selected_step_index].tick), info_x, info_y + 66, info_rect.w - 24, "right")
        end
    end
end

function App:draw_inspector()
    local rect = self.layout.right
    widgets.draw_panel(rect, { fill = theme.colors.panel_alt, border = theme.colors.border })
    self.inspector_hits = {}

    local y = rect.y + 18
    y = self:draw_entry_header(rect.x + 18, y, self.selected_entry, rect.w - 36)

    local entry = self.selected_entry
    if not entry or not self.current_work then
        love.graphics.setFont(theme.font("small"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("Open a file and select an entry to inspect it.", rect.x + 18, y + 12, rect.w - 36, "left")
        return
    end

    local preview = self:build_preview_entry(entry, self.current_work)
    local total_ticks = format.total_ticks(preview.timing)
    local nodes = timeline.build_nodes(preview)
    local final_gap = timeline.display_final_gap(preview)
    local rescue = rules.detect_rescue_section(entry)
    local scan = rules.scan_animation_indices(entry)

    local tags_y = y + 4
    local tag_x = rect.x + 18
    local function draw_flag(label, fill, border, text_color)
        local width = widgets.draw_tag(label, tag_x, tags_y, {
            fill = fill,
            border = border,
            text_color = text_color,
            radius = 6,
            padding_x = 8,
            padding_y = 3,
        })
        tag_x = tag_x + width + 8
    end
    if rescue then
        draw_flag("Rescue Section", { 0.30, 0.21, 0.08, 1.0 }, theme.colors.amber, theme.colors.amber)
    end
    if preview.start_delay > 0 then
        draw_flag("Lyrics", { 0.14, 0.22, 0.32, 1.0 }, theme.colors.accent, theme.colors.accent)
    end
    if self.current_dirty then
        draw_flag("Modified", { 0.20, 0.18, 0.08, 1.0 }, theme.colors.amber, theme.colors.amber)
    end

    local info_y = y + 42
    local function line(label, value, color, editable_key)
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.print(label, rect.x + 18, info_y)
        love.graphics.setFont(theme.font("small"))
        local text_color = color or theme.colors.text
        love.graphics.setColor(text_color[1], text_color[2], text_color[3], 1)
        love.graphics.print(value, rect.x + 132, info_y - 2)
        if editable_key then
            local edit_rect = { x = rect.x + rect.w - 78, y = info_y - 4, w = 54, h = 22 }
            widgets.draw_button(edit_rect, "Edit", { font = theme.font("tiny") })
            self.inspector_hits[#self.inspector_hits + 1] = { kind = editable_key, rect = edit_rect }
        end
        info_y = info_y + 24
    end

    line("Entry", entry.name)
    line("Step count", tostring(#self.current_work.steps), (#self.current_work.steps < scan.min_safe_step_count) and theme.colors.danger or theme.colors.text)
    line("Timing", tostring(preview.timing), theme.colors.text, "edit_timing")
    line("Total ticks", tostring(total_ticks))
    line("Start delay", tostring(preview.start_delay) .. "t", theme.colors.text, "edit_start_delay")
    local final_gap_color = final_gap < 0 and theme.colors.danger or (final_gap == 0 and theme.colors.amber or theme.colors.text)
    line("Final gap", tostring(final_gap) .. "t", final_gap_color)
    if #scan.indices > 0 then
        line("Anim min", tostring(scan.min_safe_step_count))
        line("Anim refs", table.concat(scan.indices, ", "))
    end

    local variants = self:selected_root_variants()
    if has_base_family(entry) and #variants > 0 then
        local clone_rect = { x = rect.x + 18, y = info_y + 4, w = rect.w - 36, h = 26 }
        widgets.draw_button(clone_rect, string.format("Clone %s into %d sibling%s", entry.name, #variants, #variants == 1 and "" or "s"), {
            font = theme.font("tiny"),
            fill = theme.colors.button,
            border = theme.colors.border_soft,
        })
        self.inspector_hits[#self.inspector_hits + 1] = { kind = "clone_variants", rect = clone_rect }
        info_y = info_y + 34
    end

    local detail_y = info_y + 8
    local detail_rect = {
        x = rect.x + 14,
        y = detail_y,
        w = rect.w - 28,
        h = rect.h - (detail_y - rect.y) - 18,
    }
    widgets.draw_panel(detail_rect, { fill = theme.colors.panel, border = theme.colors.border_soft, radius = 10 })
    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Selected Step", detail_rect.x + 14, detail_rect.y + 12)

    local sy = detail_rect.y + 38
    if self.selected_step_index and nodes[self.selected_step_index] then
        local node = nodes[self.selected_step_index]
        local step = self.current_work.steps[self.selected_step_index]
        local function step_line(label, value, editable_key)
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
            love.graphics.print(label, detail_rect.x + 14, sy)
            love.graphics.setFont(theme.font("small"))
            love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
            love.graphics.print(value, detail_rect.x + 118, sy - 2)
            if editable_key then
                local edit_rect = { x = detail_rect.x + detail_rect.w - 70, y = sy - 4, w = 46, h = 22 }
                widgets.draw_button(edit_rect, "Edit", { font = theme.font("tiny") })
                self.inspector_hits[#self.inspector_hits + 1] = { kind = editable_key, rect = edit_rect }
            end
            sy = sy + 24
        end

        step_line("Step index", tostring(self.selected_step_index - 1))
        step_line("Move", node.label)
        if format.is_raw_byte(step.code) then
            step_line("Raw byte", string.format("0x%02X", step.code), "edit_raw")
        end
        step_line("Tick", tostring(node.tick) .. "t", self.selected_step_index > 1 and "edit_tick" or nil)
        if self.selected_step_index == 1 then
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3], 1)
            love.graphics.printf(
                first_step_fixed_message(self.current_work.start_delay),
                detail_rect.x + 14,
                sy - 4,
                detail_rect.w - 28,
                "left"
            )
            sy = sy + 34
        end
        if self.selected_step_index < #nodes then
            step_line("Gap after", tostring(step.gap) .. "t", "edit_gap")
        else
            step_line("Gap after", tostring(node.gap_after) .. "t")
        end

        local move_prev = { x = detail_rect.x + 14, y = sy + 4, w = 92, h = 24 }
        local move_next = { x = detail_rect.x + 112, y = sy + 4, w = 92, h = 24 }
        local move_raw = { x = detail_rect.x + 210, y = sy + 4, w = 72, h = 24 }
        widgets.draw_button(move_prev, "Prev Move", { font = theme.font("tiny") })
        widgets.draw_button(move_next, "Next Move", { font = theme.font("tiny") })
        widgets.draw_button(move_raw, "Set RAW", { font = theme.font("tiny") })
        self.inspector_hits[#self.inspector_hits + 1] = { kind = "move_prev", rect = move_prev }
        self.inspector_hits[#self.inspector_hits + 1] = { kind = "move_next", rect = move_next }
        self.inspector_hits[#self.inspector_hits + 1] = { kind = "set_raw", rect = move_raw }

        local duplicate_rect = { x = detail_rect.x + 14, y = sy + 36, w = 88, h = 24 }
        local delete_rect = { x = detail_rect.x + 110, y = sy + 36, w = 88, h = 24 }
        widgets.draw_button(duplicate_rect, "Duplicate", { font = theme.font("tiny") })
        widgets.draw_button(delete_rect, "Delete", { font = theme.font("tiny"), fill = { 0.32, 0.14, 0.16, 1.0 }, hover_fill = { 0.42, 0.16, 0.18, 1.0 }, border = theme.colors.danger })
        self.inspector_hits[#self.inspector_hits + 1] = { kind = "duplicate", rect = duplicate_rect }
        self.inspector_hits[#self.inspector_hits + 1] = { kind = "delete", rect = delete_rect }
        sy = sy + 74
    else
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("Click a node in the timeline to inspect or edit that step.", detail_rect.x + 14, sy, detail_rect.w - 28, "left")
        sy = sy + 34
    end

    if rescue then
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.amber[1], theme.colors.amber[2], theme.colors.amber[3], 1)
        love.graphics.print("Rescue IDs preview", detail_rect.x + 14, sy)
        sy = sy + 18
        local expanded = rules.expand_rescue_ids(entry, entry.rest_body, #self.current_work.steps)
        local count = math.max(#self.current_work.steps - 1, 0)
        local ids = {}
        for i = 0, count - 1 do
            ids[#ids + 1] = string.format("0x%02X", format.u16(expanded, i * 2))
        end
        love.graphics.setColor(theme.colors.text_dim[1], theme.colors.text_dim[2], theme.colors.text_dim[3], 1)
        love.graphics.printf(table.concat(ids, "  "), detail_rect.x + 14, sy, detail_rect.w - 28, "left")
        sy = sy + 28
    end

    if #self.current_validation.warnings > 0 or #self.current_validation.errors > 0 then
        love.graphics.setFont(theme.font("tiny"))
        local heading_color = (#self.current_validation.errors > 0) and theme.colors.danger or theme.colors.amber
        love.graphics.setColor(heading_color[1], heading_color[2], heading_color[3], 1)
        love.graphics.print("Validation", detail_rect.x + 14, sy)
        sy = sy + 18
        for _, message in ipairs(self.current_validation.errors) do
            love.graphics.setColor(theme.colors.danger[1], theme.colors.danger[2], theme.colors.danger[3], 1)
            love.graphics.printf("- " .. message, detail_rect.x + 14, sy, detail_rect.w - 28, "left")
            sy = sy + 28
        end
        for _, message in ipairs(self.current_validation.warnings) do
            love.graphics.setColor(theme.colors.amber[1], theme.colors.amber[2], theme.colors.amber[3], 1)
            love.graphics.printf("- " .. message, detail_rect.x + 14, sy, detail_rect.w - 28, "left")
            sy = sy + 28
        end
    end
end

function App:draw()
    self:draw_background()
    self:draw_topbar()
    self:draw_editor_toolbar()
    self:draw_view_transition()

    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    local status_x
    local status_y
    if self.active_view == "mods" then
        status_x = self.layout.mods.x
        status_y = self.layout.mods.y + self.layout.mods.h + 4
    elseif self.active_view == "menu" then
        status_x = 18
        status_y = love.graphics.getHeight() - 22
    else
        status_x = self.layout.timeline.x
        status_y = self.layout.timeline.y + self.layout.timeline.h + 4
    end
    love.graphics.print(self.status_text, status_x, status_y)
    self:draw_modal()
end

function App:add_move(move)
    self:arm_insert_move(move)
end

function App:delete_selected_step()
    if not self.selected_entry or not self.current_work or not self.selected_step_index then
        return
    end

    local candidate = snapshot_from_work(self.current_work)
    local idx = self.selected_step_index
    local preview = self:build_preview_entry(self.selected_entry, candidate)
    local nodes = timeline.build_nodes(preview)
    local final_gap = (#nodes > 0 and nodes[#nodes].raw_gap_after) or 0

    if idx == 1 then
        table.remove(candidate.steps, idx)
    elseif idx < #candidate.steps then
        candidate.steps[idx - 1].gap = candidate.steps[idx - 1].gap + candidate.steps[idx].gap
        table.remove(candidate.steps, idx)
    else
        candidate.steps[idx - 1].gap = candidate.steps[idx - 1].gap + final_gap
        table.remove(candidate.steps, idx)
    end

    local new_selection = nil
    if #candidate.steps > 0 then
        new_selection = math.min(idx, #candidate.steps)
    end
    self:accept_candidate(candidate, new_selection, { push_undo = true, success_message = "Deleted step." })
end

function App:duplicate_selected_step()
    if not self.current_work or not self.selected_step_index then
        return
    end
    local selected = self.current_work.steps[self.selected_step_index]
    if not selected then
        return
    end
    self.pending_insert = {
        code = selected.code,
        preview_label = "DUP " .. format.step_display_name(selected.code),
        source_label = nil,
        color = format.is_raw_byte(selected.code) and theme.colors.raw
            or ((selected.code == format.INV.CHU or selected.code == format.INV.HEY or selected.code == format.INV.HOLDCHU or selected.code == format.INV.HOLDHEY) and theme.colors.chu)
            or theme.colors.move,
    }
    self.status_text = "Placement mode: click the timeline to place the duplicate step."
end

function App:cycle_selected_move(delta)
    if not self.current_work or not self.selected_step_index then
        return
    end
    local step = self.current_work.steps[self.selected_step_index]
    local idx = step_cycle_index(step.code) or 1
    idx = ((idx - 1 + delta) % #MOVE_CYCLE) + 1
    self:set_selected_code(MOVE_CYCLE[idx])
end

function App:set_selected_code(code)
    if not self.current_work or not self.selected_step_index then
        return
    end
    local candidate = snapshot_from_work(self.current_work)
    candidate.steps[self.selected_step_index].code = code
    self:accept_candidate(candidate, self.selected_step_index, { push_undo = true, success_message = "Changed move type." })
end

function App:set_selected_raw_code()
    if not self.current_work or not self.selected_step_index then
        return
    end
    local current = self.current_work.steps[self.selected_step_index].code
    self:request_integer("Raw byte", "Enter raw byte value (0-255):", current, function(raw)
        if raw < 0 or raw > 255 or raw % 1 ~= 0 then
            self:show_modal({
                title = "Invalid byte",
                message = "Raw byte must be an integer from 0 to 255.",
                kind = "warning",
                buttons = {
                    { id = "ok", label = "OK", primary = true },
                },
            })
            return
        end
        self:set_selected_code(raw)
    end)
end

function App:edit_start_delay()
    if not self.current_work then
        return
    end
    self:request_integer("Start delay", "Enter start delay in ticks:", self.current_work.start_delay, function(value)
        local candidate = snapshot_from_work(self.current_work)
        candidate.start_delay = value
        self:accept_candidate(candidate, self.selected_step_index, { push_undo = true, success_message = "Updated start delay." })
    end)
end

function App:edit_timing()
    if not self.current_work then
        return
    end
    self:request_integer("Timing", "Enter timing in quarter-note units:", self.current_work.timing, function(value)
        local candidate = snapshot_from_work(self.current_work)
        candidate.timing = value
        self:accept_candidate(candidate, self.selected_step_index, { push_undo = true, success_message = "Updated timing." })
    end)
end

function App:edit_selected_gap()
    if not self.current_work or not self.selected_step_index then
        return
    end
    if self.selected_step_index >= #self.current_work.steps then
        return
    end
    local current_gap = self.current_work.steps[self.selected_step_index].gap
    self:request_integer("Gap after step", "Enter gap after this step in ticks:", current_gap, function(value)
        local candidate = snapshot_from_work(self.current_work)
        candidate.steps[self.selected_step_index].gap = value
        self:accept_candidate(candidate, self.selected_step_index, { push_undo = true, success_message = "Updated step gap." })
    end)
end

function App:move_step_to_tick_in_candidate(candidate, target_tick)
    local idx = self.selected_step_index
    if not idx or idx <= 1 then
        return false, first_step_fixed_message(candidate and candidate.start_delay or 0)
    end

    local preview = self:build_preview_entry(self.selected_entry, candidate)
    local nodes = timeline.build_nodes(preview)
    local node = nodes[idx]
    if not node then
        return false, "Selected step is missing."
    end

    local prev_tick = nodes[idx - 1].raw_tick
    local next_tick = (idx < #nodes) and nodes[idx + 1].raw_tick or format.total_ticks(preview.timing)
    local clamped_tick = math.max(prev_tick, math.min(target_tick, next_tick))

    candidate.steps[idx - 1].gap = clamped_tick - prev_tick
    if idx < #candidate.steps then
        candidate.steps[idx].gap = next_tick - clamped_tick
    end
    return true, clamped_tick
end

function App:edit_selected_tick()
    if not self.current_work or not self.selected_step_index then
        return
    end
    if self.selected_step_index <= 1 then
        self.status_text = first_step_fixed_message(self.current_work.start_delay)
        return
    end

    local nodes = timeline.build_nodes(self:build_preview_entry(self.selected_entry, self.current_work))
    local current_tick = nodes[self.selected_step_index].tick
    self:request_integer("Step tick", "Enter the selected step tick position:", current_tick, function(value)
        local candidate = snapshot_from_work(self.current_work)
        local ok, result = self:move_step_to_tick_in_candidate(candidate, self:display_to_raw_tick(value))
        if not ok then
            self.status_text = result
            self:show_modal({
                title = "Move blocked",
                message = result,
                kind = "warning",
                buttons = {
                    { id = "ok", label = "OK", primary = true },
                },
            })
            return
        end
        if self:accept_candidate(candidate, self.selected_step_index, { push_undo = true, success_message = "Updated step tick." }) then
            self.status_text = string.format("Updated step tick to %dt.", self:raw_to_display_tick(result))
        end
    end)
end

function App:undo()
    if not self.current_work or #self.undo_stack == 0 then
        return
    end
    self.redo_stack[#self.redo_stack + 1] = snapshot_from_work(self.current_work)
    self.current_work = table.remove(self.undo_stack)
    self.current_validation = self:validate_work(self.selected_entry, self.current_work)
    self:update_draft_from_current()
    self.status_text = "Undo."
end

function App:redo()
    if not self.current_work or #self.redo_stack == 0 then
        return
    end
    self.undo_stack[#self.undo_stack + 1] = snapshot_from_work(self.current_work)
    self.current_work = table.remove(self.redo_stack)
    self.current_validation = self:validate_work(self.selected_entry, self.current_work)
    self:update_draft_from_current()
    self.status_text = "Redo."
end

function App:begin_drag(index)
    if not self.current_work or not index then
        return
    end
    self.selected_step_index = index
    self.drag = {
        index = index,
        original = snapshot_from_work(self.current_work),
        changed = false,
    }
end

function App:update_drag(x)
    if not self.drag or not self.timeline_render then
        return
    end
    if self.drag.index <= 1 then
        self.status_text = first_step_fixed_message(self.current_work and self.current_work.start_delay or 0)
        return
    end

    local display_tick = timeline.tick_from_x(self.timeline_render, x)
    if not display_tick then
        return
    end
    local snap = SNAP_MODES[self.snap_index]
    local raw_tick = self:display_to_raw_tick(display_tick)
    local snapped_tick = math.floor(raw_tick / snap + 0.5) * snap

    local candidate = snapshot_from_work(self.drag.original)
    local ok, result = self:move_step_to_tick_in_candidate(candidate, snapped_tick)
    if not ok then
        self.status_text = result
        return
    end

    local validation = self:validate_work(self.selected_entry, candidate)
    if not validation.ok then
        self.status_text = validation.errors[1]
        return
    end

    self.current_work = candidate
    self.current_validation = validation
    self:update_draft_from_current()
    self.drag.changed = true
    self.status_text = string.format("Dragged step to %dt.", self:raw_to_display_tick(result))
end

function App:end_drag()
    if not self.drag then
        return
    end
    if self.drag.changed then
        self:push_undo_snapshot(self.drag.original)
        self.status_text = "Moved step."
    else
        self.current_work = self.drag.original
        self.current_validation = self:validate_work(self.selected_entry, self.current_work)
        self:update_draft_from_current()
    end
    self.drag = nil
end

function App:draw_button_panel_message()
end

function App:activate_main_menu_button(button_id)
    if button_id == "mods" then
        self:prompt_noize_protocol_registration()
        return
    end
    if button_id == "launch" then
        self:launch_game()
        return
    end
    if button_id == "editor" then
        self:switch_view("editor")
        self.status_text = "Entered editor."
        return
    end
    if button_id == "settings" then
        self:show_info("Settings", "A dedicated settings menu is coming later. This button is a placeholder for now.")
        return
    end
end

function App:activate_header_target(target_id)
    if target_id == "main_menu" then
        self:switch_view("menu")
        self.status_text = "Returned to Main Menu."
        return
    end
    if target_id == "editor" then
        self:switch_view("editor")
        return
    end
    if target_id == "mods" then
        self:switch_view("mods")
        return
    end
end

function App:mousepressed(x, y, button)
    if self.modal then
        if button == 1 then
            for _, hit in ipairs(self.modal_hits) do
                if widgets.point_in_rect(x, y, hit.rect) then
                    self:dismiss_modal(hit.id)
                    return
                end
            end
        end
        return
    end

    if self.view_transition then
        return
    end

    if button == 1 then
        for i = 1, #self.header_hits do
            local hit = self.header_hits[i]
            if widgets.point_in_rect(x, y, hit.rect) then
                if hit.kind == "back" then
                    if not hit.disabled then
                        self:switch_view("menu")
                        self.status_text = "Returned to Main Menu."
                    end
                else
                    self:activate_header_target(hit.id)
                end
                return
            end
        end
    end

    if self.active_view == "menu" then
        if button == 1 then
            for i = 1, #self.recent_hits do
                local hit = self.recent_hits[i]
                if widgets.point_in_rect(x, y, hit.rect) then
                    if file_exists(hit.path) then
                        self:open_file(hit.path)
                        self:switch_view("editor")
                    else
                        self:show_error("Recent File", "That recent file could not be found anymore.")
                    end
                    return
                end
            end
            for i = 1, #self.release_hits do
                local hit = self.release_hits[i]
                if widgets.point_in_rect(x, y, hit.rect) then
                    if hit.action == "prompt_enable" then
                        self:prompt_gamebanana_previews()
                    elseif hit.action == "download" and hit.uri then
                        self:handle_noize_uri(hit.uri)
                    end
                    return
                end
            end
            for i = 1, #self.menu_hits do
                local hit = self.menu_hits[i]
                if widgets.point_in_rect(x, y, hit.rect) then
                    self:activate_main_menu_button(hit.id)
                    return
                end
            end
        end
        return
    end

    if self.active_view == "editor" then
        local buttons = self:buttons()
        if button == 1 then
            if widgets.point_in_rect(x, y, buttons.open) then
                self:open_file_dialog()
                return
            elseif widgets.point_in_rect(x, y, buttons.apply) then
                self:apply_current_entry()
                return
            elseif widgets.point_in_rect(x, y, buttons.patch) then
                self:patch_copy()
                return
            elseif widgets.point_in_rect(x, y, buttons.settings) then
                self:prompt_for_game_root()
                return
            end
        end
    end

    if self.active_view == "mods" then
        local hit = mods_tab.mousepressed(self.mods_tab, x, y, button)
        if hit then
            if hit.kind == "install_mod" then
                self:install_mod_dialog()
            elseif hit.kind == "restore_originals" then
                self:restore_original_files()
            elseif hit.kind == "back_to_editor" then
                self:switch_view("editor")
            elseif hit.kind == "enable_mod" then
                self.mods_tab.selected_name = hit.mod_name
                self:enable_selected_mod()
            elseif hit.kind == "disable_mod" then
                self.mods_tab.selected_name = hit.mod_name
                self:disable_selected_mod()
            elseif hit.kind == "uninstall_mod" then
                self.mods_tab.selected_name = hit.mod_name
                self:uninstall_selected_mod()
            end
            return
        end
        return
    end

    local tree_result = tree.mousepressed(self.tree, self.layout.left, x, y, button)
    if tree_result and tree_result.kind == "entry" then
        self:select_entry(tree_result.entry)
        return
    end

    if button == 1 then
        for _, hit in ipairs(self.controls_hits) do
            if widgets.point_in_rect(x, y, hit.rect) then
                if hit.kind == "insert_move" then
                    self:add_move(hit.move)
                elseif hit.kind == "snap" then
                    self.snap_index = hit.index
                    self.status_text = "Snap set to " .. SNAP_MODES[self.snap_index] .. "t."
                end
                return
            end
        end

        for _, hit in ipairs(self.inspector_hits) do
            if widgets.point_in_rect(x, y, hit.rect) then
                if hit.kind == "edit_start_delay" then
                    self:edit_start_delay()
                elseif hit.kind == "edit_timing" then
                    self:edit_timing()
                elseif hit.kind == "edit_gap" then
                    self:edit_selected_gap()
                elseif hit.kind == "edit_tick" then
                    self:edit_selected_tick()
                elseif hit.kind == "edit_raw" then
                    self:set_selected_raw_code()
                elseif hit.kind == "move_prev" then
                    self:cycle_selected_move(-1)
                elseif hit.kind == "move_next" then
                    self:cycle_selected_move(1)
                elseif hit.kind == "set_raw" then
                    self:set_selected_raw_code()
                elseif hit.kind == "duplicate" then
                    self:duplicate_selected_step()
                elseif hit.kind == "delete" then
                    self:delete_selected_step()
                elseif hit.kind == "clone_variants" then
                    self:clone_root_to_variants()
                end
                return
            end
        end

        if widgets.point_in_rect(x, y, self.layout.timeline) then
            if self.pending_insert then
                local display_tick = timeline.tick_from_x(self.timeline_render, x)
                if display_tick then
                    if self:insert_step_at_tick(self.pending_insert.code, display_tick) then
                        local keep_armed = love.keyboard.isDown("lshift", "rshift")
                        self.status_text = "Placed " .. self.pending_insert.preview_label .. "."
                        if keep_armed then
                            self.status_text = self.status_text .. " Still armed."
                        else
                            self:clear_pending_insert()
                        end
                    end
                end
                return
            end
            local index = timeline.hit_test(self.timeline_render, x, y)
            if index then
                self.selected_step_index = index
                self:begin_drag(index)
            end
        end
    end
end

function App:mousereleased(_, _, button)
    if self.view_transition then
        return
    end
    if self.active_view == "editor" and button == 1 then
        self:end_drag()
    end
end

function App:mousemoved(x)
    if self.view_transition then
        return
    end
    if self.active_view == "editor" and self.drag then
        self:update_drag(x)
    end
end

function App:wheelmoved(_, y)
    if self.view_transition then
        return
    end
    local mx, my = love.mouse.getPosition()
    if self.active_view == "mods" then
        mods_tab.wheelmoved(self.mods_tab, mx, my, y)
    else
        tree.wheelmoved(self.tree, self.layout.left, mx, my, y)
    end
end

function App:keypressed(key)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    local shift = love.keyboard.isDown("lshift", "rshift")

    if self.modal then
        if self.modal.input then
            local input = self.modal.input
            if key == "backspace" then
                if input.replace_on_type then
                    input.text = ""
                    input.replace_on_type = false
                else
                    input.text = string.sub(input.text, 1, math.max(0, #input.text - 1))
                end
                input.error = nil
                return
            end
            if ctrl and key == "v" and love.system and love.system.getClipboardText then
                local clip = love.system.getClipboardText() or ""
                if input.replace_on_type then
                    input.text = clip
                    input.replace_on_type = false
                else
                    input.text = input.text .. clip
                end
                input.error = nil
                return
            end
        end
        if key == "escape" then
            self:dismiss_modal(self.modal.dismiss_id or "cancel")
            return
        end
        if key == "return" or key == "kpenter" or key == "space" then
            local buttons = self.modal.buttons or {}
            local chosen = nil
            for i = 1, #buttons do
                if buttons[i].primary then
                    chosen = buttons[i]
                    break
                end
            end
            if not chosen then
                chosen = buttons[#buttons]
            end
            if chosen then
                self:dismiss_modal(chosen.id)
            else
                self:dismiss_modal("ok")
            end
            return
        end
        return
    end

    if self.view_transition then
        return
    end

    if self.active_view == "menu" then
        if key == "return" or key == "kpenter" or key == "space" then
            self:activate_main_menu_button("editor")
        end
        return
    end

    if self.active_view == "mods" then
        if key == "escape" then
            self:switch_view("menu")
        end
        return
    end

    if key == "escape" then
        if self.pending_insert then
            self:clear_pending_insert()
            self.status_text = "Placement canceled."
            return
        end
        self.selected_step_index = nil
        self.status_text = "Step selection cleared."
        return
    end

    if ctrl and key == "z" and not shift then
        self:undo()
        return
    end

    if ctrl and (key == "y" or (shift and key == "z")) then
        self:redo()
        return
    end

    if ctrl and key == "s" then
        self:patch_copy()
        return
    end

    if key == "delete" or key == "backspace" then
        self:delete_selected_step()
    end
end

function App:textinput(text)
    if self.view_transition or not self.modal or not self.modal.input then
        return
    end

    local input = self.modal.input
    if input.replace_on_type then
        input.text = text
        input.replace_on_type = false
    else
        input.text = input.text .. text
    end
    input.error = nil
end

function App:filedropped(file)
    local name = "dropped_mod.zip"
    local ok_name = pcall(function()
        name = basename(file:getFilename())
    end)
    if not ok_name then
        name = "dropped_mod.zip"
    end
    if name:lower():sub(-4) ~= ".zip" then
        self:show_error("Install Mod", "Dropped file is not a .zip archive.")
        return
    end

    local opened = file:open("r")
    if not opened then
        self:show_error("Install Mod", "Could not open the dropped zip file.")
        return
    end
    local data = file:read()
    file:close()
    if not data or data == "" then
        self:show_error("Install Mod", "Dropped zip file was empty.")
        return
    end

    self:switch_view("mods")
    local installed, err = modcore.install_zip_bytes(name, data, self.mod_base_dir)
    if not installed then
        self:show_error("Install Mod", err or "Dropped mod install failed.")
        return
    end
    self:refresh_installed_mods()
    self.mods_tab.selected_name = installed.folder_name
    self.status_text = "Installed mod: " .. installed.name
end

return App
