ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: core app test e2e run bundle release

core:
	cd $(ROOT)/core && cargo build

app:
	cd $(ROOT)/app && swift build

test:
	cd $(ROOT)/core && cargo test
	cd $(ROOT)/app && swift test

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

# Assemble an unsigned dist/Tarmac.app (arm64). No Apple cert needed; launches
# locally so you can validate bundle-relative daemon/CLI/resource resolution.
bundle:
	$(ROOT)/scripts/bundle.sh

# Sign + .dmg + notarize + staple. Needs DEVID_IDENTITY + NOTARY_PROFILE.
release:
	$(ROOT)/scripts/release.sh
