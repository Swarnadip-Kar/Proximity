#!/usr/bin/env bash
# Proximity Linux portable tarball — run on Linux in apps/proximity_app.
# For machines that cannot install the .deb: unpack and run ./proximity_app.
#
# Usage:
#   flutter build linux --release
#   packaging/linux/make_tarball.sh [bundle-dir] [output.tar.gz]
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$APP_DIR"

BUNDLE="${1:-build/linux/x64/release/bundle}"
VERSION="$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"
OUT="${2:-dist/Proximity-${VERSION}-Linux-x64.tar.gz}"

if [ ! -x "$BUNDLE/proximity_app" ]; then
  echo "error: bundle not found at $BUNDLE — run 'flutter build linux --release' first." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")"
# Rename the top-level dir inside the tarball to something friendly.
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)); unpack and run bundle/proximity_app"
