local theme = require("ui.theme")
local widgets = require("ui.widgets")

local M = {}

local function clamp_scroll(state)
    local rect = state.list_rect
    if not rect then
        return
    end
    local max_scroll = math.max(0, state.content_height - rect.h)
    if state.scroll < 0 then
        state.scroll = 0
    elseif state.scroll > max_scroll then
        state.scroll = max_scroll
    end
end

local function selected_mod(mods, selected_name)
    for i = 1, #(mods or {}) do
        if mods[i].folder_name == selected_name then
            return mods[i]
        end
    end
    return nil
end

local function status_style(mod)
    if mod.invalid then
        return "Invalid", theme.colors.danger, theme.colors.danger_soft
    end
    if mod.enabled then
        return "Enabled", theme.colors.success, theme.colors.success_soft
    end
    return "Disabled", theme.colors.text_dim, theme.colors.panel_soft
end

local function draw_file_tags(files, x, y, max_width)
    local cursor_x = x
    local cursor_y = y
    local line_h = 0
    local font = theme.font("tiny")
    for i = 1, #(files or {}) do
        local text = files[i]
        local width = font:getWidth(text) + 16
        local height = font:getHeight() + 8
        if cursor_x + width > x + max_width then
            cursor_x = x
            cursor_y = cursor_y + line_h + 8
            line_h = 0
        end
        widgets.draw_tag(text, cursor_x, cursor_y, {
            fill = theme.colors.panel_elevated,
            border = theme.colors.border_soft,
            text_color = theme.colors.text,
            padding_x = 8,
            padding_y = 4,
            radius = 6,
        })
        cursor_x = cursor_x + width + 8
        line_h = math.max(line_h, height)
    end
    return cursor_y + line_h
end

local function draw_root_notice(rect, options)
    widgets.draw_panel(rect, {
        fill = options.valid_game_root and theme.colors.panel_soft or theme.colors.danger_soft,
        border = options.valid_game_root and theme.colors.border_soft or theme.colors.danger,
        radius = 10,
    })

    love.graphics.setFont(theme.font("tiny"))
    local root_color = options.valid_game_root and theme.colors.text_dim or theme.colors.danger
    love.graphics.setColor(root_color[1], root_color[2], root_color[3], 1)
    love.graphics.printf(
        options.valid_game_root and ("Game root: " .. (options.game_root or "(not set)")) or "Game root is missing or invalid.",
        rect.x + 12,
        rect.y + 8,
        rect.w - 24,
        "left"
    )
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.printf("Drop a .zip on this tab or use Install Mod to import a package.", rect.x + 12, rect.y + 22, rect.w - 24, "left")
end

local function draw_mod_card(mod, item_rect, is_selected)
    widgets.draw_panel(item_rect, {
        fill = is_selected and theme.colors.selection_soft or theme.colors.panel_soft,
        border = mod.invalid and theme.colors.danger or (is_selected and theme.colors.selection or theme.colors.border_soft),
        radius = 10,
    })

    love.graphics.setFont(theme.font("small"))
    local name_color = mod.invalid and theme.colors.danger or theme.colors.text
    love.graphics.setColor(name_color[1], name_color[2], name_color[3], 1)
    love.graphics.print(mod.name or mod.folder_name, item_rect.x + 12, item_rect.y + 10)

    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_dim[1], theme.colors.text_dim[2], theme.colors.text_dim[3], 1)
    love.graphics.print("v" .. tostring(mod.version or "?"), item_rect.x + 12, item_rect.y + 32)

    local status_text, status_color, status_fill = status_style(mod)
    widgets.draw_tag(status_text, item_rect.x + item_rect.w - 96, item_rect.y + 10, {
        fill = status_fill,
        border = status_color,
        text_color = status_color,
        radius = 6,
        padding_x = 8,
        padding_y = 3,
    })

    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    local summary = mod.invalid and (mod.invalid_reason or "Invalid install.") or (mod.description or "")
    love.graphics.printf(summary, item_rect.x + 12, item_rect.y + 48, item_rect.w - 24, "left")
end

local function detail_line(detail_rect, y, label, value, color)
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.print(label, detail_rect.x + 14, y)
    love.graphics.setFont(theme.font("small"))
    local text_color = color or theme.colors.text
    love.graphics.setColor(text_color[1], text_color[2], text_color[3], 1)
    love.graphics.printf(value or "", detail_rect.x + 118, y - 2, detail_rect.w - 132, "left")
    return y + 24
end

function M.new_state()
    return {
        selected_name = nil,
        scroll = 0,
        content_height = 0,
        list_rect = nil,
        hit_regions = {},
    }
end

function M.sync_selection(state, mods)
    if selected_mod(mods, state.selected_name) then
        return
    end
    state.selected_name = mods[1] and mods[1].folder_name or nil
    state.scroll = 0
end

function M.selected_mod(state, mods)
    return selected_mod(mods, state.selected_name)
end

function M.draw(state, rect, mods, options)
    options = options or {}
    M.sync_selection(state, mods)
    state.hit_regions = {}

    widgets.draw_panel(rect, { fill = theme.colors.panel_alt, border = theme.colors.border })

    local toolbar_y = rect.y + 16
    local install_rect = { x = rect.x + 18, y = toolbar_y, w = 116, h = 30 }
    local restore_rect = { x = rect.x + 142, y = toolbar_y, w = 148, h = 30 }
    local back_rect = { x = rect.x + rect.w - 144, y = toolbar_y, w = 126, h = 30 }
    widgets.draw_button(install_rect, "Install Mod...", {})
    widgets.draw_button(restore_rect, "Restore Originals", {})
    widgets.draw_button(back_rect, "Back to Editor", {})
    state.hit_regions[#state.hit_regions + 1] = { kind = "install_mod", rect = install_rect }
    state.hit_regions[#state.hit_regions + 1] = { kind = "restore_originals", rect = restore_rect }
    state.hit_regions[#state.hit_regions + 1] = { kind = "back_to_editor", rect = back_rect }

    local root_rect = {
        x = rect.x + 18,
        y = toolbar_y + 40,
        w = rect.w - 36,
        h = 42,
    }
    draw_root_notice(root_rect, options)

    local list_rect = {
        x = rect.x + 18,
        y = rect.y + 98,
        w = 310,
        h = rect.h - 116,
    }
    local detail_rect = {
        x = list_rect.x + list_rect.w + 16,
        y = list_rect.y,
        w = rect.w - list_rect.w - 52,
        h = list_rect.h,
    }

    state.list_rect = list_rect
    widgets.draw_panel(list_rect, { fill = theme.colors.panel, border = theme.colors.border_soft })
    widgets.draw_panel(detail_rect, { fill = theme.colors.panel, border = theme.colors.border_soft })

    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Installed Mods", list_rect.x + 14, list_rect.y + 12)

    widgets.scissor_push({
        x = list_rect.x + 8,
        y = list_rect.y + 38,
        w = list_rect.w - 16,
        h = list_rect.h - 46,
    })

    local cursor_y = list_rect.y + 42 - state.scroll
    local item_h = 74
    for i = 1, #mods do
        local mod = mods[i]
        local item_rect = { x = list_rect.x + 8, y = cursor_y, w = list_rect.w - 16, h = item_h }
        if item_rect.y + item_rect.h >= list_rect.y and item_rect.y <= list_rect.y + list_rect.h then
            draw_mod_card(mod, item_rect, mod.folder_name == state.selected_name)
        end
        state.hit_regions[#state.hit_regions + 1] = { kind = "select_mod", rect = item_rect, mod_name = mod.folder_name }
        cursor_y = cursor_y + item_h + 8
    end
    state.content_height = math.max(0, cursor_y - (list_rect.y + 42) + state.scroll)
    widgets.scissor_pop()
    clamp_scroll(state)

    local mod = M.selected_mod(state, mods)
    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Mod Details", detail_rect.x + 14, detail_rect.y + 12)

    if not mod then
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("Install a mod zip to get started.", detail_rect.x + 14, detail_rect.y + 44, detail_rect.w - 28, "left")
        return
    end

    local y = detail_rect.y + 44
    y = detail_line(detail_rect, y, "Name", mod.name or mod.folder_name)
    y = detail_line(detail_rect, y, "Version", tostring(mod.version or "?"))
    if mod.author and mod.author ~= "" then
        y = detail_line(detail_rect, y, "Author", mod.author)
    end
    if mod.game_version and mod.game_version ~= "" then
        y = detail_line(detail_rect, y, "Game ver", mod.game_version)
    end
    local status_text, status_color = status_style(mod)
    y = detail_line(detail_rect, y, "Status", status_text, status_color)
    y = detail_line(detail_rect, y, "Folder", mod.folder_name or "")

    local desc_rect = {
        x = detail_rect.x + 14,
        y = y + 4,
        w = detail_rect.w - 28,
        h = 84,
    }
    widgets.draw_panel(desc_rect, { fill = theme.colors.panel_soft, border = theme.colors.border_soft, radius = 10 })
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.print("Description", desc_rect.x + 10, desc_rect.y + 8)
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.printf(mod.description or "", desc_rect.x + 10, desc_rect.y + 28, desc_rect.w - 20, "left")
    y = desc_rect.y + desc_rect.h + 12

    local enable_rect = { x = detail_rect.x + 14, y = y, w = 90, h = 28 }
    local disable_rect = { x = detail_rect.x + 112, y = y, w = 90, h = 28 }
    local uninstall_rect = { x = detail_rect.x + 210, y = y, w = 96, h = 28 }
    local enable_disabled = mod.invalid or mod.enabled
    local disable_disabled = mod.invalid or not mod.enabled
    widgets.draw_button(enable_rect, "Enable", {
        disabled = enable_disabled,
        fill = theme.colors.success_soft,
        hover_fill = { 0.18, 0.31, 0.22, 1.0 },
        border = theme.colors.success,
        text_color = theme.colors.success,
    })
    widgets.draw_button(disable_rect, "Disable", {
        disabled = disable_disabled,
        fill = theme.colors.panel_elevated,
        hover_fill = theme.colors.panel_soft,
        border = theme.colors.border,
    })
    widgets.draw_button(uninstall_rect, "Uninstall", {
        fill = { 0.30, 0.14, 0.16, 1.0 },
        hover_fill = { 0.40, 0.16, 0.18, 1.0 },
        border = theme.colors.danger,
    })
    state.hit_regions[#state.hit_regions + 1] = { kind = "enable_mod", rect = enable_rect, mod_name = mod.folder_name, disabled = enable_disabled }
    state.hit_regions[#state.hit_regions + 1] = { kind = "disable_mod", rect = disable_rect, mod_name = mod.folder_name, disabled = disable_disabled }
    state.hit_regions[#state.hit_regions + 1] = { kind = "uninstall_mod", rect = uninstall_rect, mod_name = mod.folder_name }

    local files_rect = {
        x = detail_rect.x + 14,
        y = y + 40,
        w = detail_rect.w - 28,
        h = detail_rect.h - (y + 54 - detail_rect.y),
    }
    widgets.draw_panel(files_rect, { fill = theme.colors.panel_soft, border = theme.colors.border_soft, radius = 10 })
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.print("Changed Files", files_rect.x + 10, files_rect.y + 8)
    if #(mod.changed_files or {}) > 0 then
        draw_file_tags(mod.changed_files, files_rect.x + 10, files_rect.y + 28, files_rect.w - 20)
    else
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.print("(none)", files_rect.x + 10, files_rect.y + 28)
    end
end

function M.mousepressed(state, x, y, button)
    if button ~= 1 then
        return nil
    end
    for i = #state.hit_regions, 1, -1 do
        local hit = state.hit_regions[i]
        if widgets.point_in_rect(x, y, hit.rect) then
            if hit.disabled then
                return nil
            end
            if hit.kind == "select_mod" then
                state.selected_name = hit.mod_name
            end
            return hit
        end
    end
    return nil
end

function M.wheelmoved(state, x, y, wheel_y)
    if not state.list_rect or not widgets.point_in_rect(x, y, state.list_rect) then
        return false
    end
    state.scroll = state.scroll - wheel_y * 28
    clamp_scroll(state)
    return true
end

return M
