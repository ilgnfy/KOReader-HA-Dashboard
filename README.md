# HA Dashboard (hadash.koplugin)

KOReader plugin: touch dashboard for Home Assistant on a Kindle Paperwhite 3.
Full plan: see `kindle-dashboard-handoff.md` in this folder.

## Status

Full dashboard (lights, dimmable bulbs, scenes, climate with heater
selector, weather, power/sensor badges) deployed and running on a real
Kindle Paperwhite 3, with periodic polling and boot autostart straight
into the dashboard. See `kindle-dashboard-handoff.md` for the real-device
setup and incident postmortem.

## Emulator setup (macOS)

Deps (already checked via Homebrew): `cmake meson ninja nasm sdl3`.

```bash
git clone --recursive https://github.com/koreader/koreader.git
cd koreader
./kodev build
./kodev run -w=1072 -h=1448 -d=300
```

First run builds a `koreader` data dir; it prints the path on startup
("User data directory: ..."). That's where `hadash_settings.lua` goes.

## Testing this plugin in the emulator

1. Symlink or copy `hadash.koplugin` into `koreader/plugins/`:
   ```bash
   ln -s "$(pwd)/hadash.koplugin" koreader/plugins/hadash.koplugin
   ```
2. Copy `config.sample.lua` to the emulator's data dir as `hadash_settings.lua`
   and fill in your HA URL, token, and a real `light.*` entity id.
3. Run `./kodev run -w=1072 -h=1448 -d=300`, open the KOReader menu, find
   "HA Dashboard" under More tools (Tools menu), tap it, tap the tile.
4. Confirm the real lamp toggles and the tile flips black/white.

The emulator can't show e-ink refresh/ghosting — that's real-device only.

## Deploying to the Kindle

```bash
./deploy.sh <kindle-ip>
```

Copies `hadash.koplugin/` over SSH into `koreader/plugins/` and restarts
KOReader. The settings file is deployed separately and manually (it never
lives inside the plugin folder, and is never committed to this repo).

## Project layout

- `hadash.koplugin/` — the plugin (`_meta.lua`, `main.lua`).
- `config.sample.lua` — settings template; copy to the device as
  `hadash_settings.lua`, never commit a filled-in copy.
- `deploy.sh` — SSH deploy + restart.
- `koreader/` — upstream KOReader source, cloned for `kodev` (emulator build),
  gitignored.
