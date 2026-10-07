local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("gettext")

-- Config lives outside the plugin folder so redeploying the plugin never
-- touches credentials. See config.sample.lua in the project root.
local SETTINGS_PATH = DataStorage:getDataDir() .. "/hadash_settings.lua"

local function loadSettings()
    local ok, settings = pcall(dofile, SETTINGS_PATH)
    if not ok or type(settings) ~= "table" then
        return nil
    end
    return settings
end

-- One rounded tile. Tap toggles the configured light via the HA REST API.
local LightTile = InputContainer:extend{
    width = Screen:scaleBySize(300),
    height = Screen:scaleBySize(300),
    settings = nil,
    is_on = false,
}

function LightTile:init()
    self:update()
    local range = Geom:new{
        x = 0, y = 0,
        w = self.width,
        h = self.height,
    }
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = range,
            },
        },
    }
end

function LightTile:fetchState()
    local settings = self.settings
    if not settings then return end
    local url = string.format("%s/api/states/%s", settings.ha_url, settings.light_entity)
    local response_body = {}
    local ok, code = http.request{
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
        },
        sink = ltn12.sink.table(response_body),
    }
    if ok and code == 200 then
        local body = table.concat(response_body)
        self.is_on = body:find('"state":"on"') ~= nil
    else
        logger.warn("hadash: fetchState failed", ok, code)
    end
end

function LightTile:toggle()
    local settings = self.settings
    if not settings then return end
    local url = string.format("%s/api/services/light/toggle", settings.ha_url)
    local payload = string.format('{"entity_id":"%s"}', settings.light_entity)
    local ok, code = http.request{
        url = url,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table({}),
    }
    if ok and (code == 200 or code == 201) then
        self.is_on = not self.is_on
    else
        logger.warn("hadash: toggle failed", ok, code)
    end
end

function LightTile:update()
    local bg = self.is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = self.is_on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local label = self.settings and self.settings.light_label or _("Light")
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = bg,
        bordercolor = Blitbuffer.COLOR_BLACK,
        radius = Size.radius.window,
        padding = Size.padding.large,
        TextWidget:new{
            text = label .. (self.is_on and " (ON)" or " (OFF)"),
            face = Font:getFace("cfont", 24),
            fgcolor = fg,
        },
    }
end

function LightTile:onTap()
    self:toggle()
    self:update()
    UIManager:setDirty(self, "ui")
    return true
end

-- Full-screen dashboard view, launched from the KOReader menu.
local HaDashboard = WidgetContainer:extend{
    name = "hadash_dashboard",
    is_always_active = false,
}

function HaDashboard:init()
    self.dimen = Screen:getSize()
    local settings = loadSettings()
    self.tile = LightTile:new{ settings = settings }
    if settings then
        self.tile:fetchState()
        self.tile:update()
    end
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordercolor = Blitbuffer.COLOR_WHITE,
        self.tile,
    }
    if not settings then
        logger.warn("hadash: missing settings file at", SETTINGS_PATH)
    end
end

function HaDashboard:onClose()
    UIManager:close(self)
    return true
end

local HaDash = WidgetContainer:extend{
    name = "hadash",
}

function HaDash:init()
    self.ui.menu:registerToMainMenu(self)
end

function HaDash:addToMainMenu(menu_items)
    menu_items.hadash = {
        text = _("HA Dashboard"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(HaDashboard:new{})
        end,
    }
end

return HaDash
