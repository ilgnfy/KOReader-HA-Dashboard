#!/usr/bin/env bash
# Run the KOReader emulator with the macOS GNU tool paths it needs
# (flock, GNU make, GNU getopt — all brew-installed but keg-only).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/koreader"
export PATH="/opt/homebrew/opt/util-linux/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:$PATH"
# Partial e-ink simulation: flash black for 300ms on full refreshes (like
# real e-ink GC16 waveform), and force grayscale to match the Kindle's
# actual screen. Partial/"ui" refreshes stay instant, same as on hardware.
export EMULATE_READER_FLASH="${EMULATE_READER_FLASH:-300}"
export EMULATE_BW_SCREEN="${EMULATE_BW_SCREEN:-1}"
# EMULATE_BW_SCREEN alone only flips a capability flag; the framebuffer is
# still RGB32 underneath, so anything that paints a real color still shows
# it. Force an actual 8bpp grayscale buffer so color can't render at all.
export EMULATE_BB_TYPE="${EMULATE_BB_TYPE:-BB8}"
# Half-scale (536x724 @ 150dpi): same physical size and aspect ratio as the
# real PW3 panel (1072x1448 @ 300dpi) once doubled by this Mac's 2x Retina
# backing, but a logical window short enough that macOS won't silently
# shrink it to fit the screen (which was happening at full 1448pt height
# and desyncing our layout math from the real screen size).
./kodev run -W=536 -H=724 -D=150 "$@"
