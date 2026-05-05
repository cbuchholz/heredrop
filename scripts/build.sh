#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/HereDrop.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
  -O \
  -parse-as-library \
  -framework AppKit \
  -framework CryptoKit \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/Sources/HereDrop/main.swift" \
  -o "$MACOS_DIR/HereDrop"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$MACOS_DIR/HereDrop"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "$APP_DIR"
