#!/bin/zsh
# Build a signed + notarized AirProbe DMG.
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=<notarytool keychain profile> ./scripts/release-probe.sh
# Create the profile once with: xcrun notarytool store-credentials <name> --apple-id … --team-id …
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Probe/Info.plist")"
APP="$ROOT/dist/AirProbe.app"
DMG="$ROOT/dist/AirProbe-${VERSION}.dmg"
STAGE="$ROOT/dist/probe-dmg-stage"
ZIP="$ROOT/dist/AirProbe-notarize.zip"

SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build-probe.sh"
codesign --verify --strict --verbose=2 "$APP"

echo "notarizing app…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "building dmg…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AirProbe.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AirProbe" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "notarizing dmg…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
spctl -a -t exec -v "$APP"
shasum -a 256 "$DMG"
echo "done: $DMG"
