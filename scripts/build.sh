#!/bin/zsh
# Builds build/LayoutFixer.app (and build/LayoutFixer.zip with --zip).
set -e
cd "$(dirname "$0")/.."
VERSION=0.1.0
APP=build/LayoutFixer.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Resources/* $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.layoutfixer</string>
  <key>CFBundleName</key><string>LayoutFixer</string>
  <key>CFBundleDisplayName</key><string>LayoutFixer</string>
  <key>CFBundleExecutable</key><string>LayoutFixer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
swiftc -O Sources/main.swift -o $APP/Contents/MacOS/LayoutFixer -framework Cocoa -framework Carbon
codesign --force --sign - $APP
if [[ "$1" == "--zip" ]]; then
  (cd build && ditto -c -k --keepParent LayoutFixer.app LayoutFixer-$VERSION.zip)
  echo "built build/LayoutFixer-$VERSION.zip"
fi
echo "built $APP"
