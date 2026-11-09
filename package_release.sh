#!/bin/bash
# Build Capit and produce the release zip, in one step that can be checked.
#
# The zip is written without extended attributes or resource forks (`--noextattr --norsrc`): macOS
# re-adds com.apple.provenance to a file after it is stripped, and `ditto` then stores it as an
# AppleDouble (`._AppIcon.icns`) inside the archive. Harmless, but it is cruft in a release asset.
#
# Usage: ./package_release.sh [output-dir]      (default: build)
set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="${1:-build}"
APP="build/Capit.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"

echo "== swift build + assemble =="
./make_app.sh release >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ZIP="$OUT_DIR/Capit-$VERSION.zip"
mkdir -p "$OUT_DIR"

echo "== stage, strip, sign =="
STAGE="$(mktemp -d)/Capit.app"
ditto --norsrc --noextattr "$APP" "$STAGE"      # xattrs would make codesign reject the bundle
xattr -cr "$STAGE" 2>/dev/null || true
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
codesign --force --sign - "$STAGE/Contents/MacOS/Capit"
codesign --force --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "== zip =="
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr "$STAGE" "$ZIP"
rm -rf "$(dirname "$STAGE")"

echo "== verify =="
if unzip -l "$ZIP" | grep -q '\._'; then
  echo "FAIL: the archive still carries AppleDouble entries"; exit 1
fi
T="$(mktemp -d)"
ditto -x -k "$ZIP" "$T"
codesign --verify --deep --strict "$T/Capit.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$T/Capit.app/Contents/Info.plist")" = "$VERSION" ]
rm -rf "$T"

echo "== $ZIP =="
echo "  version  $VERSION (build $BUILD)"
echo "  size     $(stat -f%z "$ZIP") bytes"
echo "  sha256   $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
