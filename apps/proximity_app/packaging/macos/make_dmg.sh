#!/usr/bin/env bash
# Proximity macOS DMG packager — no third-party tools, only hdiutil (ships with macOS).
#
# Usage:
#   packaging/macos/make_dmg.sh <path-to-Proximity.app> [output.dmg] [VolumeName]
#
# Defaults:
#   app     = build/macos/Build/Products/Release/proximity_app.app
#   output  = dist/Proximity-<version>-macOS-<arch>.dmg  (version from pubspec, arch from uname)
#   volume  = "Proximity"
#
# Run from apps/proximity_app. Expects a RELEASE build:
#   flutter build macos --release
#   packaging/macos/make_dmg.sh
#
# Notes:
# - No paid Apple Developer membership exists yet (see PROXIMITY_DEPLOYMENT.md
#   §3b), so the .app carries its local ad-hoc signature. First launch needs
#   right-click > Open (Gatekeeper), not a double-click. Notarization is a
#   future step once the membership lands — this script needs no changes for it.
# - Apple-Silicon runners produce an arm64-only .app; Intel runners an x64-only
#   one. A universal DMG needs a lipo merge first (not wired yet).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$APP_DIR"

APP="${1:-build/macos/Build/Products/Release/proximity_app.app}"
VOLUME="${3:-Proximity}"
VERSION="$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"
ARCH="$(uname -m)"
OUT="${2:-dist/Proximity-${VERSION}-macOS-${ARCH}.dmg}"

if [ ! -d "$APP" ]; then
  echo "error: .app not found at $APP — run 'flutter build macos --release' first." >&2
  exit 1
fi

# The .app must be signed (even ad-hoc) or Gatekeeper refuses it outright.
if ! codesign -dv "$APP" >/dev/null 2>&1; then
  echo "error: $APP is unsigned — 'flutter build macos --release' should have ad-hoc signed it." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Proximity.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "first launch on another Mac: right-click > Open (ad-hoc signature, no notarization yet)."
