#!/usr/bin/env bash
# Deploy hadash.koplugin to a Kindle running KOReader over SSH, then restart
# KOReader so it reloads the plugin. Settings file is NOT touched by this
# script (it lives outside the plugin folder on the device already).
#
# Usage: ./deploy.sh <kindle-ip> [koreader-dir] [ssh-port]
# KOReader's SSH plugin defaults to port 2222, not 22.
set -euo pipefail

KINDLE_HOST="${1:?Usage: ./deploy.sh <kindle-ip> [koreader-dir] [ssh-port]}"
KOREADER_DIR="${2:-/mnt/us/koreader}"
SSH_PORT="${3:-2222}"
PLUGIN_DIR="hadash.koplugin"

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "error: $PLUGIN_DIR not found, run from the project root" >&2
    exit 1
fi

echo "Deploying $PLUGIN_DIR to root@$KINDLE_HOST:$SSH_PORT:$KOREADER_DIR/plugins/"
tar -cf - "$PLUGIN_DIR" | ssh -p "$SSH_PORT" "root@$KINDLE_HOST" "mkdir -p '$KOREADER_DIR/plugins' && tar -xf - -C '$KOREADER_DIR/plugins'"

echo "Restarting KOReader"
ssh -p "$SSH_PORT" "root@$KINDLE_HOST" "killall -q koreader || true"

echo "Done. KOReader should relaunch and reload the plugin."
