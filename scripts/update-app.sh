#!/bin/bash
# update-app.sh — copy latest debug or release binary into build/Sotto.app
# and re-sign with the Apple Development cert so local.sotto.app stays current.
#
# Run after any rebuild:
#   ./scripts/update-app.sh
#   ./scripts/update-app.sh release   # use release build

set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/Sotto.app/Contents/MacOS/Sotto"
CONFIG="${1:-debug}"

if [ "$CONFIG" = "release" ]; then
  BIN="$REPO/.build/release/Sotto"
else
  # Xcode puts the debug binary here:
  BIN="$REPO/.build/out/Products/Debug/Sotto"
  [ -f "$BIN" ] || BIN="$REPO/.build/debug/Sotto"
fi

[ -f "$BIN" ] || { echo "❌ Binary not found: $BIN — build first."; exit 1; }

echo "→ Copying $BIN → $APP"
cp "$BIN" "$APP"

BIN_DIR="$(dirname "$BIN")"
echo "→ Syncing resource bundles from $BIN_DIR..."
cp -R "$BIN_DIR/"*.bundle "$REPO/build/Sotto.app/Contents/Resources/" 2>/dev/null || true

# Try Apple Development cert first; fall back to ad-hoc
CERT="Apple Development: prashant@digitaltaantra.com (687GPC75G5)"
if codesign -dvv "$APP" 2>&1 | grep -q "$CERT" || \
   security find-certificate -c "Apple Development" 2>/dev/null | grep -q "prashant"; then
  codesign --force --deep --sign "$CERT" "$REPO/build/Sotto.app" 2>/dev/null && \
    echo "✅ Signed with Apple Development cert (local.sotto.app)" || \
    codesign --force --deep --sign - "$REPO/build/Sotto.app" && echo "✅ Ad-hoc signed (local.sotto.app)"
else
  codesign --force --deep --sign - "$REPO/build/Sotto.app"
  echo "✅ Ad-hoc signed (local.sotto.app)"
fi

echo "✅ build/Sotto.app is up to date."
echo ""
echo "Launch with:  open '$REPO/build/Sotto.app'"
