-- Copy this file to the KOReader data dir as hadash_settings.lua.
-- Emulator data dir (macOS): ko-cross/ or koreader/ build output, printed on
-- startup as "User data directory: ...". On the Kindle it's typically
-- /mnt/us/koreader/.
-- Never commit a filled-in copy of this file; it holds your HA token.
return {
    ha_url = "http://192.168.1.10:8123",
    ha_token = "REPLACE_WITH_LONG_LIVED_TOKEN",
    light_entity = "light.living_room_lamp",
    light_label = "Lamp",
}
