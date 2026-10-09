local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local JSON = require("json")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local mqtt = require("mqttlib")
local _ = require("gettext")

-- Without this, a request that hangs instead of failing fast (brief Wi-Fi
-- blip, HA momentarily unreachable) blocks KOReader's single Lua thread
-- -- and thus all touch input -- for whatever LuaSocket's own default
-- timeout is. A real LAN round-trip to HA is milliseconds, so 3s is
-- already generous; combined with fetchAllStates's fallback loop now
-- aborting after the first connection-level failure (see haGet), this
-- caps a real network-down UI freeze at ~3s instead of multiple minutes.
http.TIMEOUT = 3

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

-- Flat black/white/one-gray palette, rounded everything, generous touch targets.
local GRAY_FILL = Blitbuffer.COLOR_GRAY_E
local GUTTER = Screen:scaleBySize(16)
local RADIUS_CARD = Screen:scaleBySize(28)
local RADIUS_TILE = Screen:scaleBySize(20)
local RADIUS_PILL = Screen:scaleBySize(34)
local RADIUS_ROUND = Screen:scaleBySize(36) -- +/- circular buttons

-- Robustness (milestone 4): how often to poll HA for state changes made
-- elsewhere (HA app, another tablet, automations), and how many polls
-- between a full-screen refresh to clear any e-ink ghosting that's
-- accumulated from all the partial updates in between.
local POLL_INTERVAL_S = 60
local FULL_REFRESH_EVERY_N_POLLS = 30 -- ~30 minutes at the default 60s interval

----------------------------------------------------------------
-- HA REST helpers
----------------------------------------------------------------

local function haGet(settings, path)
    local resp_body = {}
    local ok, code = http.request{
        url = settings.ha_url .. path,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
        },
        sink = ltn12.sink.table(resp_body),
    }
    if ok and code == 200 then
        local decode_ok, decoded = pcall(JSON.decode, table.concat(resp_body))
        if decode_ok then return decoded end
    end
    logger.warn("hadash: GET failed", path, ok, code)
    -- Second return is only set for a connection-level failure (ok falsy
    -- -- "Network is unreachable", a timeout, DNS failure, etc, where
    -- `code` is LuaSocket's error string, not an HTTP status). An HTTP-
    -- level failure (ok truthy, e.g. a 401) is per-request and doesn't
    -- mean every other entity will fail the same way, so callers looping
    -- over several entities can use this to stop early only on the
    -- former -- no point burning a full timeout on each remaining entity
    -- when the network itself is down for all of them alike.
    return nil, (not ok) and code or nil
end

-- Used by the periodic poller's tile-refresh closures: during a poll tick
-- dashboard_self._poll_cache holds one combined fetchAllStates() result
-- for every entity, so individual tiles don't each do their own GET.
-- Outside a poll tick (e.g. the 0.4s re-check right after a tap) the cache
-- is nil and this just falls through to a fresh single-entity GET.
local function haGetCached(dashboard_self, settings, entity_id)
    local cache = dashboard_self and dashboard_self._poll_cache
    if cache and cache[entity_id] ~= nil then return cache[entity_id] end
    return haGet(settings, "/api/states/" .. entity_id)
end

local function haCallService(settings, domain, service, payload)
    local body = JSON.encode(payload)
    local ok, code = http.request{
        url = string.format("%s/api/services/%s/%s", settings.ha_url, domain, service),
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table({}),
    }
    local success = ok and (code == 200 or code == 201)
    if not success then
        logger.warn("hadash: service call failed", domain, service, ok, code)
    end
    return success
end

-- Pushes a state TO Home Assistant instead of reading one -- the
-- "sensor.kindle_battery"-style direction. HA's REST API accepts a plain
-- POST /api/states/<entity_id> from any authenticated client and creates
-- the entity if it doesn't exist yet; no integration config needed on
-- the HA side. (These push-created states aren't restored across an HA
-- restart the way a real integration's sensors are -- fine here, since
-- this plugin re-pushes the value every poll anyway.)
local function haSetState(settings, entity_id, state, attributes)
    local body = JSON.encode({ state = state, attributes = attributes })
    local ok, code = http.request{
        url = settings.ha_url .. "/api/states/" .. entity_id,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table({}),
    }
    local success = ok and (code == 200 or code == 201)
    if not success then
        logger.warn("hadash: set state failed", entity_id, ok, code)
    end
    return success
end

----------------------------------------------------------------
-- Power Saving mode + MQTT (HA auto-discovery, bundled as one Device)
----------------------------------------------------------------

-- Module-level, not per-instance: the MQTT connection and Power Saving
-- state need to survive the periodic full-dashboard-rebuild (every
-- FULL_REFRESH_EVERY_N_POLLS ticks creates a brand new HaDashboard
-- instance), same reasoning as active_dashboard/has_auto_opened below.
local mqtt_client = nil
local mqtt_ioloop = nil
local mqtt_discovery_sent = false
local ps_armed = false
local ps_sleeping = false
local last_activity = os.time()
-- Whether a tap is currently allowed to turn the frontlight on at all
-- (e.g. an HA automation says "too bright outside, don't bother") --
-- true (always allowed) when frontlight_entity isn't configured.
local fl_allowed = true
local fl_off_task = nil
-- Both HA-adjustable via MQTT (number entities) -- see mqttPublishDiscovery.
local fl_auto_off_s = 30
local fl_wake_brightness = 12 -- native Kindle scale is 0-24, not 0-100
-- HA-adjustable via MQTT too; seeded once from settings.power_saving_
-- timeout_s on first use (not every full-rebuild, or a live MQTT change
-- would get reset back to the config-file value every ~30 min).
local ps_timeout_s = 300
local ps_timeout_seeded = false

local MQTT_DEVICE = {
    identifiers = { "kindle_dashboard" },
    name = "Kindle Dashboard",
    manufacturer = "hadash.koplugin",
    model = "Kindle Paperwhite 3",
}

-- Real OS-level suspend powers down the touch controller itself (verified
-- this session -- that's exactly why touch stayed dead until a power-
-- button press before preventScreenSaver was set). "Power Saving" here
-- is deliberately a software-only pause instead: Wi-Fi radio off,
-- frontlight off, polling paused -- the CPU/touch controller/KOReader
-- process stay fully live throughout, so any tap wakes instantly.
local function setWifiEnabled(enabled)
    os.execute("lipc-set-prop com.lab126.cmd wirelessEnable " .. (enabled and "1" or "0"))
end

-- Drives luamqtt manually, once per our own poll tick, instead of the
-- library's own blocking mqtt.run_ioloop -- that would never return
-- control to KOReader's cooperative scheduler. Attaching a real ioloop
-- object (for its timeout config only, 50ms here) is what makes the
-- client's socket reads bounded instead of blocking indefinitely
-- (client.lua's _apply_network_timeout disables the timeout entirely
-- when no ioloop is attached).
local function mqttConnect(settings)
    if not settings.mqtt_host or mqtt_client then return end
    local ok, client = pcall(mqtt.client, {
        uri = settings.mqtt_host .. ":" .. (settings.mqtt_port or 1883),
        id = "kindle_dashboard",
        username = settings.mqtt_user,
        password = settings.mqtt_password,
        clean = true,
        -- Last Will: the BROKER publishes this itself if the connection
        -- drops without a clean disconnect (e.g. Wi-Fi cut abruptly) --
        -- this is what lets HA mark the whole device unavailable
        -- promptly even on an ungraceful drop, not just when we
        -- ourselves remember to say so. Entering Power Saving also
        -- publishes this explicitly before disconnecting (see
        -- mqttDisconnect), since waiting for the broker's own keepalive-
        -- timeout detection would be slower than doing it ourselves.
        will = { topic = "kindle_dashboard/availability", payload = "offline", retain = true },
    })
    if not ok or not client then
        logger.warn("hadash: mqtt client creation failed", client)
        return
    end
    client:on{
        connect = function()
            mqtt_discovery_sent = false
            client:publish{ topic = "kindle_dashboard/availability", payload = "online", retain = true }
            client:subscribe{ topic = "kindle_dashboard/power_saving/set" }
            client:subscribe{ topic = "kindle_dashboard/power_saving_timeout_s/set" }
            client:subscribe{ topic = "kindle_dashboard/frontlight_allowed/set" }
            client:subscribe{ topic = "kindle_dashboard/frontlight_auto_off_s/set" }
            client:subscribe{ topic = "kindle_dashboard/frontlight_brightness/set" }
        end,
        message = function(msg)
            if msg.topic == "kindle_dashboard/power_saving/set" then
                ps_armed = (tostring(msg.payload) == "ON")
            elseif msg.topic == "kindle_dashboard/power_saving_timeout_s/set" then
                local n = tonumber(msg.payload)
                if n then ps_timeout_s = math.max(30, math.min(3600, n)) end
            elseif msg.topic == "kindle_dashboard/frontlight_allowed/set" then
                fl_allowed = (tostring(msg.payload) == "ON")
            elseif msg.topic == "kindle_dashboard/frontlight_auto_off_s/set" then
                local n = tonumber(msg.payload)
                if n then fl_auto_off_s = math.max(5, math.min(300, n)) end
            elseif msg.topic == "kindle_dashboard/frontlight_brightness/set" then
                local n = tonumber(msg.payload)
                if n then fl_wake_brightness = math.max(0, math.min(24, math.floor(n))) end
            end
        end,
        error = function(err)
            logger.warn("hadash: mqtt error", err)
        end,
    }
    mqtt_ioloop = require("mqtt.ioloop").get(true, { timeout = 0.05 })
    mqtt_ioloop:add(client)
    client:start_connecting()
    mqtt_client = client
end

-- Shared by every discovered entity below: lets HA mark the whole
-- device "unavailable" (grayed out, not just showing a stale retained
-- value) whenever this topic says "offline" -- set via the client's
-- own Last Will (ungraceful drops) or explicitly by us (graceful ones,
-- e.g. entering Power Saving). Addresses the real gap otherwise: HA has
-- no idea the device is asleep and Wi-Fi is off, so without this it
-- would keep showing the last values as if still live and controllable.
local function withAvailability(t)
    t.availability_topic = "kindle_dashboard/availability"
    t.payload_available = "online"
    t.payload_not_available = "offline"
    return t
end

local function mqttPublishDiscovery()
    if not mqtt_client or mqtt_discovery_sent then return end
    mqtt_client:publish{
        topic = "homeassistant/sensor/kindle_dashboard/battery/config",
        payload = JSON.encode(withAvailability{
            name = "Battery",
            unique_id = "kindle_dashboard_battery",
            device_class = "battery",
            unit_of_measurement = "%",
            state_topic = "kindle_dashboard/battery/state",
            device = MQTT_DEVICE,
        }),
        retain = true,
    }
    mqtt_client:publish{
        topic = "homeassistant/switch/kindle_dashboard/power_saving/config",
        payload = JSON.encode(withAvailability{
            name = "Power Saving",
            unique_id = "kindle_dashboard_power_saving",
            state_topic = "kindle_dashboard/power_saving/state",
            command_topic = "kindle_dashboard/power_saving/set",
            device = MQTT_DEVICE,
        }),
        retain = true,
    }
    mqtt_client:publish{
        topic = "homeassistant/number/kindle_dashboard/power_saving_timeout_s/config",
        payload = JSON.encode(withAvailability{
            name = "Power Saving Idle Timeout",
            unique_id = "kindle_dashboard_power_saving_timeout_s",
            state_topic = "kindle_dashboard/power_saving_timeout_s/state",
            command_topic = "kindle_dashboard/power_saving_timeout_s/set",
            min = 30,
            max = 3600,
            step = 30,
            unit_of_measurement = "s",
            device = MQTT_DEVICE,
        }),
        retain = true,
    }
    mqtt_client:publish{
        topic = "homeassistant/switch/kindle_dashboard/frontlight_allowed/config",
        payload = JSON.encode(withAvailability{
            name = "Frontlight Allowed",
            unique_id = "kindle_dashboard_frontlight_allowed",
            state_topic = "kindle_dashboard/frontlight_allowed/state",
            command_topic = "kindle_dashboard/frontlight_allowed/set",
            device = MQTT_DEVICE,
        }),
        retain = true,
    }
    mqtt_client:publish{
        topic = "homeassistant/number/kindle_dashboard/frontlight_auto_off_s/config",
        payload = JSON.encode(withAvailability{
            name = "Frontlight Auto-off Seconds",
            unique_id = "kindle_dashboard_frontlight_auto_off_s",
            state_topic = "kindle_dashboard/frontlight_auto_off_s/state",
            command_topic = "kindle_dashboard/frontlight_auto_off_s/set",
            min = 5,
            max = 300,
            step = 5,
            unit_of_measurement = "s",
            device = MQTT_DEVICE,
        }),
        retain = true,
    }
    mqtt_client:publish{
        topic = "homeassistant/number/kindle_dashboard/frontlight_brightness/config",
        payload = JSON.encode(withAvailability{
            name = "Frontlight Brightness on Wake",
            unique_id = "kindle_dashboard_frontlight_brightness",
            state_topic = "kindle_dashboard/frontlight_brightness/state",
            command_topic = "kindle_dashboard/frontlight_brightness/set",
            -- Native Kindle scale is 0-24, not 0-100 -- deliberately not
            -- converting to %, to avoid rounding mismatches against what
            -- setIntensity actually applies.
            min = 0,
            max = 24,
            step = 1,
            device = MQTT_DEVICE,
        }),
        retain = true,
    }
    mqtt_discovery_sent = true
end

local function mqttDisconnect()
    if not mqtt_client then return end
    -- Graceful path: say so ourselves immediately, rather than relying
    -- on the broker's own keepalive-timeout-based Last Will detection,
    -- which is correct but slower (bounded by the keepalive interval).
    pcall(function()
        mqtt_client:publish{ topic = "kindle_dashboard/availability", payload = "offline", retain = true }
    end)
    pcall(function() mqtt_client:disconnect() end)
    mqtt_client = nil
    mqtt_discovery_sent = false
end

-- Called once per normal (awake) poll tick. One bounded-timeout iteration
-- of the client's own state machine (connect handshake, incoming message
-- parsing, keepalive) -- never blocks noticeably given the 50ms ioloop
-- timeout above.
local function mqttTick(settings, battery_pct)
    if not mqtt_client then
        mqttConnect(settings)
        return
    end
    local ok = pcall(function() return mqtt_client:_ioloop_iteration() end)
    if not ok then
        -- Connection died; drop it, mqttConnect will recreate it on a
        -- later tick.
        mqtt_client = nil
        mqtt_discovery_sent = false
        return
    end
    if mqtt_client.connection then
        mqttPublishDiscovery()
        if battery_pct then
            mqtt_client:publish{ topic = "kindle_dashboard/battery/state", payload = tostring(battery_pct), retain = true }
        end
        mqtt_client:publish{ topic = "kindle_dashboard/power_saving/state", payload = ps_armed and "ON" or "OFF", retain = true }
        mqtt_client:publish{ topic = "kindle_dashboard/power_saving_timeout_s/state", payload = tostring(ps_timeout_s), retain = true }
        mqtt_client:publish{ topic = "kindle_dashboard/frontlight_allowed/state", payload = fl_allowed and "ON" or "OFF", retain = true }
        mqtt_client:publish{ topic = "kindle_dashboard/frontlight_auto_off_s/state", payload = tostring(fl_auto_off_s), retain = true }
        mqtt_client:publish{ topic = "kindle_dashboard/frontlight_brightness/state", payload = tostring(fl_wake_brightness), retain = true }
    end
end

-- Like haCallService, but asks HA to return the service's result payload
-- (needed for weather.get_forecasts, which has no useful state attribute).
local function haCallServiceReturn(settings, domain, service, payload)
    local body = JSON.encode(payload)
    local resp_body = {}
    local ok, code = http.request{
        url = string.format("%s/api/services/%s/%s?return_response", settings.ha_url, domain, service),
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp_body),
    }
    if ok and (code == 200 or code == 201) then
        local decode_ok, decoded = pcall(JSON.decode, table.concat(resp_body))
        if decode_ok then return decoded end
    end
    logger.warn("hadash: service call (return_response) failed", domain, service, ok, code)
    return nil
end

-- Today's forecast (max/min temp, rain chance) for the weather chip.
-- weather entities stopped exposing this as a plain attribute; it now
-- needs an explicit get_forecasts service call.
local function fetchForecast(settings)
    if not settings.weather_entity then return nil end
    local result = haCallServiceReturn(settings, "weather", "get_forecasts", {
        entity_id = settings.weather_entity,
        type = "daily",
    })
    local sr = result and (result.service_response or result)
    local entity_data = sr and sr[settings.weather_entity]
    local forecast_list = entity_data and entity_data.forecast
    return forecast_list and forecast_list[1] or nil
end

-- One combined fetch for every entity the dashboard shows, instead of one
-- GET per entity -- cuts N HTTP round-trips (and N Wi-Fi radio wake
-- windows per poll) down to 1. Uses HA's templating API to build a JSON
-- map of entity_id -> {state, attributes} server-side; only state and
-- attributes are ever read anywhere in this file, so that's all we ask for.
local function fetchAllStates(settings)
    local entity_ids = {}
    local function addAll(list)
        for _, item in ipairs(list or {}) do table.insert(entity_ids, item.entity) end
    end
    addAll(settings.lights_onoff)
    addAll(settings.lights_dimmable)
    addAll(settings.sensors)
    addAll(settings.climate_entities)
    if settings.all_lights_entity then table.insert(entity_ids, settings.all_lights_entity) end
    if settings.weather_entity then table.insert(entity_ids, settings.weather_entity) end
    if settings.battery_entity then table.insert(entity_ids, settings.battery_entity) end
    if settings.solar_power_entity then table.insert(entity_ids, settings.solar_power_entity) end
    if settings.consumption_entity then table.insert(entity_ids, settings.consumption_entity) end
    if settings.frontlight_entity then table.insert(entity_ids, settings.frontlight_entity) end
    if #entity_ids == 0 then return {} end

    local quoted_ids = {}
    for _, id in ipairs(entity_ids) do table.insert(quoted_ids, string.format("%q", id)) end
    local template = string.format([[
{%% set ns = namespace(result={}) %%}
{%% for eid in [%s] %%}
{%% set st = states[eid] %%}
{%% if st %%}
{%% set ns.result = ns.result | combine({(eid): {'state': st.state, 'attributes': st.attributes}}) %%}
{%% endif %%}
{%% endfor %%}
{{ ns.result | tojson }}
]], table.concat(quoted_ids, ", "))

    local body = JSON.encode({ template = template })
    local resp_body = {}
    local ok, code = http.request{
        url = settings.ha_url .. "/api/template",
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. settings.ha_token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp_body),
    }
    if ok and code == 200 then
        local decode_ok, decoded = pcall(JSON.decode, table.concat(resp_body))
        if decode_ok and type(decoded) == "table" then return decoded end
    end
    logger.warn("hadash: template fetch failed, falling back to per-entity GET", ok, code, table.concat(resp_body):sub(1, 300))

    local states = {}
    for _, entity_id in ipairs(entity_ids) do
        local state, conn_err = haGet(settings, "/api/states/" .. entity_id)
        states[entity_id] = state
        if conn_err then
            -- Network itself is down (not just this one entity) -- every
            -- remaining GET in this loop would hit the same failure, so
            -- stop here instead of burning a full http.TIMEOUT on each of
            -- them in turn. This is what previously turned a single 5s
            -- timeout into a multi-dozen-second UI freeze on a real Wi-Fi
            -- blip (fetchAllStates can cover a dozen-plus entities).
            logger.warn("hadash: connection-level failure, aborting remaining GETs", conn_err)
            break
        end
    end
    return states
end

----------------------------------------------------------------
-- Small widget builders
----------------------------------------------------------------

-- Touch-drag brightness slider. KOReader has no ready-made Slider class --
-- this mirrors how the real frontlight-brightness control is built
-- (ui/widget/frontlightwidget.lua): a plain ProgressWidget (paints the
-- bar, has no gesture handling of its own) wrapped in a small
-- InputContainer that owns the actual touch handling. `range = self.dimen`
-- (not a fresh Geom copy) is deliberate -- GestureRange needs the SAME
-- table the paint system fills in with the widget's real x/y once
-- positioned, not a frozen snapshot taken at construction time before
-- that's known (an earlier bug in this file, now fixed everywhere else
-- by using Button, which does exactly this internally -- see button.lua).
-- Both tap and pan land on the same handler: KOReader's own frontlight
-- slider doesn't distinguish "dragging" from "released" either, since a
-- pan delivers a touch position on every tick regardless.
local DragSlider = InputContainer:extend{
    width = nil,
    height = nil,
    percentage = 0,
    on_change = nil, -- function(perc) end, called on every tap/drag tick
}

function DragSlider:init()
    self.progress = ProgressWidget:new{
        width = self.width,
        height = self.height,
        percentage = self.percentage,
        -- Match the dashboard's rounded/flat style, but gently --
        -- ProgressWidget rounds its border/background via
        -- paintRoundedRect/paintBorder, but always paints the actual
        -- fill bar as a plain rectangle (progresswidget.lua) regardless
        -- of radius. At a full pill radius (height/2) that mismatch is
        -- very visible (a sharp-cornered fill poking into a big rounded
        -- arc); a small radius keeps it rounded without the seam being
        -- obvious. This is a KOReader core-widget limitation, not
        -- something fixable from the plugin side.
        radius = Screen:scaleBySize(6),
        bordersize = Size.border.window,
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }
    self[1] = self.progress
    -- getSize() on ProgressWidget returns a bare {w,h} table, not a real
    -- Geom instance -- GestureRange:match() calls :contains() on this,
    -- which a bare table doesn't have. Wrap explicitly; x/y start at 0
    -- here but this is the same table instance that gets positioned
    -- (x/y filled in in place) once the layout system places the
    -- widget, same as self.dimen = self.frame:getSize() in button.lua.
    local size = self.progress:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    if Device:isTouchDevice() then
        self.ges_events = {
            SliderDrag = { GestureRange:new{ ges = "pan", range = self.dimen } },
            SliderTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
end

function DragSlider:onSliderDrag(_, ges_ev)
    local perc = self.progress:getPercentageFromPosition(ges_ev.pos)
    if not perc then return true end
    self.progress:setPercentage(perc)
    if self.on_change then self.on_change(perc) end
    return true
end
DragSlider.onSliderTap = DragSlider.onSliderDrag

-- Button text is always black unless we invert it for a black-filled button.
local function whiten(btn)
    if btn.label_widget then
        btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end
    return btn
end

local function round(n)
    if type(n) ~= "number" then return nil end
    return math.floor(n + 0.5)
end

local function brightnessPct(attrs)
    local b = attrs and attrs.brightness
    if type(b) ~= "number" then return nil end
    return round(b / 255 * 100)
end

-- Repaints just one already-shown widget's own screen region (no full-
-- dashboard rebuild, no full-screen flash) -- mirrors Button:refresh().
local function partialRefresh(dashboard_self, widget)
    if not widget.dimen then return end
    UIManager:widgetRepaint(widget, widget.dimen.x, widget.dimen.y)
    UIManager:setDirty(dashboard_self, "ui", widget.dimen)
end

local function setToggleVisual(btn, is_on, label, off_bg)
    btn:setText(label .. (is_on and " · ON" or " · OFF"), btn.width)
    btn.frame.background = is_on and Blitbuffer.COLOR_BLACK or off_bg
    btn.label_widget.fgcolor = is_on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
end

-- Compact row for an on/off light: label on the left, a small rounded
-- ON/OFF pill on the right (same style as the climate card's Heat/Off
-- toggle). Only repaints its own rectangle on tap.
local function buildOnOffTile(settings, light, state, width, height, dashboard_self)
    local is_on = state and state.state == "on"
    local last_is_on = is_on
    local label = light.label or light.entity
    local card, toggle_btn

    -- Shared by the tap callback and the periodic poller. Returns false on
    -- a fetch failure (used to drive the stale indicator); skips the
    -- repaint entirely when nothing actually changed, so a 30s poll of an
    -- untouched light doesn't flash it on real e-ink for no reason.
    local function syncFromServer()
        local new_state = haGetCached(dashboard_self, settings, light.entity)
        if not new_state then return false end
        local new_is_on = new_state.state == "on"
        if new_is_on == last_is_on then return true end
        last_is_on = new_is_on
        toggle_btn:setText(new_is_on and _("ON") or _("OFF"), toggle_btn.width)
        toggle_btn.frame.background = new_is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        toggle_btn.label_widget.fgcolor = new_is_on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        partialRefresh(dashboard_self, card)
        return true
    end
    table.insert(dashboard_self.poll_fns, syncFromServer)

    toggle_btn = Button:new{
        text = is_on and _("ON") or _("OFF"),
        width = Screen:scaleBySize(80),
        height = Screen:scaleBySize(44),
        background = is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_PILL,
        text_font_face = "cfont",
        text_font_size = 16,
        text_font_bold = true,
        callback = function()
            -- Pending feedback: show the command was registered immediately
            -- (grey), independent of how long HA actually takes to confirm
            -- it -- then the 0.4s resync below settles it to the real
            -- black/white once that confirmation (or failure) comes back.
            toggle_btn.frame.background = Blitbuffer.COLOR_GRAY_5
            partialRefresh(dashboard_self, card)
            haCallService(settings, "light", "toggle", { entity_id = light.entity })
            UIManager:scheduleIn(0.4, function()
                syncFromServer()
                dashboard_self:refreshHeaderBadges()
            end)
        end,
    }
    if is_on then whiten(toggle_btn) end

    local label_widget = TextWidget:new{
        text = label,
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Left/RightContainer each center their own child against whatever
    -- height they're given -- if that height differs from the label's and
    -- the button's own heights, each ends up centered on a different
    -- baseline and the two look misaligned relative to each other. Give
    -- them both the same (smaller) reference height first, matched to the
    -- taller of the two, then center that whole row as one unit in the
    -- card's full height.
    local avail_w = width - Size.padding.large * 2
    local row_h = math.max(label_widget:getSize().h, toggle_btn:getSize().h)
    local row = OverlapGroup:new{
        dimen = { w = avail_w, h = row_h },
        LeftContainer:new{ dimen = { w = avail_w, h = row_h }, label_widget },
        RightContainer:new{ dimen = { w = avail_w, h = row_h }, toggle_btn },
    }

    card = FrameContainer:new{
        width = width,
        height = height,
        background = GRAY_FILL,
        bordersize = 0,
        radius = RADIUS_TILE,
        -- padding_h/padding_v aren't real FrameContainer fields (only
        -- Button has those) -- passing them silently fell through to the
        -- nonzero default `padding`, pushing content down off-center.
        padding_top = 0,
        padding_bottom = 0,
        padding_left = Size.padding.large,
        padding_right = Size.padding.large,
        CenterContainer:new{
            dimen = { w = avail_w, h = height },
            row,
        },
    }
    return card
end

-- A card for a dimmable light: toggle button + brightness -/+ row.
-- Any action here only repaints this card's own rectangle.
local function buildDimmableCard(settings, light, state, width, dashboard_self)
    local is_on = state and state.state == "on"
    local pct = brightnessPct(state and state.attributes)
    local label = light.label or light.entity
    local card, toggle_btn, slider -- forward-declared, wired up below
    local last_is_on, last_pct = is_on, pct

    -- Percentage lives in the toggle button's own label ("Bedroom · ON -
    -- 89%") rather than a separate text row, to save vertical space.
    local function toggleLabel(is_on_, pct_)
        return label .. (is_on_ and " · ON" or " · OFF") .. (pct_ and (" - " .. pct_ .. "%") or "")
    end

    -- Shared by the toggle callback and the periodic poller. Returns
    -- false on fetch failure; skips the repaint when nothing changed.
    -- (The slider's own drag handler updates the label/slider itself
    -- immediately and sets last_pct right away -- see onSliderChange
    -- below -- so this only visibly does anything here when HA's
    -- confirmed value disagrees with what was optimistically shown, or
    -- when the change came from elsewhere, e.g. the HA app.)
    local function refreshFromServer()
        local new_state = haGetCached(dashboard_self, settings, light.entity)
        if not new_state then return false end
        local new_is_on = new_state.state == "on"
        local new_pct = brightnessPct(new_state.attributes)
        if new_is_on == last_is_on and new_pct == last_pct then return true end
        last_is_on, last_pct = new_is_on, new_pct
        toggle_btn:setText(toggleLabel(new_is_on, new_pct), toggle_btn.width)
        toggle_btn.frame.background = new_is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        toggle_btn.label_widget.fgcolor = new_is_on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        if slider and new_pct then
            slider.progress:setPercentage(new_pct / 100)
        end
        partialRefresh(dashboard_self, card)
        return true
    end
    table.insert(dashboard_self.poll_fns, refreshFromServer)

    toggle_btn = Button:new{
        text = toggleLabel(is_on, pct),
        width = width - Size.padding.large * 2,
        height = Screen:scaleBySize(56),
        background = is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_TILE,
        text_font_face = "cfont",
        text_font_size = 20,
        text_font_bold = true,
        callback = function()
            toggle_btn.frame.background = Blitbuffer.COLOR_GRAY_5
            partialRefresh(dashboard_self, card)
            haCallService(settings, "light", "toggle", { entity_id = light.entity })
            UIManager:scheduleIn(0.4, function()
                refreshFromServer()
                dashboard_self:refreshHeaderBadges()
            end)
        end,
    }
    if is_on then whiten(toggle_btn) end

    -- Debounced HA call: fires ~0.3s after the finger pauses/lifts, not on
    -- every touch-move tick -- a fast drag would otherwise spam HA with a
    -- service call per pixel of movement. The slider position and label
    -- update immediately regardless (see DragSlider:onSliderDrag above),
    -- so dragging itself never waits on the network either way.
    local send_task
    local function onSliderChange(perc)
        local new_pct = round(perc * 100)
        last_pct = new_pct
        toggle_btn:setText(toggleLabel(last_is_on, new_pct), toggle_btn.width)
        partialRefresh(dashboard_self, card)
        if send_task then UIManager:unschedule(send_task) end
        send_task = function()
            haCallService(settings, "light", "turn_on", {
                entity_id = light.entity,
                brightness_pct = new_pct,
            })
            UIManager:scheduleIn(0.4, function()
                refreshFromServer()
                dashboard_self:refreshHeaderBadges()
            end)
        end
        UIManager:scheduleIn(0.3, send_task)
    end

    slider = DragSlider:new{
        width = width - Size.padding.large * 2,
        height = Screen:scaleBySize(36),
        percentage = (pct or 0) / 100,
        on_change = onSliderChange,
    }

    card = FrameContainer:new{
        width = width,
        -- No fixed height: let the card size itself to its content.
        -- A hardcoded height here previously didn't match the actual
        -- toggle+brightness-row content height, so the toggle button's
        -- rounded bottom edge was bleeding out past the card's bottom.
        background = GRAY_FILL,
        bordercolor = Blitbuffer.COLOR_BLACK,
        bordersize = 0,
        radius = RADIUS_CARD,
        padding = Size.padding.large,
        VerticalGroup:new{
            toggle_btn,
            VerticalSpan:new{ width = Size.span.vertical_large },
            slider,
        },
    }
    return card
end

-- Small pill: scene activation, "all lights" toggle.
local function buildPillButton(opts)
    local btn = Button:new{
        text = opts.text,
        width = opts.width,
        height = opts.height or Screen:scaleBySize(70),
        background = opts.background or Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_PILL,
        text_font_face = "cfont",
        text_font_size = 20,
        text_font_bold = true,
        callback = opts.callback,
    }
    if opts.white_text then whiten(btn) end
    return btn
end

-- Big climate card. Shows one of settings.climate_entities at a time
-- (a selector pill per heater, e.g. "Electric"/"Oil"), with a Heat/Off
-- toggle and target-temp +/- for whichever heater is selected. Selecting
-- a heater turns every *other* configured heater off, so only one ever
-- runs at a time. Any action here only repaints this card's rectangle.
local function buildClimateCard(settings, heater_states, width, dashboard_self)
    local heaters = settings.climate_entities or {}
    local selected = 1
    local card, current_text, humidity_text, target_text, heat_btn
    local selector_btns = {}

    -- Ambient humidity, shown next to the current temperature (same
    -- source that used to be the header's own temp/humidity chip, now
    -- removed -- the temperature half of that is already this card's own
    -- current_text via the heater's current_temperature attribute).
    local humidity_sensor
    for _, s in ipairs(settings.sensors or {}) do
        if s.unit == "%" then humidity_sensor = s break end
    end

    local function currentHeater() return heaters[selected] end

    -- Includes `selected`: switching the displayed heater must always
    -- repaint, even when neither heater's own HA state happens to have
    -- changed (e.g. both are already off) -- otherwise the diff check
    -- below sees an identical signature and silently skips the redraw,
    -- which looked like the selector just not responding to taps.
    local function computeSignature()
        local parts = { tostring(selected) }
        for _, h in ipairs(heaters) do
            local s = heater_states[h.entity]
            table.insert(parts, s and string.format(
                "%s|%s|%s",
                s.state,
                tostring(s.attributes and s.attributes.current_temperature),
                tostring(s.attributes and s.attributes.temperature)
            ) or "nil")
        end
        if humidity_sensor then
            local hs = heater_states[humidity_sensor.entity]
            table.insert(parts, hs and tostring(hs.state) or "nil")
        end
        return table.concat(parts, ";")
    end
    local last_signature = computeSignature()

    local function render()
        local heater = currentHeater()
        local state = heater and heater_states[heater.entity]
        local attrs = state and state.attributes or {}
        local current = round(attrs.current_temperature)
        local target = attrs.temperature
        local is_heat = state and state.state == "heat"

        current_text:setText(current and (current .. "°") or "—")
        target_text:setText(target and (_("Target: ") .. target .. "°") or _("Target: —"))

        if humidity_text and humidity_sensor then
            local hs = heater_states[humidity_sensor.entity]
            local hval = hs and tonumber(hs.state)
            humidity_text:setText(hval and (round(hval) .. "%") or "—")
        end

        heat_btn:setText(is_heat and _("Heat") or _("Off"), heat_btn.width)
        heat_btn.frame.background = is_heat and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        heat_btn.label_widget.fgcolor = is_heat and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

        for i, btn in ipairs(selector_btns) do
            local is_sel = (i == selected)
            btn.frame.background = is_sel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            btn.label_widget.fgcolor = is_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        end
    end

    -- Shared by every control in this card and the periodic poller.
    -- Returns false on fetch failure; skips the repaint when nothing
    -- changed, and follows whichever heater HA reports as actively
    -- heating in case it was switched from elsewhere (HA app, automation).
    local function refreshFromServer()
        for _, h in ipairs(heaters) do
            local new_state = haGetCached(dashboard_self, settings, h.entity)
            if not new_state then return false end
            heater_states[h.entity] = new_state
        end
        if humidity_sensor then
            heater_states[humidity_sensor.entity] = haGetCached(dashboard_self, settings, humidity_sensor.entity)
        end
        for i, h in ipairs(heaters) do
            local s = heater_states[h.entity]
            if s and s.state == "heat" then
                selected = i
                break
            end
        end
        local sig = computeSignature()
        if sig == last_signature then return true end
        last_signature = sig
        render()
        partialRefresh(dashboard_self, card)
        return true
    end
    table.insert(dashboard_self.poll_fns, refreshFromServer)

    local function selectHeater(idx)
        if idx == selected then return end
        selected = idx
        for i, h in ipairs(heaters) do
            if i ~= idx then
                haCallService(settings, "climate", "set_hvac_mode", { entity_id = h.entity, hvac_mode = "off" })
            end
        end
        UIManager:scheduleIn(0.4, refreshFromServer)
    end

    for i, heater in ipairs(heaters) do
        local is_sel = (i == selected)
        local btn = Button:new{
            text = heater.label or heater.entity,
            width = Screen:scaleBySize(130),
            height = Screen:scaleBySize(48),
            background = is_sel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = RADIUS_PILL,
            text_font_face = "cfont",
            text_font_size = 18,
            text_font_bold = true,
            callback = function() selectHeater(i) end,
        }
        if is_sel then whiten(btn) end
        table.insert(selector_btns, btn)
    end
    local selector_row = nil
    if #selector_btns > 1 then
        local items = {}
        for i, btn in ipairs(selector_btns) do
            if i > 1 then table.insert(items, HorizontalSpan:new{ width = Size.span.horizontal_default }) end
            table.insert(items, btn)
        end
        selector_row = HorizontalGroup:new(items)
    end

    local initial_heater = currentHeater()
    local initial_state = initial_heater and heater_states[initial_heater.entity]
    local initial_attrs = initial_state and initial_state.attributes or {}
    local initial_current = round(initial_attrs.current_temperature)
    local initial_target = initial_attrs.temperature
    local initial_is_heat = initial_state and initial_state.state == "heat"

    current_text = TextWidget:new{
        text = initial_current and (initial_current .. "°") or "—",
        face = Font:getFace("cfont", 54),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    if humidity_sensor then
        local initial_hs = heater_states[humidity_sensor.entity]
        local initial_hval = initial_hs and tonumber(initial_hs.state)
        humidity_text = TextWidget:new{
            text = initial_hval and (round(initial_hval) .. "%") or "—",
            face = Font:getFace("cfont", 54),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    target_text = TextWidget:new{
        text = initial_target and (_("Target: ") .. initial_target .. "°") or _("Target: —"),
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }
    heat_btn = Button:new{
        text = initial_is_heat and _("Heat") or _("Off"),
        width = Screen:scaleBySize(130),
        height = Screen:scaleBySize(56),
        background = initial_is_heat and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_PILL,
        text_font_face = "cfont",
        text_font_size = 20,
        text_font_bold = true,
        callback = function()
            local heater = currentHeater()
            if not heater then return end
            local state = heater_states[heater.entity]
            local is_heat = state and state.state == "heat"
            heat_btn.frame.background = Blitbuffer.COLOR_GRAY_5
            partialRefresh(dashboard_self, card)
            haCallService(settings, "climate", "set_hvac_mode", {
                entity_id = heater.entity,
                hvac_mode = is_heat and "off" or "heat",
            })
            UIManager:scheduleIn(0.4, function()
                refreshFromServer()
                dashboard_self:refreshHeaderBadges()
            end)
        end,
    }
    if initial_is_heat then whiten(heat_btn) end

    local function stepTarget(sign)
        return function()
            local heater = currentHeater()
            if not heater then return end
            local state = heater_states[heater.entity]
            local target = state and state.attributes and state.attributes.temperature
            local step = (state and state.attributes and state.attributes.target_temp_step) or 0.5
            if not target then return end
            haCallService(settings, "climate", "set_temperature", {
                entity_id = heater.entity,
                temperature = target + sign * step,
            })
            UIManager:scheduleIn(0.4, function()
                refreshFromServer()
                dashboard_self:refreshHeaderBadges()
            end)
        end
    end

    -- Selector pills (left) + Heat/Off toggle (right) share one row, which
    -- saves a whole row of vertical space versus stacking them.
    local top_row_h = math.max(
        selector_row and selector_row:getSize().h or 0,
        heat_btn:getSize().h
    )
    local small_vgap = Size.span.vertical_default

    -- Humidity (same ambient sensor the header's own temp/humidity chip
    -- used to show, now removed) fills the whitespace beside the big
    -- current-temperature number, same size, rather than its own row.
    local temp_row = current_text
    if humidity_text then
        temp_row = HorizontalGroup:new{
            current_text,
            HorizontalSpan:new{ width = Screen:scaleBySize(40) },
            humidity_text,
        }
    end
    local temp_target_stack = VerticalGroup:new{
        temp_row,
        VerticalSpan:new{ width = small_vgap },
        target_text,
    }
    local temp_target_h = temp_target_stack:getSize().h

    -- Quick-set presets: pick a target temp (and switch the heater to Heat)
    -- in one tap. A column to the left of the number/target, sized to
    -- fill that whole height (from under Electric/Oil to the card's
    -- bottom), not squeezed into a single row alongside the number.
    local presets = {
        { label = _("Night"), temp = 18 },
        { label = _("Comfort"), temp = 22 },
        { label = _("Eco"), temp = 20 },
    }
    -- A visible gap between pills (rather than the near-zero default span)
    -- so the three presets read as distinct elements, not one block.
    local preset_gap = Screen:scaleBySize(8)
    local preset_h = math.max(Screen:scaleBySize(28), (temp_target_h - preset_gap * (#presets - 1)) / #presets)
    local preset_items = {}
    for i, preset in ipairs(presets) do
        if i > 1 then table.insert(preset_items, VerticalSpan:new{ width = preset_gap }) end
        table.insert(preset_items, Button:new{
            text = string.format("%s %d°", preset.label, preset.temp),
            width = Screen:scaleBySize(112),
            height = preset_h,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Screen:scaleBySize(14),
            padding_h = Size.padding.tiny,
            padding_v = Size.padding.tiny,
            text_font_face = "cfont",
            text_font_size = 15,
            text_font_bold = true,
            callback = function()
                local heater = currentHeater()
                if not heater then return end
                haCallService(settings, "climate", "set_temperature", {
                    entity_id = heater.entity,
                    temperature = preset.temp,
                    hvac_mode = "heat",
                })
                UIManager:scheduleIn(0.4, function()
                refreshFromServer()
                dashboard_self:refreshHeaderBadges()
            end)
            end,
        })
    end
    local presets_col = VerticalGroup:new(preset_items)
    local row2_h = math.max(presets_col:getSize().h, temp_target_h)

    -- Height the left column will end up at, computed *before* the +/-
    -- buttons exist, so their size can be derived from it (see below) --
    -- neither row's height depends on the +/- button size.
    local left_col_h_estimate = top_row_h + small_vgap + row2_h

    -- Size the +/- buttons so the pair (with a small gap) fills that same
    -- height, instead of a fixed size with a stretched gap between them.
    local btn_gap = small_vgap
    local round_btn_size = math.max(Screen:scaleBySize(48), math.min(Screen:scaleBySize(86), (left_col_h_estimate - btn_gap) / 2))
    local round_btn_radius = round_btn_size / 2 -- true circle, whatever the size

    local minus_btn = Button:new{
        text = "−",
        width = round_btn_size,
        height = round_btn_size,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = round_btn_radius,
        text_font_size = 32,
        text_font_bold = true,
        callback = stepTarget(-1),
    }
    local plus_btn = whiten(Button:new{
        text = "+",
        width = round_btn_size,
        height = round_btn_size,
        background = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.window,
        radius = round_btn_radius,
        text_font_size = 32,
        text_font_bold = true,
        callback = stepTarget(1),
    })

    local right_col_w = round_btn_size
    local col_gap = Screen:scaleBySize(16)
    local left_col_w = width - right_col_w - col_gap - Size.padding.large * 2
    local top_row = OverlapGroup:new{
        dimen = { w = left_col_w, h = top_row_h },
        LeftContainer:new{
            dimen = { w = left_col_w, h = top_row_h },
            selector_row or HorizontalGroup:new{},
        },
        RightContainer:new{
            dimen = { w = left_col_w, h = top_row_h },
            heat_btn,
        },
    }

    -- Presets pinned to the left edge, spanning the full row height;
    -- current temp + target centered in the space to the right of the
    -- presets column (not the full column width -- adding the humidity
    -- reading next to the current temperature widened this block enough
    -- that centering it across the *full* width made it overlap the
    -- presets; indenting the centering region past the presets' own
    -- width keeps them apart). A plain HorizontalGroup of the two would
    -- instead center them as one glued block, pulling the presets off
    -- the left edge, hence still using OverlapGroup for the presets.
    local presets_w = presets_col:getSize().w
    local temp_indent = presets_w + Screen:scaleBySize(12)
    local temp_area_w = left_col_w - temp_indent
    local row2 = OverlapGroup:new{
        dimen = { w = left_col_w, h = row2_h },
        LeftContainer:new{ dimen = { w = left_col_w, h = row2_h }, presets_col },
        LeftContainer:new{
            dimen = { w = left_col_w, h = row2_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = temp_indent },
                CenterContainer:new{ dimen = { w = temp_area_w, h = row2_h }, temp_target_stack },
            },
        },
    }

    local left_col = VerticalGroup:new{
        top_row,
        VerticalSpan:new{ width = small_vgap },
        row2,
    }
    local right_col = VerticalGroup:new{
        plus_btn,
        VerticalSpan:new{ width = btn_gap },
        minus_btn,
    }

    card = FrameContainer:new{
        width = width,
        background = GRAY_FILL,
        bordersize = 0,
        radius = RADIUS_CARD,
        padding = Size.padding.large,
        HorizontalGroup:new{
            left_col,
            HorizontalSpan:new{ width = col_gap },
            right_col,
        },
    }
    return card
end

-- Weather chip: bold "now" reading, then a clearly-labelled forecast
-- segment (today's high/low, rain chance) in lighter gray.
local function buildWeatherChip(width, state, forecast)
    local height = Screen:scaleBySize(64)
    local condition = state and state.state or "?"
    local now_temp = state and round((state.attributes or {}).temperature)
    local now_text = now_temp and string.format("%s  %s°", condition, now_temp) or condition

    local detail_parts = {}
    if forecast then
        local hi = round(forecast.temperature)
        local lo = round(forecast.templow)
        if hi and lo then
            table.insert(detail_parts, string.format("H:%s°  L:%s°", hi, lo))
        end
        -- Prefer HA's standard rain-chance percentage field when the
        -- weather integration provides it; fall back to a precipitation
        -- amount (mm) for integrations that don't.
        local rain_chance = forecast.precipitation_probability
        local rain_mm = forecast.precipitation
        if type(rain_chance) == "number" then
            table.insert(detail_parts, string.format(_("Rain: %d%%"), round(rain_chance)))
        elseif type(rain_mm) == "number" then
            table.insert(detail_parts, rain_mm > 0
                and string.format(_("Rain: %.1fmm"), rain_mm)
                or _("No rain"))
        end
    end

    local row = {
        TextWidget:new{
            text = now_text,
            face = Font:getFace("cfont", 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    if #detail_parts > 0 then
        table.insert(row, HorizontalSpan:new{ width = Size.span.horizontal_default * 2 })
        table.insert(row, TextWidget:new{
            text = table.concat(detail_parts, "   "),
            face = Font:getFace("cfont", 18),
            fgcolor = Blitbuffer.COLOR_GRAY_5,
        })
    end

    -- FrameContainer already shifts its child down/right by `padding`, so
    -- the CenterContainer here must center within the space that's left
    -- over (height minus padding on both sides), not the full outer
    -- height -- otherwise the content ends up off-center, pushed low.
    local pad = Size.padding.default
    return FrameContainer:new{
        width = width,
        height = height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_PILL,
        padding = pad,
        CenterContainer:new{
            dimen = { w = width - pad * 2, h = height - pad * 2 },
            HorizontalGroup:new(row),
        },
    }
end

-- Formerly "21° · 45%" header chip -- removed; the temperature half is
-- already shown big in the climate card (heater's own current_temperature
-- attribute) and the humidity half now sits next to it there instead
-- (see buildClimateCard/humidity_sensor), filling whitespace that used to
-- go unused next to the big number.

local function buildHeader(width, power_badges, exit_callback, ps_callback, ps_armed_initial)
    local height = Screen:scaleBySize(70)
    -- Power badges (battery/solar/consumption) sit left-aligned in the
    -- header itself now, in place of a greeting -- saves the separate
    -- row they used to need below the header.
    local left_items = {}
    if power_badges then
        table.insert(left_items, power_badges)
    end
    local powerd = Device:getPowerDevice()
    local battery = powerd and powerd:getCapacity()
    local time_text = TextWidget:new{
        text = string.format("%s%s", os.date("%H:%M"), battery and ("  " .. battery .. "%") or ""),
        face = Font:getFace("cfont", 22),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }
    -- Stale/offline indicator: empty (zero-ish width) when everything's
    -- fine, set to a warning glyph by HaDashboard when a poll fails to
    -- reach HA. Wrapped in its own FrameContainer (not just a bare
    -- TextWidget) so it has a .dimen to target with a partial refresh.
    local stale_text = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }
    -- Full-screen modal with no built-in way back to KOReader's own menu
    -- (Settings, file browser, etc) -- this is the only way out of it.
    -- Lives in the header's own row (not a floating corner overlay) so it
    -- can't overlap the time/battery text.
    local exit_btn = Button:new{
        text = "\u{2699}",
        width = Screen:scaleBySize(36),
        height = Screen:scaleBySize(36),
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Screen:scaleBySize(18),
        text_font_size = 18,
        callback = exit_callback,
    }
    -- Sits left of the gear, same reasoning as the gear sitting left of
    -- the clock: a new icon goes next to its closest-related sibling,
    -- not tacked onto the far edge. Filled black when Power Saving is
    -- armed, outline when not -- same visual language as every other
    -- toggle in this file.
    local ps_btn = Button:new{
        text = "PS",
        width = Screen:scaleBySize(36),
        height = Screen:scaleBySize(36),
        background = ps_armed_initial and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Screen:scaleBySize(18),
        text_font_size = 13,
        text_font_bold = true,
        callback = ps_callback,
    }
    if ps_armed_initial then whiten(ps_btn) end
    local stale_frame = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        HorizontalGroup:new{
            stale_text,
            HorizontalSpan:new{ width = Size.span.horizontal_small },
            ps_btn,
            HorizontalSpan:new{ width = Size.span.horizontal_small },
            exit_btn,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            time_text,
        },
    }
    stale_frame.stale_text = stale_text
    stale_frame.time_text = time_text
    stale_frame.ps_btn = ps_btn
    return OverlapGroup:new{
        dimen = { w = width, h = height },
        LeftContainer:new{
            dimen = { w = width, h = height },
            HorizontalGroup:new(left_items),
        },
        RightContainer:new{
            dimen = { w = width, h = height },
            stale_frame,
        },
    }, stale_frame
end

-- Left-aligned row of small power badges: home battery %, solar
-- production, house consumption. No bundled icon assets exist for
-- battery/solar, so those use text glyphs; house consumption reuses the
-- real "home" SVG icon.
local function buildPowerBadges(settings, states)
    local function readKw(entity_id)
        local state = entity_id and states[entity_id]
        local num = state and tonumber(state.state)
        if not num then return nil end
        return string.format("%.1fkW", num)
    end
    local function readPct(entity_id)
        local state = entity_id and states[entity_id]
        local num = state and tonumber(state.state)
        if not num then return nil end
        return round(num) .. "%"
    end

    local battery_text = readPct(settings.battery_entity)
    local solar_text = readKw(settings.solar_power_entity)
    local consumption_text = readKw(settings.consumption_entity)
    if not (battery_text or solar_text or consumption_text) then return nil end

    local icon_size = Screen:scaleBySize(20)
    local items = {}
    local text_widgets = {}
    local function addBadge(key, glyph_widget, text)
        if not text then return end
        if #items > 0 then
            table.insert(items, HorizontalSpan:new{ width = Size.span.horizontal_default * 2 })
        end
        table.insert(items, glyph_widget)
        table.insert(items, HorizontalSpan:new{ width = Size.span.horizontal_small })
        local text_widget = TextWidget:new{
            text = text,
            face = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_GRAY_5,
        }
        text_widgets[key] = text_widget
        table.insert(items, text_widget)
    end
    addBadge("battery", TextWidget:new{
        text = "\u{26A1}",
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }, battery_text)
    addBadge("solar", TextWidget:new{
        text = "\u{2600}",
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }, solar_text)
    addBadge("consumption", IconWidget:new{ icon = "home", width = icon_size, height = icon_size, alpha = true }, consumption_text)

    local group = HorizontalGroup:new(items)
    group.text_widgets = text_widgets
    return group
end

----------------------------------------------------------------
-- Full-screen dashboard
----------------------------------------------------------------

local HaDashboard = WidgetContainer:extend{
    name = "hadash_dashboard",
}

-- Module-level, not per-instance -- same reasoning as has_auto_opened
-- below. Hard guarantee against two live instances ever polling at once:
-- confirmed on-device via crash.log timestamps showing a clean single
-- "template fetch failed" every 60s *plus* a separate cluster of ~3 near-
-- simultaneous ones every 60s, i.e. more than one instance's poll loop
-- running concurrently -- each doing its own full entity fetch and
-- stacking CPU/network work on KOReader's single Lua thread, which lines
-- up with the "unresponsive after a while, needs a power-button press"
-- freeze. Whatever the exact path that creates a second instance (close
-- not going through onClose, a race during the periodic full-refresh
-- rebuild, etc), forcing any previous instance closed before a new one
-- is ever shown rules it out categorically rather than chasing the
-- specific trigger.
local active_dashboard = nil

-- Module-level, not per-instance (poll_count resets to 0 for every
-- rebuilt instance, so a per-instance check would retrigger forever).
-- Caps how many early "the initial fetch may have been incomplete,
-- rebuild and try again" corrections happen per process lifetime -- see
-- runPoll below.
local early_rebuild_count = 0
local MAX_EARLY_REBUILDS = 2

function HaDashboard:init()
    if active_dashboard and not active_dashboard._closed then
        active_dashboard:onClose()
    end
    active_dashboard = self

    self.dimen = Screen:getSize()
    local settings = loadSettings()
    if not settings then
        self[1] = CenterContainer:new{
            dimen = self.dimen,
            TextWidget:new{
                text = _("hadash: no settings file found"),
                face = Font:getFace("cfont", 22),
            },
        }
        logger.warn("hadash: missing settings file at", SETTINGS_PATH)
        return
    end

    self.settings = settings
    self.poll_fns = {} -- populated by builders below; polled every POLL_INTERVAL_S

    mqttConnect(settings)

    local states = fetchAllStates(settings)
    local forecast = fetchForecast(settings)
    local content_w = self.dimen.w - GUTTER * 2
    local power_badges = buildPowerBadges(settings, states)
    self.power_badges = power_badges
    local header, stale_frame = buildHeader(content_w, power_badges, function()
        UIManager:close(self)
    end, function()
        ps_armed = not ps_armed
        if self.stale_frame and self.stale_frame.ps_btn then
            local btn = self.stale_frame.ps_btn
            btn.frame.background = ps_armed and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            btn.label_widget.fgcolor = ps_armed and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            partialRefresh(self, self.stale_frame)
        end
        if mqtt_client and mqtt_client.connection then
            mqtt_client:publish{ topic = "kindle_dashboard/power_saving/state", payload = ps_armed and "ON" or "OFF", retain = true }
        end
    end, ps_armed)
    self.stale_frame = stale_frame
    local rows = {
        header,
    }

    table.insert(rows, VerticalSpan:new{ width = GUTTER })
    table.insert(rows, buildWeatherChip(content_w, states[settings.weather_entity], forecast))

    if settings.climate_entities and #settings.climate_entities > 0 then
        table.insert(rows, VerticalSpan:new{ width = GUTTER })
        table.insert(rows, buildClimateCard(settings, states, content_w, self))
    end

    if settings.lights_onoff and #settings.lights_onoff > 0 then
        -- Rows of 2 (not one row stretched to fit N) -- an odd entry at
        -- the end gets its own row with just the left slot filled, not
        -- stretched to fill both.
        local tile_w = (content_w - GUTTER) / 2
        local tile_h = Screen:scaleBySize(60)
        for i = 1, #settings.lights_onoff, 2 do
            table.insert(rows, VerticalSpan:new{ width = GUTTER })
            local left_light = settings.lights_onoff[i]
            local right_light = settings.lights_onoff[i + 1]
            local tile_row = {
                buildOnOffTile(settings, left_light, states[left_light.entity], tile_w, tile_h, self),
            }
            if right_light then
                table.insert(tile_row, HorizontalSpan:new{ width = GUTTER })
                table.insert(tile_row, buildOnOffTile(settings, right_light, states[right_light.entity], tile_w, tile_h, self))
            end
            -- Without this, a row with only the left tile (odd entry)
            -- is narrower than the other rows and gets centered in the
            -- available width instead of staying flush left.
            table.insert(rows, LeftContainer:new{
                dimen = { w = content_w, h = tile_h },
                HorizontalGroup:new(tile_row),
            })
        end
    end

    if settings.lights_dimmable and #settings.lights_dimmable > 0 then
        table.insert(rows, VerticalSpan:new{ width = GUTTER })
        local card_w = (content_w - GUTTER) / 2
        local card_row = {}
        for i, light in ipairs(settings.lights_dimmable) do
            table.insert(card_row, buildDimmableCard(settings, light, states[light.entity], card_w, self))
            if i < #settings.lights_dimmable then
                table.insert(card_row, HorizontalSpan:new{ width = GUTTER })
            end
        end
        table.insert(rows, HorizontalGroup:new(card_row))
    end

    -- All-lights toggle (smaller) + scene buttons, one row. Each only
    -- repaints itself -- toggling never touches the rest of the screen.
    local action_items = {}
    if settings.all_lights_entity then
        local all_state = states[settings.all_lights_entity]
        local all_on = all_state and all_state.state == "on"
        local last_all_on = all_on
        local all_btn
        local function syncAllLights()
            local new_state = haGetCached(self, settings, settings.all_lights_entity)
            if not new_state then return false end
            local new_on = new_state.state == "on"
            if new_on == last_all_on then return true end
            last_all_on = new_on
            setToggleVisual(all_btn, new_on, _("All lights"), Blitbuffer.COLOR_WHITE)
            all_btn:refresh()
            return true
        end
        table.insert(self.poll_fns, syncAllLights)
        all_btn = Button:new{
            text = _("All lights") .. (all_on and " · ON" or " · OFF"),
            width = content_w * 0.28,
            height = Screen:scaleBySize(70),
            background = all_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = RADIUS_PILL,
            text_font_face = "cfont",
            text_font_size = 20,
            text_font_bold = true,
            callback = function()
                all_btn.frame.background = Blitbuffer.COLOR_GRAY_5
                all_btn:refresh()
                haCallService(settings, "light", "toggle", { entity_id = settings.all_lights_entity })
                -- Toggling a light group can take a moment to actually
                -- propagate to each real bulb, longer than a single
                -- light's own 0.4s -- refresh twice, catching stragglers
                -- that hadn't finished applying on the first check.
                UIManager:scheduleIn(0.8, function() self:refreshAllTiles() end)
                UIManager:scheduleIn(2.5, function() self:refreshAllTiles() end)
            end,
        }
        if all_on then whiten(all_btn) end
        table.insert(action_items, all_btn)
    end
    if settings.scenes and #settings.scenes > 0 then
        local remaining_w = content_w - (action_items[1] and action_items[1]:getSize().w or 0)
        local scene_w = (remaining_w - GUTTER * #settings.scenes) / #settings.scenes
        for _, scene in ipairs(settings.scenes) do
            if #action_items > 0 then
                table.insert(action_items, HorizontalSpan:new{ width = GUTTER })
            end
            -- Scenes have no on/off state of their own, but typically
            -- change several OTHER entities (lights, etc.) at once, so
            -- refresh everything shortly after activating one.
            table.insert(action_items, buildPillButton{
                text = scene.label or scene.entity,
                width = scene_w,
                background = GRAY_FILL,
                callback = function()
                    haCallService(settings, "scene", "turn_on", { entity_id = scene.entity })
                    -- A scene can change several real bulbs at once, each
                    -- taking its own moment to actually apply (Zigbee/
                    -- Wi-Fi propagation, not instant like an HA-internal
                    -- state change) -- refresh twice, well past both the
                    -- initial check and typical real-device lag, so a
                    -- slow light doesn't stay showing its pre-scene value.
                    UIManager:scheduleIn(0.8, function() self:refreshAllTiles() end)
                    UIManager:scheduleIn(2.5, function() self:refreshAllTiles() end)
                end,
            })
        end
    end
    if #action_items > 0 then
        table.insert(rows, VerticalSpan:new{ width = GUTTER })
        table.insert(rows, HorizontalGroup:new(action_items))
    end

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = GUTTER,
        VerticalGroup:new(rows),
    }

    -- One early retry a few seconds after init instead of waiting a full
    -- POLL_INTERVAL_S: at boot, this dashboard can launch before Wi-Fi has
    -- actually associated (autostart now triggers on an event earlier
    -- than the native network daemon), so the very first fetch above may
    -- have failed outright with every tile left blank/stale. runPoll's
    -- own tail call re-establishes the normal POLL_INTERVAL_S cadence
    -- from here, so this is a one-time catch-up, not a tighter loop.
    UIManager:scheduleIn(5, function()
        if self._closed then return end
        self:runPoll()
    end)

    -- Global activity tracking for Power Saving mode: fires on every raw
    -- input event regardless of which widget actually handles the
    -- gesture (same mechanism KOReader's own autostandby.koplugin uses),
    -- so a tap on an actual button counts as activity too, not just taps
    -- that land on empty background. Auto-unregisters on close via the
    -- wrapped onCloseWidget this sets up internally -- no manual cleanup
    -- needed.
    UIManager.event_hook:registerWidget("InputEvent", self)

    self:scheduleMqttTick()
end

-- A separate, much faster ticker than the main 60s HA poll -- MQTT
-- messages (HA-side switch/number changes) are only actually read when
-- something calls the client's iteration method, which the main poll
-- only does once every POLL_INTERVAL_S. Without this, a command sent
-- from HA while the dashboard is awake could sit unapplied for up to a
-- minute. This only drives the MQTT client (cheap, 50ms-bounded) and
-- skips the expensive fetchAllStates/haSetState work the main poll does.
function HaDashboard:scheduleMqttTick()
    self._mqtt_task = function()
        if self._closed or ps_sleeping then return end
        mqttTick(self.settings, nil)
        self:scheduleMqttTick()
    end
    UIManager:scheduleIn(3, self._mqtt_task)
end

function HaDashboard:onInputEvent()
    last_activity = os.time()
    if ps_sleeping then
        self:wakeFromPowerSaving()
        -- Falls through to the frontlight logic below too, so the tap
        -- that wakes it also turns the light on (if allowed) instead of
        -- needing a second tap.
    end
    -- Tap-to-light: turn the frontlight on on any tap (if allowed right
    -- now -- see fl_allowed above), auto-off again after fl_auto_off_s
    -- seconds of no further taps. Both that duration and the brightness
    -- level applied here are HA-adjustable (see the two "number"
    -- entities in mqttPublishDiscovery). Replaces KOReader's own
    -- generic autodim timer (disabled in settings.reader.lua), which
    -- had no way to gate on an HA condition and fought any attempt to
    -- control it from here.
    if fl_allowed then
        local powerd = Device:getPowerDevice()
        if powerd then
            powerd:setIntensity(fl_wake_brightness)
        end
        if fl_off_task then
            UIManager:unschedule(fl_off_task)
        end
        fl_off_task = function()
            local powerd2 = Device:getPowerDevice()
            if powerd2 then powerd2:turnOffFrontlight() end
        end
        UIManager:scheduleIn(fl_auto_off_s, fl_off_task)
    end
end

function HaDashboard:enterPowerSaving()
    if ps_sleeping then return end
    ps_sleeping = true
    if self._poll_task then
        UIManager:unschedule(self._poll_task)
    end
    if self._mqtt_task then
        UIManager:unschedule(self._mqtt_task)
    end
    mqttDisconnect()
    setWifiEnabled(false)
    if fl_off_task then
        UIManager:unschedule(fl_off_task)
        fl_off_task = nil
    end
    local powerd = Device:getPowerDevice()
    if powerd and powerd:isFrontlightOn() then
        powerd:turnOffFrontlight()
    end
    -- InfoMessage already vanishes on its own on any key/tap press; our
    -- own onInputEvent hook (fires globally, regardless of what's on
    -- top) explicitly closes it too below, so either path dismisses it.
    self._ps_overlay = InfoMessage:new{
        text = _("Power Saving mode\nTap anywhere to wake"),
        dismissable = true,
    }
    UIManager:show(self._ps_overlay)
end

function HaDashboard:wakeFromPowerSaving()
    if not ps_sleeping then return end
    ps_sleeping = false
    last_activity = os.time()
    if self._ps_overlay then
        UIManager:close(self._ps_overlay)
        self._ps_overlay = nil
    end
    setWifiEnabled(true)
    self:schedulePoll()
    self:scheduleMqttTick()
    -- Wi-Fi needs a moment to reassociate -- same reasoning as the
    -- existing scene/all-lights double-refresh delay.
    UIManager:scheduleIn(3, function()
        if self._closed then return end
        self:refreshAllTiles()
    end)
end

-- Shows/clears the header's stale-connection indicator. No-ops if nothing
-- changed, so a run of consecutive successful (or consecutive failed)
-- polls doesn't keep re-flashing it.
function HaDashboard:setStale(is_stale)
    if is_stale == self._is_stale then return end
    self._is_stale = is_stale
    if not self.stale_frame then return end
    self.stale_frame.stale_text:setText(is_stale and _("\u{26A0} Offline") or "")
    partialRefresh(self, self.stale_frame)
end

function HaDashboard:schedulePoll()
    -- Stored on self (not a bare inline closure) so onClose can cancel it
    -- outright via UIManager:unschedule -- the _closed flag already stops
    -- the chain from continuing on its own, but this removes the queued
    -- tick immediately instead of waiting for it to fire and no-op.
    self._poll_task = function()
        if self._closed then return end
        self:runPoll()
    end
    UIManager:scheduleIn(POLL_INTERVAL_S, self._poll_task)
end

-- Cheap, standalone refresh of just the header sensor chip and power
-- badges (temp/humidity/battery/solar/consumption -- a handful of
-- entities at most), independent of the much heavier fetchAllStates/
-- poll_fns loop. Safe to call after every single tap (unlike
-- refreshAllTiles, which can be a dozen-plus sequential HTTP round-trips
-- and visibly freezes input if called that often) so these badges stay
-- current regardless of which control was touched.
function HaDashboard:refreshHeaderBadges()
    if self._closed then return end
    local settings = self.settings
    local any_failed = false
    if self.power_badges and self.power_badges.text_widgets then
        local function readKw(entity_id)
            local state = entity_id and haGetCached(self, settings, entity_id)
            local num = state and tonumber(state.state)
            if not num then return nil end
            return string.format("%.1fkW", num)
        end
        local function readPct(entity_id)
            local state = entity_id and haGetCached(self, settings, entity_id)
            local num = state and tonumber(state.state)
            if not num then return nil end
            return round(num) .. "%"
        end
        local tw = self.power_badges.text_widgets
        local function updateBadge(key, text)
            if tw[key] and text and text ~= self["_last_" .. key .. "_text"] then
                self["_last_" .. key .. "_text"] = text
                tw[key]:setText(text)
                partialRefresh(self, self.power_badges)
            end
        end
        updateBadge("battery", readPct(settings.battery_entity))
        updateBadge("solar", readKw(settings.solar_power_entity))
        updateBadge("consumption", readKw(settings.consumption_entity))
    end
    return not any_failed
end

-- Re-checks every tile this dashboard shows and repaints only the ones
-- whose value actually changed (each poll_fn is the same sync function
-- its widget's own tap callback uses, which already diffs before
-- repainting), and refreshes the header clock/badges. Shared by the
-- periodic poller and by tap callbacks -- so toggling one light, running
-- a scene, changing the heater, etc. also catches any OTHER entity it
-- affected (e.g. a scene turning on several lights, not just the button
-- tapped), not just the one tile that was interacted with.
function HaDashboard:refreshAllTiles()
    if self._closed then return end
    local powerd = Device:getPowerDevice()
    local battery = powerd and powerd:getCapacity()
    if self.stale_frame and self.stale_frame.time_text then
        self.stale_frame.time_text:setText(string.format("%s%s", os.date("%H:%M"), battery and ("  " .. battery .. "%") or ""))
        partialRefresh(self, self.stale_frame)
    end
    -- Report the Kindle's own battery back to HA as a sensor, not just
    -- read entities from it -- optional, set kindle_battery_entity in
    -- hadash_settings.lua to enable. haSetState creates the entity on
    -- HA's side on first push if it doesn't already exist.
    if self.settings.kindle_battery_entity and battery then
        haSetState(self.settings, self.settings.kindle_battery_entity, battery, {
            unit_of_measurement = "%",
            device_class = "battery",
            friendly_name = "Kindle Dashboard Battery",
        })
    end
    -- One combined fetch for every tile this tick instead of one GET per
    -- tile's own closure (see fetchAllStates/haGetCached above).
    self._poll_cache = fetchAllStates(self.settings)
    -- Optional: an HA entity (e.g. a lux-sensor-driven automation with a
    -- time-of-day condition) gates whether tapping is ALLOWED to turn
    -- the frontlight on at all -- e.g. off during the day when there's
    -- enough ambient light. This just refreshes the cached flag; the
    -- actual on-tap-turn-on + 30s-auto-off behavior lives in
    -- onInputEvent/scheduleFrontlightOff below, not here.
    if self.settings.frontlight_entity then
        local fl_state = haGetCached(self, self.settings, self.settings.frontlight_entity)
        if fl_state then
            fl_allowed = (fl_state.state == "on")
        end
    end
    local any_failed = false
    for _, fn in ipairs(self.poll_fns) do
        local ok = fn()
        if ok == false then any_failed = true end
    end
    self:refreshHeaderBadges()
    self._poll_cache = nil
    self:setStale(any_failed)
    mqttTick(self.settings, battery)
end

-- Periodic tick (milestone 4, "robustness"). Every Nth tick instead does
-- a full dashboard rebuild, which forces a real full-screen refresh -- on
-- e-ink that's what clears the ghosting that accumulates from all the
-- partial updates in between.
function HaDashboard:runPoll()
    if self._closed then return end
    if not ps_timeout_seeded then
        ps_timeout_seeded = true
        ps_timeout_s = self.settings.power_saving_timeout_s or 300
    end
    if ps_armed and not ps_sleeping then
        if os.time() - last_activity >= ps_timeout_s then
            self:enterPowerSaving()
            return
        end
    end
    self._poll_count = (self._poll_count or 0) + 1
    -- Power badges and scenes (and anything else whose presence depends
    -- on data available at build time) are structural -- decided once
    -- when the widget tree is built, not something refreshAllTiles can
    -- retroactively add. If the very first fetchAllStates (at init) hit
    -- the device-boot network-not-ready window, those rows are just
    -- absent until a full rebuild re-evaluates them with fresh data.
    -- Force that rebuild on the first tick (in addition to the normal
    -- Nth-tick cadence below) instead of leaving a possibly incomplete
    -- first render to wait out the full ~10 minutes -- capped at
    -- MAX_EARLY_REBUILDS total per process lifetime (not per instance:
    -- poll_count resets to 0 on every rebuild, so without this cap this
    -- would retrigger every cycle forever and never settle).
    local want_early_rebuild = self._poll_count == 1 and early_rebuild_count < MAX_EARLY_REBUILDS
    if want_early_rebuild or self._poll_count % FULL_REFRESH_EVERY_N_POLLS == 0 then
        if want_early_rebuild then early_rebuild_count = early_rebuild_count + 1 end
        self._closed = true
        UIManager:close(self)
        UIManager:show(HaDashboard:new{})
        return
    end
    self:refreshAllTiles()
    self:schedulePoll()
end

function HaDashboard:onClose()
    self._closed = true
    if self._poll_task then
        UIManager:unschedule(self._poll_task)
    end
    if self._mqtt_task then
        UIManager:unschedule(self._mqtt_task)
    end
    UIManager:close(self)
    -- Force a full flashing refresh of whatever's now on top, clearing any
    -- e-ink ghost of the dashboard's last-drawn frame immediately instead
    -- of leaving it to bleed through until the next natural refresh.
    UIManager:setDirty(nil, "full")
    return true
end

----------------------------------------------------------------
-- Plugin registration
----------------------------------------------------------------

local HaDash = WidgetContainer:extend{
    name = "hadash",
}

-- Module-level (not per-instance): KOReader reinstantiates every plugin on
-- each FileManager/Reader switch, not just at process startup -- so
-- without this, auto_open fires every single time the dashboard closes
-- and FileManager flashes underneath it, making it impossible to ever
-- actually leave. A plain local here persists for the life of the Lua
-- process (the module is only require()'d once), so it only fires once
-- per real boot/launch.
local has_auto_opened = false
local has_set_keepalive = false

function HaDash:init()
    self.ui.menu:registerToMainMenu(self)
    local settings = loadSettings()
    -- KOReader's own auto_suspend/auto_standby settings (both disabled in
    -- settings.reader.lua) only control how KOReader *reacts* to a
    -- suspend -- they don't stop the underlying powerd OS layer from
    -- deciding to suspend on its own independent inactivity timer, which
    -- is what was still happening (screen holds its last e-ink image
    -- through a real hardware suspend, touch dead until a power-button
    -- wake). This is the actual property that prevents that, same one
    -- KOReader's own stock keepalive.koplugin uses on Kindle. The
    -- dashboard should never sleep at all -- that's the whole point of
    -- the appliance -- so set it unconditionally, once per process.
    if not has_set_keepalive then
        has_set_keepalive = true
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    -- Jump straight to the dashboard on first launch instead of needing
    -- Tools > HA Dashboard. Set auto_open = true in hadash_settings.lua.
    if settings and settings.auto_open and not has_auto_opened then
        has_auto_opened = true
        UIManager:scheduleIn(1, function()
            UIManager:show(HaDashboard:new{})
        end)
    end
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
