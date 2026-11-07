#!/bin/zsh
# Packages build/Rclone.app into build/Rclone-<VERSION>.dmg with an Applications shortcut,
# plus a .sha256 checksum file. Run scripts/bundle.sh first.
#
# Environment:
#   VERSION=1.2.3   used in the file and volume name (default 0.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"
APP="build/Rclone.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }

STAGE="build/dmg-stage"
DMG="build/Rclone-${VERSION}.dmg"
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Rclone.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Rclone ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

(cd build && shasum -a 256 "Rclone-${VERSION}.dmg" > "Rclone-${VERSION}.dmg.sha256")
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
