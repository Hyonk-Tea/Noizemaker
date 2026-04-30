local theme = require("ui.theme")

local M = {}

local FONT_ATLAS_ROWS = {
    " !\"#$%&'[]*+",
    "_./012345678",
    "9:;<=>?@ABCD",
    "EFGHIJKLMNOP",
    "QRSTUVWXYZ[|",
    "]^=`abcdefgh",
    "ijklmnopqrst",
    "uvwxyz{\\}~",
}

local function set_color(color)
    love.graphics.setColor(color[1], color[2], color[3], color[4] or 1.0)
end

function M.point_in_rect(x, y, rect)
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end

function M.round_rect(mode, rect, radius)
    love.graphics.rectangle(mode, rect.x, rect.y, rect.w, rect.h, radius or 10, radius or 10)
end

function M.draw_panel(rect, options)
    options = options or {}
    set_color(options.fill or theme.colors.panel)
    M.round_rect("fill", rect, options.radius or 12)
    set_color(options.border or theme.colors.border)
    M.round_rect("line", rect, options.radius or 12)
end

function M.draw_button(rect, label, options)
    options = options or {}
    local fill = options.fill or theme.colors.button
    if options.disabled then
        fill = options.disabled_fill or theme.colors.button_disabled
    elseif options.hovered then
        fill = options.hover_fill or theme.colors.button_hover
    end

    set_color(fill)
    M.round_rect("fill", rect, options.radius or 10)
    set_color(options.border or theme.colors.border)
    M.round_rect("line", rect, options.radius or 10)

    love.graphics.setFont(options.font or theme.font("small"))
    set_color(options.text_color or (options.disabled and theme.colors.text_muted or theme.colors.text))
    love.graphics.printf(label, rect.x, rect.y + math.floor((rect.h - love.graphics.getFont():getHeight()) * 0.5), rect.w, "center")
end

function M.draw_label(text, x, y, options)
    options = options or {}
    love.graphics.setFont(options.font or theme.font("body"))
    set_color(options.color or theme.colors.text)
    love.graphics.print(text, x, y)
end

function M.draw_tag(text, x, y, options)
    options = options or {}
    local padding_x = options.padding_x or 10
    local padding_y = options.padding_y or 4
    local font = options.font or theme.font("tiny")
    love.graphics.setFont(font)
    local width = font:getWidth(text) + padding_x * 2
    local height = font:getHeight() + padding_y * 2
    local rect = { x = x, y = y, w = width, h = height }
    M.draw_panel(rect, {
        fill = options.fill or theme.colors.panel_soft,
        border = options.border or theme.colors.border_soft,
        radius = options.radius or 8,
    })
    set_color(options.text_color or theme.colors.text)
    love.graphics.print(text, x + padding_x, y + padding_y)
    return width, height
end

function M.draw_chevron(x, y, size, direction, color)
    size = size or 10
    direction = direction or "right"
    local half = size * 0.5
    local points
    if direction == "down" then
        points = {
            x - half, y - half * 0.6,
            x, y + half * 0.6,
            x + half, y - half * 0.6,
        }
    else
        points = {
            x - half * 0.5, y - half,
            x + half * 0.5, y,
            x - half * 0.5, y + half,
        }
    end
    set_color(color or theme.colors.amber)
    love.graphics.setLineWidth(2)
    love.graphics.line(points)
    love.graphics.setLineWidth(1)
end

function M.scissor_push(rect)
    love.graphics.push("all")
    love.graphics.setScissor(rect.x, rect.y, rect.w, rect.h)
end

function M.scissor_pop()
    love.graphics.setScissor()
    love.graphics.pop()
end

function M.basename(path)
    return (path:gsub("[/\\]+$", ""):match("([^/\\]+)$")) or path
end

function M.try_load_bitmap_title(path)
    if not path then
        return nil
    end

    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end

    local bytes = fh:read("*a")
    fh:close()
    if not bytes or bytes == "" then
        return nil
    end

    local ok, renderer = pcall(function()
        local filedata = love.filesystem.newFileData(bytes, M.basename(path))
        local imagedata = love.image.newImageData(filedata)
        local image = love.graphics.newImage(imagedata)
        image:setFilter("nearest", "nearest")

        local char_to_index = {}
        for row = 1, #FONT_ATLAS_ROWS do
            local chars = FONT_ATLAS_ROWS[row]
            for col = 1, #chars do
                local ch = chars:sub(col, col)
                if char_to_index[ch] == nil then
                    char_to_index[ch] = {
                        col = col - 1,
                        row = row - 1,
                    }
                end
            end
        end

        local atlas = {
            image = image,
            char_to_index = char_to_index,
            cell_w = 30,
            cell_h = 30,
        }

        function atlas:measure(text, scale)
            scale = scale or 1
            return #text * self.cell_w * scale, self.cell_h * scale
        end

        function atlas:draw(text, x, y, scale, color)
            scale = scale or 1
            love.graphics.setColor((color or theme.colors.text)[1], (color or theme.colors.text)[2], (color or theme.colors.text)[3], (color or theme.colors.text)[4] or 1.0)
            local cursor_x = x
            for i = 1, #text do
                local ch = text:sub(i, i)
                local info = self.char_to_index[ch]
                if info then
                    love.graphics.draw(
                        self.image,
                        love.graphics.newQuad(info.col * self.cell_w, info.row * self.cell_h, self.cell_w, self.cell_h, self.image:getWidth(), self.image:getHeight()),
                        cursor_x,
                        y,
                        0,
                        scale,
                        scale
                    )
                end
                cursor_x = cursor_x + self.cell_w * scale
            end
        end

        return atlas
    end)

    if ok then
        return renderer
    end
    return nil
end

return M
