#!/bin/bash
# Build Capit and assemble a runnable .app bundle (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

# Optionally use Xcode's SDK when it is usable; otherwise fall back to the active
# developer dir (xcode-select, typically Command Line Tools) — the project builds fine
# against the CLT SDK and avoids Xcode's license prompt.
if [ -d "/Applications/Xcode.app" ] && [ -z "${DEVELOPER_DIR:-}" ] && xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

CONFIG="${1:-release}"
APP_NAME="Capit"
APP="build/$APP_NAME.app"
BIN=".build/${CONFIG}/Capit"

echo "== swift build ($CONFIG) =="
swift build -c "$CONFIG"

# Assemble + sign in a NON-synced temp dir first: a .app created directly under an
# iCloud-synced folder gets FinderInfo / FileProvider xattrs that break codesigning.
STAGE="$(mktemp -d)/${APP_NAME}.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"

if [ -f "resources/AppIcon.icns" ]; then
  cp "resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
  # A downloaded icon carries provenance / quarantine / lastuseddate. Those are inside the bundle,
  # so codesign refuses to sign ("resource fork, Finder information, or similar detritus").
  xattr -c "$STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>1.5.7</string>
    <key>CFBundleVersion</key><string>44</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Strip resource-fork/provenance xattrs, then sign.
xattr -cr "$STAGE" 2>/dev/null || true
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
codesign --force --sign - "$STAGE/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$STAGE"
codesign --verify --deep "$STAGE"

# Copy the signed bundle into place. `build/` lives in an iCloud-synced folder, and the file provider
# stamps FinderInfo / fpfs xattrs onto new files — asynchronous, so it can land after the copy and even
# after signing, which breaks the seal ("resource fork, Finder information, or similar detritus").
# Copy without any extended attributes, then strip, re-sign and verify, retrying a couple of times
# because the file provider may still add one in the moment after we look.
mkdir -p build
rm -rf "$APP"
ditto --norsrc --noextattr "$STAGE" "$APP"
for attempt in 1 2 3; do
  xattr -cr "$APP" 2>/dev/null || true
  find "$APP" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
  find "$APP" -name '._*' -delete 2>/dev/null || true
  codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1
  codesign --force --sign - "$APP" >/dev/null 2>&1
  if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    break
  fi
  if [ "$attempt" = 3 ]; then
    echo "FAIL: $APP still fails verification after 3 attempts (iCloud xattrs?)" >&2
    codesign --verify --deep --strict "$APP"
    exit 1
  fi
  sleep 0.3
done

echo "== done: $APP =="
echo "Launch with: open \"$APP\""
