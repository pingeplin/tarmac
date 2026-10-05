---
name: release
description: Cut a notarized Tarmac macOS release — bump versions, build/sign/notarize/staple the .dmg, publish the GitHub release, and update the Homebrew tap. Use when the user says "release a new version", "cut a release", "ship vX.Y.Z", "publish a release", "bump the version and release", or "update the homebrew cask".
---

# /release [x.y.z] — cut a notarized macOS release

Ship Tarmac as a notarized `.dmg` on GitHub Releases (`pingeplin/tarmac`) plus a
self-hosted Homebrew cask in the tap repo `pingeplin/homebrew-tarmac`. Install
line: `brew install pingeplin/tarmac/tarmac`. **arm64-only** for now (no
x86_64 toolchain; universal is a fast-follow). Design: `docs/designs/2606.0002_*`.

The whole release is **one command, run on the maintainer's Mac** —
`scripts/release.sh`. There is no CI release workflow on purpose: the Developer
ID key and the notarytool profile stay in the login keychain. This skill is what
to decide before running it and what to do when a step fails.

## Before running

- **Version.** If `x.y.z` is omitted, look at `git tag` + commits since the last
  tag and propose the bump (feat → minor, fix-only → patch). Confirm it with the
  user — the command publishes, and nothing after it asks again.
- **Summary.** One short phrase for the commit subject
  `release: x.y.z — <summary>`.
- **Tree.** A fresh release starts from a clean `main`, level with
  `origin/main`. A resumed one may sit on `release-x.y.z` with the three release
  files stamped. The script refuses anything else.

## Credentials (NOT in this repo)

This skill is git-tracked, so secrets live elsewhere — pull them from the
`macos-release-runbook` memory / 1Password at run time, don't hard-code them here.
- `DEVID_IDENTITY` — the `Developer ID Application: …` signing identity.
- `NOTARY_PROFILE` — the `notarytool` keychain profile name (its app-specific
  password lives in 1Password). First `codesign` of a release may pop a keychain
  prompt for the Developer ID key — the user should click **Always Allow**.

## Run

```
DEVID_IDENTITY="…" NOTARY_PROFILE="…" VERSION=x.y.z SUMMARY="…" make release
```

From the **repo root**, **in the background**, teeing to a log: notarization and
the PR's CI push it well past a 2-minute command timeout. `NOTES_FILE=<path>`
replaces the generated release notes (the commit subjects since the last tag).

What it does, in order — each step is skipped when GitHub shows it already landed:

1. **Build** — `scripts/dmg.sh`: stamps `VERSION` into `core/Cargo.toml` +
   `Cargo.lock`, runs `scripts/bundle.sh` (which stamps the bundle's
   `Info.plist`; the committed plist keeps its `0.0.0` placeholders), signs
   inside-out, builds, notarizes and staples `dist/Tarmac-x.y.z.dmg`.
2. **Cask** — stamps `version` + `sha256` into `packaging/Casks/tarmac.rb`.
3. **Gatekeeper** — mounts the dmg and requires
   `spctl -a -t exec` → `Notarized Developer ID` on the app inside, at version
   `x.y.z`.
4. **Release PR** — branch `release-x.y.z` rebuilt from this tree, the three
   files (cask, `core/Cargo.toml`, `core/Cargo.lock`), signed-off commit, HTTPS
   force-push, PR (an open one is reused), waits for the checks, squash-merges,
   fast-forwards local `main`.
5. **GitHub release** — `vx.y.z` on the bump commit, with the dmg. A draft left
   by an interrupted upload is replaced.
6. **Tap** — PRs the committed cask into `pingeplin/homebrew-tarmac`, merges it.
7. **Verify** — downloads the published dmg and compares its sha256 with the
   cask on `main` and the cask in the tap.

It ends on `==> released vx.y.z`. Anything else is a failed step: read the
`FATAL:` line, fix the cause, and **run the same command again, from where it
stopped** — it resumes. Going back to a clean `main` first also works, but
un-stamps `core/Cargo.toml`, so the dmg is rebuilt and notarized again.

`make dmg` (same variables, no `SUMMARY`) runs step 1 alone and publishes nothing.

## When a step fails

- **Never rebuild a dmg whose sha256 is already on `main`.** A rebuild does not
  reproduce the bytes. The script reuses the stapled dmg in `dist/` while the
  sources are unchanged (`dist/Tarmac-x.y.z.dmg.src` records the commit it was
  built from), and refuses to go on if `main` pins a dmg that is no longer in
  `dist/` — then the way out is a new version.
- **Do not launch the result to "see if it runs".** `dist/Tarmac.app` and a
  mounted copy are release builds: unpinned they attach to the *installed*
  Tarmac's daemon and, the version being new, SIGTERM and replace it — every
  open terminal dies. If a launch check is wanted, pin a scratch channel:
  ```
  d=$(mktemp -d) && TARMAC_SOCKET="$d/tarmacd.sock" TARMAC_STATE="$d/state.json" \
    dist/Tarmac.app/Contents/MacOS/tarmac-app
  ```
  then stop that daemon by its socket (`lsof -t "$d/tarmacd.sock"`), never by name.
- **Don't kill any daemon before building** — the build only compiles binaries,
  and `pkill -f tarmacd` would take down the user's installed Tarmac.
  `make kill-daemon` is the socket-scoped one, if a dev daemon must go.
- **`WARNING: could not fetch origin` from `bundle.sh`** is its own freshness
  check being skipped over an unreachable ssh remote. `release.sh` has already
  made the same check over HTTPS before the build, so the release is still safe;
  under a bare `make dmg` it is not — check
  `git merge-base --is-ancestor origin/main HEAD` yourself.
- **An Xcode update resets its license acceptance**, and then every Rust link
  fails (`linking with cc failed: exit status: 69` / "You have not agreed to the
  Xcode license agreements"). The fix is `sudo xcodebuild -license accept`, run
  by the user in their **own** terminal — the `!` prompt has no TTY for sudo.
- **A 403 "required agreement is missing or has expired" from `notarytool`**
  means the account holder has an agreement to accept at developer.apple.com.
  After accepting, `notarytool history` recovered within minutes and `submit`
  some minutes after that. Then re-run the release.
- **An agent's `gh pr merge` on a self-authored PR can be stopped by the
  auto-mode classifier**, once per repo. When the script dies on
  `did not merge`, have the user run `gh pr merge <n> --repo <owner>/<repo>
  --squash --delete-branch`, check `gh pr view <n> --json state`, and re-run the
  release — it picks up from the merged PR.
- **A pre-release version works as a plain string.** `VERSION=1.14.0-beta` went
  through Cargo, the app↔daemon handshake, signing and notarization
  (2026-10-02), although Apple documents both bundle version keys as digits and
  periods only. Nothing in the repo parses the version.
- **The libghostty-vt pin is not a release-time decision.** `GHOSTTY_COMMIT` and
  `GHOSTTY_VT_SHA256` in `scripts/fetch-ghostty-vt.sh` move together, in their
  own change with `make test` green — never bump it while cutting a release.
- The Rust workspace version tracks the release version; don't reset it.
