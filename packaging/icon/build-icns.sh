#!/bin/sh
# Regenerate packaging/Tarmac.icns from AppIcon.iconset.
#
# The iconset here already uses the real "@2x" filenames iconutil expects, so
# this is a straight compile — no rename dance. scripts/bundle.sh copies the
# resulting Tarmac.icns into Tarmac.app/Contents/Resources (CFBundleIconFile).
#
# Source masters live alongside: Tarmac.svg (full-bleed vector) and
# Tarmac-1024.png (raster master with macOS padding + contact shadow).
set -e
cd "$(dirname "$0")"

iconutil -c icns AppIcon.iconset -o ../Tarmac.icns
echo "✓ Wrote packaging/Tarmac.icns"
