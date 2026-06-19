# Tarmac

Tarmac is a terminal-first macOS cockpit for working alongside CLI coding agents. You run an agent (or anything) in a real terminal inside Tarmac; when that process — or you, a Makefile, a git hook, CI — runs `tarmac open <path>`, the referenced markdown doc surfaces as a live card on an infinite, pannable, zoomable **board**, placed next to the terminal that opened it and tied by a dashed provenance edge. It is deliberately **not an agent harness**: every on-screen mark is backed by an observable OS fact (a running process, an mtime change, a `tarmac open` socket call, a terminal bell), never by parsing agent output. Status: working prototype (M0–M3 + the v4 whiteboard migration complete on `main`).

## Architecture

Two processes that share nothing in-process, plus a tiny CLI, talking over **one Unix stream socket** (`~/Library/Application Support/tarmac/tarmacd.sock`, override `TARMAC_SOCKET`) with **length-prefixed MessagePack** frames (4-byte big-endian u32 length + msgpack map with string keys; `"t"` field tags the type; 16 MiB max frame).

- **`tarmacd`** (Rust / Tokio) — the PTY owner + observatory. Spawns and owns every terminal (`portable-pty`), watches opened docs (`notify` on the parent dir), tracks OS facts (foreground process name, file changes, bells, exits), holds all boards, persists to atomic JSON (`state.json`, override `TARMAC_STATE`). In `core/` (Cargo workspace, edition 2024): crates `tarmacd`, `tarmac-cli`, `tarmac-protocol`.
- **`TarmacApp`** (Swift / AppKit, macOS 14+, Swift 6.2) — the cockpit glass. Renders boards/cards, hosts terminal surfaces (SwiftTerm) and doc cards (WKWebView markdown), turns input into daemon requests. In `app/` (one SwiftPM package).
- **`tarmac` CLI** (Rust, std-only) — the universal doorbell. `tarmac open <path>` connects, names a doc, exits. Inside a Tarmac PTY it reads `TARMAC_TERM_ID` (the daemon sets it per PTY) to attribute the doc to the calling terminal. `open` is the only verb.

**TarmacKit vs TarmacApp split** — the app package has four targets:
- **`TarmacKit`** (`app/Sources/TarmacKit/`) — pure, AppKit-free logic and the **only unit-tested target**. Codec (`Framing.swift`, `MsgPack.swift`, `Messages.swift`), board math (`BoardTransform.swift`, `BoardWayfinding.swift`), and deterministic rule/view-model modules (`DocStore`, `BoardSwitcher`, `TermRestore`, `Reconnect`, `TermBoardIndex`, …). Also hosts `DaemonClient.swift`/`DaemonLaunch.swift` (the live socket client — exercised via `tarmac-smoke`, NOT unit-tested).
- **`TarmacApp`** (`app/Sources/TarmacApp/`) — the AppKit GUI, **not unit-tested by design**. `AppController.swift` is the coordinator spine (message routing, focus, board switching); `BoardView.swift`/`CardView.swift` are the infinite canvas and cards. Views delegate all math to TarmacKit so they stay thin.
- **`tarmac-smoke`** — cross-language e2e client that drives a real daemon.

The Rust side mirrors the same wire contract in `core/crates/tarmac-protocol` (the single `Msg` serde enum). Protocol grows **additive-only** (new optional keys / new message types; unknown keys and types ignored). Authoritative spec: `docs/protocol.md`; full engineering overview: `docs/architecture.md`.

## Build, run, test

Everything goes through the root `Makefile` (all targets `cd` into `core/` or `app/` with absolute paths):

- `make core` — `cargo build` the Rust workspace (daemon + CLI + protocol).
- `make app` — `swift build` the Swift package (app + TarmacKit + smoke client).
- `make test` — runs **both** `cargo test` and `swift test`. Rust-only: `cd core && cargo test`; Swift-only: `cd app && swift test`.
- `make e2e` — `scripts/e2e.sh`: boots a real daemon + smoke client + CLI on an **isolated** socket/state in a tmpdir (asserts `RESULT: PASS`). Needs debug binaries already built — run `make core app` first; it does NOT build them for you.
- `make run` — builds both, then launches the app with daemon env wiring (see below).
- `make bundle` — `scripts/bundle.sh`: unsigned arm64 `dist/Tarmac.app` (no cert needed).
- `make release` — `scripts/release.sh`: sign + `.dmg` + notarize + staple. Requires env `DEVID_IDENTITY` and `NOTARY_PROFILE` (both hard-asserted); `VERSION` optional (default `0.1.0`).

**`make run` nuance** (this is how you actually launch a working dev app): it runs `app/.build/debug/TarmacApp` with two env vars prefixed —
- `TARMAC_DAEMON=core/target/debug/tarmacd` — tells the **app** which daemon binary to auto-spawn (`DaemonClient.connect()` spawns it and retries ~3s). The Rust daemon itself never reads this var; it's purely app-side.
- `PATH=core/target/debug:$PATH` — prepends the debug dir so the daemon (and the PTYs it spawns) resolve the fresh `tarmac` CLI. This is what makes `tarmac open <file>` work inside the app's own terminal cards.

Build outputs (gitignored): Rust → `core/target/{debug,release}/`, Swift → `app/.build/{debug,release}/`, bundle/dmg → `dist/`.

## Repository layout

- `app/` — Swift package. `Sources/{TarmacKit,TarmacApp,tarmac-smoke}/`, tests in `Tests/TarmacKitTests/`, `Package.swift`, `Resources/DocTemplate.html` (doc rendering).
- `core/` — Cargo workspace. `crates/{tarmacd,tarmac-cli,tarmac-protocol}/`. Daemon source: `main.rs`, `conn.rs`, `docs.rs`, `state.rs`, `term.rs`, `persist.rs`. Daemon integration tests: `core/crates/tarmacd/tests/{m0,m1,m2,m3}_integration.rs` + `cjk_locale_integration.rs`.
- `docs/` — `architecture.md`, `protocol.md` (wire contract + conformance vectors), `backlog.md` (designed-but-unbuilt + deferred), `v4c/visual-crib.md` (next milestone: editable docs), `designs/`.
- `scripts/` — `e2e.sh`, `bundle.sh`, `release.sh`.
- `packaging/` — `Info.plist`, `Tarmac.entitlements`, `Tarmac.icns`, `Casks/tarmac.rb` (Homebrew cask — bump version+sha256 after release), `icon/`.

## Conventions

- **Commits: Conventional Commits.** `type(scope): summary` (whole history conforms). Types in use: `feat`, `fix`, `refactor`, `perf`, `docs`, `chore`, plus bare `release:` for version bumps. Scopes are area tags, not paths (`feat(terminal)`, `fix(board)`, `feat(m3)`, `feat(protocol)`, …). PRs are squash-merged with `(#N)` suffix.
- **Where tests live.** Swift: unit tests only in `app/Tests/TarmacKitTests/`. Rust: inline `#[test]`/`#[tokio::test]` in `src/` + milestone-named integration suites under each crate's `tests/`. To test app logic, extract the pure part into TarmacKit first — there's no path to unit-testing `TarmacApp` directly.
- **Formatting is convention-by-imitation.** No `rustfmt.toml`/`.swiftformat`/`.editorconfig`, no CI, no formatter command. Match surrounding code. `make` must pass before opening a PR.
- Note: `CONTRIBUTING.md` mandates a DCO `Signed-off-by` line, but the actual history uses `Co-Authored-By` trailers instead — follow the repo's de-facto pattern, not the literal CONTRIBUTING text.

## Gotchas

- **`make` is the source of truth, not the editor.** SourceKit/IDE diagnostics for the Swift app are stale and lie — always verify compilation with `make` / `swift build`.
- **Only TarmacKit is unit-tested.** `TarmacApp` (all AppKit UI) is untested by design; `DaemonClient` lives in TarmacKit but is also not unit-tested (live socket, e2e-only). Don't assume "in TarmacKit" means "covered."
- **A persistent installed `tarmacd` can hijack the dev app.** `make run` only points the dev app at the debug daemon via env — it doesn't kill an already-installed one. Kill any running/installed daemon before testing daemon changes.
- **Do NOT `cargo fmt` the Rust crates.** Local rustfmt disagrees with the whole committed repo and would create spurious churn.
- **Wire protocol is additive-keys-only and conformance-gated.** Never change/remove a key or alter encoding without regenerating the hex conformance vectors (V1–V8), which are mandatory tests in BOTH Rust (`tarmac-protocol`) and Swift (`TarmacKit`) and must decode identically. Rust must encode with `rmp_serde::to_vec_named` (plain `to_vec` emits arrays and breaks the contract); binary payloads use msgpack `bin` via `serde_bytes`.
- **Serde stack is pinned with `=`** (`serde =1.0.228`, `rmp-serde =1.3.1`, `serde_bytes =0.11.19`) — the tagged-enum + serde_bytes interaction is verified only on those versions. The SwiftTerm dependency is pinned to an untagged commit (`c2fe63d`) for CJK/IME marked-text support; see the `app/Package.swift` comment before bumping.
- **`repo_color_index` (Rust, FNV-1a 64 mod 4) must stay byte-for-byte identical to the app's color logic** — changing it alters colors users already saw.
- **`socket_path()` is duplicated** in `tarmacd/src/main.rs` and `tarmac-cli/src/main.rs` (not shared) — keep them in sync.
- **Daemon lock discipline is load-bearing.** `std::sync::Mutex`es (watcher, term master, scrollback) are never held across `.await`; board-delete clones PTY handles and drops the lock before `kill()`. PTY kill signals the whole process group (`SIGHUP`).
- Tarmac is **not MCP / not an agent harness** on purpose — `tarmac open` is a plain CLI over a Unix socket so any caller can ring the doorbell. Don't propose MCP-based coupling.
