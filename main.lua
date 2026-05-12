local App = require("ui.app")

local app

local function try_set_window_icon()
    local path = nil
    if love.filesystem.getInfo("assets/noizemaker_icon.png") then
        path = "assets/noizemaker_icon.png"
    elseif love.filesystem.getInfo("assets/noizemaker_icon.tga") then
        path = "assets/noizemaker_icon.tga"
    end
    if not path then
        return false, "missing app icon file"
    end

    local ok, err = pcall(function()
        local imagedata = love.image.newImageData(path)
        love.window.setIcon(imagedata)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, path
end

function love.load(args)
    love.window.setTitle("Noizemaker")
    love.window.setMode(1280, 720, {
        resizable = true,
        minwidth = 960,
        minheight = 600,
    })
    local icon_ok, icon_detail = try_set_window_icon()

    app = App.new()
    app:load(args or {})
    if app and not icon_ok then
        app.status_text = "Window icon load failed: " .. tostring(icon_detail)
    end
end

function love.update(dt)
    if app then
        app:update(dt)
    end
end

function love.draw()
    if app then
        app:draw()
    end
end

function love.mousepressed(x, y, button)
    if app then
        app:mousepressed(x, y, button)
    end
end

function love.mousereleased(x, y, button)
    if app then
        app:mousereleased(x, y, button)
    end
end

function love.mousemoved(x, y, dx, dy, istouch)
    if app then
        app:mousemoved(x, y, dx, dy, istouch)
    end
end

function love.keypressed(key, scancode, isrepeat)
    if app then
        app:keypressed(key, scancode, isrepeat)
    end
end

function love.textinput(text)
    if app then
        app:textinput(text)
    end
end

function love.filedropped(file)
    if app then
        app:filedropped(file)
    end
end

function love.wheelmoved(x, y)
    if app then
        app:wheelmoved(x, y)
    end
end

function love.resize(w, h)
    if app then
        app:resize(w, h)
    end
end
