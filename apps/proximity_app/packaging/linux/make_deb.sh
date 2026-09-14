#!/usr/bin/env bash
# Proximity Linux .deb packager — run on Linux in apps/proximity_app.
#
# Usage:
#   flutter build linux --release
#   packaging/linux/make_deb.sh [bundle-dir] [output.deb]
#
# Defaults:
#   bundle = build/linux/x64/release/bundle
#   output = dist/proximity_<version>_amd64.deb  (version from pubspec)
#
# Layout inside the .deb: /opt/proximity/<bundle...>, /usr/bin/proximity
# symlink, /usr/share/applications/proximity.desktop. Depends on
# libgtk-3-0 + libsecret-1-0 (same surface the flutter bundle links).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$APP_DIR"

BUNDLE="${1:-build/linux/x64/release/bundle}"
VERSION="$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"
OUT="${2:-dist/proximity_${VERSION}_amd64.deb}"

if [ ! -x "$BUNDLE/proximity_app" ]; then
  echo "error: bundle not found at $BUNDLE — run 'flutter build linux --release' first." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/opt/proximity" "$STAGE/usr/bin" "$STAGE/usr/share/applications" "$STAGE/DEBIAN"
cp -R "$BUNDLE/." "$STAGE/opt/proximity/"
ln -s /opt/proximity/proximity_app "$STAGE/usr/bin/proximity"
cp packaging/linux/proximity.desktop "$STAGE/usr/share/applications/"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: proximity
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libsecret-1-0
Maintainer: Proximity <proximity@iitbhilai.ac.in>
Description: Proximity — campus attendance system
 Offline-first attendance over BLE proximity proofs + WiFi transport.
 Professor hosting + records on Linux; student enrollment/marking stay
 mobile-only (records viewable on desktop).
EOF

mkdir -p "$(dirname "$OUT")"
dpkg-deb --build "$STAGE" "$OUT" >/dev/null
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
