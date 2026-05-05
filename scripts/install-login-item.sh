#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/HereDrop.app"
PLIST="$HOME/Library/LaunchAgents/com.cortbuchholz.heredrop.plist"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build.sh" >/dev/null
fi

mkdir -p "$HOME/Library/LaunchAgents"

/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Label string com.cortbuchholz.heredrop" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /usr/bin/open" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $APP_DIR" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool false" "$PLIST"

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "Installed login item: $PLIST"
