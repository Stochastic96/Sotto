#!/bin/bash
# Sotto — build a real, signed macOS .app bundle and install it.
#
# Produces build/Sotto.app (a proper menu-bar agent app with a stable code
# identity) and, unless run with --no-install, copies it into /Applications.
#
# Usage:
#   ./package.sh              build + sign + install to /Applications
#   ./package.sh --no-install build + sign only (leaves build/Sotto.app)
#   ./package.sh --adhoc      sign ad-hoc instead of with a Developer identity
#
# Why a .app and not the bare CLI binary (see update.sh): macOS keeps
# Microphone / Screen Recording / Accessibility grants keyed to a code
# signature. An unsigned binary in /usr/local/bin gets its permissions reset
# on every rebuild. A .app signed with your stable Apple Development identity
# keeps them.
set -euo pipefail

APP_NAME="Sotto"
BUNDLE_ID="com.prashant.Sotto"
INSTALL_DIR="/Applications"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

INSTALL=1
ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --adhoc)      ADHOC=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Version from git (falls back to 1.0.0 outside a git checkout).
VERSION="$(git describe --tags --always 2>/dev/null || echo 1.0.0)"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "=== Packaging ${APP_NAME}.app (${VERSION}) ==="

# 1. Release build.
echo "[1/6] Building release binary..."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

# 2. Assemble the bundle skeleton.
echo "[2/6] Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"

# 3. Copy SwiftPM resource bundles next to the executable.
echo "[3/6] Copying resource bundles..."
for bundle in "${BIN_PATH}"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "${APP}/Contents/Resources/"
done

# 4. Info.plist. LSUIElement=1 keeps it a menu-bar agent (no Dock icon).
echo "[4/6] Writing Info.plist..."
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD_NUM}</string>
    <key>LSMinimumSystemVersion</key>  <string>27.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sotto listens to your microphone to transcribe dictation and voice commands on-device.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Sotto uses on-device speech recognition to turn your voice into text and commands.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Sotto controls other apps and the system to carry out your voice commands.</string>
</dict>
</plist>
PLIST

# 5. Code sign (binary must be signed for TCC permissions to persist).
echo "[5/6] Code signing..."
if [ "$ADHOC" -eq 1 ]; then
    SIGN_ID="-"
    echo "      Using ad-hoc signature (permissions reset on each rebuild)."
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -Eo '"Apple Development: [^"]+"' | head -1 | tr -d '"')"
    if [ -z "$SIGN_ID" ]; then
        echo "      No Apple Development identity found; falling back to ad-hoc."
        SIGN_ID="-"
    else
        echo "      Using identity: ${SIGN_ID}"
    fi
fi

codesign --force --deep --options runtime \
    --entitlements Sotto.entitlements \
    --sign "$SIGN_ID" \
    "$APP"
codesign --verify --verbose "$APP"

# 6. Install.
if [ "$INSTALL" -eq 1 ]; then
    echo "[6/6] Installing to ${INSTALL_DIR}..."
    pkill "${APP_NAME}" 2>/dev/null || true
    sleep 1
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    cp -R "$APP" "${INSTALL_DIR}/"
    echo ""
    echo "=== Installed ${INSTALL_DIR}/${APP_NAME}.app ==="
    echo "Launch it from Spotlight/Launchpad, or:  open -a ${APP_NAME}"
else
    echo "[6/6] Skipping install (--no-install)."
    echo ""
    echo "=== Built ${APP} ==="
    echo "Run it with:  open ${APP}"
fi
