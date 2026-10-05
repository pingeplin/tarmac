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
CASK="packaging/Casks/tarmac.rb"
RELEASE_FILES=("$CASK" core/Cargo.toml core/Cargo.lock)
EVERYTHING_ELSE=(.)
for f in "${RELEASE_FILES[@]}"; do EVERYTHING_ELSE+=(":(exclude)$f"); done

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }
cleanup() { hdiutil detach -quiet "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"; }

# HTTPS with gh's token: an ssh remote needs an agent, which a non-interactive
# shell often cannot reach.
ghgit() { git -c credential.helper= -c credential.helper='!gh auth git-credential' "$@"; }

sync_origin() {
  ghgit fetch --quiet --tags "https://github.com/$REPO" '+refs/heads/main:refs/remotes/origin/main'
}

cask_field() { sed -n "s/^  $1 \"\(.*\)\"/\1/p" | head -1; }
pinned() { git show origin/main:"$CASK" | cask_field "$1"; }
dmg_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
# "false" once published, "true" for a draft, empty when there is none.
release_draft_state() { gh release view "v$VERSION" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null || true; }

stamp_cask() {
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$1\"/" "$CASK"
  [ "$(cask_field version < "$CASK")" = "$VERSION" ] && [ "$(cask_field sha256 < "$CASK")" = "$1" ] \
    || die "could not stamp version and sha256 into $CASK"
}

# Everything since the tag before <ref>.
changes() {
  local prev
  prev="$(git describe --tags --abbrev=0 "$1" 2>/dev/null || true)"
  git log --format='- %s' ${prev:+"$prev.."}"$1" | grep -v '^- release:' || true
}

# Only the build reads the working tree; every later step works from origin/main.
require_releasable_tree() {
  local branch dirty
  branch="$(git branch --show-current)"
  [ "$branch" = main ] || [ "$branch" = "$BRANCH" ] || die "on '$branch' — release from main"
  dirty="$(git status --porcelain -- "${EVERYTHING_ELSE[@]}")"
  [ -z "$dirty" ] || die "working tree has changes outside the release files:
$dirty"
  git merge-base --is-ancestor origin/main HEAD \
    || die "HEAD is behind origin/main — switch to main, fast-forward it, and run again"
  [ "$branch" != main ] || [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "main has commits origin/main does not"
}

# True when dist/ holds a stapled dmg built from this tree, release files aside,
# and the tree still carries the version dmg.sh stamped for it.
dmg_is_current() {
  [ -f "$DMG" ] && [ -f "$DMG.src" ] || return 1
  grep -q "^version = \"$VERSION\"\$" core/Cargo.toml || return 1
  grep -A1 '^name = "tarmacd"$' core/Cargo.lock | grep -q "^version = \"$VERSION\"\$" || return 1
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || return 1
  git diff --quiet "$(cat "$DMG.src")" -- "${EVERYTHING_ELSE[@]}"
}

build_dmg() {
  if dmg_is_current; then
    say "reusing the notarized $DMG"
  else
    scripts/dmg.sh
  fi
}

# The real Gatekeeper verdict is on the app inside: the ticket staples to the
# dmg, and the dmg itself carries no signature to assess.
assess_dmg() {
  say "Gatekeeper assessment"
  local mnt="$WORK/mnt" verdict
  mkdir "$mnt"
  hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$mnt" >/dev/null \
    || die "could not mount $DMG — eject any mounted copy of it"
  verdict="$(spctl -a -t exec -vvv "$mnt/Tarmac.app" 2>&1)" || die "Gatekeeper rejected the app:
$verdict"
  grep -q 'source=Notarized Developer ID' <<<"$verdict" || die "not a notarized Developer ID app:
$verdict"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mnt/Tarmac.app/Contents/Info.plist")" = "$VERSION" ] \
    || die "the app in $DMG is not version $VERSION"
}

# Force-pushes $BRANCH from <dir> to <repo> and prints its PR's number, opening
# the PR unless an earlier run left one. Forced, so that PR can only ever carry
# this run's tree.
push_pr() {
  local dir="$1" repo="$2" title="$3" body="$4" pr url
  ghgit -C "$dir" push --quiet --force "https://github.com/$repo" "$BRANCH" || return 1
  pr="$(gh pr list --repo "$repo" --head "$BRANCH" --state open --json number -q '.[0].number // empty')"
  if [ -z "$pr" ]; then
    url="$(gh pr create --repo "$repo" --base main --head "$BRANCH" --title "$title" --body "$body")" || return 1
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

land_bump() {
  local subject="release: $VERSION${SUMMARY:+ — $SUMMARY}" body pr attempt=0
  body="$(changes HEAD)"
  say "release PR"
  git switch --quiet -C "$BRANCH"
  git add -- "${RELEASE_FILES[@]}"
  git diff --cached --quiet || git commit --quiet -s -m "$subject" ${body:+-m "$body"}
  pr="$(push_pr . "$REPO" "$subject" "${body:-$subject}")" || die "could not open the release PR"
  # A check that registers late is invisible to the first wait; the merge then
  # refuses, and the next wait sees it.
  until wait_for_checks "$pr" && merge_pr "$REPO" "$pr"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || die "$REPO#$pr did not merge"
    sleep 10
  done
  sync_origin
}

# The cask on origin/main naming this version is the point of no return: from
# there the dmg in dist/ is the only one that can ship.
ensure_bump_landed() {
  if [ "$(pinned version)" = "$VERSION" ]; then
    say "the version bump is already on main"
    return
  fi
  require_releasable_tree
  build_dmg
  stamp_cask "$(dmg_sha "$DMG")"
  assess_dmg
  land_bump
}

publish_release() {
  say "GitHub release v$VERSION"
  local sha bump notes
  [ -f "$DMG" ] && sha="$(dmg_sha "$DMG")" && [ "$sha" = "$(pinned sha256)" ] \
    || die "main pins a dmg that is not in dist/ — it cannot be rebuilt byte for byte; release a new version"
  # The commit the dmg was built for, not whatever has merged since.
  bump="$(git log -1 --format=%H origin/main -- "$CASK")"
  if [ -n "${NOTES_FILE:-}" ]; then
    notes="$(cat "$NOTES_FILE")"
  else
    notes="$(changes "$bump")

Install or upgrade: \`brew install pingeplin/tarmac/tarmac\` · \`brew upgrade pingeplin/tarmac/tarmac\`

arm64 only. sha256: \`$sha\`"
  fi
  # An upload that was cut short leaves a draft holding the tag.
  [ "$(release_draft_state)" != true ] || gh release delete "v$VERSION" --repo "$REPO" --yes
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --target "$bump" --title "v$VERSION" --notes "$notes"
}

update_tap() {
  say "Homebrew tap"
  local tap="$WORK/tap" pr
  ghgit clone --quiet --depth 1 "https://github.com/$TAP" "$tap"
  git show origin/main:"$CASK" > "$tap/Casks/tarmac.rb"
  if git -C "$tap" diff --quiet; then
    echo "    the tap already serves $VERSION"
    return
  fi
  git -C "$tap" switch --quiet -c "$BRANCH"
  git -C "$tap" commit --quiet -s -am "tarmac $VERSION"
  pr="$(push_pr "$tap" "$TAP" "tarmac $VERSION" \
    "Bump the cask to [v$VERSION](https://github.com/$REPO/releases/tag/v$VERSION).")" \
    || die "could not open the tap PR"
  merge_pr "$TAP" "$pr" || die "$TAP#$pr did not merge"
}

# What a user gets: the published asset and the tap's cask, not local copies.
verify_published() {
  say "verifying what was published"
  local want got tapped
  want="$(pinned sha256)"
  got="$(curl -fsSL "https://github.com/$REPO/releases/download/v$VERSION/Tarmac-$VERSION.dmg" | shasum -a 256 | awk '{print $1}')"
  [ "$got" = "$want" ] || die "published dmg is $got, the cask pins $want"
  tapped="$(gh api "repos/$TAP/contents/Casks/tarmac.rb" -H 'Accept: application/vnd.github.raw')"
  [ "$(cask_field version <<<"$tapped")" = "$VERSION" ] && [ "$(cask_field sha256 <<<"$tapped")" = "$want" ] \
    || die "the tap's cask does not pin $VERSION / $want"
  echo "    v$VERSION  sha256 $want"
}

# Nothing after the merge reads the checkout, so a tree that will not move is
# not a failed release.
settle_on_main() {
  [ "$(git branch --show-current)" != "$BRANCH" ] || git switch --quiet main || return 1
  [ "$(git branch --show-current)" != main ] || git merge --quiet --ff-only origin/main || return 1
  git branch --quiet -D "$BRANCH" 2>/dev/null || true
}

main() {
  VERSION="${VERSION:?set VERSION to the version being released}"
  BRANCH="release-$VERSION"
  DMG="$ROOT/dist/Tarmac-$VERSION.dmg"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "VERSION '$VERSION' is not x.y.z"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
  cd "$ROOT"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/tarmac-release.XXXXXX")"
  trap cleanup EXIT

  sync_origin
  if [ "$(release_draft_state)" = false ]; then
    say "v$VERSION is already published"
  else
    ensure_bump_landed
    publish_release
  fi
  [ "$(pinned version)" = "$VERSION" ] || die "main's cask is not at $VERSION"
  update_tap
  verify_published
  settle_on_main || echo "WARNING: could not bring the local main up to origin/main" >&2
  say "released v$VERSION"
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
