#!/bin/bash
# Sign, package into a .dmg, notarize, and staple Tarmac.app for distribution.
#
# Prerequisites (one-time):
#   - A "Developer ID Application" identity in your login keychain
#     (Xcode > Settings > Accounts > [team] > Manage Certificates > + ).
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials "tarmac-notary" \
#         --apple-id <enrolled-apple-id> --team-id <TEAMID> \
#         --password <app-specific-password>
#     (or the App Store Connect API-key form: --key/--key-id/--issuer)
#
# Usage:
#   DEVID_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="tarmac-notary" \
#   VERSION=0.1.0 \
#   scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
: "${DEVID_IDENTITY:?set DEVID_IDENTITY to 'Developer ID Application: NAME (TEAMID)'}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"

DIST="$ROOT/dist"
APP="$DIST/Tarmac.app"
ENT="$ROOT/packaging/Tarmac.entitlements"
DMG="$DIST/Tarmac-$VERSION.dmg"

# 1. (re)assemble the unsigned bundle
VERSION="$VERSION" "$ROOT/scripts/bundle.sh"

# 2. sign INSIDE-OUT, no --deep. Embedded Mach-Os first, no entitlements; the
#    main app last, WITH the hardened-runtime entitlements. --timestamp needs
#    network access (Apple's TSA).
echo "==> signing (identity: $DEVID_IDENTITY)"
codesign --force --options runtime --timestamp --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/tarmacd"
codesign --force --options runtime --timestamp --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/tarmac"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$DEVID_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 3. stage the .dmg: the app, a drag-target symlink to /Applications, and the
#    standalone `tarmac` CLI at the root (the cask's `binary` stanza links it).
#    Sign that standalone copy too.
echo "==> staging .dmg layout"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tarmac-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Tarmac.app"
cp "$APP/Contents/MacOS/tarmac" "$STAGE/tarmac"
codesign --force --options runtime --timestamp --sign "$DEVID_IDENTITY" "$STAGE/tarmac"
ln -s /Applications "$STAGE/Applications"

echo "==> building $DMG"
rm -f "$DMG"
hdiutil create -volname "Tarmac" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# 4. notarize the .dmg, then staple it (offline Gatekeeper). notarytool
#    inspects the .app inside the dmg.
echo "==> notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo
echo "==> done: $DMG"
echo "    sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    -> bump version + sha256 in packaging/Casks/tarmac.rb and the tap repo"
