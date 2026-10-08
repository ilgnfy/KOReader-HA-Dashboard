# HA Dashboard for Kindle (hadash.koplugin)

A touch dashboard for [Home Assistant](https://www.home-assistant.io/) that turns a jailbroken Kindle Paperwhite 3 into a dedicated, always-on wall/nightstand control panel — lights, dimmable bulbs, scenes, heating, weather, and power/solar readouts — running entirely as a [KOReader](https://koreader.rocks/) plugin.

> **⚠️ This project is fully "vibe-coded" with Claude (Anthropic) in roughly a day.** It works on the author's own Kindle Paperwhite 3 and Home Assistant setup, but it comes with **no guarantees whatsoever**. Expect rough edges, untested configurations, and the possibility that something doesn't work on your specific device/firmware/HA setup. Read everything before running it, especially the jailbreak and `/etc/upstart` sections — those touch your device's boot process and can leave it in a bad state if something goes wrong. You are responsible for your own hardware.

## What this is

- A full-screen KOReader plugin that polls Home Assistant over its REST API and renders a flat, black/white/gray, rounded-corner touch UI tuned for e-ink.
- Designed to run as the **only** thing the Kindle ever does — boots straight into the dashboard, stays on, native Kindle/Amazon software disabled.
- Built for a **Kindle Paperwhite 3** (7th gen, 1072×1448, 300ppi) specifically. It may work on other KOReader-supported Kindles with adjustments, but that's untested.

## Features

- **Lights**: on/off tiles, dimmable lights with a touch-drag brightness slider.
- **Scenes** and an **all-lights** toggle.
- **Heating/climate**: current + target temperature, Heat/Off toggle, quick presets, a selector when you have more than one heater (mutually exclusive — picking one turns the others off).
- **Weather** chip (condition, today's high/low, rain amount or probability depending on what your HA weather integration provides).
- **Power/solar badges**: battery %, solar production, house consumption (optional, configure what you have).
- **Periodic polling** with diff-and-redraw (only repaints tiles whose value actually changed), a stale/offline indicator, and a periodic full e-ink refresh to clear ghosting.
- **Boot autostart** straight into the dashboard, with the native Kindle/Amazon software stack (reader app, store, status bar, cellular modem) disabled for battery life — see [Real-device setup](#real-device-setup--appliance-mode).

## Requirements

- A **jailbroken** Kindle Paperwhite 3 with [KOReader](https://koreader.rocks/) installed. See [KindleModding](https://kindlemodding.org/) for jailbreak tools and instructions — not covered here, and out of scope for support.
- A **Home Assistant** instance reachable over your LAN, with a long-lived access token.
- A Mac/Linux/Windows machine to build the plugin bundle and deploy it over SSH (KOReader's `SSH.koplugin`, not the Kindle's own SSH).

## Quick start

1. Jailbreak your Kindle and install KOReader (see KindleModding above). Enable KOReader's `SSH.koplugin` (default port **2222**, not 22).
2. Clone this repo.
3. Copy `config.sample.lua` and fill in your Home Assistant URL, a long-lived access token, and your entity IDs:
   ```bash
   cp config.sample.lua hadash_settings.lua
   # edit hadash_settings.lua with your real values
   ```
4. Deploy the plugin to your Kindle:
   ```bash
   ./deploy.sh <kindle-ip>
   # then separately, since it's never committed to the repo:
   scp -P 2222 hadash_settings.lua root@<kindle-ip>:/mnt/us/koreader/hadash_settings.lua
   ```
5. In KOReader, open **Tools → HA Dashboard**, or set `auto_open = true` in your settings file to launch straight into it.
6. (Optional, bigger step) Set up full boot-autostart/appliance mode — see below.

## Testing without a Kindle (emulator)

```bash
git clone --recursive https://github.com/koreader/koreader.git
cd koreader && ./kodev build
```
Then from the repo root:
```bash
ln -s "$(pwd)/hadash.koplugin" koreader/plugins/hadash.koplugin
cp config.sample.lua "$(./kodev run 2>&1 | grep -oE '/.*koreader$' | head -1)/hadash_settings.lua"  # path varies, see kodev's own startup log
./emulator.sh
```
The emulator renders against your real Home Assistant instance but can't show real e-ink refresh/ghosting behavior — that's real-device only.

## Configuration

See `config.sample.lua` for the full, commented list of options: `ha_url`, `ha_token`, `lights_onoff`, `lights_dimmable`, `scenes`, `all_lights_entity`, `climate_entities`, `sensors`, `weather_entity`, `battery_entity`/`solar_power_entity`/`consumption_entity` (all optional — leave unset to omit that part of the UI), and `auto_open`.

**Token permissions**: a non-admin HA user's token works, but Home Assistant restricts the `/api/template` endpoint (used for one combined fetch per poll instead of one request per entity) to admin-level tokens. Non-admin falls back automatically to one request per entity — works fine, just slightly less efficient. Your call on that trade-off.

## Real-device setup & appliance mode

Turning the Kindle into a dedicated, always-on, native-software-disabled appliance involves editing `/etc/upstart/*` and setting a couple of flag files — this is the part most likely to go wrong on a device/firmware this project wasn't tested on. **Full details, exact upstart job contents, and a complete incident postmortem (what broke during development and how it was fixed) are in [`kindle-dashboard-handoff.md`](kindle-dashboard-handoff.md).** Read that before touching `/etc/upstart` on your own device.

Short version of what it sets up:
- Boots straight into the dashboard via a custom upstart job.
- Disables the native Kindle reading app, status bar, and (on 3G models) the cellular modem — pure battery/CPU savings, Wi-Fi is unaffected.
- Prevents the device from ever sleeping (both KOReader's own idle timers and the underlying OS power daemon), since an always-on wall display is the entire point.
- An HTTP timeout + early-abort-on-failure so a Wi-Fi blip can't freeze the UI for minutes.

## Known limitations

- Native Kindle reading/store functionality is disabled once appliance mode is set up — this is a dedicated single-purpose device at that point, by design.
- Rain probability (vs. just an amount in mm) depends entirely on what your HA weather integration provides — Met.no, for example, doesn't expose it at all.
- Not tested on any Kindle model other than the Paperwhite 3, or any firmware version other than what the author's device happened to be on.
- No automated tests. Verification throughout development was manual (emulator + real device).

## Project layout

- `hadash.koplugin/` — the plugin itself (`_meta.lua`, `main.lua`).
- `config.sample.lua` — settings template. Copy it, fill it in, never commit the filled-in copy (it holds your HA token).
- `deploy.sh` — builds and pushes the plugin to a Kindle over SSH, restarts KOReader.
- `emulator.sh` — runs the KOReader emulator with the settings this project needs.
- `kindle-dashboard-handoff.md` — full technical deep-dive: exact upstart job configs, the appliance-mode setup story, and a detailed incident postmortem from development. Read this before editing anything under `/etc/upstart` on a real device.
- `koreader/` — upstream KOReader source, cloned locally for the emulator build. Gitignored, not part of this repo.

## Contributing

This was a fast, single-session personal project, not a maintained product. Issues and PRs are welcome but may not get fast (or any) attention. If you fork this for your own Kindle model or HA setup, you're very much on your own hardware-wise — test in the emulator first, and don't run the appliance-mode upstart changes until you understand what they do.

## License

MIT — see `LICENSE`. (If you'd prefer a different license, change it; nothing here depends on MIT specifically.)
