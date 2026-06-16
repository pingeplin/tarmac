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
# through the daemon into spawned ptys so `tarmac open <file>` works inside
# the app's own terminal.
run: core app
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
