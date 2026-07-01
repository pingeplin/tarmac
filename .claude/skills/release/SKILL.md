---
name: release
description: Cut a notarized Tarmac macOS release — bump versions, build/sign/notarize/staple the .dmg, publish the GitHub release, and update the Homebrew tap. Use when the user says "release a new version", "cut a release", "ship vX.Y.Z", "publish a release", "bump the version and release", or "update the homebrew cask".
---

# /release [x.y.z] — cut a notarized macOS release

Ship Tarmac as a notarized `.dmg` on GitHub Releases (`pingeplin/tarmac`) plus a
self-hosted Homebrew cask in the tap repo `pingeplin/homebrew-tarmac`. Install
line: `brew install pingeplin/tarmac/tarmac`. **arm64-only** for now (no
x86_64 toolchain; universal is a fast-follow). Design: `docs/designs/2606.0002_*`.

`x.y.z` is the new version. If omitted, look at `git tag` + commits since the
last tag and propose the bump (feat → minor, fix-only → patch) — confirm with the
user before doing anything irreversible (signing/notarizing/publishing).

## Credentials (NOT in this repo)

This skill is git-tracked, so secrets live elsewhere — pull them from the
`macos-release-runbook` memory / 1Password at run time, don't hard-code them here.
You need, as env vars for `make release`:
- `DEVID_IDENTITY` — the `Developer ID Application: …` signing identity.
- `NOTARY_PROFILE` — the `notarytool` keychain profile name (its app-specific
  password lives in 1Password). First `codesign` of a release may pop a keychain
  prompt for the Developer ID key — the user should click **Always Allow**.

## Steps

1. **Bump the version — eight files end up in the release commit.**
   Hand-edit `version` to `x.y.z` in **three** files:
   - `desktop/src-tauri/tauri.conf.json` — Tauri stamps this into the bundle; the
     authoritative embedded version. (`packaging/Info.plist` is gone — Tauri
     generates Info.plist from this.)
   - `desktop/package.json` — then regenerate the lockfile:
     `(cd desktop && npm install --package-lock-only)`.
   - `packaging/Casks/tarmac.rb` — version now; the `sha256` is filled in at step 4.

   The **two Rust crate versions are auto-stamped, not hand-edited**: `release.sh`
   step 0 `sed`s `VERSION` into `core/Cargo.toml` and `desktop/src-tauri/Cargo.toml`
   so `CARGO_PKG_VERSION` matches the shipped version (this is what makes the daemon
   auto-restart-on-version-mismatch check fire across upgrades). `make release`
   leaves them modified in the working tree — they **MUST go in the release commit**,
   else HEAD keeps the old `0.1.0`, the committed tree won't match what shipped, and
   the version check silently breaks again.

2. **Pre-build fixups (both are easy to forget and fail the build):**
   - **Refresh the Cargo lockfiles.** The release build passes `--locked`, but
     step-0's `sed` bumps the Cargo.toml versions without touching the locks → build
     dies with `cannot update the lock file ... --locked was passed`. Run
     `(cd core && cargo build --offline)` and
     `(cd desktop/src-tauri && cargo build --offline)` to rewrite the workspace-crate
     version entries in `core/Cargo.lock` and `desktop/src-tauri/Cargo.lock`. Commit
     both. *(If `release.sh` ever learns to stamp the locks itself, drop this.)*
   - **Full `npm install` if a release added a frontend dep.** `--package-lock-only`
     rewrites the lockfile but NOT `node_modules`; a missing dep (e.g.
     `@xterm/addon-webgl`) makes the Tauri `npm run build` fail with
     `Cannot find module …`. Run a full `(cd desktop && npm install)`.

3. **Build, sign, notarize, staple.** Kill any stray daemon first
   (`pkill -f tarmacd`), then:
   ```
   DEVID_IDENTITY="…" NOTARY_PROFILE="…" VERSION=x.y.z make release
   ```
   Run from the **repo root** (Bash cwd persists between calls — a prior `cd` into a
   crate dir will make `make` say "No rule to make target `release`"). This builds
   (Tauri + Rust sidecars), signs inside-out, notarizes, staples
   `dist/Tarmac-x.y.z.dmg`, and **prints the sha256**. `release.sh` warns if
   `$VERSION` ≠ `tauri.conf.json` version — keep them in sync.

4. **Update the cask sha256** in `packaging/Casks/tarmac.rb` with the printed value,
   then verify locally:
   - `shasum -a 256 dist/Tarmac-x.y.z.dmg` matches.
   - `xcrun stapler validate dist/Tarmac-x.y.z.dmg` → "The validate action worked!"
     (the ticket staples to the **dmg**, not the app).
   - Mount and assess the actual app — this is the real Gatekeeper verdict; the dmg
     itself is unsigned so `spctl -t install` on it says "no usable signature":
     ```
     hdiutil attach dist/Tarmac-x.y.z.dmg -nobrowse -readonly
     spctl -a -t exec -vvv /Volumes/Tarmac/Tarmac.app   # expect: accepted, Notarized Developer ID
     hdiutil detach /Volumes/Tarmac
     ```

5. **Commit + PR the main repo** (8 files: `tauri.conf.json`, `package.json`,
   `package-lock.json`, `packaging/Casks/tarmac.rb`, `core/Cargo.toml`,
   `core/Cargo.lock`, `desktop/src-tauri/Cargo.toml`, `desktop/src-tauri/Cargo.lock`).
   `main` is protected (PR-only, 0 approvals → self-merge; no direct/force push):
   ```
   git switch -c release-x.y.z
   git add <the 8 files>
   git commit -F <msg>            # subject: "release: x.y.z — <summary>"
   git push https://github.com/pingeplin/tarmac.git release-x.y.z   # HTTPS, see SSH note
   gh pr create --base main --head release-x.y.z --title '…' --body-file <f>
   gh pr merge release-x.y.z --squash --delete-branch
   ```

6. **Publish the GitHub release** (sync local `main` first):
   ```
   git switch main && git pull https://github.com/pingeplin/tarmac.git main
   gh release create vx.y.z dist/Tarmac-x.y.z.dmg --target main --title vx.y.z --notes-file <f>
   ```

7. **PR the cask into the tap repo** `pingeplin/homebrew-tarmac` (also protected):
   clone it, copy the repo's source-of-truth cask over the tap's
   (`git show main:packaging/Casks/tarmac.rb > <tap>/Casks/tarmac.rb` — they should
   differ only in version + sha256), branch → commit → HTTPS push →
   `gh pr create --repo pingeplin/homebrew-tarmac …` → `gh pr merge … --repo pingeplin/homebrew-tarmac --squash --delete-branch`.

8. **Verify end-to-end.** Download the published artifact and re-check it:
   ```
   curl -sL -o /tmp/pub.dmg https://github.com/pingeplin/tarmac/releases/download/vx.y.z/Tarmac-x.y.z.dmg
   shasum -a 256 /tmp/pub.dmg     # must equal the step-3 sha256
   curl -sL https://raw.githubusercontent.com/pingeplin/homebrew-tarmac/main/Casks/tarmac.rb | grep -E 'version|sha256'
   ```
   `brew upgrade pingeplin/tarmac/tarmac` now serves the new version.

## Gotchas

- **SSH-agent fails in Claude Code's non-interactive shell** ("communication with
  agent failed") — but only for raw `git push`/`git fetch`, NOT `gh` API ops. Push
  branches over **HTTPS** (`gh auth setup-git` once, then
  `git push https://github.com/<owner>/<repo>.git <branch>`); `gh pr create` /
  `gh pr merge` / `gh release create` work over the token unchanged. The user's own
  terminal SSH is fine.
- **The auto-classifier blocks `gh pr merge` on a self-authored PR**, and treats
  approval as scoped to ONE repo. Expect to pause for **two separate approvals** —
  once for the main-repo PR, once for the `homebrew-tarmac` tap PR — or have the
  user run the `gh pr merge … --squash --delete-branch` themselves.
- Squash-merge yields the repo's `<title> (#N)` convention. Commit subject is
  `release: x.y.z — <summary>` (bare `release:` type, per the repo's history).
- The Rust crate version was historically frozen at `0.1.0`; since #46 it tracks the
  release. Don't "fix" it back.
