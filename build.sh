#!/bin/bash
# Собирает MicToggle.app (universal: Apple Silicon + Intel, macOS 13+) в build/ и архив для передачи
# в dist/MicToggle.zip. ./build.sh install — ещё и поставить в /Applications и перезапустить.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=0.9
APP=build/MicToggle.app
rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
swift makeicon.swift build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset
rm -rf build/AppIcon.iconset
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# Постоянная подпись (make-signing-cert.sh), если есть, иначе ad-hoc. Подписываем по SHA-1: сертификат
# самоподписанный и недоверенный, по имени codesign его не берёт.
SIGN=$(security find-certificate -c "MicToggle Local Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3}' || true)
codesign -s "${SIGN:--}" --force "$APP"
cp README-users.md dist/README.txt
ditto -c -k --keepParent "$APP" dist/MicToggle.app.zip
(cd dist && zip -q MicToggle.zip MicToggle.app.zip README.txt && rm MicToggle.app.zip README.txt)
echo "built $APP, dist/MicToggle.zip"
if [ "${1:-}" = install ]; then
  pkill -x MicToggle || true
  while pgrep -x MicToggle >/dev/null; do sleep 0.2; done
  rm -rf /Applications/MicToggle.app
  ditto "$APP" /Applications/MicToggle.app
  # LaunchServices ещё секунду-две считает старый процесс живым (-600) — повторяем.
  for _ in 1 2 3 4 5 6 7 8 9 10; do open /Applications/MicToggle.app 2>/dev/null && break; sleep 0.5; done
  echo "installed /Applications/MicToggle.app"
fi
