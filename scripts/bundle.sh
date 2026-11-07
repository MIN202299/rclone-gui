#!/bin/zsh
# Builds a release binary and wraps it in build/Rclone.app (ad-hoc signed).
#
# Environment:
#   VERSION=1.2.3     CFBundleShortVersionString (default 0.0.0)
#   BUILD_NUMBER=42   CFBundleVersion (default 1)
#   UNIVERSAL=1       build for Apple Silicon + Intel (default: this Mac's architecture)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release $ARCH_FLAGS
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/RcloneGUI"

APP="build/Rclone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RcloneGUI"

# App icon: Icon Composer document with light + dark appearances -> Assets.car (+ AppIcon.icns).
# Older Xcode can't compile .icon documents; fall back to a light-only .icns from the preview PNG.
[[ -d Resources/AppIcon.icon ]] || swift scripts/make-icon.swift
if ! xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
     --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist build/icon-partial.plist >/dev/null 2>&1 \
   || [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  echo "actool couldn't compile AppIcon.icon; using a light-only .icns instead"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon-light.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon-light.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Rclone</string>
  <key>CFBundleDisplayName</key><string>Rclone</string>
  <key>CFBundleIdentifier</key><string>local.rclone-gui</string>
  <key>CFBundleExecutable</key><string>RcloneGUI</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/RcloneGUI"))"
