local format = require("core.format")
local rules = require("core.rules")
local widgets = require("ui.widgets")
local theme = require("ui.theme")

local M = {}

local function color_for_code(code, is_rescue)
    if code == 0 then
        return theme.colors.rest
    elseif format.is_raw_byte(code) then
        return theme.colors.raw
    elseif code == 1 then
        return theme.colors.chu
    elseif code == 2 then
        return theme.colors.hey
    elseif is_rescue then
        return theme.colors.amber
    end
    return theme.colors.move
end

local function format_beats(timing)
    local beats = timing / 4
    if beats == math.floor(beats) then
        return tostring(beats)
    end
    return string.format("%.2f", beats)
end

local function node_rect(x, y, is_selected)
    local size = is_selected and 22 or 18
    return {
        x = x - math.floor(size * 0.5),
        y = y - math.floor(size * 0.5),
        w = size,
        h = size,
    }
end

function M.build_nodes(entry)
    local nodes = {}
    if not entry then
        return nodes
    end

    local rescue = rules.detect_rescue_section(entry) ~= nil
    local start_delay = entry.start_delay or 0
    local tick = 0
    local raw_final_gap = format.implied_last_gap(entry.timing, entry.hits)
    local display_final_gap = raw_final_gap - start_delay
    for i = 1, #entry.steps do
        local raw_gap_after = (i <= #entry.hits) and entry.hits[i] or raw_final_gap
        local gap_after = (i <= #entry.hits) and entry.hits[i] or display_final_gap
        nodes[i] = {
            index = i,
            raw_tick = tick,
            tick = tick + start_delay,
            raw_gap_after = raw_gap_after,
            gap_after = gap_after,
            code = entry.steps[i],
            label = format.step_display_name(entry.steps[i]),
            color = color_for_code(entry.steps[i], rescue),
        }
        if i <= #entry.hits then
            tick = tick + entry.hits[i]
        end
    end

    return nodes
end

function M.display_final_gap(entry)
    if not entry then
        return 0
    end
    return format.implied_last_gap(entry.timing, entry.hits) - (entry.start_delay or 0)
end

function M.summary_text(entry)
    if not entry then
        return "Total: -"
    end
    local total_ticks = format.total_ticks(entry.timing)
    return string.format(
        "Total: %dt | %s beats | %d 1/4ths | 6t each",
        total_ticks,
        format_beats(entry.timing),
        entry.timing,
        6
    )
end

function M.start_delay_text(entry)
    if not entry then
        return ""
    end
    if (entry.start_delay or 0) > 0 then
        return string.format("Start delay: %dt. First step is shown at %dt.", entry.start_delay, entry.start_delay)
    end
    return "Start delay: 0t. First step is shown at 0t."
end

function M.draw(rect, entry, selected_step_index, options)
    options = options or {}

    widgets.draw_panel(rect, { fill = theme.colors.panel, border = theme.colors.border })
    local render = {
        rect = rect,
        hits = {},
        plot = nil,
        nodes = {},
    }

    if not entry then
        love.graphics.setFont(theme.font("title"))
        love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
        love.graphics.printf("Open a DGSH file to view a sequence timeline.", rect.x + 24, rect.y + rect.h * 0.5 - 12, rect.w - 48, "center")
        return render
    end

    local nodes = M.build_nodes(entry)
    render.nodes = nodes
    local sequence_ticks = math.max(format.total_ticks(entry.timing), 1)
    local start_delay = math.max(entry.start_delay or 0, 0)
    local total_ticks = sequence_ticks
    local display_final_gap = M.display_final_gap(entry)
    local validation = options.validation
    local invalid_final = false
    if validation then
        for _, message in ipairs(validation.errors or {}) do
            if message:find("implied final gap", 1, true) then
                invalid_final = true
                break
            end
        end
    end
    if display_final_gap < 0 then
        invalid_final = true
    end

    love.graphics.setFont(theme.font("small"))
    love.graphics.setColor(theme.colors.text_dim[1], theme.colors.text_dim[2], theme.colors.text_dim[3], 1)
    love.graphics.print(M.summary_text(entry), rect.x + 20, rect.y + 16)
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.setColor(theme.colors.text_muted[1], theme.colors.text_muted[2], theme.colors.text_muted[3], 1)
    love.graphics.print(M.start_delay_text(entry), rect.x + 20, rect.y + 38)

    local plot = {
        x = rect.x + 28,
        y = rect.y + 98,
        w = rect.w - 56,
        h = rect.h - 144,
    }
    render.plot = plot

    local baseline_y = plot.y + plot.h * 0.62
    local scale = plot.w / total_ticks
    render.scale = scale
    local start_x = plot.x + math.min(start_delay, total_ticks) * scale

    love.graphics.setColor((invalid_final and theme.colors.danger or theme.colors.track)[1], (invalid_final and theme.colors.danger or theme.colors.track)[2], (invalid_final and theme.colors.danger or theme.colors.track)[3], 1)
    love.graphics.rectangle("fill", plot.x, baseline_y - 4, plot.w, 8, 8, 8)
    if start_delay > 0 then
        local delay_rect = {
            x = plot.x,
            y = baseline_y - 8,
            w = math.max(0, start_x - plot.x),
            h = 16,
        }
        widgets.draw_panel(delay_rect, {
            fill = theme.colors.accent_soft,
            border = theme.colors.accent,
            radius = 8,
        })
        if delay_rect.w >= 76 then
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3], 1)
            love.graphics.printf("START DELAY", delay_rect.x, delay_rect.y + 2, delay_rect.w, "center")
        end
    end

    love.graphics.setColor(theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3], 1)
    love.graphics.setLineWidth(2)
    love.graphics.line(plot.x, plot.y + 6, plot.x, plot.y + plot.h - 6)
    love.graphics.setFont(theme.font("tiny"))
    love.graphics.print("0t", plot.x + 4, plot.y + plot.h - 18)

    for tick = 0, sequence_ticks, 6 do
        local x = plot.x + tick * scale
        local is_major = (tick % 24) == 0
        local line_color = is_major and theme.colors.grid_major or theme.colors.grid_minor
        love.graphics.setColor(line_color[1], line_color[2], line_color[3], 1)
        love.graphics.setLineWidth(is_major and 2 or 1)
        love.graphics.line(x, plot.y + 8, x, plot.y + plot.h - 8)
        if is_major then
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.print(tostring(tick), x + 4, plot.y + 6)
        end
    end

    if options.insert_preview then
        local preview_tick = math.max(0, math.min(options.insert_preview.tick or 0, total_ticks))
        local preview_x = plot.x + preview_tick * scale
        local preview_color = options.insert_preview.color or theme.colors.amber
        love.graphics.setColor(preview_color[1], preview_color[2], preview_color[3], 0.9)
        love.graphics.setLineWidth(2)
        love.graphics.line(preview_x, plot.y + 4, preview_x, plot.y + plot.h - 4)
        widgets.draw_panel({
            x = preview_x - 8,
            y = baseline_y - 8,
            w = 16,
            h = 16,
        }, {
            fill = preview_color,
            border = preview_color,
            radius = 5,
        })
        widgets.draw_panel({
            x = preview_x - 12,
            y = baseline_y - 12,
            w = 24,
            h = 24,
        }, {
            fill = { 0.0, 0.0, 0.0, 0.0 },
            border = preview_color,
            radius = 7,
        })

        local ghost_rect = {
            x = math.max(plot.x, math.min(preview_x - 40, plot.x + plot.w - 80)),
            y = plot.y + 12,
            w = 80,
            h = 24,
        }
        widgets.draw_panel(ghost_rect, {
            fill = theme.colors.panel_soft,
            border = preview_color,
            radius = 8,
        })
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.printf(options.insert_preview.label or "PLACE", ghost_rect.x, ghost_rect.y + 4, ghost_rect.w, "center")
    end

    love.graphics.setLineWidth(1)
    for i = 1, #nodes do
        local node = nodes[i]
        local x = plot.x + node.tick * scale
        local y = baseline_y
        local is_selected = selected_step_index == i
        local is_dragging = options.drag_index == i
        local rect_node = node_rect(x, y, is_selected)
        local label_rect = {
            x = x - 34,
            y = y + ((i % 2 == 0) and 20 or -48),
            w = 68,
            h = 24,
        }

        local fill = node.color
        if is_dragging then
            fill = theme.colors.amber
        end

        local ring = is_dragging and theme.colors.amber or (is_selected and theme.colors.accent or ((i == 1) and theme.colors.accent or theme.colors.border))
        widgets.draw_panel(rect_node, {
            fill = fill,
            border = ring,
            radius = 6,
        })
        love.graphics.setColor(ring[1], ring[2], ring[3], 0.45)
        love.graphics.line(x, baseline_y - 18, x, label_rect.y + ((label_rect.y > y) and 0 or label_rect.h))

        if i == 1 then
            local fixed_rect = {
                x = x - 40,
                y = y - 44,
                w = 80,
                h = 18,
            }
            widgets.draw_panel(fixed_rect, {
                fill = theme.colors.accent_soft,
                border = theme.colors.accent,
                radius = 6,
            })
            love.graphics.setFont(theme.font("tiny"))
            love.graphics.setColor(theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3], 1)
            love.graphics.printf("STEP 1", fixed_rect.x, fixed_rect.y + 3, fixed_rect.w, "center")
        end

        widgets.draw_panel(label_rect, {
            fill = is_selected and theme.colors.selection_soft or theme.colors.panel_soft,
            border = ring,
            radius = 8,
        })
        love.graphics.setFont(theme.font("tiny"))
        love.graphics.setColor(theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        love.graphics.printf(node.label, label_rect.x, label_rect.y + 4, label_rect.w, "center")

        local hit = {
            index = i,
            node = node,
            x = x,
            y = y,
            circle_rect = { x = rect_node.x - 3, y = rect_node.y - 3, w = rect_node.w + 6, h = rect_node.h + 6 },
            label_rect = label_rect,
        }
        render.hits[#render.hits + 1] = hit
    end

    return render
end

function M.hit_test(render, x, y)
    if not render then
        return nil, nil
    end

    for i = #render.hits, 1, -1 do
        local hit = render.hits[i]
        if widgets.point_in_rect(x, y, hit.circle_rect) or widgets.point_in_rect(x, y, hit.label_rect) then
            return hit.index, hit.node
        end
    end
    return nil, nil
end

function M.tick_from_x(render, x)
    if not render or not render.plot or not render.scale then
        return nil
    end

    local plot = render.plot
    local clamped = math.max(plot.x, math.min(x, plot.x + plot.w))
    return (clamped - plot.x) / render.scale
end

return M
