#!/usr/bin/env bash
# Stop and remove the LaunchAgent. Mirror blocks already on the calendar are left as-is.
set -euo pipefail

for LABEL in com.calendar-mirror com.calendar-mirror.menubar; do
    OUT="$HOME/Library/LaunchAgents/${LABEL}.plist"
    launchctl unload "$OUT" 2>/dev/null || true
    rm -f "$OUT"
    echo "Uninstalled $LABEL (removed $OUT)."
done
echo "Note: existing 'Personal' blocks on the calendar are not deleted. Remove them manually if desired."
