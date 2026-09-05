# Homebrew cask for Tarmac.
#
# This file is the SOURCE OF TRUTH; at release time it is copied to the tap repo
# (github.com/pingeplin/homebrew-tarmac → Casks/tarmac.rb) where users install
# it. The repo MUST be named homebrew-tarmac: `brew install <user>/<tap>/<cask>`
# resolves the tap to github.com/<user>/homebrew-<tap>, so homebrew-tarmac is
# what makes this line work:
#
#     brew install pingeplin/tarmac/tarmac
#
# Per release, bump `version` and `sha256` (the .dmg's shasum -a 256, printed by
# scripts/release.sh). arm64-only for the first ship — the arch guard gives
# Intel users a clear message instead of a broken install.
cask "tarmac" do
  arch arm: "arm64"

  version "0.9.0"
  sha256 "dcbd855062c5f4294aecee7d41f116281d80b892bd1b2e19d91adda355c660fb"

  url "https://github.com/pingeplin/tarmac/releases/download/v#{version}/Tarmac-#{version}.dmg"
  name "Tarmac"
  desc "Whiteboard cockpit for terminals and docs"
  homepage "https://github.com/pingeplin/tarmac"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  # Tahoe (26), not Sonoma: doc/HTML cards freeze their layout with CSS `zoom`,
  # which older field WebKit no-ops entirely — cards would render at 1/K size.
  # Standardized `zoom` ships ~Safari 26.4; 17.4 is a verified no-op and the
  # range between them was never tested. See desktop/qa/one-x-display-crispness.md.
  depends_on macos: :tahoe

  app "Tarmac.app"
  # The standalone universal CLI shipped at the .dmg root (NOT a path inside the
  # bundle — in-bundle symlink targets can need a shim). Symlinked onto PATH so
  # `tarmac open` works from any shell.
  binary "tarmac"

  zap trash: [
    "~/Library/Application Support/tarmac",
  ]
end
