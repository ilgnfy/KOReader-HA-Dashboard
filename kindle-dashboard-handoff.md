# Technical notes: real-device setup, upstart internals, incident history

This is the detailed technical companion to the main [README](README.md) — exact upstart job contents, the reasoning behind each native-service disable, and a full incident postmortem from development (what broke, how it was diagnosed, how it was fixed). Read this before editing anything under `/etc/upstart` on your own device; several of the mistakes documented here came from skipping exactly that.

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
6. (Backlog, V1.1, not started) On-screen brightness slider for dimmable lights, replacing the -/+ buttons. KOReader has a slider widget and the Kindle's touch/e-ink can drive one (laggy but workable). Needs an architecture change first: current tiles wait for the HA round-trip response before redrawing; a slider needs the opposite -- redraw immediately on drag/release, then reconcile against HA's actual reported state shortly after (and correct the slider position if they disagree). Deferred until the current real-device setup is stable.

## Testing

KOReader desktop emulator on the Mac: `./kodev build` then `./kodev run -w=1072 -h=1448 -d=300` (macOS prerequisites via Homebrew: cmake, meson, ninja, nasm, sdl3, etc.). A prebuilt macOS download may exist on the KOReader releases page (latest seen: 2026.07.1); not confirmed. The emulator cannot show real e-ink refresh or ghosting behavior.

## Facts from research (verify on the device)

- KOReader's Kindle launcher (`koreader.sh`) by default disables the status bar, pauses the window manager, stops several services (stored, webreader, kfxreader, kfxview, todo, tmd, rcm, archive, scanner, otav3, otaupd), pauses `volumd`. `--framework_stop` stops the whole Amazon GUI (`lab126_gui`) and restarts it on exit. Exiting with code 85 restarts KOReader.
- USB mass-storage mode while KOReader runs is unsupported; quit KOReader before connecting USB.
- Jailbreak candidates for the PW3: WinterBreak (firmware below 5.18.1) or LanguageBreak (up to 5.16.2.1.1). The KindleModding wizard decides. Fill the disk (50 to 90 MB free) and use Airplane mode before registering or connecting.
- KOReader install after jailbreak: `;kpm update`, then `;kpm install koreader`.
- Items marked "to test" in the plan (sleep/Wi-Fi keep-alive, startup-hook behavior, KOReader menu names) are not verified.

## Incident postmortem (SSH_autostart edit, factory-reset recovery)

An attempt to make `SSH_autostart` persistent triggered a blank-screen/
crash-loop requiring several `DO_FACTORY_RESTORE` cycles. Root-caused via
UART/bist diagnostics during recovery:

1. **Killed the only remote-access path from inside itself.** SSH runs
   inside KOReader's own Lua process (`SSH.koplugin`). A `kill -9` aimed
   at KOReader while testing upstart respawn behavior also killed the SSH
   server sharing that process — remote access was lost mid-edit, before
   `koreader-autostart.conf` could be restored.
2. **Wrong assumption about `KPPMainApp`.** Disabled on the belief it was
   "just the Store/Aa-menu app." It's actually load-bearing for native UI
   rendering; disabling it, combined with the broken autostart job from
   (1), left the device unable to render anything at all, native or
   KOReader.
3. The `cvm`-killing kill-loop itself was not implicated, nor was
   disabling `statusbar.conf` — both tested clean across many reboots
   before the incident.

Lesson: never cut your only remote-access path mid-edit with no fallback,
and don't disable a component whose role you haven't actually verified —
even one that looks safe in isolation. The real-device setup below was
rebuilt deliberately more conservative as a result: only the proven-safe
`statusbar.conf` disable is kept; `kppmainapp.conf` is left enabled; the
`cvm`/native-process kill-loop is dropped entirely (power/CPU saving only,
not worth the added risk for now).

Separately (unrelated to the above): `KPPMainAppV2` was found to
crash-loop several times (visible as a blank screen + "die ausgewählte
Anwendung konnte nicht gestartet werden" error, and crash dumps cluttering
`/mnt/us/documents/` — the native library folder) before eventually
recovering on its own. Confirmed present even on a from-scratch factory
reset with zero trace of any jailbreak/upstart edits, and independent of
Wi-Fi/internet access — a pre-existing stock-firmware/storage issue on
this specific unit, not something our setup causes. Crash dump files
(`KPPMainAppV2_*_crash_*.{tgz,txt,sdr}`) can be deleted straight out of
`/mnt/us/documents/` if they clutter the library; they're not needed once
triaged.

## Troubleshooting: recovering a half-bricked Kindle (blank screen / boot loop)

A second, separate incident, later in development: repeatedly `kill -9`ing live native processes on a tight cycle (the original `cvm`/`KPPMainApp`-killing approach, before it was replaced with disabling those jobs so they never start at all — see above) read to the device's own firmware-level watchdog as instability, and it started force-rebooting on its own. End result: blank screen, or a boot loop that never got further than Amazon's bare fallback/setup screen. If you hit something like this, here's the path that actually worked, cheapest option first.

### Step 1: confirm the system isn't actually destroyed, via UART

Before assuming the worst, get a serial console on the boot process — this tells you whether the underlying Linux system and your data are intact, or genuinely corrupted, before you commit to anything destructive.

- **Hardware**: the PW3's UART pins run at **1.8V logic internally**. Most cheap USB-serial adapters are 3.3V or 5V. The safe way to bridge the two is a 3.3V UART-to-USB adapter with a resistor voltage divider on its TX line into the Kindle's RX pin, so you never drive the 1.8V-rated input above its tolerance. (In practice, a bare 3.3V adapter connected directly — no divider — was used successfully during development without visible damage, but that's a real gamble with the hardware, not something to copy. Do the divider.)
- **Pinout**: GND/RX/TX exposed as small test pads, usually near a board edge; the smallest pad is typically GND. 115200 8N1.
- Connect (macOS example): `screen /dev/tty.usbserial-XXXX 115200`. Power on, watch the boot log, and interrupt autoboot (any key during the countdown) to drop into the u-boot/diagnostic console.
- From that console, if a self-test command is available (this device had `diag run mmc_crc32`), run it. It CRC-checks each eMMC partition individually. If `.kernel`/`.system`/`.userdata` (and similar) **pass** but only low-level partitions like `.bootloader`/`.bist`/`.diags` **fail**, your actual OS and data are intact — only the recovery/bootloader side is damaged, which isn't needed for normal booting. That's a very different (much better) situation than genuine corruption, and means you very likely don't need a deep flash-level repair at all.

### Step 2: the easy fix (worked here)

With the real system confirmed intact, the fix was almost anticlimactic:

1. Download the **official** Amazon firmware file for this exact model and the version already installed (`update_kindle_<version>.bin` — don't substitute a different version).
2. Connect the Kindle over USB, drag that file onto the root of its drive, eject.
3. Restart normally.

Amazon's own updater detects it and reapplies the firmware on boot — even reinstalling the *same* version works, since it's a full image reinstall, not a diff, and it repairs whatever got corrupted. This alone resolved the boot loop without needing any UART-level flashing.

### Step 3 (last resort): hard factory reset

If the update-file trick doesn't resolve it: create an **empty** file named exactly `DO_FACTORY_RESTORE` (no extension) at the root of the Kindle's USB-mounted drive, eject, restart. This triggers Amazon's own factory-restore flow on next boot. It's more destructive (wipes more local state than a normal update) but it's a reliable last-resort recovery path — used more than once during development to get back from a worse state than described here.

## Real-device setup (Kindle PW3, WinterBreak 2)

Verified working end-to-end, survives reboot.

- **SSH**: KOReader's SSH.koplugin, port **2222** (not 22). Must be started by hand once per cold boot unless `autostart` is set -- the plugin reads that from `settings.reader.lua` at its own init, so toggling it live via httpinspector doesn't persist; it must be edited into the file directly (remount `/` rw first, see below) while KOReader is stopped, or saved through the plugin's own UI flow.
- **Root filesystem**: `/` is read-only by default (`ext3 ro`). `mount -o remount,rw /` to edit `/etc/upstart/*`, `mount -o remount,ro /` after. `/mnt/us` (KOReader's own install/settings) is writable directly, no remount needed.
- **httpinspector** (port 8080, `httpinspector.koplugin`, `autostart=true` in settings): invaluable for remote debugging without SSH -- browses and calls live Lua objects over HTTP (e.g. `GET /koreader/device/screen/bb` for a live screenshot, `GET /koreader/UIManager/_window_stack/` for the active widget tree). Never used it to run arbitrary shell commands or write files (`os.execute`/`io.*`) -- that's a real RCE surface on an unauthenticated endpoint; stuck to the plugins' own exposed methods (`start()`, `stop()`, field toggles) only.
- **Boot autostart, current version** (`/etc/upstart/koreader-autostart.conf`):
  ```
  start on mounted_userstore
  respawn
  normal exit 0

  exec /mnt/us/documents/KOReader.sh --framework_stop
  ```
  Superseded the earlier `framework_ready`-triggered version (and its
  `post-start script` kill-loop targeting `cvm`/`KPPMainApp`/etc) after
  that kill-loop tripped a firmware-level watchdog (repeatedly `kill -9`ing
  live processes on a 2s cycle reads to Amazon's own stack as instability
  and force-reboots -- a real, different failure mode from the earlier
  SSH_autostart incident, discovered the hard way via another reboot
  loop). Fixed by never starting those processes in the first place
  instead of starting-then-killing them (see below) -- upstart's own
  dependency graph (read directly off the device via
  `grep -E "^start on|^emits|^stop on" /etc/upstart/*.conf`, not guessed)
  showed `framework_ready` depends on `lab126_gui` having started first;
  disabling `lab126_gui.conf` breaks that whole chain, so `framework_ready`
  never fires -- hence the retrigger onto `mounted_userstore` (a pure
  filesystem-mount event, fires well before `lab126_gui`/network even
  start; Wi-Fi/power daemons hang off a separate `lab126` base job,
  confirmed unaffected).
  `auto_open = true` in `hadash_settings.lua` still launches straight to
  the dashboard (module-level flag guard against KOReader reinstantiating
  plugins on every FileManager/Reader switch). `normal exit 0` still lets
  a deliberate "Exit" fall through to native UI without instant respawn,
  though native UI doesn't fully work anymore now that `lab126_gui` is
  disabled (see below) -- traded off deliberately since native reading
  on this device was dropped as a requirement.
- **Disabled outright (never start, nothing to crash/watchdog-trip)**:
  `lab126_gui.conf` -- transitively prevents `cvm`, `KPPMainApp`,
  `JunoStatusBarDriver`/`statusbar.conf`, `whisperstore`, `kfxreader`/
  `kfxview`, `progressivedownloads`, `webreader`, and everything else
  hanging off `framework_ready` or `started lab126_gui`, via upstart's
  own dependency graph -- zero kills needed. Also `wand.conf` (WAN/
  cellular modem daemon, separate job from `wifid`/Wi-Fi -- this is a 3G
  model Kindle, "Edge" network indicator was this daemon trying to
  register; disabling it is pure power saving, Wi-Fi unaffected).
  `statusbar.conf`/`kppmainapp.conf` were already independently disabled
  before `lab126_gui` was, now redundant but left as-is.
- **Flags set**: `/mnt/us/DONT_START_FRAMEWORK` (Amazon's own
  `framework.conf` `pre-start script` check, belt-and-suspenders with
  `lab126_gui` being disabled) and `/mnt/us/DISABLE_CORE_DUMP` (stops
  Amazon's crash-dump generator from littering `/mnt/us/documents/` --
  the native library folder -- with `KPPMainAppV2_*_crash_*` files every
  time something in the stack fails to start).
- **KPPMainAppV2 crash-loops on its own on this unit**, independent of
  any of the above: confirmed via `/mnt/us/koreader/crash.log` timestamps
  spanning a full ~8 hours overnight, ~29 crash dumps, regardless of
  Wi-Fi/internet state. Pre-existing stock-firmware/storage instability on
  this specific device, not caused by this project's changes -- the
  `lab126_gui` disable above sidesteps it entirely rather than fixing it.
- **USB mass storage**: didn't get this working with `--framework_stop` + `respawn` active (KOReader never released long enough, and native services it may depend on could be among those stopped). Likely needs the autostart job paused first (rename `koreader-autostart.conf` to `.disabled`, reboot, do the USB transfer, restore, reboot again) -- not tried end-to-end.
- Deploy flow in practice: `./deploy.sh <ip>` (now takes an optional 3rd arg for SSH port, defaults to 2222) copies the plugin and restarts KOReader; `scp -P 2222 ... hadash_settings.lua` separately for config (never committed, same as the emulator's copy).
- **HTTP requests have an explicit 5s timeout** (`http.TIMEOUT = 5` in
  `main.lua`) -- without it, a request that hangs instead of failing fast
  (brief Wi-Fi blip) blocks KOReader's single Lua thread, and thus all
  touch input, for whatever LuaSocket's own default is. Confirmed in
  practice: a ~6-minute full UI freeze traced to exactly this, since the
  periodic poll's fallback path can do over a dozen sequential requests
  when the combined-fetch optimization below isn't available.
- **`/api/template` (the combined-fetch optimization) returns 401** on
  this HA setup -- likely because the long-lived token's user is
  deliberately non-admin (per the original plan), and HA restricts
  template rendering to admin-level tokens while plain
  `/api/states/<entity>` GETs work for any authenticated user. Falls back
  automatically to one GET per entity (same as before the optimization
  existed) -- not broken, just not activating. Not fixed (would mean
  granting the token's user admin rights, a real security trade-off,
  deliberately not made).

