local widgets = require("ui.widgets")
local theme = require("ui.theme")

local M = {}

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
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

local function infer_report_key(path)
    if not path or path == "" then
        return "default"
    end
    local base = widgets.basename(path):lower()
    local digit = base:match("^r(%d)")
    if digit then
        return ("r%s"):format(digit)
    end
    return base:gsub("%.bin$", "")
end

local function exact_file_key(path)
    if not path or path == "" then
        return "default"
    end
    return widgets.basename(path):lower():gsub("%.bin$", "")
end

local function section_labels_for_file(path, reports_paths)
    local labels = {}
    local cfg
    for _, candidate in ipairs(reports_paths or {}) do
        cfg = parse_ini(candidate)
        if cfg then
            break
        end
    end
    if not cfg then
        return labels
    end

    local ordered_sections = {
        "sections",
        "default",
        infer_report_key(path),
        exact_file_key(path),
    }

    for _, section in ipairs(ordered_sections) do
        local entries = cfg[section]
        if entries then
            for key, value in pairs(entries) do
                if key ~= "" and value ~= "" then
                    labels[key] = value
                end
            end
        end
    end

    return labels
end

local function section_for_base(base, labels)
    local lower = (base or ""):lower()
    local prefixes = {}
    for prefix in pairs(labels) do
        prefixes[#prefixes + 1] = prefix
    end
    table.sort(prefixes, function(a, b)
        if #a == #b then
            return a < b
        end
        return #a > #b
    end)

    for _, prefix in ipairs(prefixes) do
        if lower:sub(1, #prefix) == prefix then
            return prefix, labels[prefix]
        end
    end
    return nil, nil
end

local function fallback_group_name(base)
    local prefix = (base or ""):match("^[A-Za-z]+")
    if prefix and prefix ~= "" then
        return prefix
    end
    return base or "Ungrouped"
end

local function build_branches(entries, collapse_state, group_key)
    local clusters = {}
    local order = {}

    for _, entry in ipairs(entries or {}) do
        local base_key = entry.base or entry.name
        if not clusters[base_key] then
            clusters[base_key] = {}
            order[#order + 1] = base_key
        end
        clusters[base_key][#clusters[base_key] + 1] = entry
    end

    local branches = {}
    for _, base_key in ipairs(order) do
        local cluster = clusters[base_key]
        if #cluster == 1 then
            branches[#branches + 1] = {
                kind = "entry",
                entry = cluster[1],
            }
        else
            local base_entry = cluster[1]
            local children = {}
            for i = 1, #cluster do
                if cluster[i].name == base_key then
                    base_entry = cluster[i]
                else
                    children[#children + 1] = cluster[i]
                end
            end
            if #children == 0 then
                for i = 2, #cluster do
                    children[#children + 1] = cluster[i]
                end
            end
            branches[#branches + 1] = {
                kind = "branch",
                key = ("%s::%s"):format(group_key, base_key),
                label = base_key,
                entry = base_entry,
                collapsed = collapse_state and collapse_state[("%s::%s"):format(group_key, base_key)] or false,
                children = children,
            }
        end
    end

    return branches
end

function M.build_groups(entries, file_path, reports_paths, collapse_state)
    local labels = section_labels_for_file(file_path, reports_paths)
    local group_map = {}
    local groups = {}

    for _, entry in ipairs(entries or {}) do
        local prefix, label = section_for_base(entry.base, labels)
        local group_key = prefix or fallback_group_name(entry.base)
        local group_label = label or group_key

        local group = group_map[group_key]
        if not group then
            group = {
                key = group_key,
                label = group_label,
                collapsed = collapse_state and collapse_state[group_key] or false,
                entries = {},
            }
            group_map[group_key] = group
            groups[#groups + 1] = group
        end
        group.entries[#group.entries + 1] = entry
    end

    for i = 1, #groups do
        groups[i].items = build_branches(groups[i].entries, collapse_state, groups[i].key)
    end

    return groups
end

function M.new_state()
    return {
        groups = {},
        scroll = 0,
        collapse_state = {},
        hit_regions = {},
        hovered = nil,
        content_height = 0,
    }
end

local function clamp_scroll(state, rect)
    local max_scroll = math.max(0, state.content_height - rect.h)
    if state.scroll < 0 then
        state.scroll = 0
    elseif state.scroll > max_scroll then
        state.scroll = max_scroll
    end
end

local function row_visible(row_rect, list_rect)
    return row_rect.y + row_rect.h >= list_rect.y and row_rect.y <= list_rect.y + list_rect.h
end

local function marker_palette(marker)
    if marker and marker.invalid then
        return theme.colors.danger_soft, theme.colors.danger
    end
    return theme.colors.amber_soft, theme.colors.amber
end

local function draw_marker_badge(rect, marker, y_offset)
    if not marker or not marker.dirty then
        return
    end
    local badge_fill, badge_border = marker_palette(marker)
    widgets.draw_tag(marker.invalid and "ERR" or "MOD", rect.x + rect.w - 46, rect.y + (y_offset or 3), {
        fill = badge_fill,
        border = badge_border,
        text_color = badge_border,
        padding_x = 7,
        padding_y = 2,
        radius = 6,
    })
end

local function draw_entry_row(rect, entry, selected_entry, marker, options)
    options = options or {}
    local is_selected = selected_entry and selected_entry.name == entry.name
    local text_color = marker and marker.invalid and theme.colors.danger
        or (is_selected and theme.colors.accent or (options.text_color or theme.colors.text))

    widgets.draw_panel(rect, {
        fill = is_selected and theme.colors.selection_soft or theme.colors.panel,
        border = marker and marker.invalid and theme.colors.danger or (is_selected and theme.colors.selection or theme.colors.border_soft),
        radius = 8,
    })

    if options.chevron then
        widgets.draw_chevron(rect.x + 12, rect.y + math.floor(rect.h * 0.5), 9, options.chevron, theme.colors.amber)
    end

    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(text_color[1], text_color[2], text_color[3], 1)
    love.graphics.print(options.label or entry.name, rect.x + (options.label_x or 12), rect.y + (options.label_y or 4))
    draw_marker_badge(rect, marker, options.badge_y)
end

function M.set_groups(state, groups)
    state.groups = groups or {}
    state.hit_regions = {}
    state.content_height = 0
    state.scroll = 0
end

function M.draw(state, rect, selected_entry, entry_markers)
    widgets.draw_panel(rect, { fill = theme.colors.panel_alt, border = theme.colors.border })
    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
    love.graphics.print("Entries", rect.x + 16, rect.y + 12)

    local list_rect = {
        x = rect.x + 8,
        y = rect.y + 40,
        w = rect.w - 16,
        h = rect.h - 48,
    }

    widgets.scissor_push(list_rect)

    state.hit_regions = {}
    local cursor_y = list_rect.y + 4 - state.scroll
    local group_h = 28
    local item_h = 24
    local branch_h = 24
    local child_h = 22

    for _, group in ipairs(state.groups) do
        local group_rect = { x = list_rect.x, y = cursor_y, w = list_rect.w, h = group_h }
        if group_rect.y + group_rect.h >= list_rect.y and group_rect.y <= list_rect.y + list_rect.h then
            widgets.draw_panel(group_rect, {
                fill = theme.colors.panel_soft,
                border = theme.colors.border_soft,
                radius = 8,
            })
            widgets.draw_chevron(group_rect.x + 15, group_rect.y + 14, 10, group.collapsed and "right" or "down", theme.colors.amber)
            love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
            love.graphics.print(group.label, group_rect.x + 28, group_rect.y + 6)
        end
        state.hit_regions[#state.hit_regions + 1] = { kind = "group", rect = group_rect, group = group }
        cursor_y = cursor_y + group_h + 4

        if not group.collapsed then
            for _, item in ipairs(group.items) do
                if item.kind == "branch" then
                    local branch_rect = { x = list_rect.x + 10, y = cursor_y, w = list_rect.w - 10, h = branch_h }
                    local branch_selected = selected_entry and item.entry and selected_entry.name == item.entry.name
                    local branch_marker = item.entry and entry_markers and entry_markers[item.entry.name] or nil
                    if row_visible(branch_rect, list_rect) then
                        draw_entry_row(branch_rect, item.entry, selected_entry, branch_marker, {
                            label = item.label,
                            label_x = 24,
                            chevron = item.collapsed and "right" or "down",
                        })
                    end
                    state.hit_regions[#state.hit_regions + 1] = {
                        kind = "branch_toggle",
                        rect = { x = branch_rect.x + 4, y = branch_rect.y + 2, w = 18, h = branch_rect.h - 4 },
                        branch = item,
                    }
                    state.hit_regions[#state.hit_regions + 1] = {
                        kind = "entry",
                        rect = { x = branch_rect.x + 22, y = branch_rect.y, w = branch_rect.w - 22, h = branch_rect.h },
                        entry = item.entry,
                    }
                    cursor_y = cursor_y + branch_h + 2

                    if not item.collapsed then
                        for _, entry in ipairs(item.children or {}) do
                            local item_rect = { x = list_rect.x + 28, y = cursor_y, w = list_rect.w - 28, h = child_h }
                            if row_visible(item_rect, list_rect) then
                                draw_entry_row(item_rect, entry, selected_entry, entry_markers and entry_markers[entry.name] or nil, {
                                    text_color = theme.colors.text_dim,
                                    label_y = 3,
                                    badge_y = 2,
                                })
                            end
                            state.hit_regions[#state.hit_regions + 1] = { kind = "entry", rect = item_rect, entry = entry }
                            cursor_y = cursor_y + child_h + 2
                        end
                    end
                else
                    local entry = item.entry
                    local item_rect = { x = list_rect.x + 10, y = cursor_y, w = list_rect.w - 10, h = item_h }
                    if row_visible(item_rect, list_rect) then
                        draw_entry_row(item_rect, entry, selected_entry, entry_markers and entry_markers[entry.name] or nil)
                    end
                    state.hit_regions[#state.hit_regions + 1] = { kind = "entry", rect = item_rect, entry = entry }
                    cursor_y = cursor_y + item_h + 2
                end
            end
        end
    end

    state.content_height = math.max(0, cursor_y - list_rect.y + state.scroll + 8)
    widgets.scissor_pop()
    clamp_scroll(state, list_rect)
end

function M.mousepressed(state, rect, x, y, button)
    if button ~= 1 then
        return nil
    end
    if not widgets.point_in_rect(x, y, rect) then
        return nil
    end

    for _, hit in ipairs(state.hit_regions) do
        if widgets.point_in_rect(x, y, hit.rect) then
            if hit.kind == "group" then
                hit.group.collapsed = not hit.group.collapsed
                state.collapse_state[hit.group.key] = hit.group.collapsed
                return { kind = "group", group = hit.group }
            end
            if hit.kind == "branch_toggle" then
                hit.branch.collapsed = not hit.branch.collapsed
                state.collapse_state[hit.branch.key] = hit.branch.collapsed
                return { kind = "branch", branch = hit.branch }
            end
            if hit.kind == "entry" then
                return { kind = "entry", entry = hit.entry }
            end
        end
    end

    return nil
end

function M.wheelmoved(state, rect, mx, my, wheel_y)
    if not widgets.point_in_rect(mx, my, rect) then
        return false
    end
    local list_rect = {
        x = rect.x + 8,
        y = rect.y + 40,
        w = rect.w - 16,
        h = rect.h - 48,
    }
    state.scroll = state.scroll - wheel_y * 28
    clamp_scroll(state, list_rect)
    return true
end

return M
