#!/bin/bash
# Cut a whole release from this Mac: build + notarize the .dmg (scripts/dmg.sh),
# land the version bump on main, publish the GitHub release, update the Homebrew
# tap, and check what users will download. Local only by design — the Developer
# ID key and the notarytool profile never leave the login keychain.
#
# Usage, from a clean main level with origin/main:
#   DEVID_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="tarmac-notary" \
#   VERSION=1.2.3 SUMMARY="what this release is" \
#   scripts/release.sh
#
# SUMMARY (optional) finishes the commit subject `release: x.y.z — …`.
# NOTES_FILE (optional) replaces the generated release notes.
#
# Every step first asks GitHub whether it already landed, so a failed run is
# resumed by running the same command again. A notarized .dmg is never rebuilt
# while the sources it was built from are unchanged: its sha256 is what the
# cask pins, and a rebuild would not reproduce it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="pingeplin/tarmac"
TAP="pingeplin/homebrew-tarmac"
FORMULA="pingeplin/tarmac/tarmac"
CASK="packaging/Casks/tarmac.rb"
RELEASE_FILES=("$CASK" core/Cargo.toml core/Cargo.lock)
EVERYTHING_ELSE=(. ":(exclude)$CASK" ":(exclude)core/Cargo.toml" ":(exclude)core/Cargo.lock")

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

CLEANUP=()
cleanup() { local c; for c in ${CLEANUP[@]+"${CLEANUP[@]}"}; do eval "$c" || true; done; }

# HTTPS with gh's token: an ssh remote needs an agent, which a non-interactive
# shell often cannot reach.
ghgit() { git -c credential.helper= -c credential.helper='!gh auth git-credential' "$@"; }
repo_url() { echo "https://github.com/$1.git"; }

sync_origin() {
  ghgit -C "$ROOT" fetch --quiet --tags "$(repo_url "$REPO")" '+refs/heads/main:refs/remotes/origin/main'
}

cask_field() { sed -n "s/^  $1 \"\(.*\)\"/\1/p" | head -1; }
main_cask() { git -C "$ROOT" show origin/main:"$CASK"; }
dmg_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
# "false" once published, "true" for a draft, empty when there is none.
release_draft_state() { gh release view "v$VERSION" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null || true; }

stamp_cask() {
  sed -i '' -e "s/^  version \".*\"/  version \"$2\"/" -e "s/^  sha256 \".*\"/  sha256 \"$3\"/" "$1"
  [ "$(cask_field version < "$1")" = "$2" ] && [ "$(cask_field sha256 < "$1")" = "$3" ] \
    || die "could not stamp version and sha256 into $1"
}

# The commits a release carries: everything since the tag before <ref>.
changes() {
  local prev
  prev="$(git -C "$ROOT" describe --tags --abbrev=0 "$1" 2>/dev/null || true)"
  git -C "$ROOT" log --format='- %s' ${prev:+"$prev.."}"$1" | grep -v '^- release:' || true
}

# Only the build reads the working tree; every later step works from origin/main.
require_releasable_tree() {
  local branch dirty
  branch="$(git -C "$ROOT" branch --show-current)"
  [ "$branch" = main ] || [ "$branch" = "$BRANCH" ] || die "on '$branch' — release from main"
  dirty="$(git -C "$ROOT" status --porcelain -- "${EVERYTHING_ELSE[@]}")"
  [ -z "$dirty" ] || die "working tree has changes outside the release files:
$dirty"
  git -C "$ROOT" merge-base --is-ancestor origin/main HEAD \
    || die "HEAD is behind origin/main — switch to main, fast-forward it, and run again"
  [ "$branch" != main ] || [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] \
    || die "main has commits origin/main does not"
}

# True when dist/ holds a stapled dmg built from this tree, release files aside,
# and the tree still carries the version dmg.sh stamped for it.
dmg_is_current() {
  [ -f "$DMG" ] && [ -f "$DMG.src" ] || return 1
  grep -q "^version = \"$VERSION\"\$" "$ROOT/core/Cargo.toml" || return 1
  grep -A1 '^name = "tarmacd"$' "$ROOT/core/Cargo.lock" | grep -q "^version = \"$VERSION\"\$" || return 1
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || return 1
  git -C "$ROOT" diff --quiet "$(cat "$DMG.src")" -- "${EVERYTHING_ELSE[@]}"
}

build_dmg() {
  if dmg_is_current; then
    say "reusing the notarized $DMG"
    return
  fi
  local src
  src="$(git -C "$ROOT" rev-parse HEAD)"
  VERSION="$VERSION" "$ROOT/scripts/dmg.sh"
  echo "$src" > "$DMG.src"
}

# The real Gatekeeper verdict is on the app inside: the ticket staples to the
# dmg, and the dmg itself carries no signature to assess.
assess_dmg() {
  say "Gatekeeper assessment"
  local mnt verdict
  mnt="$(mktemp -d "${TMPDIR:-/tmp}/tarmac-mnt.XXXXXX")"
  CLEANUP+=("hdiutil detach -quiet '$mnt'; rmdir '$mnt'")
  hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$mnt" >/dev/null \
    || die "could not mount $DMG — eject any mounted copy of it"
  verdict="$(spctl -a -t exec -vvv "$mnt/Tarmac.app" 2>&1)" || die "Gatekeeper rejected the app:
$verdict"
  grep -q 'source=Notarized Developer ID' <<<"$verdict" || die "not a notarized Developer ID app:
$verdict"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mnt/Tarmac.app/Contents/Info.plist")" = "$VERSION" ] \
    || die "the app in $DMG is not version $VERSION"
}

open_pr() { gh pr list --repo "$1" --head "$BRANCH" --state open --json number -q '.[0].number // empty'; }

# Creates the PR for $BRANCH unless one is open; prints its number either way.
ensure_pr() {
  local pr url
  pr="$(open_pr "$1")"
  if [ -z "$pr" ]; then
    url="$(gh pr create --repo "$1" --base main --head "$BRANCH" --title "$2" --body "$3")" || return 1
    pr="${url##*/}"
  fi
  [ -n "$pr" ] && echo "$pr"
}

wait_for_checks() {
  local tries=0
  while [[ "$(gh pr checks "$1" --repo "$REPO" 2>&1 || true)" == *'no checks reported'* ]]; do
    tries=$((tries + 1))
    [ "$tries" -lt 24 ] || die "no checks appeared on #$1"
    sleep 5
  done
  gh pr checks "$1" --repo "$REPO" --watch --fail-fast --interval 15 >/dev/null || die "checks failed on #$1"
}

merge_pr() {
  gh pr merge "$2" --repo "$1" --squash --delete-branch || return 1
  [ "$(gh pr view "$2" --repo "$1" --json state -q .state)" = MERGED ]
}

settle_on_main() {
  git -C "$ROOT" switch --quiet main \
    && git -C "$ROOT" merge --quiet --ff-only origin/main \
    && { git -C "$ROOT" branch --quiet -D "$BRANCH" 2>/dev/null || true; }
}

# The branch is rebuilt from this tree and force-pushed every run, so an open
# PR from an earlier attempt can never land a sha256 other than this dmg's.
land_bump() {
  local subject="release: $VERSION${SUMMARY:+ — $SUMMARY}" body pr attempt=0
  body="$(changes HEAD)"
  say "release PR"
  git -C "$ROOT" switch --quiet -C "$BRANCH"
  git -C "$ROOT" add -- "${RELEASE_FILES[@]}"
  git -C "$ROOT" diff --cached --quiet || git -C "$ROOT" commit --quiet -s -m "$subject" ${body:+-m "$body"}
  ghgit -C "$ROOT" push --quiet --force "$(repo_url "$REPO")" "$BRANCH"
  pr="$(ensure_pr "$REPO" "$subject" "${body:-$subject}")" || die "could not open the release PR"
  # A check that registers late is invisible to the first wait; the merge then
  # refuses, and the next wait sees it.
  until wait_for_checks "$pr" && merge_pr "$REPO" "$pr"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || die "$REPO#$pr did not merge"
    sleep 10
  done
  sync_origin
  settle_on_main || die "merged, but the local main could not be fast-forwarded"
}

publish_release() {
  say "GitHub release v$VERSION"
  local notes="${NOTES_FILE:-}" bump
  # The commit the dmg was built for, not whatever has merged since.
  bump="$(git -C "$ROOT" log -1 --format=%H origin/main -- "$CASK")"
  if [ -z "$notes" ]; then
    notes="$(mktemp "${TMPDIR:-/tmp}/tarmac-notes.XXXXXX")"
    CLEANUP+=("rm -f '$notes'")
    {
      changes "$bump"
      printf '\nInstall or upgrade: `brew install %s` · `brew upgrade %s`\n' "$FORMULA" "$FORMULA"
      printf '\narm64 only. sha256: `%s`\n' "$(dmg_sha "$DMG")"
    } > "$notes"
  fi
  [ "$(main_cask | cask_field sha256)" = "$(dmg_sha "$DMG")" ] || die "origin/main does not pin $DMG"
  # An upload that was cut short leaves a draft holding the tag.
  [ "$(release_draft_state)" != true ] || gh release delete "v$VERSION" --repo "$REPO" --yes
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --target "$bump" \
    --title "v$VERSION" --notes-file "$notes"
}

update_tap() {
  say "Homebrew tap"
  local pr tap
  tap="$(mktemp -d "${TMPDIR:-/tmp}/tarmac-tap.XXXXXX")"
  CLEANUP+=("rm -rf '$tap'")
  ghgit clone --quiet --depth 1 "$(repo_url "$TAP")" "$tap"
  main_cask > "$tap/Casks/tarmac.rb"
  if git -C "$tap" diff --quiet; then
    echo "    the tap already serves $VERSION"
    return
  fi
  git -C "$tap" switch --quiet -c "$BRANCH"
  git -C "$tap" commit --quiet -s -am "tarmac $VERSION"
  ghgit -C "$tap" push --quiet --force "$(repo_url "$TAP")" "$BRANCH"
  pr="$(ensure_pr "$TAP" "tarmac $VERSION" "Bump the cask to [v$VERSION](https://github.com/$REPO/releases/tag/v$VERSION).")" \
    || die "could not open the tap PR"
  merge_pr "$TAP" "$pr" || die "$TAP#$pr did not merge"
}

# What a user gets: the published asset and the tap's cask, not local copies.
verify_published() {
  say "verifying what was published"
  local want got tapped pub
  want="$(main_cask | cask_field sha256)"
  pub="$(mktemp "${TMPDIR:-/tmp}/tarmac-pub.XXXXXX")"
  CLEANUP+=("rm -f '$pub'")
  curl -fsSL -o "$pub" "https://github.com/$REPO/releases/download/v$VERSION/Tarmac-$VERSION.dmg"
  got="$(dmg_sha "$pub")"
  [ "$got" = "$want" ] || die "published dmg is $got, the cask pins $want"
  tapped="$(gh api "repos/$TAP/contents/Casks/tarmac.rb" -H 'Accept: application/vnd.github.raw')"
  [ "$(cask_field version <<<"$tapped")" = "$VERSION" ] && [ "$(cask_field sha256 <<<"$tapped")" = "$want" ] \
    || die "the tap's cask does not pin $VERSION / $want"
  echo "    v$VERSION  sha256 $want"
}

main() {
  VERSION="${VERSION:?set VERSION to the version being released}"
  BRANCH="release-$VERSION"
  DMG="$ROOT/dist/Tarmac-$VERSION.dmg"
  trap cleanup EXIT

  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "VERSION '$VERSION' is not x.y.z"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
  sync_origin
  if [ "$(release_draft_state)" = false ]; then
    say "v$VERSION is already published"
  else
    if [ "$(main_cask | cask_field version)" = "$VERSION" ]; then
      say "the version bump is already on main"
      [ -f "$DMG" ] && [ "$(dmg_sha "$DMG")" = "$(main_cask | cask_field sha256)" ] \
        || die "main pins a dmg that is not in dist/ — it cannot be rebuilt byte for byte; release a new version"
      settle_on_main || echo "WARNING: could not bring the local main up to origin/main" >&2
    else
      require_releasable_tree
      build_dmg
      stamp_cask "$ROOT/$CASK" "$VERSION" "$(dmg_sha "$DMG")"
      assess_dmg
      land_bump
    fi
    publish_release
  fi
  [ "$(main_cask | cask_field version)" = "$VERSION" ] || die "main's cask is not at $VERSION"
  update_tap
  verify_published
  say "released v$VERSION"
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
