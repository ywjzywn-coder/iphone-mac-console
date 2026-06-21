#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mac Console Host"
PRODUCT="MacConsoleHost"
BUNDLE="$ROOT/dist/$APP_NAME.app"
EXECUTABLE="$BUNDLE/Contents/MacOS/$PRODUCT"
INFO="$BUNDLE/Contents/Info.plist"
RESOURCES="$BUNDLE/Contents/Resources"

pkill -x "$PRODUCT" 2>/dev/null || true
pkill -f "$ROOT/bin/mac-control serve" 2>/dev/null || true

cd "$ROOT"
swift build

mkdir -p "$BUNDLE/Contents/MacOS" "$RESOURCES"
cp ".build/debug/$PRODUCT" "$EXECUTABLE"
chmod +x "$EXECUTABLE"
cp "$ROOT/assets/MacConsole.icns" "$RESOURCES/MacConsole.icns"

cat > "$INFO" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT</string>
  <key>CFBundleIdentifier</key>
  <string>local.mac-console.host</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>MacConsole</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Mac Console 需要发送鼠标、触控板和键盘事件来让手机控制这台 Mac。</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>MCProjectRoot</key>
  <string>$ROOT</string>
</dict>
</plist>
PLIST

/usr/bin/xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
SIGN_IDENTITY="${MAC_CONSOLE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null | /usr/bin/awk -F '"' '/valid identities found/{exit} /"/{print $2; exit}')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$BUNDLE" >/dev/null
else
  /usr/bin/codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true
fi

/usr/bin/open -n "$BUNDLE"

if [[ "${1:-}" == "--verify" ]]; then
  sleep 2
  pgrep -x "$PRODUCT" >/dev/null
  test -f "$ROOT/.runtime/status.json"
  grep -q '"running" *: *true' "$ROOT/.runtime/status.json"
  echo "$APP_NAME is running."
fi
