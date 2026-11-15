#!/usr/bin/env bash
# Builds build/AdbFiles.app (release) and packs it into build/AdbFiles.dmg with an Applications shortcut.
# Uses only hdiutil, which ships with macOS.
# Usage: scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-app.sh

APP="build/AdbFiles.app"
DMG="build/AdbFiles.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "AdbFiles $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

echo "Built $(pwd)/$DMG (version $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
