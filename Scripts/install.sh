#!/bin/bash
# Installs build/MemBar.app into /Applications, replacing the previous copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/timeout.sh
source "$ROOT/Scripts/timeout.sh"
SOURCE="$ROOT/build/MemBar.app"
DESTINATION="/Applications/MemBar.app"

if [ ! -d "$SOURCE" ]; then
  echo "error: $SOURCE not found — run Scripts/build-app.sh first"
  exit 1
fi

if pgrep -x MemBar >/dev/null 2>&1; then
  echo "==> quitting running MemBar"
  # `osascript` can wait on an app that will not quit; cap it so the install never blocks.
  run_with_timeout 10 osascript -e 'quit app "MemBar"' >/dev/null 2>&1 \
    || pkill -x MemBar || true
  sleep 1
fi

echo "==> installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R "$SOURCE" "$DESTINATION"

echo "==> launching"
open "$DESTINATION"
echo "installed: $DESTINATION"