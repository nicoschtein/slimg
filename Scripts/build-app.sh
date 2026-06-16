#!/usr/bin/env bash
# Builds Slimg.app — a self-contained, double-clickable macOS app bundle.
#
# Usage:
#   ./Scripts/build-app.sh [debug|release]        # default: release
#   ./Scripts/build-app.sh release --universal    # arm64 + x86_64 fat binary
#   SLIMG_UNIVERSAL=1 ./Scripts/build-app.sh       # same, via env
#   SLIMG_VERSION=1.2.3 ./Scripts/build-app.sh     # stamp a version into the bundle
#
# Environment:
#   SLIMG_UNIVERSAL  if "1", build a universal (arm64 + x86_64) binary.
#   SLIMG_VERSION    if set, overrides CFBundleShortVersionString / CFBundleVersion
#                    in the *bundled* Info.plist (the committed Resources/Info.plist
#                    is never mutated).
#
# Designed to work both locally and in CI; resolves all paths from the repo root
# regardless of the current working directory.
set -euo pipefail

# --- Resolve repo root (robust against symlinks / arbitrary CWD) -------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

# --- Args / config -----------------------------------------------------------
CONFIG="release"
UNIVERSAL="${SLIMG_UNIVERSAL:-0}"
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --universal)   UNIVERSAL=1 ;;
        *) echo "warning: ignoring unknown argument '$arg'" >&2 ;;
    esac
done

APP="Slimg.app"

# --- Build -------------------------------------------------------------------
BUILD_FLAGS=(-c "$CONFIG" --product SlimgApp)
if [ "$UNIVERSAL" = "1" ]; then
    echo "Building SlimgApp ($CONFIG, universal arm64 + x86_64)…"
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
else
    echo "Building SlimgApp ($CONFIG)…"
fi
swift build "${BUILD_FLAGS[@]}"

# Locate the build product. With multiple --arch flags, SwiftPM places the fat
# binary in an apple/Products path; otherwise it's the plain bin dir.
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/SlimgApp"
[ -f "$BIN" ] || { echo "error: build product not found at $BIN"; exit 1; }

# For a universal build, fail fast if the product isn't actually a fat binary
# (guards against --show-bin-path resolving to a single-arch directory).
if [ "$UNIVERSAL" = "1" ]; then
    ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
    case "$ARCHS" in
        *arm64*x86_64*|*x86_64*arm64*) echo "Verified universal binary: $ARCHS" ;;
        *) echo "error: expected a universal (arm64 + x86_64) binary at $BIN, got: '$ARCHS'"; exit 1 ;;
    esac
fi

# --- Assemble bundle ---------------------------------------------------------
echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Slimg"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Embed the app icon if it has been generated.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    echo "Embedded AppIcon.icns"
else
    echo "note: Resources/AppIcon.icns not found — run 'swift Scripts/generate-icons.swift' to add the icon"
fi

# Stamp the version into the *bundled* plist only (never the committed source).
if [ -n "${SLIMG_VERSION:-}" ]; then
    PLIST="$APP/Contents/Info.plist"
    # CFBundleShortVersionString must be a dotted numeric string (x[.y[.z]]).
    # Strip any pre-release/build suffix (e.g. "1.2.3-dev" -> "1.2.3") and fall
    # back to 0.0.0 for anything non-numeric, so the bundle stays valid for
    # Gatekeeper / notarization.
    SHORT_VERSION="${SLIMG_VERSION%%-*}"
    case "$SHORT_VERSION" in
        ''|*[!0-9.]*) SHORT_VERSION="0.0.0" ;;
    esac
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SHORT_VERSION" "$PLIST" 2>/dev/null || true
    echo "Stamped version $SHORT_VERSION (from '$SLIMG_VERSION') into bundled Info.plist"
fi

# --- Code signing ------------------------------------------------------------
# If a real Developer ID identity is provided, sign with hardened runtime so the
# bundle is notarization-ready; otherwise fall back to an ad-hoc signature so
# Gatekeeper lets it launch locally. Release notarization is handled by CI.
if [ -n "${SLIMG_SIGN_IDENTITY:-}" ]; then
    echo "Signing with a Developer ID identity (hardened runtime)…"
    codesign --force --deep --options runtime --timestamp \
        --sign "$SLIMG_SIGN_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
        echo "note: codesign skipped (continuing; app still runs locally)"
fi

echo "Done: $ROOT/$APP"
echo "Launch with:  open '$APP'"
