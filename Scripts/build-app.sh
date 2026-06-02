#!/usr/bin/env bash
# Builds Slimg.app — a self-contained, double-clickable macOS app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="Slimg.app"

echo "Building SlimgApp ($CONFIG)…"
swift build -c "$CONFIG" --product SlimgApp

BIN=".build/$CONFIG/SlimgApp"
[ -f "$BIN" ] || { echo "error: build product not found at $BIN"; exit 1; }

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Slimg"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc code signature so Gatekeeper lets it launch locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
    echo "note: codesign skipped (continuing; app still runs locally)"

echo "Done: $(pwd)/$APP"
echo "Launch with:  open '$APP'"
