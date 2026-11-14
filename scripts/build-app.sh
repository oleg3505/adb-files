#!/usr/bin/env bash
# Builds build/AdbFiles.app and ad-hoc signs it.
# Usage: scripts/build-app.sh            # release build
#        CONFIG=debug scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/AdbFiles.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

scripts/make-icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AdbFiles" "$APP/Contents/MacOS/AdbFiles"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP"

# Verify the bundle layout and signature; fail loudly if anything is missing.
for f in Contents/MacOS/AdbFiles Contents/Info.plist Contents/Resources/AppIcon.icns; do
    [[ -e "$APP/$f" ]] || { echo "error: missing $APP/$f" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"

echo "Built $(pwd)/$APP ($CONFIG)"
