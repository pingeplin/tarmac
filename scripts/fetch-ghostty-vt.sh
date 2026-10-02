#!/bin/bash
# Stage the pinned libghostty-vt XCFramework at app/Vendor/ (gitignored).
#
# libghostty-vt declares its C API unstable, no tagged Ghostty release
# publishes it, and Ghostty's `tip` release is replaced on every tip build —
# so the pin is a COMMIT, fetched from the per-commit address Ghostty publishes
# for consumers (ghostty-org/ghostty 90b706b97, PR #12149) and checked against
# a SHA-256 recorded here. That is the only check this script makes. Ghostty's
# signature over the zip is published only while the build is the tip, so it
# is kept beside this script as ghostty-vt-<commit>.xcframework.zip.minisig.
# Bump GHOSTTY_COMMIT and GHOSTTY_VT_SHA256 together, and replace or remove
# that signature. The whole story: docs/architecture.md, "The libghostty-vt
# dependency".
#
#   scripts/fetch-ghostty-vt.sh   # -> app/Vendor/ghostty-vt.xcframework
set -euo pipefail

GHOSTTY_COMMIT="33da6848d63b3bba2b4f31ab1531d618f2795192"
GHOSTTY_VT_SHA256="46f774e2e3affcc880af36f0b1a9eda7bb6e585b123f8ad5ccf4a3caf10cb4dc"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/app/Vendor"
FRAMEWORK="$VENDOR/ghostty-vt.xcframework"
STAMP="$VENDOR/.ghostty-vt-commit"
URL="https://tip.files.ghostty.org/$GHOSTTY_COMMIT/ghostty-vt.xcframework.zip"

if [ -d "$FRAMEWORK" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$GHOSTTY_COMMIT" ]; then
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> fetching libghostty-vt @ ${GHOSTTY_COMMIT:0:12}"
curl -fsSL --retry 3 -o "$tmp/ghostty-vt.xcframework.zip" "$URL"

actual="$(shasum -a 256 "$tmp/ghostty-vt.xcframework.zip" | cut -d' ' -f1)"
[ "$actual" = "$GHOSTTY_VT_SHA256" ] || {
  echo "FATAL: ghostty-vt.xcframework.zip sha256 $actual != pinned $GHOSTTY_VT_SHA256" >&2
  exit 1
}

unzip -q "$tmp/ghostty-vt.xcframework.zip" -d "$tmp"
mkdir -p "$VENDOR"
rm -rf "$FRAMEWORK"
mv "$tmp/ghostty-vt.xcframework" "$FRAMEWORK"
echo "$GHOSTTY_COMMIT" > "$STAMP"
echo "==> staged $FRAMEWORK"
