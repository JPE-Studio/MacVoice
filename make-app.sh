#!/bin/bash
# Build MacVoice and assemble the .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/MacVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacVoice "$APP/Contents/MacOS/MacVoice"

mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacVoice</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleIdentifier</key><string>at.petermaier.macvoice</string>
    <key>CFBundleExecutable</key><string>MacVoice</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>MacVoice wandelt deine Sprache in Text und Steuerbefehle um.</string>
    <key>NSAppleEventsUsageDescription</key><string>MacVoice steuert Apps (z. B. App beenden über AppleScript).</string>
</dict>
</plist>
EOF

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'MacVoiceDev' | head -1)
# bundle the models so the app is self-contained
mkdir -p "$APP/Contents/Resources"
for model in whistle.cact needle3.cact; do
    if [ -f "$HOME/$model" ]; then
        cp "$HOME/$model" "$APP/Contents/Resources/$model"
    else
        echo "WARNING: ~/$model missing — app will need it in the home dir" >&2
    fi
done

codesign --force --sign "${IDENTITY:-MacVoiceDev}" "$APP" || codesign --force -s - "$APP"
echo "built: $APP (signed: ${IDENTITY:-ad-hoc})"
