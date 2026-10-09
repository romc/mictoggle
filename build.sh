#!/bin/bash
# Собирает MicToggle.app (universal: Apple Silicon + Intel, macOS 13+) в build/ и архив для передачи
# в dist/MicToggle.zip. Запуск локально: open build/MicToggle.app
set -euo pipefail
cd "$(dirname "$0")"
VERSION=0.8
APP=build/MicToggle.app
rm -rf build dist
mkdir -p "$APP/Contents/MacOS" dist
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" -o "build/MicToggle-$arch" main.swift
done
lipo -create -output "$APP/Contents/MacOS/MicToggle" build/MicToggle-arm64 build/MicToggle-x86_64
rm build/MicToggle-arm64 build/MicToggle-x86_64
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.mictoggle</string>
  <key>CFBundleName</key><string>MicToggle</string>
  <key>CFBundleExecutable</key><string>MicToggle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign -s - --force "$APP"
cp README-users.md dist/README.txt
ditto -c -k --keepParent "$APP" dist/MicToggle.app.zip
(cd dist && zip -q MicToggle.zip MicToggle.app.zip README.txt && rm MicToggle.app.zip README.txt)
echo "built $APP, dist/MicToggle.zip"
