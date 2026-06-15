#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"

APP_NAME="Clawd Native.app"
BUNDLE_ID="com.clawd.on-desk.native"
VERSION="$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$REPO_ROOT/package.json" | head -n 1)"
VERSION="${VERSION:-0.0.0}"

DIST_DIR="$NATIVE_DIR/dist"
WORK_DIR="$DIST_DIR/.package-arm64"
APP_DIR="$DIST_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PROJECT_DIR="$RESOURCES_DIR/Project"
ZIP_PATH="$DIST_DIR/ClawdNative-macos-arm64-$VERSION.zip"
DMG_PATH="$DIST_DIR/ClawdNative-macos-arm64-$VERSION.dmg"

copy_dir() {
  local source="$1"
  local target="$2"
  rm -rf "$target"
  mkdir -p "$(dirname "$target")"
  ditto "$source" "$target"
}

copy_file_if_exists() {
  local source="$1"
  local target_dir="$2"
  if [[ -f "$source" ]]; then
    mkdir -p "$target_dir"
    cp "$source" "$target_dir/"
  fi
}

create_app_icon() {
  local iconset="$WORK_DIR/AppIcon.iconset"
  local source_dir="$REPO_ROOT/assets/icons"
  rm -rf "$iconset"
  mkdir -p "$iconset"

  cp "$source_dir/16x16.png" "$iconset/icon_16x16.png"
  cp "$source_dir/32x32.png" "$iconset/icon_16x16@2x.png"
  cp "$source_dir/32x32.png" "$iconset/icon_32x32.png"
  cp "$source_dir/64x64.png" "$iconset/icon_32x32@2x.png"
  cp "$source_dir/128x128.png" "$iconset/icon_128x128.png"
  cp "$source_dir/256x256.png" "$iconset/icon_128x128@2x.png"
  cp "$source_dir/256x256.png" "$iconset/icon_256x256.png"
  cp "$source_dir/512x512.png" "$iconset/icon_256x256@2x.png"
  cp "$source_dir/512x512.png" "$iconset/icon_512x512.png"

  iconutil -c icns "$iconset" -o "$RESOURCES_DIR/AppIcon.icns"
}

require_arm64_binary() {
  local binary="$1"
  local archs
  archs="$(lipo -archs "$binary")"
  case " $archs " in
    *" arm64 "*) ;;
    *)
      echo "error: $binary is not arm64 (archs: $archs)" >&2
      exit 1
      ;;
  esac
}

cd "$NATIVE_DIR"
swift build -c release --arch arm64 --product ClawdNative
swift build -c release --arch arm64 --product ClawdNativeHook
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

require_arm64_binary "$BIN_DIR/ClawdNative"
require_arm64_binary "$BIN_DIR/ClawdNativeHook"

rm -rf "$WORK_DIR" "$APP_DIR" "$ZIP_PATH" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$PROJECT_DIR"

cp "$BIN_DIR/ClawdNative" "$MACOS_DIR/ClawdNative"
cp "$BIN_DIR/ClawdNativeHook" "$MACOS_DIR/ClawdNativeHook"
chmod 755 "$MACOS_DIR/ClawdNative" "$MACOS_DIR/ClawdNativeHook"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Clawd Native</string>
  <key>CFBundleExecutable</key>
  <string>ClawdNative</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Clawd Native</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

copy_dir "$REPO_ROOT/themes" "$PROJECT_DIR/themes"
copy_dir "$REPO_ROOT/agents" "$PROJECT_DIR/agents"
copy_dir "$REPO_ROOT/hooks" "$PROJECT_DIR/hooks"
mkdir -p "$PROJECT_DIR/assets"
copy_dir "$REPO_ROOT/assets/icons" "$PROJECT_DIR/assets/icons"
copy_dir "$REPO_ROOT/assets/svg" "$PROJECT_DIR/assets/svg"
copy_dir "$REPO_ROOT/assets/sounds" "$PROJECT_DIR/assets/sounds"
copy_file_if_exists "$REPO_ROOT/assets/dock-icon.png" "$PROJECT_DIR/assets"
copy_file_if_exists "$REPO_ROOT/assets/icon.png" "$PROJECT_DIR/assets"
for tray_icon in "$REPO_ROOT"/assets/tray-icon*.png; do
  copy_file_if_exists "$tray_icon" "$PROJECT_DIR/assets"
done
cp "$REPO_ROOT/package.json" "$PROJECT_DIR/package.json"

create_app_icon
plutil -lint "$CONTENTS_DIR/Info.plist"

xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

DMG_STAGING="$WORK_DIR/dmg"
mkdir -p "$DMG_STAGING"
ditto "$APP_DIR" "$DMG_STAGING/$APP_NAME"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Clawd Native" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
echo "DMG: $DMG_PATH"
