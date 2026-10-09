# HA Dashboard for Kindle (hadash.koplugin)

A touch dashboard for [Home Assistant](https://www.home-assistant.io/) that turns a jailbroken Kindle Paperwhite 3 into a dedicated, always-on wall/nightstand control panel — lights, dimmable bulbs, scenes, heating, weather, and power/solar readouts — running entirely as a [KOReader](https://koreader.rocks/) plugin.

> **⚠️ This project is fully "vibe-coded" with Claude (Anthropic) in roughly a day.** It works on the author's own Kindle Paperwhite 3 and Home Assistant setup, but comes with **no guarantees**. Expect rough edges and untested configurations. Read everything before running it, especially the appliance-mode section — it touches your device's boot process and can leave it in a bad state if something goes wrong. You are responsible for your own hardware.

## Why

A good always-on touch display for a home dashboard is normally expensive: e-ink panels with touch, in particular, are a small, costly niche market. Kindles solve that by accident — they're an e-ink touchscreen, built at consumer-electronics scale, and available **cheap** secondhand, with a display quality (contrast, resolution) that a purpose-built touch e-ink panel at the same price doesn't match. A jailbroken Kindle repurposed as a dashboard gets you: a touch e-ink display, for less money, that draws near-zero power while idle (e-ink holds its image with no backlight and no refresh needed) — ideal for something meant to sit on a wall or nightstand permanently.

## Features

- **Lights**: on/off tiles, dimmable lights with a touch-drag brightness slider.
- **Scenes** and an **all-lights** toggle.
- **Heating/climate**: current + target temperature, Heat/Off toggle, quick presets, a selector when you have more than one heater (mutually exclusive — picking one turns the others off).
- **Weather** chip (condition, today's high/low, rain amount or probability depending on what your HA weather integration provides).
- **Power/solar badges**: battery %, solar production, house consumption (optional).
- **Power Saving mode**: after N idle minutes, pauses polling and turns Wi-Fi + the frontlight off — any tap wakes it instantly (no power button needed; this is a software pause, not real device suspend, which would kill touch responsiveness on this hardware). Armable from the dashboard's own "PS" icon, or remotely from Home Assistant.
- **MQTT auto-discovery** (optional): if you have an MQTT broker, the plugin publishes a "Kindle Dashboard" Device to HA — bundling a battery sensor and the Power Saving switch under one Device card, zero manual HA-side setup.
- Diff-and-redraw polling (only repaints tiles whose value changed), a stale/offline indicator, periodic full e-ink refresh to clear ghosting.
- Boot autostart straight into the dashboard, with the native Kindle software stack disabled for battery life.

## Requirements

- A **jailbroken** Kindle Paperwhite 3 with [KOReader](https://koreader.rocks/) installed — see [KindleModding](https://kindlemodding.org/) for jailbreak tools. Not covered here, out of scope for support.
- A **Home Assistant** instance reachable over your LAN, with a long-lived access token.
- A machine to build/deploy the plugin over SSH (KOReader's own `SSH.koplugin`, not the Kindle's stock SSH).

## Quick start

1. Jailbreak, install KOReader, enable `SSH.koplugin` (port **2222**, not 22).
2. Clone this repo, copy the config template and fill it in:
   ```bash
   cp config.sample.lua hadash_settings.lua
   # edit hadash_settings.lua: HA URL, token, entity IDs
   ```
3. Deploy:
   ```bash
   ./deploy.sh <kindle-ip>
   scp -P 2222 hadash_settings.lua root@<kindle-ip>:/mnt/us/koreader/hadash_settings.lua
   ```
4. In KOReader: **Tools → HA Dashboard**, or set `auto_open = true` in the settings file to launch straight into it.
5. Optional: set up full boot-autostart/appliance mode (below).

## Testing without a Kindle (emulator)

```bash
git clone --recursive https://github.com/koreader/koreader.git
cd koreader && ./kodev build
```
From the repo root:
```bash
ln -s "$(pwd)/hadash.koplugin" koreader/plugins/hadash.koplugin
# copy config.sample.lua to the emulator's data dir as hadash_settings.lua
# (path is printed by kodev on first run, "User data directory: ...")
./emulator.sh
```
The emulator talks to your real Home Assistant but can't show real e-ink refresh/ghosting — that's real-device only.

## Configuration

See `config.sample.lua` for the full commented option list: `ha_url`, `ha_token`, `lights_onoff`, `lights_dimmable`, `scenes`, `all_lights_entity`, `climate_entities`, `sensors`, `weather_entity`, `battery_entity`/`solar_power_entity`/`consumption_entity`, `kindle_battery_entity`, `power_saving_timeout_s`, `mqtt_host`/`mqtt_port`/`mqtt_user`/`mqtt_password` (all optional except `ha_url`/`ha_token`), `auto_open`.

**Token permissions**: a non-admin HA user's token works fine for everything. The one thing it can't do is HA's `/api/template` endpoint, which this plugin uses to fetch all tile data in a single request instead of one request per entity — that endpoint requires an admin-level token. Non-admin falls back automatically to one request per entity. Your call on that trade-off.

## Power Saving mode

Real OS-level suspend on this hardware powers down the touch controller itself — there's no touch-wake from it, only a power-button press. So Power Saving mode here is a deliberate **software pause** instead: after `power_saving_timeout_s` idle seconds (default 300), it pauses polling, disables Wi-Fi (`lipc-set-prop com.lab126.cmd wirelessEnable 0`), and turns the frontlight off if it was on. The CPU and touch controller stay fully live throughout, so **any tap wakes it instantly**, reconnecting Wi-Fi and resuming polling within a few seconds.

Arm/disarm it by tapping the "PS" icon next to the gear in the header, or remotely via the MQTT switch described below.

## MQTT auto-discovery (optional)

If `mqtt_host` is set, the plugin connects to that broker and publishes Home Assistant MQTT Discovery config for a single "Kindle Dashboard" Device, bundling:
- A battery sensor (the Kindle's own battery %).
- A switch for Power Saving mode (readable and writable from HA — arm it remotely when you're away, and the dashboard's own icon reflects HA-side changes on the next poll).

No HA-side setup beyond having the MQTT integration enabled (if you already run Zigbee2MQTT, you already have both a broker and that integration). The device and entities appear automatically the first time the Kindle connects. Uses a small vendored copy of [`xHasKx/luamqtt`](https://github.com/xHasKx/luamqtt) (MIT), driven manually once per poll tick rather than via its own blocking event loop, to fit KOReader's cooperative scheduler.

## Appliance mode (boot straight into the dashboard, disable native Kindle software)

This is the part most likely to go wrong on a device/firmware this wasn't tested on — it edits `/etc/upstart` and sets flag files that change what the Kindle boots into. Understand each step before running it.

- **Boot trigger**: a custom `/etc/upstart/koreader-autostart.conf` job, triggered on `mounted_userstore` (an early filesystem-mount event — intentionally *not* `framework_ready`, since that depends on the native GUI job this setup disables):
  ```
  start on mounted_userstore
  respawn
  normal exit 0

  exec /mnt/us/documents/KOReader.sh --framework_stop
  ```
- **Disable the native Kindle app stack** by renaming its upstart job so it never starts at all (safer than killing a running process — nothing to crash or trip a watchdog):
  ```
  mv /etc/upstart/lab126_gui.conf /etc/upstart/lab126_gui.conf.disabled
  ```
  This transitively prevents the native reader app (`cvm`), the Store/Aa-menu app (`KPPMainApp`), the native status bar, and several other services from ever starting — they all depend on `lab126_gui` one way or another. On a 3G model, also disable the cellular modem daemon the same way (`wand.conf` — separate from Wi-Fi's `wifid`, unaffected):
  ```
  mv /etc/upstart/wand.conf /etc/upstart/wand.conf.disabled
  ```
- **Stop the device from ever sleeping.** Two separate layers need this, not just one:
  - KOReader's own idle timers, in `settings.reader.lua`: `auto_suspend_timeout_seconds = -1`, `auto_standby_timeout_seconds = -1`, `screensaver_type = "disable"`.
  - The underlying OS power daemon's *own independent* inactivity timer, which those settings don't reach at all — this plugin sets it itself, once per process, in `HaDash:init()`: `lipc-set-prop com.lab126.powerd preventScreenSaver 1`.
- **Stop Amazon's crash-dump generator** from littering the library folder every time something in the (now largely disabled) stack fails to start: an empty flag file, `touch /mnt/us/DISABLE_CORE_DUMP`.
- **`DONT_START_FRAMEWORK`** (`touch /mnt/us/DONT_START_FRAMEWORK`): Amazon's own kill-switch for the framework/`cvm` stack, belt-and-suspenders alongside disabling `lab126_gui.conf`.

Deploy flow once set up: `./deploy.sh <ip>` pushes the plugin and restarts KOReader; the settings file is pushed separately (`scp`), never committed.

## Known issues / gotchas

- **Killing live native processes to "free up" resources is the wrong approach** — repeatedly `kill -9`ing things on a timer reads to the device's firmware as instability and can trigger a watchdog reboot loop. Disable the upstart job so the process never starts at all instead (see above). This is the one mistake in this project's history worth not repeating.
- **A blocking HTTP request with no timeout will freeze the whole UI**, not just the network call — KOReader runs on a single Lua thread, and polling can mean a dozen-plus sequential requests. This plugin sets `http.TIMEOUT = 3` and aborts the rest of a poll batch on the first connection-level failure, rather than retrying each entity in turn.
- **Rain probability depends entirely on your HA weather integration** — some (Met.no, for example) only provide a precipitation amount, never a probability, and there's no way around that from this side.
- Native Kindle reading/store functionality is fully disabled once appliance mode is set up — this becomes a single-purpose device at that point, by design.
- No automated tests; verification throughout development was manual (emulator + real device).

## Recovering a half-bricked Kindle (blank screen / boot loop)

If something goes wrong with the appliance-mode setup and the device won't boot past a blank screen or Amazon's bare fallback screen, in order of least to most destructive:

1. **UART console, to check whether the system is actually damaged.** PW3's UART runs at **1.8V logic** — bridge it with a 3.3V USB-serial adapter *through a resistor voltage divider* on the TX line, not a direct connection (don't risk the 1.8V-rated input). GND/RX/TX are small test pads, usually near a board edge; smallest pad is typically GND. 115200 8N1. Interrupt autoboot (any key during the countdown) to reach the diagnostic console, then run a partition checksum command if one's available (`diag run mmc_crc32` worked on this unit). If `.kernel`/`.system`/`.userdata` pass but only low-level partitions (`.bootloader`/`.bist`/`.diags`) fail, your actual OS and data are intact.
2. **Reinstall the firmware over USB.** Download the official `update_kindle_<version>.bin` for the exact version already installed, drag it onto the root of the Kindle's USB drive, eject, restart normally. Amazon's updater reapplies it automatically — even the same version works, since it's a full image reinstall, not a diff, and it repairs whatever got corrupted. This alone resolved a boot loop during this project's development.
3. **Last resort: factory reset.** An empty file named exactly `DO_FACTORY_RESTORE` (no extension) at the root of the USB-mounted drive, then restart. More destructive, but reliable.

## Project layout

- `hadash.koplugin/` — the plugin (`_meta.lua`, `main.lua`, `mqttlib.lua` + `mqtt/` — a vendored copy of [`xHasKx/luamqtt`](https://github.com/xHasKx/luamqtt), MIT).
- `config.sample.lua` — settings template. Copy it, fill it in, never commit the filled-in copy.
- `deploy.sh` — pushes the plugin to a Kindle over SSH, restarts KOReader.
- `emulator.sh` — runs the KOReader emulator with the settings this project needs.
- `koreader/` — upstream KOReader source, cloned locally for the emulator build. Gitignored.

## Contributing

Fast, single-session personal project, not a maintained product. Issues/PRs welcome but may not get fast attention. If you fork this for a different Kindle model or HA setup, test in the emulator first, and understand the appliance-mode steps before running them on real hardware.

## License

MIT — see `LICENSE`.
