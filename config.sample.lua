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
}
