#!/bin/bash
# Assemble an UNSIGNED Tarmac.app from a release build of the Swift GUI plus the
# two Rust binaries. arm64-only (first-ship decision; see design 2606.0002).
#
# This step needs no Apple certificate — the resulting bundle launches locally,
# so it is the way to validate the design's riskiest assumption (does the app
# find Contents/MacOS/tarmacd, resolve `tarmac` on the PTY PATH, and load the
# DocTemplate.html resource bundle?) BEFORE any signing exists.
#
# Signing + notarization + .dmg are the separate scripts/release.sh step.
#
#   VERSION=0.1.0 scripts/bundle.sh   # -> dist/Tarmac.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"

DIST="$ROOT/dist"
APP="$DIST/Tarmac.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

SWIFT_BIN="$ROOT/app/.build/release"
RUST_BIN="$ROOT/core/target/release"

echo "==> building Rust core (release, arm64)"
cargo build --release --locked --manifest-path "$ROOT/core/Cargo.toml"

echo "==> building Swift app (release)"
( cd "$ROOT/app" && swift build -c release )

for f in "$SWIFT_BIN/TarmacApp" "$RUST_BIN/tarmacd" "$RUST_BIN/tarmac"; do
  [ -x "$f" ] || { echo "FATAL: missing build output $f" >&2; exit 1; }
done

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# 1. main GUI executable
cp "$SWIFT_BIN/TarmacApp" "$MACOS/TarmacApp"

# 2. embedded Rust binaries. Names MUST be exactly tarmacd / tarmac: the app
#    spawns <bundle>/Contents/MacOS/tarmacd and prepends Contents/MacOS to the
#    PTY PATH so the bundled `tarmac` resolves (DaemonLaunch.swift).
cp "$RUST_BIN/tarmacd" "$MACOS/tarmacd"
cp "$RUST_BIN/tarmac" "$MACOS/tarmac"

# 3. App resources -> Contents/Resources (flat). We copy the CONTENTS of the
#    app's own SwiftPM resource bundle so DocWebView can load DocTemplate.html
#    via Bundle.main (DocWebView prefers Bundle.main, falls back to Bundle.module
#    for `make run`). We do NOT place the *.bundle at the .app root: SwiftPM's
#    Bundle.module accessor wants it there (Bundle.main.bundleURL/<Pkg>_<Target>
#    .bundle), but codesign rejects loose contents at the bundle root
#    ("unsealed contents present in the bundle root").
#
#    Found by CONTENT (DocTemplate.html), not by the literal bundle name
#    Tarmac_TarmacApp.bundle, so a package rename fails loudly here instead of
#    silently shipping a broken app.
#
#    We deliberately DROP SwiftTerm_SwiftTerm.bundle: its only payload is
#    Shaders.metal, used solely by SwiftTerm's opt-in Metal renderer
#    (setUseMetal), which the app never enables — so it is never loaded.
app_res=""
shopt -s nullglob
for b in "$SWIFT_BIN"/*.bundle; do
  [ -f "$b/DocTemplate.html" ] && { app_res="$b"; break; }
done
shopt -u nullglob
[ -n "$app_res" ] || { echo "FATAL: no *.bundle containing DocTemplate.html under $SWIFT_BIN" >&2; exit 1; }
echo "    + $(basename "$app_res")/ -> Contents/Resources/"
cp -R "$app_res"/. "$RES/"

# 4. Info.plist, version stamped from $VERSION
cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"

# 5. icon, if one has been created (optional for now)
if [ -f "$ROOT/packaging/Tarmac.icns" ]; then
  cp "$ROOT/packaging/Tarmac.icns" "$RES/Tarmac.icns"
else
  echo "    (no packaging/Tarmac.icns — app will use the generic icon)"
fi

echo "==> assembled $APP"
echo "    Contents/MacOS:      $(ls "$MACOS" | tr '\n' ' ')"
echo "    Contents/Resources:  $(ls "$RES" 2>/dev/null | tr '\n' ' ')"
