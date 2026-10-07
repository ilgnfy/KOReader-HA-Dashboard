#!/usr/bin/env bash
# Run the KOReader emulator with the macOS GNU tool paths it needs
# (flock, GNU make, GNU getopt — all brew-installed but keg-only).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/koreader"
export PATH="/opt/homebrew/opt/util-linux/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:$PATH"
./kodev run -W=1072 -H=1448 -D=300 "$@"
