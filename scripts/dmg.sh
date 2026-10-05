#!/bin/bash
# Sign, package into a .dmg, notarize, and staple Tarmac.app for distribution.
# Publishes nothing: scripts/release.sh runs this and then ships the result.
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
#   VERSION=1.2.3 \
#   scripts/dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?set VERSION to the version being released}"
: "${DEVID_IDENTITY:?set DEVID_IDENTITY to 'Developer ID Application: NAME (TEAMID)'}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"

DIST="$ROOT/dist"
APP="$DIST/Tarmac.app"
DMG="$DIST/Tarmac-$VERSION.dmg"

# 0. Stamp the Cargo version so CARGO_PKG_VERSION is the shipped version: the
#    app's bundle version is stamped from the same $VERSION (scripts/bundle.sh),
#    and the app replaces a daemon whose version differs from its own. Matches
#    only `^version = "..."` — dependency pins like `serde = { version = ...}`
#    start with the crate name and are never touched. The lockfile names the
#    workspace crates' version too, and the release build is --locked.
sed -i '' "s/^version = \".*\"/version = \"$VERSION\"/" "$ROOT/core/Cargo.toml"
cargo update --workspace --manifest-path "$ROOT/core/Cargo.toml"

# 1. (re)assemble the unsigned bundle
VERSION="$VERSION" "$ROOT/scripts/bundle.sh"

# 2. sign INSIDE-OUT, no --deep: the embedded Mach-Os first, the app last.
#    Hardened runtime with no entitlements — nothing in the app generates code;
#    the JIT behind doc cards runs in WebKit's own content process. --timestamp
#    needs network access (Apple's TSA).
echo "==> signing (identity: $DEVID_IDENTITY)"
codesign --force --options runtime --timestamp --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/tarmacd"
codesign --force --options runtime --timestamp --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/tarmac"
codesign --force --options runtime --timestamp --sign "$DEVID_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 3. stage the .dmg: the app, a drag-target symlink to /Applications, and the
#    standalone `tarmac` CLI at the root (the cask's `binary` stanza links it).
#    The copy carries the signature step 2 embedded in the binary.
echo "==> staging .dmg layout"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tarmac-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Tarmac.app"
cp "$APP/Contents/MacOS/tarmac" "$STAGE/tarmac"
ln -s /Applications "$STAGE/Applications"

echo "==> building $DMG"
rm -f "$DMG" "$DMG.src"
hdiutil create -volname "Tarmac" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# 4. notarize the .dmg, then staple it (offline Gatekeeper). notarytool
#    inspects the .app inside the dmg.
echo "==> notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
# What this dmg was built from: scripts/release.sh reuses a stapled dmg only
# while the sources still match.
git -C "$ROOT" rev-parse HEAD > "$DMG.src"

echo
echo "==> done: $DMG"
echo "    sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
