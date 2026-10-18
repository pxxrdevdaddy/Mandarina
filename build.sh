#!/bin/bash
# Compila y crea Mandarina.app (necesita Xcode Command Line Tools: xcode-select --install)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Mandarina.app
rm -rf "$APP" AppIcon.iconset; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Mandarina "$APP/Contents/MacOS/Mandarina"

# Icono de la app (se dibuja con el propio programa)
./.build/release/Mandarina --iconset AppIcon.iconset
iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Mandarina</string>
<key>CFBundleIdentifier</key><string>local.mandarina</string>
<key>CFBundleExecutable</key><string>Mandarina</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
touch "$APP"
echo "Listo: $(pwd)/$APP  (arrástrala a /Aplicaciones y ábrela)"
