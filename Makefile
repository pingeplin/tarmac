ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: core app desktop desktop-deps test e2e run run-desktop kill-daemon bundle release

core:
	cd $(ROOT)/core && cargo build

app:
	cd $(ROOT)/app && swift build

# Install the desktop (Tauri 2 + Vite + React) JS deps. Separate so build/test
# targets stay fast once node_modules exists.
desktop-deps:
	cd $(ROOT)/desktop && npm install

# Build the desktop UI: frontend bundle + the Rust backend (which path-deps the
# untouched tarmac-protocol crate). Does NOT touch core/ or app/.
desktop: desktop-deps
	cd $(ROOT)/desktop && npm run build
	cargo build --manifest-path $(ROOT)/desktop/src-tauri/Cargo.toml

# Coexistence: run BOTH UIs' test suites alongside core's. The Swift app stays
# green until the Tauri app reaches parity (cutover deletes `swift test`).
test:
	cd $(ROOT)/core && cargo test
	cd $(ROOT)/app && swift test
	cd $(ROOT)/desktop && npm test
	cargo test --manifest-path $(ROOT)/desktop/src-tauri/Cargo.toml

e2e:
	$(ROOT)/scripts/e2e.sh

# TARMAC_DAEMON lets the app auto-spawn the daemon; the PATH prefix flows
# through the daemon into spawned ptys so `tarmac open <file>` works inside the
# app's own terminal. TARMAC_SOCKET/TARMAC_STATE pin a stable per-worktree path
# (an 8-hex hash of $ROOT) UNDER the dev/ channel, so simultaneous `make run`s
# from different worktrees don't share a socket or state file (spec 2606.0003).
# These ride the existing verbatim-override path — no app/daemon/CLI code change.
run: core app
	wt="$$HOME/Library/Application Support/tarmac/dev/wt-$$(echo -n "$(ROOT)" | shasum | head -c8)"; \
	TARMAC_SOCKET="$$wt/tarmacd.sock" \
	TARMAC_STATE="$$wt/state.json" \
	TARMAC_DAEMON="$(ROOT)/core/target/debug/tarmacd" \
	PATH="$(ROOT)/core/target/debug:$$PATH" \
	"$(ROOT)/app/.build/debug/TarmacApp"

# Run the new Tauri UI in dev (vite HMR + the Rust backend). Same env wiring as
# `run`: the app auto-spawns the debug daemon (TARMAC_DAEMON), the PATH prefix
# flows through it so `tarmac open` resolves inside the app's xterm terminals, and
# TARMAC_SOCKET/TARMAC_STATE pin the same per-worktree dev path the Swift app uses
# (the Tauri backend reuses tarmac-protocol's resolver, so it honors the override).
run-desktop: core desktop-deps
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
