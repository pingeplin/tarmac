#!/bin/bash
# Assemble an UNSIGNED Tarmac.app via `tauri build`. arm64-only.
# Sidecars (tarmacd, tarmac) are staged into desktop/src-tauri/binaries/ with
# the required Tauri target-triple suffix before the build, then Tauri embeds
# them into Contents/MacOS/ automatically.
#
# Signing + notarization + .dmg are the separate scripts/release.sh step.
#
#   VERSION=0.1.0 scripts/bundle.sh   # -> dist/Tarmac.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"

DIST="$ROOT/dist"
APP="$DIST/Tarmac.app"
RUST_BIN="$ROOT/core/target/release"
SIDECAR_DIR="$ROOT/desktop/src-tauri/binaries"
TRIPLE="aarch64-apple-darwin"
TAURI_APP="$ROOT/desktop/src-tauri/target/$TRIPLE/release/bundle/macos/Tarmac.app"

echo "==> building Rust core (release, arm64)"
cargo build --release --locked --manifest-path "$ROOT/core/Cargo.toml"

echo "==> staging sidecars"
mkdir -p "$SIDECAR_DIR"
cp "$RUST_BIN/tarmacd" "$SIDECAR_DIR/tarmacd-$TRIPLE"
cp "$RUST_BIN/tarmac"  "$SIDECAR_DIR/tarmac-$TRIPLE"

echo "==> tauri build (version $VERSION)"
( cd "$ROOT/desktop" && npx tauri build --bundles app --target "$TRIPLE" )

[ -d "$TAURI_APP" ] || { echo "FATAL: tauri build did not produce $TAURI_APP" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$DIST"
cp -R "$TAURI_APP" "$APP"

MACOS="$APP/Contents/MacOS"
for bin in tarmacd tarmac; do
  [ -x "$MACOS/$bin" ] || { echo "FATAL: $bin missing from Contents/MacOS/" >&2; exit 1; }
done

echo "==> assembled $APP"
echo "    Contents/MacOS: $(ls "$MACOS" | tr '\n' ' ')"
