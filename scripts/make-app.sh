#!/bin/bash
# Builds Sotto in release mode and wraps it into a proper .app bundle.
#
# Uses xcodebuild (not `swift build`): plain SwiftPM cannot compile the Metal
# GPU shaders that MLX (the Qwen engine) needs — see mlx-swift README.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=".xcbuild"
xcodebuild build \
    -scheme Sotto \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -clonedSourcePackagesDirPath "$DERIVED/spm" \
    -skipMacroValidation \
    -quiet

PRODUCTS="$DERIVED/Build/Products/Release"
APP="build/Sotto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PRODUCTS/Sotto" "$APP/Contents/MacOS/Sotto"

# MLX's Metal shader library and other SPM resources live in .bundle folders
# next to the built product — the app aborts at LLM load without them.
for bundle in "$PRODUCTS"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Copy voice generation scripts into Resources
cp -R scripts "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.sotto.app</string>
    <key>CFBundleName</key>
    <string>Sotto</string>
    <key>CFBundleDisplayName</key>
    <string>Sotto</string>
    <key>CFBundleExecutable</key>
    <string>Sotto</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Local Sotto URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>sotto</string>
            </array>
        </dict>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sotto records your voice only while you hold the hotkey, transcribes it on-device, and never sends audio anywhere.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Sotto uses speech recognition to transcribe your voice locally or using Siri's speech engine.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Sotto controls apps like Spotify, Notes, and Finder on your behalf to carry out your spoken commands.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Sotto creates calendar events when you ask Jarvis to schedule something.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Sotto creates calendar events when you ask Jarvis to schedule something.</string>
    <key>NSRemindersUsageDescription</key>
    <string>Sotto creates reminders when you ask Jarvis to remind you of something.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Sotto creates reminders when you ask Jarvis to remind you of something.</string>
</dict>
</plist>
EOF

# Sign with a STABLE identity so macOS keeps the Accessibility/Microphone grants across
# rebuilds (ad-hoc "-" changes the code identity every build, dropping the permissions).
# Preference order: a self-signed "Sotto Local Signing" cert → any Apple Development cert →
# ad-hoc as a last resort. Override with SOTTO_SIGN_IDENTITY if you want a specific one.
SIGN_IDENTITY="${SOTTO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Sotto Local Signing"; then
        SIGN_IDENTITY="Sotto Local Signing"
    elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
    fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with stable identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "No stable signing identity found — falling back to ad-hoc (permissions reset each rebuild)."
    codesign --force --deep --sign - "$APP"
fi
echo "Built $APP — move it to /Applications if you like, then open it."
