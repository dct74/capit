#!/bin/bash
# Build Capit and assemble a runnable .app bundle (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

if [ -d "/Applications/Xcode.app" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

CONFIG="${1:-release}"
APP_NAME="Capit"
APP="build/$APP_NAME.app"
BIN=".build/${CONFIG}/Capit"

echo "== swift build ($CONFIG) =="
swift build -c "$CONFIG"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [ -f "resources/AppIcon.icns" ]; then
  cp "resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>Capit</string>
    <key>CFBundleIdentifier</key><string>com.capit.Capit</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Capit</string>
    <key>CFBundleDisplayName</key><string>Capit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Strip resource-fork/provenance xattrs that break ad-hoc codesigning, then sign.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null
find "$APP" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP"

echo "== done: $APP =="
echo "Launch with: open \"$APP\""
