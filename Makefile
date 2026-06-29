ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: core app app-deps test run kill-daemon bundle release

core:
	cd $(ROOT)/core && cargo build

# Install the app (Tauri 2 + Vite + React) JS deps. Separate so build/test
# targets stay fast once node_modules exists.
app-deps:
	cd $(ROOT)/desktop && npm install

# Build the app: frontend bundle + the Rust backend (which path-deps the
# untouched tarmac-protocol crate). Does NOT touch core/.
app: app-deps
	cd $(ROOT)/desktop && npm run build
	cargo build --manifest-path $(ROOT)/desktop/src-tauri/Cargo.toml

test:
	cd $(ROOT)/core && cargo test
	cd $(ROOT)/desktop && npm test
	cargo test --manifest-path $(ROOT)/desktop/src-tauri/Cargo.toml

# `make run` launches the Tauri dev app (Vite HMR + Rust backend). TARMAC_DAEMON
# lets it auto-spawn the debug daemon; the PATH prefix flows through the daemon
# into spawned ptys so `tarmac open <file>` works inside xterm terminals.
# TARMAC_SOCKET/TARMAC_STATE pin a stable per-worktree dev path so simultaneous
# `make run`s from different worktrees don't share a socket or state file.
run: core app-deps
	cd $(ROOT)/desktop && \
	wt="$$HOME/Library/Application Support/tarmac/dev/wt-$$(echo -n "$(ROOT)" | shasum | head -c8)"; \
	TARMAC_SOCKET="$$wt/tarmacd.sock" \
	TARMAC_STATE="$$wt/state.json" \
	TARMAC_DAEMON="$(ROOT)/core/target/debug/tarmacd" \
	PATH="$(ROOT)/core/target/debug:$$PATH" \
	npm run tauri dev

# Kill the dev tarmacd for this worktree (same socket path as `make run`).
# Sends SIGTERM so the daemon can clean up; exits 0 whether or not it was running.
kill-daemon:
	sock="$$HOME/Library/Application Support/tarmac/dev/wt-$$(echo -n "$(ROOT)" | shasum | head -c8)/tarmacd.sock"; \
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
