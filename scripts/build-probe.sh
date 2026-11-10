#!/bin/zsh
# Build AirProbe.app — an AirPod used as an IMU inside an object (活萃力 tube demo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/AirProbe.app"
ICNS="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
    python3 "$ROOT/scripts/generate-icon.py"
    iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ICNS"
fi

swift build -c release --product AirProbe

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AirProbe" "$APP/Contents/MacOS/AirProbe"
cp "$ROOT/Resources/Probe/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# Object Capture scan of the tube (optional; the app falls back to a parametric model).
if [ -f "$ROOT/Resources/Probe/huocuili.usdz" ]; then
    cp "$ROOT/Resources/Probe/huocuili.usdz" "$APP/Contents/Resources/"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

ENT="$ROOT/Resources/Probe/AirProbe.entitlements"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Release: Developer ID + hardened runtime (required for notarization).
    SIGN="$SIGN_IDENTITY"
    /usr/bin/codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$SIGN" "$APP"
else
    # Dev: same identity preference as build-app.sh so permissions survive rebuilds.
    SIGN="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
    if [ -z "$SIGN" ]; then
        if security find-identity -v -p codesigning 2>/dev/null | grep -qF "AirPoise Dev"; then SIGN="AirPoise Dev"; else SIGN="-"; fi
    fi
    /usr/bin/codesign --force --deep --entitlements "$ENT" --sign "$SIGN" "$APP"
fi

echo "built $APP (signed: $SIGN)"
echo "launch with:  open '$APP'"
