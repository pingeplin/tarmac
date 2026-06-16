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

  version "0.3.0"
  sha256 "b93c611b91008a40beccecdbde81d97cc32da636bed9ed15f2d314f5adf0e8ce"

  url "https://github.com/pingeplin/tarmac/releases/download/v#{version}/Tarmac-#{version}.dmg"
  name "Tarmac"
  desc "Whiteboard cockpit for terminals and docs"
  homepage "https://github.com/pingeplin/tarmac"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Tarmac.app"
  # The standalone universal CLI shipped at the .dmg root (NOT a path inside the
  # bundle — in-bundle symlink targets can need a shim). Symlinked onto PATH so
  # `tarmac open` works from any shell.
  binary "tarmac"

  zap trash: [
    "~/Library/Application Support/tarmac",
  ]
end
