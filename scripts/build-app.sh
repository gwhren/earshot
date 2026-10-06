#!/usr/bin/env bash
# Builds build/Earshot.app from the Swift package and signs it ad hoc.
#
#   ./scripts/build-app.sh            # release build
#   CONFIGURATION=debug ./scripts/build-app.sh
#
# Needs Xcode or the Command Line Tools (Swift 5.9+) on macOS 14 or later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Earshot.app"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Earshot.app can only be built on macOS." >&2
  exit 1
fi

echo "==> Compiling Earshot ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product Earshot
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Earshot" "$APP/Contents/MacOS/Earshot"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Rendering the icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Earshot" --export-iconset "$ICONSET"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo
echo "Built $APP"
echo "Run it with:  open \"$APP\""
