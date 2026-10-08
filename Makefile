ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: core ghostty-vt app test docs-check dco-check run qa qa-quit kill-daemon bundle dmg release

# The dev channel: one directory that holds this worktree's own daemon socket,
# state, driver socket and config directory. Everything that launches or drives
# a dev build goes through these, so `make run DEV_DIR=<dir>` is a second, whole
# channel: none of the four can be left out. DEV_DIR is taken from the command
# line only: one in the environment is ignored (unless `make -e`). A relative
# one is taken from the directory make runs in, because the recipes run in
# other directories. `abspath` splits at a space and expands no `~`, so a value
# the caller gives with one of those is refused.
DEV_DIR := $(ROOT)/.dev
ifneq ($(origin DEV_DIR),file)
ifneq ($(words $(DEV_DIR)),1)
$(error DEV_DIR must be one path, not empty and with no space: "$(DEV_DIR)")
endif
ifneq ($(filter ~%,$(DEV_DIR)),)
$(error DEV_DIR starts with ~, which make does not expand: "$(DEV_DIR)")
endif
override DEV_DIR := $(abspath $(DEV_DIR))
endif
DEV_LABEL := $(notdir $(ROOT))$(if $(filter-out $(ROOT)/.dev,$(DEV_DIR)),/$(notdir $(DEV_DIR)))
DEV_SOCKET := $(DEV_DIR)/tarmacd.sock
DEV_ENV := TARMAC_SOCKET="$(DEV_SOCKET)" \
	TARMAC_STATE="$(DEV_DIR)/state.json" \
	TARMAC_DEV_SOCKET="$(DEV_DIR)/tarmac-dev.sock" \
	TARMAC_CONFIG_DIR="$(DEV_DIR)/config"

core:
	cd $(ROOT)/core && cargo build

# Stage the pinned libghostty-vt XCFramework the terminal cards link
# (app/Vendor/, gitignored). A no-op once the pinned commit is staged.
ghostty-vt:
	$(ROOT)/scripts/fetch-ghostty-vt.sh

# Build the app (the SwiftPM package in app/). Does NOT touch core/.
app: ghostty-vt
	cd $(ROOT)/app && swift build

# Deterministic doc tripwires: status banners, link rot, ACTIVE docs citing
# source paths that don't exist, and wire messages missing from the docs. No
# dependencies (plain node), sub-second, so it runs first in `test`.
docs-check:
	node $(ROOT)/scripts/docs-check.mjs

# DCO sign-off tripwire over the commits a branch adds. Not part of `test`: it is
# a property of the commits, not the tree, and needs a fetched base ref, while
# `make test` is otherwise offline-safe. Override BASE for a stacked branch —
# `make dco-check BASE=origin/some-other-branch`.
BASE ?= origin/main
dco-check:
	node $(ROOT)/scripts/dco-check.mjs --base $(BASE)

test: docs-check ghostty-vt
	cd $(ROOT)/core && cargo test
	cd $(ROOT)/app && swift test

# `make run` launches the dev app against this worktree's own daemon.
# TARMAC_DAEMON lets it auto-spawn the debug daemon; the PATH prefix flows
# through the daemon into spawned ptys so `tarmac open <file>` works inside its
# terminals. TARMAC_SOCKET/TARMAC_STATE pin a stable per-worktree dev path so
# simultaneous `make run`s from different worktrees don't share a socket or
# state file, and none of them can reach the installed Tarmac. TARMAC_CONFIG_DIR
# pins the config directory, where the preferences and the theme files are, for
# the same reason. TARMAC_DEV_SOCKET pins the QA driver's own socket (issue
# #166) for the same reason — unpinned,
# `make qa` from one worktree would drive another's window. TARMAC_DEV_LABEL
# suffixes the window title with ` · <worktree>`, and for a DEV_DIR channel
# with ` · <worktree>/<its directory>`: the dev binary is not a .app,
# so Launch Services reports no bundle id for it and the title is the only tell
# separating one dev app from another (and from the installed one).
# TARMAC_APP_VERSION stands in for the bundle's version: an unbundled binary has
# no Info.plist, and the app must name the same version as the daemon it just
# built or it would replace that daemon as stale. `bundle`/`release` set none of
# these, so a shipped Tarmac is unchanged. MAKEFLAGS, MFLAGS and MAKELEVEL are
# taken out of the app's environment: MAKEFLAGS carries a command-line DEV_DIR,
# and a make that is run later in one of the app's terminals would take it as
# its own.
run: core app
	mkdir -p "$(DEV_DIR)"
	cd $(ROOT)/app && \
	$(DEV_ENV) \
	TARMAC_DEV_LABEL="$(DEV_LABEL)" \
	TARMAC_APP_VERSION="$$(sed -n 's/^version = "\(.*\)"/\1/p' $(ROOT)/core/Cargo.toml | head -1)" \
	TARMAC_DAEMON="$(ROOT)/core/target/debug/tarmacd" \
	PATH="$(ROOT)/core/target/debug:$$PATH" \
	env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL "$$(swift build --show-bin-path)/TarmacApp"

# The QA driver's scenario suite (spec 2609.0015). NOT part of `make test` and
# not on CI: every scenario drives a LIVE window, so it needs `make run` up in
# another shell. The same TARMAC_DEV_SOCKET pin as `run`, so this can only ever
# reach this worktree's app; TARMAC_SOCKET is pinned too, so the doc-card
# scenarios can `tarmac open` their fixtures into that same app (#183).
qa: core
	$(DEV_ENV) \
	node $(ROOT)/scripts/qa/smoke.mjs

# The ⌘Q guard's QUITTING scenarios (spec 2609.0018): one CASE per run, and
# each ends the app, so `make run` again between cases.
CASE ?= hold
qa-quit: core
	$(DEV_ENV) \
	CASE="$(CASE)" \
	node $(ROOT)/scripts/qa/quit.mjs

# Kill the dev tarmacd for this worktree (same socket path as `make run`).
# Sends SIGKILL (kill -9); exits 0 whether or not it was running.
# `lsof -t` prints ONE PID PER LINE, and a restarted `make run` can leave more
# than one daemon holding the socket — so the list is unquoted on purpose, to
# reach `kill` as separate arguments. Quoting it makes the target fail outright
# in exactly the case it exists for.
kill-daemon:
	sock="$(DEV_SOCKET)"; \
	pids=$$(lsof -t "$$sock" 2>/dev/null | tr '\n' ' '); \
	if [ -n "$$pids" ]; then \
		echo "killing tarmacd pid(s) $${pids% } on $$sock"; \
		kill -9 $$pids; \
	else \
		echo "no tarmacd on $$sock"; \
	fi

# Assemble an unsigned dist/Tarmac.app (arm64). No Apple cert needed. To try
# it, run Contents/MacOS/tarmac-app with TARMAC_SOCKET, TARMAC_STATE and
# TARMAC_CONFIG_DIR set to scratch paths: launched bare it attaches to the
# installed Tarmac's daemon.
bundle:
	$(ROOT)/scripts/bundle.sh

# Sign + .dmg + notarize + staple; publishes nothing. Needs VERSION,
# DEVID_IDENTITY + NOTARY_PROFILE.
dmg:
	$(ROOT)/scripts/dmg.sh

# The whole release, from this Mac: `dmg`, then the version-bump PR, the GitHub
# release, the Homebrew tap and a check of what was published. Re-run to resume.
release:
	$(ROOT)/scripts/release.sh
