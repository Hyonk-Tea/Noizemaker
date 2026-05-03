local App = require("ui.app")

local app

function love.load(args)
    love.window.setTitle("Noizemaker")
    love.window.setMode(1280, 720, {
        resizable = true,
        minwidth = 960,
        minheight = 600,
    })

    app = App.new()
    app:load(args or {})
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
