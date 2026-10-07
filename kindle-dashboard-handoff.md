# Kindle PW3 Home Assistant dashboard: handoff

Project: touch dashboard for Home Assistant (lights, heating, room values) on a Kindle Paperwhite 3 (7th gen, 1072 x 1448 px, 300 ppi), implemented as a KOReader plugin (`hadash.koplugin`, Lua).
Full plan (setup steps, HA config, risks): https://claude.ai/code/artifact/086c207d-b376-49a8-8b1e-359fa113a444

User preferences: metric units, concise and factual language, iterative collaboration (small steps, feedback over big rewrites).

## Decisions made

- No browser: the Kindle browser is too old for Home Assistant's UI.
- Run inside KOReader as a plugin; tapping a tile redraws only that tile (`UIManager:setDirty()` on the widget).
- Talk to Home Assistant over plain HTTP on the LAN with its REST API and a long-lived token. No websockets. Poll every 30 to 60 s, redraw only changed tiles.
- Deploy from the PC over SSH (tar pipe), restart KOReader to reload. Config (URL, token, entities) lives in a separate settings file, never in the plugin folder.
- Boot into the dashboard later via an upstart job in `/etc/upstart` (trigger `framework_ready`), after the plugin works by hand. Needs root, SSH and a rescue path first. Untested.
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

1. Hello light: one rounded tile toggling one light; done when the real lamp switches and the tile flips.
2. Temperature card with +/- and polling.
3. Full grid in the agreed design.
4. Robustness: Wi-Fi reconnect, stale marker, periodic full refresh, settings file.
5. Polish: refresh modes tuned on the real panel, icons, bundled font.

## Testing

KOReader desktop emulator on the Mac: `./kodev build` then `./kodev run -w=1072 -h=1448 -d=300` (macOS prerequisites via Homebrew: cmake, meson, ninja, nasm, sdl3, etc.). A prebuilt macOS download may exist on the KOReader releases page (latest seen: 2026.07.1); not confirmed. The emulator cannot show real e-ink refresh or ghosting behavior.

## Facts from research (verify on the device)

- KOReader's Kindle launcher (`koreader.sh`) by default disables the status bar, pauses the window manager, stops several services (stored, webreader, kfxreader, kfxview, todo, tmd, rcm, archive, scanner, otav3, otaupd), pauses `volumd`. `--framework_stop` stops the whole Amazon GUI (`lab126_gui`) and restarts it on exit. Exiting with code 85 restarts KOReader.
- USB mass-storage mode while KOReader runs is unsupported; quit KOReader before connecting USB.
- Jailbreak candidates for the PW3: WinterBreak (firmware below 5.18.1) or LanguageBreak (up to 5.16.2.1.1). The KindleModding wizard decides. Fill the disk (50 to 90 MB free) and use Airplane mode before registering or connecting.
- KOReader install after jailbreak: `;kpm update`, then `;kpm install koreader`.
- Items marked "to test" in the plan (sleep/Wi-Fi keep-alive, startup-hook behavior, KOReader menu names) are not verified.

## Open inputs needed from the user

- Kindle firmware version and which jailbreak the wizard names.
- One light entity ID and one climate entity ID from Home Assistant.
- Whether the KOReader release page offers a macOS build.

## Suggested first tasks for Claude Code

1. Create `hadash.koplugin/_meta.lua` and `main.lua` for milestone 1 (one light tile), reading URL, token and entity from a separate settings file.
2. Add a `deploy.sh` (tar over SSH, then restart) and a README with emulator instructions.
3. Run in the emulator against the real Home Assistant and fix issues before touching the Kindle.
