# Kindle PW3 Home Assistant dashboard: handoff

Project: touch dashboard for Home Assistant (lights, heating, room values) on a Kindle Paperwhite 3 (7th gen, 1072 x 1448 px, 300 ppi), implemented as a KOReader plugin (`hadash.koplugin`, Lua).
Full plan (setup steps, HA config, risks): https://claude.ai/code/artifact/086c207d-b376-49a8-8b1e-359fa113a444

User preferences: metric units, concise and factual language, iterative collaboration (small steps, feedback over big rewrites).

## Decisions made

- No browser: the Kindle browser is too old for Home Assistant's UI.
- Run inside KOReader as a plugin; tapping a tile redraws only that tile (`UIManager:setDirty()` on the widget).
- Talk to Home Assistant over plain HTTP on the LAN with its REST API and a long-lived token. No websockets. Poll every 30 to 60 s, redraw only changed tiles.
- Deploy from the PC over SSH (tar pipe), restart KOReader to reload. Config (URL, token, entities) lives in a separate settings file, never in the plugin folder.
- Boot into the dashboard via an upstart job in `/etc/upstart` (trigger `framework_ready`). Done and working, survives reboot. See "Real-device setup" below.
- Kindle should end up on a Wi-Fi without internet access so firmware updates are impossible. KOReader updates are pushed manually.
- Not pursued: UART jailbreak, Debian/Alpine chroot (optional later), custom OS images (none exist for the PW3).

## Design (rounded, black and white, flat)

Portrait screen, white background, no shadows or gradients.
- Header: greeting on the left, time and battery on the right.
- Temperature card (light gray fill, large radius): room name, big current temperature, target below; round minus (outlined) and plus (black filled) buttons on the right.
- Two pill chips: second room temperature, humidity (2 px outline).
- 2 x 2 light tiles: ON = black fill, white text, switch graphic; OFF = light gray fill, outline switch.
- Heating pill at the bottom with mode (Auto).
- Use black/white and one light gray only, large touch targets, a full flash refresh every few minutes against ghosting.

## Home Assistant API used

- `GET /api/states/<entity_id>` with `Authorization: Bearer <TOKEN>`
- `POST /api/services/light/toggle` with `{"entity_id": "..."}`
- `POST /api/services/climate/set_temperature` with `entity_id`, `temperature`
- `POST /api/services/climate/set_hvac_mode` with `entity_id`, `hvac_mode`
- Optional: `POST /api/template` to fetch all tile values in one request.
- Use a dedicated non-admin local user for the token.

## Milestones

1. ✅ Hello light: one rounded tile toggling one light.
2. ✅ Temperature/climate card with +/-, presets, polling.
3. ✅ Full grid in the agreed design (lights, dimmable bulbs, scenes, climate with heater selector, weather, power/sensor badges).
4. ✅ Robustness: periodic polling (diff-and-redraw-only-changed-tiles), stale/offline indicator, periodic full refresh against ghosting. Deployed and running on real hardware with boot autostart.
5. Polish: refresh modes tuned on the real panel (ongoing), icons, bundled font. Not started.

## Testing

KOReader desktop emulator on the Mac: `./kodev build` then `./kodev run -w=1072 -h=1448 -d=300` (macOS prerequisites via Homebrew: cmake, meson, ninja, nasm, sdl3, etc.). A prebuilt macOS download may exist on the KOReader releases page (latest seen: 2026.07.1); not confirmed. The emulator cannot show real e-ink refresh or ghosting behavior.

## Facts from research (verify on the device)

- KOReader's Kindle launcher (`koreader.sh`) by default disables the status bar, pauses the window manager, stops several services (stored, webreader, kfxreader, kfxview, todo, tmd, rcm, archive, scanner, otav3, otaupd), pauses `volumd`. `--framework_stop` stops the whole Amazon GUI (`lab126_gui`) and restarts it on exit. Exiting with code 85 restarts KOReader.
- USB mass-storage mode while KOReader runs is unsupported; quit KOReader before connecting USB.
- Jailbreak candidates for the PW3: WinterBreak (firmware below 5.18.1) or LanguageBreak (up to 5.16.2.1.1). The KindleModding wizard decides. Fill the disk (50 to 90 MB free) and use Airplane mode before registering or connecting.
- KOReader install after jailbreak: `;kpm update`, then `;kpm install koreader`.
- Items marked "to test" in the plan (sleep/Wi-Fi keep-alive, startup-hook behavior, KOReader menu names) are not verified.

## Real-device setup (Kindle PW3, WinterBreak 2)

Verified working end-to-end, survives reboot.

- **SSH**: KOReader's SSH.koplugin, port **2222** (not 22). Must be started by hand once per cold boot unless `autostart` is set -- the plugin reads that from `settings.reader.lua` at its own init, so toggling it live via httpinspector doesn't persist; it must be edited into the file directly (remount `/` rw first, see below) while KOReader is stopped, or saved through the plugin's own UI flow.
- **Root filesystem**: `/` is read-only by default (`ext3 ro`). `mount -o remount,rw /` to edit `/etc/upstart/*`, `mount -o remount,ro /` after. `/mnt/us` (KOReader's own install/settings) is writable directly, no remount needed.
- **httpinspector** (port 8080, `httpinspector.koplugin`, `autostart=true` in settings): invaluable for remote debugging without SSH -- browses and calls live Lua objects over HTTP (e.g. `GET /koreader/device/screen/bb` for a live screenshot, `GET /koreader/UIManager/_window_stack/` for the active widget tree). Never used it to run arbitrary shell commands or write files (`os.execute`/`io.*`) -- that's a real RCE surface on an unauthenticated endpoint; stuck to the plugins' own exposed methods (`start()`, `stop()`, field toggles) only.
- **Boot autostart** (`/etc/upstart/koreader-autostart.conf`, `start on framework_ready`, `respawn`, `exec /mnt/us/documents/KOReader.sh --framework_stop`): launches straight to the dashboard (`auto_open = true` in `hadash_settings.lua`; the plugin guards this with a module-level flag so it only fires once per process, since KOReader reinstantiates plugins on every FileManager/Reader switch, not just at boot).
- **`--framework_stop` doesn't fully suppress Amazon's stack.** Confirmed still running under it: `JunoStatusBarDriver` (native status bar -- visually collided with our header), `KPPMainApp` (Kindle Store/Aa-menu), and the big `cvm` Java VM (the entire native reader app -- store, Whispersync, X-Ray, ads; heaviest single process). None of this is needed for a dashboard appliance and the device sits on a no-internet Wi-Fi anyway, so the network-dependent ones (sync, store, telemetry) can't do anything even if left running.
  - `statusbar.conf` and `kppmainapp.conf` are independent upstart jobs (don't emit `framework_ready`, safe to disable outright): renamed to `*.disabled` under `/etc/upstart/`.
  - `cvm` is launched directly inside Amazon's own `framework.conf` script -- deliberately did not hand-edit that file, since `framework_setup.conf` (which emits `framework_ready`, our own boot trigger's dependency) only starts after `framework.conf` itself starts. Instead, `koreader-autostart.conf` has a `post-start script` that polls every 2s for up to 60s and kills `cvm`/`whisperstore`/`KindleContentDownloadManagerApplication`/`fastmetrics`/`contentpackd`/`pillowd` as they appear. A short fixed delay (8s) was tried first and missed `cvm`, which spawns partway through `framework.conf`'s own (fairly long) startup script -- polling was needed.
  - Deliberately left alone: `wifid`, `powerd`, `deviced`, `dpmd`, `wand`, `mcsd`, `appmgrd`, `perfd`, `dynconfig`, `demd`, `lipc-daemon`, `dbus-daemon`, `udevd`, `syslog-ng`, `crond` -- core power/network/IPC management, didn't find a confident basis for touching these.
- **Official Amazon kill-switch exists**: `/mnt/us/DONT_START_FRAMEWORK` (checked in `framework.conf`'s `pre-start script`) skips the whole framework/cvm stack from the start. Not used here because it also skips `framework_ready`, breaking our own boot trigger. The cleaner long-term fix (not done): retrigger our autostart off an earlier, framework-independent upstart event, then this flag becomes safe to use for maximum savings. More testing/reboot iterations required; the current post-start-kill approach was lower-risk to validate incrementally.
- **USB mass storage**: didn't get this working with `--framework_stop` + `respawn` active (KOReader never released long enough, and native services it may depend on could be among those stopped). Likely needs the autostart job paused first (rename `koreader-autostart.conf` to `.disabled`, reboot, do the USB transfer, restore, reboot again) -- not tried end-to-end.
- Deploy flow in practice: `./deploy.sh <ip>` (now takes an optional 3rd arg for SSH port, defaults to 2222) copies the plugin and restarts KOReader; `scp -P 2222 ... hadash_settings.lua` separately for config (never committed, same as the emulator's copy).

## Open inputs needed from the user

- Kindle firmware version and which jailbreak the wizard names.
- One light entity ID and one climate entity ID from Home Assistant.
- Whether the KOReader release page offers a macOS build.

## Suggested first tasks for Claude Code

1. Create `hadash.koplugin/_meta.lua` and `main.lua` for milestone 1 (one light tile), reading URL, token and entity from a separate settings file.
2. Add a `deploy.sh` (tar over SSH, then restart) and a README with emulator instructions.
3. Run in the emulator against the real Home Assistant and fix issues before touching the Kindle.
