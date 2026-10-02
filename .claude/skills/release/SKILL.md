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

**Pre-flight — sync `main` before you build.** A tree behind `origin/main` ships
stale bits while git history still looks complete. Make sure local HEAD contains
`origin/main` first:

```
git fetch origin && git merge-base --is-ancestor origin/main HEAD \
  || { echo "HEAD is behind origin/main — rebase before releasing" >&2; exit 1; }
```

`scripts/bundle.sh` enforces the same check at build time, so a stale release
can't ship — but sync here to catch it up front.

1. **Bump the version — three files end up in the release commit.**
   Hand-edit `version` to `x.y.z` in **one** file:
   - `packaging/Casks/tarmac.rb` — version now; the `sha256` is filled in at step 4.

   The rest is stamped for you:
   - **`core/Cargo.toml`** — `release.sh` step 0 `sed`s `VERSION` into the workspace
     version, idempotently, so the daemon's `CARGO_PKG_VERSION` is the shipped
     version. `make release` leaves it modified in the working tree — it **MUST go
     in the release commit** (with `core/Cargo.lock`), else HEAD keeps the previous
     version and the committed tree won't match what shipped.
   - **The bundle's `Info.plist`** — `scripts/bundle.sh` copies
     `packaging/Info.plist` into the bundle and stamps `CFBundleShortVersionString`
     and `CFBundleVersion` from `VERSION`. The committed plist keeps its `0.0.0`
     placeholders; never edit it for a release.

   The app sends its bundle version as `hello.app_version` and replaces any daemon
   whose `CARGO_PKG_VERSION` differs. Both come from the one `VERSION`, which is
   what makes the daemon auto-restart-on-version-mismatch check fire across
   upgrades — and only across upgrades.

2. **Pre-build fixups (easy to forget; each fails the build):**
   - **Refresh the Cargo lockfile — but stamp `core/Cargo.toml` first.** The release
     build passes `--locked`, and `release.sh` step 0 bumps the Cargo.toml version
     without touching the lock → build dies with
     `cannot update the lock file ... --locked was passed`. A `cargo build` only
     rewrites a lock to whatever the toml *currently* says, so refreshing before the
     stamp just re-writes the **old** version and the build still dies. Apply step 0's
     own sed yourself, then build:
     ```
     sed -i '' "s/^version = \".*\"/version = \"x.y.z\"/" core/Cargo.toml
     (cd core && cargo build --offline)
     ```
     `release.sh` re-applies the same sed later, so pre-stamping is a no-op for it.
     Verify with `grep -A1 'name = "tarmacd"' core/Cargo.lock` before `make release`.
     Commit the lock. *(If `release.sh` ever learns to stamp the lock itself, drop
     this.)*
   - **The pinned libghostty-vt must be staged.** `scripts/bundle.sh` runs
     `scripts/fetch-ghostty-vt.sh`, a no-op once `app/Vendor/` holds the pinned
     commit and a download (checked against a recorded SHA-256) otherwise. Run
     `make ghostty-vt` up front if the release machine may be offline.

3. **Build, sign, notarize, staple.** Don't kill any daemon first — the build only
   compiles binaries, it never binds the socket, and `pkill -f tarmacd` would take
   down the user's *installed* Tarmac. (If a dev daemon ever genuinely needs to go,
   `make kill-daemon` is socket-scoped to this worktree.)
   ```
   DEVID_IDENTITY="…" NOTARY_PROFILE="…" VERSION=x.y.z make release
   ```
   Run from the **repo root** (Bash cwd persists between calls — a prior `cd` into a
   crate dir will make `make` say "No rule to make target `release`"). Notarization
   pushes this well past a 2-minute command timeout — run it **in the background**,
   teeing to a log you can grep the sha256 out of. `scripts/release.sh` calls
   `scripts/bundle.sh` — the Rust release binaries, the Swift release build of the
   app, and `dist/Tarmac.app` assembled from them with the app's resources
   flattened into `Contents/Resources` — then signs inside-out, builds and
   notarizes `dist/Tarmac-x.y.z.dmg`, staples it, and **prints the sha256**.

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
   - **Do not launch it to "see if it runs".** `dist/Tarmac.app` and the mounted
     copy are release builds: unpinned they attach to your *installed* Tarmac's
     daemon and, the version being new, SIGTERM and replace it — every terminal
     you have open dies. If a launch check is wanted, pin a scratch channel:
     ```
     d=$(mktemp -d) && TARMAC_SOCKET="$d/tarmacd.sock" TARMAC_STATE="$d/state.json" \
       dist/Tarmac.app/Contents/MacOS/tarmac-app
     ```
     then stop that daemon by its socket (`lsof -t "$d/tarmacd.sock"`), never by name.

5. **Commit + PR the main repo** (3 files: `packaging/Casks/tarmac.rb`,
   `core/Cargo.toml`, `core/Cargo.lock`).
   `main` is protected (PR-only, 0 approvals → self-merge; no direct/force push):
   ```
   git switch -c release-x.y.z
   git add <the 3 files>
   git commit -s -F <msg>            # subject: "release: x.y.z — <summary>"
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

- **An Xcode update resets its license acceptance**, and then every Rust link fails
  at step 2's `cargo build` (and `swift build` with it): `linking with cc failed:
  exit status: 69` / "You have not agreed to the Xcode license agreements". The
  fix is
  `sudo xcodebuild -license accept`, run by the user in their **own** terminal
  (Terminal.app or a Tarmac terminal). The `!` prompt has no TTY, so sudo there
  fails with "a terminal is required to read the password".
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
  **After either path, verify — don't assume it landed:** `gh pr view <n> --json
  state,mergedAt --repo <owner>/<repo>`. The user's own `gh pr merge` can leave the
  PR `OPEN` while an identical retry goes through, so if `state` still comes back
  `OPEN`, retry the merge yourself once before reporting a block.
- Squash-merge yields the repo's `<title> (#N)` convention. Commit subject is
  `release: x.y.z — <summary>` (bare `release:` type, per the repo's history).
- The Rust workspace version tracks the release version (step 1); don't reset it.
- **The libghostty-vt pin is not a release-time decision.** `GHOSTTY_COMMIT` and
  `GHOSTTY_VT_SHA256` in `scripts/fetch-ghostty-vt.sh` move together, in their own
  change with `make test` green — its C API is unstable, so never bump it while
  cutting a release.
