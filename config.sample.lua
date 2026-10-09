-- Copy this file to the KOReader data dir as hadash_settings.lua.
-- Emulator data dir (macOS): printed on startup, e.g.
-- koreader/koreader-emulator-<arch>-debug/koreader/
-- On the Kindle it's typically /mnt/us/koreader/.
-- Never commit a filled-in copy of this file; it holds your HA token.
return {
    ha_url = "http://192.168.1.10:8123",
    ha_token = "REPLACE_WITH_LONG_LIVED_TOKEN",

    -- Emulator/dev only: auto-opens the dashboard ~1s after KOReader boots,
    -- skipping Tools > HA Dashboard. Leave false/unset for the real Kindle.
    auto_open = false,

    -- Simple on/off lights, shown as a 2-up tile row. Whole tile toggles.
    lights_onoff = {
        { entity = "light.living_room_lamp", label = "Lamp" },
    },

    -- Dimmable lights, shown as a 2-up card row with brightness -/+.
    lights_dimmable = {
        { entity = "light.bedroom_bulb", label = "Bedroom" },
    },

    -- Scene activation buttons (small pills).
    scenes = {
        { entity = "scene.evening", label = "Evening" },
    },

    -- Single "toggle everything" pill, shown smaller alongside the scenes.
    all_lights_entity = "light.all_lights",

    -- One or more climate entities, shown in a single big card with a
    -- Heat/Off toggle and target-temp +/-. With more than one, a selector
    -- pill per entity lets you pick which heater is active; picking one
    -- turns every other configured heater off, so only one ever runs.
    climate_entities = {
        { entity = "climate.heating", label = "Heating" },
    },

    -- Read-only sensor chips (temperature, humidity, ...).
    sensors = {
        { entity = "sensor.living_room_temperature", label = "Temp", unit = "°C" },
        { entity = "sensor.living_room_humidity", label = "Humidity", unit = "%" },
    },

    -- Current weather chip, from a weather integration entity.
    weather_entity = "weather.forecast_home",

    -- Optional: a left-aligned row of small power badges under the header
    -- (home battery %, solar production, house consumption). Leave any of
    -- them nil to omit that badge.
    battery_entity = nil, -- e.g. "sensor.battery_state_of_charge"
    solar_power_entity = nil, -- e.g. "sensor.solar_production"
    consumption_entity = nil, -- e.g. "sensor.house_consumption"

    -- Optional: report the Kindle's OWN battery level back to HA as a
    -- sensor entity (HA creates it automatically on first push, no
    -- integration config needed). Leave nil to not report anything.
    kindle_battery_entity = nil, -- e.g. "sensor.kindle_dashboard_battery"

    -- Optional: Power Saving mode. When armed (tap the "PS" icon next to
    -- the gear, or flip the switch from HA once MQTT discovery below is
    -- set up), the dashboard pauses polling, turns Wi-Fi off, and turns
    -- the frontlight off after this many idle seconds -- any tap wakes
    -- it instantly (this is a software pause, not real device suspend,
    -- so the touch controller never actually powers down).
    power_saving_timeout_s = 300,

    -- Optional: MQTT broker for Home Assistant auto-discovery. If set,
    -- this plugin publishes a "Kindle Dashboard" Device to HA (bundling
    -- the battery sensor and the Power Saving switch under one Device
    -- card) with zero manual HA-side setup -- no helper entities needed.
    -- Requires an MQTT broker reachable from the Kindle and the MQTT
    -- integration enabled in HA (if you already run Zigbee2MQTT, you
    -- already have both).
    mqtt_host = nil, -- e.g. "192.168.1.5"
    mqtt_port = 1883,
    mqtt_user = nil,
    mqtt_password = nil,

    -- Optional: tapping the screen turns the frontlight on, auto-off
    -- again after 30s of no further taps -- this replaces KOReader's
    -- own generic autodim timer (already disabled in settings.reader.lua,
    -- autodim_starttime_minutes = -1, so the two don't fight). Set this
    -- to an HA entity ("on"/"off" state) to gate WHETHER a tap is even
    -- allowed to turn it on at all -- e.g. a lux-sensor-driven automation
    -- that says "off" during the day when there's enough ambient light.
    -- Leave nil and tapping always turns it on. Ignored while Power
    -- Saving mode is asleep -- that mode's own frontlight-off always
    -- wins, and the tap that wakes it also re-triggers this logic.
    -- If mqtt_host is set below, you don't need this at all -- a
    -- "Frontlight Allowed" switch is auto-discovered as part of the
    -- same bundled Device, no separate helper entity required. This
    -- setting is only for a REST-polled entity instead/as well.
    frontlight_entity = nil, -- e.g. "input_boolean.kindle_frontlight_allowed"
    -- If mqtt_host is set, the auto-off duration and the brightness
    -- level applied on wake are ALSO exposed as adjustable "number"
    -- entities on the same bundled Device -- no config needed here for
    -- those, they're controlled live from HA once connected.
}
