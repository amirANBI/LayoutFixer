#!/bin/zsh
# Regenerates the app icon and menu bar icon from icon/make_icon.swift.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift icon/make_icon.swift "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP"/MenuBarIcon.png "$TMP"/MenuBarIcon@2x.png Resources/
cp "$TMP"/icon_1024.png icon/icon_1024.png
rm -rf "$TMP"
echo "icons updated"
