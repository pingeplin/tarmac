ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: setup core ghostty-vt app test docs-check arch-check check-test mutants fmt fmt-check lint dco-check run qa qa-quit qa-resume kill-daemon bundle dmg release

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
# make hands a command-line variable to every child in MAKEFLAGS. The app's
# terminals would carry DEV_DIR, and a make run in one would take it as its own.
MAKEOVERRIDES =
DEV_LABEL := $(notdir $(ROOT))$(if $(filter-out $(ROOT)/.dev,$(DEV_DIR)),/$(notdir $(DEV_DIR)))
DEV_SOCKET := $(DEV_DIR)/tarmacd.sock
DEV_ENV := TARMAC_SOCKET="$(DEV_SOCKET)" \
	TARMAC_STATE="$(DEV_DIR)/state.json" \
	TARMAC_DEV_SOCKET="$(DEV_DIR)/tarmac-dev.sock" \
	TARMAC_CONFIG_DIR="$(DEV_DIR)/config"
# `make run SHELL_GATE=1` (#380): each shell of the channel starts through
# scripts/qa/gate-shell.sh, which holds it while $(SHELL_GATE_FILE) exists, so
# `make qa-resume CASE=before-output` can act before a shell's first output.
# TARMAC_QA_SHELL comes first: a gated terminal already has one, and its SHELL
# is the gate script.
SHELL_GATE_FILE := $(DEV_DIR)/shell-gate
GATE_ENV := $(if $(filter 1,$(SHELL_GATE)),TARMAC_QA_SHELL="$${TARMAC_QA_SHELL:-$$SHELL}" \
	TARMAC_QA_SHELL_GATE="$(SHELL_GATE_FILE)" \
	SHELL="$(ROOT)/scripts/qa/gate-shell.sh")

# Once per clone: what git keeps outside the tree, so a checkout cannot carry
# it. Worktrees share the clone's configuration and its hooks. `git blame` then
# skips the commits in .git-blame-ignore-revs (the formatter baselines), and
# the git hooks of lefthook.yml run on a commit and a push.
setup:
	git -C $(ROOT) config blame.ignoreRevsFile .git-blame-ignore-revs
	@command -v lefthook >/dev/null || { echo "make setup: lefthook is not installed (brew install lefthook); the git hooks are not installed" >&2; exit 1; }
	cd $(ROOT) && lefthook install

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

# The formatter, one definition for people, hooks and CI (scripts/check/fmt.mjs).
# `fmt` rewrites every tracked file; `fmt-check` changes nothing and names the
# files `fmt` would rewrite. ONLY=rust limits a run to one language. The Rust
# toolchain, and so the rustfmt version, is pinned in rust-toolchain.toml.
fmt:
	cd $(ROOT) && node scripts/check/fmt.mjs --write $(ONLY)

fmt-check:
	cd $(ROOT) && node scripts/check/fmt.mjs --check $(ONLY)

# The lint check (scripts/check/lint.mjs), where a warning is a failure: clippy
# over the workspace with the lint table of core/Cargo.toml, and the lint rules
# of swift-format (.swift-format) over the tracked Swift files, and the Swift
# compiler's warnings from a build of the package into an empty directory
# (swiftc; it needs the staged libghostty-vt). ONLY=rust, ONLY=swift or
# ONLY=swiftc limits a run. Not part of `test`: it compiles both workspaces a
# second way. CI runs it (lint.yml).
lint: $(if $(filter rust swift,$(ONLY)),,ghostty-vt)
	cd $(ROOT) && node scripts/check/lint.mjs $(ONLY)

# Rules about the tree that no formatter, linter or compiler setting holds
# (scripts/check/arch.mjs): what TarmacKit and TarmacTerm may import, where
# Bundle.module and a signal may be used, no profile that changes
# debug-assertions, the pinned serde stack, a test file for each kit module.
# Plain node and sub-second, like docs-check, so it runs in `test`.
arch-check:
	cd $(ROOT) && node scripts/check/arch.mjs

# Mutation testing for the Rust workspace (scripts/check/mutants.mjs, spec
# 2611.0032): cargo-mutants changes one expression at a time in the Rust lines
# this branch changed since BASE and runs the tests; a change that no test saw
# fails. The script gives the tool a new empty HOME and a short list of
# variables, so a mutant cannot reach the real home. ALL=1 runs the whole
# workspace (hours; SHARD=k/n takes one part), JOBS=n sets the parallel runs
# (default 2), REPORT=1 words a survivor and passes. Not part of `test`: a
# mutant costs a build and a test run. CI runs it on every PR (mutants.yml).
mutants:
	cd $(ROOT) && node scripts/check/mutants.mjs --base $(BASE)$(if $(ALL), --all)$(if $(SHARD), --shard $(SHARD))$(if $(JOBS), --jobs $(JOBS))$(if $(REPORT), --report)

# The unit tests of the check scripts themselves. They make small git
# repositories in the temp directory and run the real formatter there.
check-test:
	node --test '$(ROOT)/scripts/check/*.test.mjs'

test: docs-check arch-check check-test ghostty-vt
	cd $(ROOT)/core && cargo test
	cd $(ROOT)/app && swift test

# `make run` launches the dev app against this worktree's own daemon.
# TARMAC_DAEMON lets it auto-spawn the debug daemon; the PATH prefix flows
# through the daemon into spawned ptys so `tarmac open <file>` works inside its
# terminals. TARMAC_SOCKET/TARMAC_STATE/TARMAC_CONFIG_DIR pin a stable
# per-worktree dev path so simultaneous `make run`s from different worktrees
# don't share a socket, a state file or a config directory, and none of them can
# reach the installed Tarmac. TARMAC_DEV_SOCKET pins the QA driver's own socket
# (issue #166) for the same reason — unpinned, `make qa` from one worktree would
# drive another's window. TARMAC_DEV_LABEL suffixes the window title with
# ` · $(DEV_LABEL)`: the dev binary is not a .app, so Launch Services reports no
# bundle id for it and the title is the only tell separating one dev app from
# another. TARMAC_DEV_ICON separates any dev app from the installed one: its
# Dock and ⌘Tab icon, the Tarmac icon with a DEV mark (issue #438), used only
# with a dev label.
# TARMAC_APP_VERSION stands in for the bundle's version: an unbundled binary has
# no Info.plist, and the app must name the same version as the daemon it just
# built or it would replace that daemon as stale. `bundle`/`release` set none of
# these, so a shipped Tarmac is unchanged.
run: core app
	mkdir -p "$(DEV_DIR)"
	cd $(ROOT)/app && \
	$(DEV_ENV) \
	$(GATE_ENV) \
	TARMAC_DEV_LABEL="$(DEV_LABEL)" \
	TARMAC_DEV_ICON="$(ROOT)/packaging/icon/Tarmac-dev-1024.png" \
	TARMAC_APP_VERSION="$$(sed -n 's/^version = "\(.*\)"/\1/p' $(ROOT)/core/Cargo.toml | head -1)" \
	TARMAC_DAEMON="$(ROOT)/core/target/debug/tarmacd" \
	PATH="$(ROOT)/core/target/debug:$$PATH" \
	"$$(swift build --show-bin-path)/TarmacApp"

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
qa-quit: CASE ?= hold
qa-quit: core
	$(DEV_ENV) \
	CASE="$(CASE)" \
	node $(ROOT)/scripts/qa/quit.mjs

# Resume after a restart (spec 2611.0011 S37, 2611.0015 D15): it kills the dev
# daemon by the pid that holds its socket, so every dev terminal ends; `make run`
# again after. One CASE per run.
qa-resume: CASE ?= reopen
qa-resume: core
	$(DEV_ENV) \
	TARMAC_QA_SHELL_GATE="$(SHELL_GATE_FILE)" \
	CASE="$(CASE)" \
	node $(ROOT)/scripts/qa/resume.mjs

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
