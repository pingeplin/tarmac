#!/bin/bash
# Assemble an UNSIGNED dist/Tarmac.app from the native Swift app plus the two
# Rust binaries. arm64-only. Needs no Apple certificate; signing, the .dmg and
# notarization are scripts/release.sh.
#
#   VERSION=0.1.0 scripts/bundle-native.sh   # -> dist/Tarmac.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"

DIST="$ROOT/dist"
APP="$DIST/Tarmac.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
RUST_BIN="$ROOT/core/target/release"

# Never compile a tree behind origin/main, or a stale DMG ships while git
# history still looks complete. Ancestry only; offline downgrades to a warning.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "==> freshness guard: HEAD must contain origin/main"
  if git -C "$ROOT" fetch --quiet origin 2>/dev/null; then
    git -C "$ROOT" merge-base --is-ancestor origin/main HEAD || {
      echo "FATAL: HEAD is behind origin/main — rebase before building." >&2
      exit 1
    }
  else
    echo "WARNING: could not fetch origin — skipping freshness check (offline?)." >&2
  fi
fi

echo "==> building Rust core (release, arm64)"
cargo build --release --locked --manifest-path "$ROOT/core/Cargo.toml"

echo "==> building the native app (release)"
"$ROOT/scripts/fetch-ghostty-vt.sh"
( cd "$ROOT/app" && swift build -c release --product TarmacApp )
SWIFT_BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

for f in "$SWIFT_BIN/TarmacApp" "$RUST_BIN/tarmacd" "$RUST_BIN/tarmac"; do
  [ -x "$f" ] || { echo "FATAL: missing build output $f" >&2; exit 1; }
done

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$SWIFT_BIN/TarmacApp" "$MACOS/tarmac-app"
# Names must be exactly tarmacd / tarmac: the app spawns the daemon beside its
# own executable and puts that directory on every PTY's PATH.
cp "$RUST_BIN/tarmacd" "$MACOS/tarmacd"
cp "$RUST_BIN/tarmac" "$MACOS/tarmac"

# The app's SwiftPM resource bundle, flattened into Contents/Resources: codesign
# rejects loose content at the bundle root, where SwiftPM's own accessor would
# look. Found by content so a package rename fails here, not at first launch.
app_res=""
shopt -s nullglob
for b in "$SWIFT_BIN"/*.bundle; do
  [ -f "$b/DocTemplate.html" ] && { app_res="$b"; break; }
done
shopt -u nullglob
[ -n "$app_res" ] || { echo "FATAL: no *.bundle containing DocTemplate.html under $SWIFT_BIN" >&2; exit 1; }
cp -R "$app_res"/. "$RES/"

cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"

iconutil -c icns "$ROOT/packaging/icon/AppIcon.iconset" -o "$RES/Tarmac.icns"

echo "==> assembled $APP"
echo "    Contents/MacOS:     $(ls "$MACOS" | tr '\n' ' ')"
echo "    Contents/Resources: $(ls "$RES" | tr '\n' ' ')"
