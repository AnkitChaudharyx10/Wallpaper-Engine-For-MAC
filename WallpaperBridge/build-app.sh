#!/bin/bash
# Builds "Wallpaper Bridge.app" into ./build. Run on a Mac with Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Wallpaper Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WallpaperBridge" "$APP/Contents/MacOS/WallpaperBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will launch it locally.
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
echo "Move it to /Applications and open it. It lives in the menu bar."
