ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: core app app-deps sidecars test docs-check dco-check run kill-daemon bundle release kit

core:
	cd $(ROOT)/core && cargo build

# Stage the debug daemon + CLI as Tauri externalBin sidecars. tauri.conf.json
# declares binaries/{tarmacd,tarmac}, which Tauri resolves to the arch-suffixed
# binaries/<name>-<triple> even in `tauri dev` — so they must exist before `run`,
# not just at bundle time (scripts/bundle.sh stages the *release* builds).
sidecars: core
	triple=$$(rustc -vV | sed -n 's/host: //p'); \
	dir="$(ROOT)/desktop/src-tauri/binaries"; \
	mkdir -p "$$dir"; \
	cp "$(ROOT)/core/target/debug/tarmacd" "$$dir/tarmacd-$$triple"; \
	cp "$(ROOT)/core/target/debug/tarmac"  "$$dir/tarmac-$$triple"

# Install the app (Tauri 2 + Vite + React) JS deps. Separate so build/test
# targets stay fast once node_modules exists.
app-deps:
	cd $(ROOT)/desktop && npm install

# Build the app: frontend bundle + the Rust backend (which path-deps the
# untouched tarmac-protocol crate). Does NOT touch core/.
app: app-deps
	cd $(ROOT)/desktop && npm run build
	cargo build --manifest-path $(ROOT)/desktop/src-tauri/Cargo.toml

# Builds the standalone design-sync kit (desktop/dist-kit/) via esbuild. NOT a
# dependency of `app`/`core` — invoke directly when refreshing the kit for
# /design-sync. See docs/designs/2607.0001_tarmac_ui_kit_design_sync_export.md.
kit: app-deps
	cd $(ROOT)/desktop && npm run build:kit

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

test: docs-check
	cd $(ROOT)/core && cargo test
	cd $(ROOT)/desktop && npm test
	cargo test --manifest-path $(ROOT)/desktop/src-tauri/Cargo.toml

# `make run` launches the Tauri dev app (Vite HMR + Rust backend). TARMAC_DAEMON
# lets it auto-spawn the debug daemon; the PATH prefix flows through the daemon
# into spawned ptys so `tarmac open <file>` works inside xterm terminals.
# TARMAC_SOCKET/TARMAC_STATE pin a stable per-worktree dev path so simultaneous
# `make run`s from different worktrees don't share a socket or state file.
# VITE_TARMAC_DEV_LABEL suffixes the window title with ` · <worktree>` for the
# same reason: the dev binary is not a .app, so Launch Services reports no bundle
# id for it and the title is the only tell separating one dev app from another
# (and from the installed one). The VITE_ prefix is load-bearing — it is what
# makes Vite bake the value into the bundle, so the title needs no IPC hop.
# `bundle`/`release` never set it, so a shipped Tarmac's title is unchanged.
run: core app-deps sidecars
	cd $(ROOT)/desktop && \
	TARMAC_SOCKET="$(ROOT)/.dev/tarmacd.sock" \
	TARMAC_STATE="$(ROOT)/.dev/state.json" \
	VITE_TARMAC_DEV_LABEL="$(notdir $(ROOT))" \
	TARMAC_DAEMON="$(ROOT)/core/target/debug/tarmacd" \
	PATH="$(ROOT)/core/target/debug:$$PATH" \
	npm run tauri dev

# Kill the dev tarmacd for this worktree (same socket path as `make run`).
# Sends SIGKILL (kill -9); exits 0 whether or not it was running.
kill-daemon:
	sock="$(ROOT)/.dev/tarmacd.sock"; \
	pid=$$(lsof -t "$$sock" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		echo "killing tarmacd pid $$pid on $$sock"; \
		kill -9 "$$pid"; \
	else \
		echo "no tarmacd on $$sock"; \
	fi

# Assemble an unsigned dist/Tarmac.app (arm64). No Apple cert needed; launches
# locally so you can validate bundle-relative daemon/CLI/resource resolution.
bundle:
	$(ROOT)/scripts/bundle.sh

# Sign + .dmg + notarize + staple. Needs DEVID_IDENTITY + NOTARY_PROFILE.
release:
	$(ROOT)/scripts/release.sh
