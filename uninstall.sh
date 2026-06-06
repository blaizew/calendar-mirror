#!/usr/bin/env bash
# Stop and remove the LaunchAgent. Mirror blocks already on the calendar are left as-is.
set -euo pipefail

LABEL="com.calendar-mirror"
OUT="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl unload "$OUT" 2>/dev/null || true
rm -f "$OUT"
echo "Uninstalled $LABEL (removed $OUT)."
echo "Note: existing '$LABEL' blocks on the calendar are not deleted. Remove them manually if desired."
