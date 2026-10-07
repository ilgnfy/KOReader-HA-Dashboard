local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local JSON = require("json")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
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
local POLL_INTERVAL_S = 30
local FULL_REFRESH_EVERY_N_POLLS = 10 -- ~5 minutes at the default interval

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
    return nil
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

    local states = {}
    for _, entity_id in ipairs(entity_ids) do
        states[entity_id] = haGet(settings, "/api/states/" .. entity_id)
    end
    return states
end

----------------------------------------------------------------
-- Small widget builders
----------------------------------------------------------------

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
        local new_state = haGet(settings, "/api/states/" .. light.entity)
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
            haCallService(settings, "light", "toggle", { entity_id = light.entity })
            UIManager:scheduleIn(0.4, syncFromServer)
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
    local card, toggle_btn, pct_text -- forward-declared, wired up below
    local last_is_on, last_pct = is_on, pct

    -- Shared by the +/-/toggle callbacks and the periodic poller. Returns
    -- false on fetch failure; skips the repaint when nothing changed.
    local function refreshFromServer()
        local new_state = haGet(settings, "/api/states/" .. light.entity)
        if not new_state then return false end
        local new_is_on = new_state.state == "on"
        local new_pct = brightnessPct(new_state.attributes)
        if new_is_on == last_is_on and new_pct == last_pct then return true end
        last_is_on, last_pct = new_is_on, new_pct
        setToggleVisual(toggle_btn, new_is_on, label, Blitbuffer.COLOR_WHITE)
        pct_text:setText(new_pct and (new_pct .. "%") or "—")
        partialRefresh(dashboard_self, card)
        return true
    end
    table.insert(dashboard_self.poll_fns, refreshFromServer)

    toggle_btn = Button:new{
        text = label .. (is_on and " · ON" or " · OFF"),
        width = width - Size.padding.large * 2,
        height = Screen:scaleBySize(56),
        background = is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_TILE,
        text_font_face = "cfont",
        text_font_size = 20,
        text_font_bold = true,
        callback = function()
            haCallService(settings, "light", "toggle", { entity_id = light.entity })
            UIManager:scheduleIn(0.4, refreshFromServer)
        end,
    }
    if is_on then whiten(toggle_btn) end

    local function step(delta)
        return function()
            haCallService(settings, "light", "turn_on", {
                entity_id = light.entity,
                brightness_step_pct = delta,
            })
            UIManager:scheduleIn(0.4, refreshFromServer)
        end
    end

    local minus_btn = Button:new{
        text = "−",
        width = Screen:scaleBySize(52),
        height = Screen:scaleBySize(52),
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = RADIUS_ROUND,
        text_font_size = 26,
        text_font_bold = true,
        callback = step(-10),
    }
    local plus_btn = whiten(Button:new{
        text = "+",
        width = Screen:scaleBySize(52),
        height = Screen:scaleBySize(52),
        background = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.window,
        radius = RADIUS_ROUND,
        text_font_size = 26,
        text_font_bold = true,
        callback = step(10),
    })
    pct_text = TextWidget:new{
        text = pct and (pct .. "%") or "—",
        face = Font:getFace("cfont", 22),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local brightness_row = HorizontalGroup:new{
        minus_btn,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        CenterContainer:new{
            dimen = { w = width - Size.padding.large * 2 - minus_btn:getSize().w * 2 - Size.span.horizontal_default * 2, h = pct_text:getSize().h },
            pct_text,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        plus_btn,
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
            brightness_row,
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
    local card, current_text, target_text, heat_btn
    local selector_btns = {}

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
            local new_state = haGet(settings, "/api/states/" .. h.entity)
            if not new_state then return false end
            heater_states[h.entity] = new_state
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
            haCallService(settings, "climate", "set_hvac_mode", {
                entity_id = heater.entity,
                hvac_mode = is_heat and "off" or "heat",
            })
            UIManager:scheduleIn(0.4, refreshFromServer)
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
            UIManager:scheduleIn(0.4, refreshFromServer)
        end
    end

    -- Selector pills (left) + Heat/Off toggle (right) share one row, which
    -- saves a whole row of vertical space versus stacking them.
    local top_row_h = math.max(
        selector_row and selector_row:getSize().h or 0,
        heat_btn:getSize().h
    )
    local small_vgap = Size.span.vertical_default

    local temp_target_stack = VerticalGroup:new{
        current_text,
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
                UIManager:scheduleIn(0.4, refreshFromServer)
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
    -- current temp + target centered in the full column width,
    -- independent of the presets' width (a plain HorizontalGroup would
    -- instead center the two of them as one glued block, pulling the
    -- presets off the left edge).
    local row2 = OverlapGroup:new{
        dimen = { w = left_col_w, h = row2_h },
        LeftContainer:new{ dimen = { w = left_col_w, h = row2_h }, presets_col },
        CenterContainer:new{ dimen = { w = left_col_w, h = row2_h }, temp_target_stack },
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
        -- This integration doesn't expose a rain-chance percentage, only a
        -- forecast precipitation amount (mm) for the day.
        local rain_mm = forecast.precipitation
        if type(rain_mm) == "number" then
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

-- "21° · 45%" readout from the configured sensors, in a small boxed chip
-- with a house icon, shown next to the greeting in the header.
local function buildHeaderSensorBox(settings, states)
    if not settings.sensors or #settings.sensors == 0 then return nil end
    local parts = {}
    for _, sensor in ipairs(settings.sensors) do
        local state = states[sensor.entity]
        local value = state and state.state
        if value and value ~= "unavailable" and value ~= "unknown" then
            local num = tonumber(value)
            table.insert(parts, string.format("%s%s", num and round(num) or value, sensor.unit or ""))
        end
    end
    if #parts == 0 then return nil end

    local icon_size = Screen:scaleBySize(26)
    return FrameContainer:new{
        background = GRAY_FILL,
        bordersize = Size.border.window,
        radius = RADIUS_PILL,
        -- padding_h/padding_v aren't real FrameContainer fields.
        padding_top = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left = Size.padding.default,
        padding_right = Size.padding.default,
        HorizontalGroup:new{
            -- alpha=true: without it, icons get pre-flattened against a
            -- hard-coded white backing (fine on white, but leaves a visible
            -- white box here since this chip's background is gray).
            IconWidget:new{ icon = "home", width = icon_size, height = icon_size, alpha = true },
            HorizontalSpan:new{ width = Size.span.horizontal_small },
            TextWidget:new{
                text = table.concat(parts, " · "),
                face = Font:getFace("cfont", 20),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    }
end

local function buildHeader(width, greeting, sensor_box, exit_callback)
    local height = Screen:scaleBySize(70)
    local left_items = {
        TextWidget:new{
            text = greeting,
            face = Font:getFace("cfont", 26),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    if sensor_box then
        table.insert(left_items, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(left_items, sensor_box)
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
    local stale_frame = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        HorizontalGroup:new{
            stale_text,
            HorizontalSpan:new{ width = Size.span.horizontal_small },
            exit_btn,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            time_text,
        },
    }
    stale_frame.stale_text = stale_text
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
    local function addBadge(glyph_widget, text)
        if not text then return end
        if #items > 0 then
            table.insert(items, HorizontalSpan:new{ width = Size.span.horizontal_default * 2 })
        end
        table.insert(items, glyph_widget)
        table.insert(items, HorizontalSpan:new{ width = Size.span.horizontal_small })
        table.insert(items, TextWidget:new{
            text = text,
            face = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_GRAY_5,
        })
    end
    addBadge(TextWidget:new{
        text = "\u{26A1}",
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }, battery_text)
    addBadge(TextWidget:new{
        text = "\u{2600}",
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_GRAY_5,
    }, solar_text)
    addBadge(IconWidget:new{ icon = "home", width = icon_size, height = icon_size, alpha = true }, consumption_text)

    return HorizontalGroup:new(items)
end

local function greetingForHour()
    local h = tonumber(os.date("%H"))
    if h < 6 then return _("Good night")
    elseif h < 12 then return _("Good morning")
    elseif h < 18 then return _("Good afternoon")
    else return _("Good evening") end
end

----------------------------------------------------------------
-- Full-screen dashboard
----------------------------------------------------------------

local HaDashboard = WidgetContainer:extend{
    name = "hadash_dashboard",
}

function HaDashboard:init()
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

    local states = fetchAllStates(settings)
    local forecast = fetchForecast(settings)
    local content_w = self.dimen.w - GUTTER * 2
    local header, stale_frame = buildHeader(content_w, greetingForHour(), buildHeaderSensorBox(settings, states), function()
        UIManager:close(self)
    end)
    self.stale_frame = stale_frame
    local rows = {
        header,
    }
    local power_badges = buildPowerBadges(settings, states)
    if power_badges then
        local badges_h = power_badges:getSize().h
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(rows, LeftContainer:new{
            dimen = { w = content_w, h = badges_h },
            power_badges,
        })
    end

    table.insert(rows, VerticalSpan:new{ width = GUTTER })
    table.insert(rows, buildWeatherChip(content_w, states[settings.weather_entity], forecast))

    if settings.climate_entities and #settings.climate_entities > 0 then
        table.insert(rows, VerticalSpan:new{ width = GUTTER })
        table.insert(rows, buildClimateCard(settings, states, content_w, self))
    end

    if settings.lights_onoff and #settings.lights_onoff > 0 then
        table.insert(rows, VerticalSpan:new{ width = GUTTER })
        local tile_w = (content_w - GUTTER) / 2
        local tile_h = Screen:scaleBySize(60)
        local tile_row = {}
        for i, light in ipairs(settings.lights_onoff) do
            table.insert(tile_row, buildOnOffTile(settings, light, states[light.entity], tile_w, tile_h, self))
            if i < #settings.lights_onoff then
                table.insert(tile_row, HorizontalSpan:new{ width = GUTTER })
            end
        end
        table.insert(rows, HorizontalGroup:new(tile_row))
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
            local new_state = haGet(settings, "/api/states/" .. settings.all_lights_entity)
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
                haCallService(settings, "light", "toggle", { entity_id = settings.all_lights_entity })
                UIManager:scheduleIn(0.4, syncAllLights)
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
            -- Fire-and-forget: scenes have no on/off state to reflect back,
            -- so there's nothing to repaint after activating one.
            table.insert(action_items, buildPillButton{
                text = scene.label or scene.entity,
                width = scene_w,
                background = GRAY_FILL,
                callback = function()
                    haCallService(settings, "scene", "turn_on", { entity_id = scene.entity })
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

    self:schedulePoll()
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
    UIManager:scheduleIn(POLL_INTERVAL_S, function()
        if self._closed then return end
        self:runPoll()
    end)
end

-- Periodic tick (milestone 4, "robustness"): re-checks every entity this
-- dashboard shows and repaints only the tiles whose value actually
-- changed (each poll_fn is the same sync function its widget's own tap
-- callback uses, which already diffs before repainting). Every Nth tick
-- instead does a full dashboard rebuild, which forces a real full-screen
-- refresh -- on e-ink that's what clears the ghosting that accumulates
-- from all the partial updates in between.
function HaDashboard:runPoll()
    if self._closed then return end
    self._poll_count = (self._poll_count or 0) + 1
    if self._poll_count % FULL_REFRESH_EVERY_N_POLLS == 0 then
        self._closed = true
        UIManager:close(self)
        UIManager:show(HaDashboard:new{})
        return
    end
    local any_failed = false
    for _, fn in ipairs(self.poll_fns) do
        local ok = fn()
        if ok == false then any_failed = true end
    end
    self:setStale(any_failed)
    self:schedulePoll()
end

function HaDashboard:onClose()
    self._closed = true
    UIManager:close(self)
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

function HaDash:init()
    self.ui.menu:registerToMainMenu(self)
    local settings = loadSettings()
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
