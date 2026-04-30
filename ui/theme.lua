local M = {}

M.colors = {
    bg_top = { 0.06, 0.07, 0.10, 1.0 },
    bg_bottom = { 0.03, 0.04, 0.06, 1.0 },
    panel = { 0.10, 0.11, 0.15, 0.95 },
    panel_alt = { 0.12, 0.13, 0.18, 0.98 },
    panel_soft = { 0.14, 0.15, 0.20, 0.92 },
    panel_elevated = { 0.16, 0.17, 0.23, 0.96 },
    border = { 0.26, 0.29, 0.36, 1.0 },
    border_soft = { 0.20, 0.22, 0.28, 1.0 },
    text = { 0.87, 0.90, 0.96, 1.0 },
    text_dim = { 0.63, 0.67, 0.75, 1.0 },
    text_muted = { 0.46, 0.50, 0.58, 1.0 },
    accent = { 0.33, 0.73, 0.97, 1.0 },
    accent_soft = { 0.14, 0.38, 0.55, 1.0 },
    selection = { 0.18, 0.44, 0.68, 1.0 },
    selection_soft = { 0.12, 0.24, 0.33, 1.0 },
    danger = { 0.92, 0.37, 0.42, 1.0 },
    danger_soft = { 0.28, 0.14, 0.17, 1.0 },
    success = { 0.42, 0.84, 0.57, 1.0 },
    success_soft = { 0.14, 0.25, 0.18, 1.0 },
    chu = { 0.96, 0.44, 0.76, 1.0 },
    hey = { 0.96, 0.44, 0.76, 1.0 },
    rest = { 0.32, 0.35, 0.40, 1.0 },
    move = { 0.84, 0.87, 0.92, 1.0 },
    raw = { 0.91, 0.63, 0.25, 1.0 },
    amber = { 0.91, 0.63, 0.25, 1.0 },
    amber_soft = { 0.29, 0.19, 0.06, 1.0 },
    move_blue_fill = { 0.16, 0.23, 0.35, 1.0 },
    move_blue_hover = { 0.20, 0.29, 0.44, 1.0 },
    move_blue_border = { 0.29, 0.44, 0.65, 1.0 },
    move_pink_fill = { 0.35, 0.16, 0.29, 1.0 },
    move_pink_hover = { 0.45, 0.20, 0.37, 1.0 },
    move_pink_border = { 0.72, 0.35, 0.58, 1.0 },
    grid_major = { 0.34, 0.38, 0.46, 1.0 },
    grid_minor = { 0.22, 0.24, 0.30, 1.0 },
    track = { 0.16, 0.18, 0.24, 1.0 },
    button = { 0.15, 0.18, 0.23, 1.0 },
    button_hover = { 0.18, 0.22, 0.28, 1.0 },
    button_disabled = { 0.11, 0.12, 0.16, 1.0 },
}

function M.init()
    M.fonts = {
        tiny = love.graphics.newFont(11),
        small = love.graphics.newFont(13),
        body = love.graphics.newFont(15),
        title = love.graphics.newFont(22),
    }
end

function M.font(name)
    return M.fonts[name] or M.fonts.body
end

return M
