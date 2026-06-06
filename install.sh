#!/usr/bin/env bash
# Render the LaunchAgent from the template + config.json, then load it.
# Re-run this any time you change interval_seconds in config.json.
# Once installed, launchd auto-starts it at every login — no manual start needed.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3)"
INTERVAL="$("$PY" "$DIR/mirror.py" --print-interval)"
LABEL="com.calendar-mirror"
OUT="$HOME/Library/LaunchAgents/${LABEL}.plist"

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__DIR__|$DIR|g" -e "s|__PYTHON__|$PY|g" -e "s|__INTERVAL__|$INTERVAL|g" \
  "$DIR/calendar-mirror.plist.template" > "$OUT"

launchctl unload "$OUT" 2>/dev/null || true
launchctl load -w "$OUT"

echo "Installed $LABEL — runs every ${INTERVAL}s, auto-starts at login."
echo "Plist: $OUT"
echo "Logs:  $DIR/sync.log  (changes only)  |  $DIR/launchd.err.log (errors)"
