# Tarmac

Tarmac is a terminal-first macOS cockpit for working alongside CLI coding agents. You run an agent (or anything) in a real terminal inside Tarmac; when that process — or you, a Makefile, a git hook, CI — runs `tarmac open <path>`, the referenced markdown doc surfaces as a live card on an infinite, pannable, zoomable **board**, placed next to the terminal that opened it and tied by a dashed provenance edge. It is deliberately **not an agent harness**: every on-screen mark is backed by an observable OS fact (a running process, an mtime change, a `tarmac open` socket call, a terminal bell), never by parsing agent output. Status: working prototype (M0–M3 + the v4 whiteboard migration complete on `main`).

## Architecture

Two processes that share nothing in-process, plus a tiny CLI, talking over **one Unix stream socket** (`~/Library/Application Support/tarmac/tarmacd.sock`, override `TARMAC_SOCKET`) with **length-prefixed MessagePack** frames (4-byte big-endian u32 length + msgpack map with string keys; `"t"` field tags the type; 16 MiB max frame).

- **`tarmacd`** (Rust / Tokio) — the PTY owner + observatory. Spawns and owns every terminal (`portable-pty`), watches opened docs (`notify` on the parent dir), tracks OS facts (foreground process name, file changes, bells, exits), holds all boards, persists to atomic JSON (`state.json`, override `TARMAC_STATE`). In `core/` (Cargo workspace, edition 2024): crates `tarmacd`, `tarmac-cli`, `tarmac-protocol`.
- **`TarmacApp`** (Tauri 2 + React + xterm.js, macOS 14+) — the cockpit glass. Renders boards/cards, hosts terminal surfaces (xterm.js) and doc cards, turns input into daemon requests. In `desktop/` (Vite + React frontend, Rust/Tauri backend via `desktop/src-tauri/`).
- **`tarmac` CLI** (Rust, std-only) — the universal doorbell. `tarmac open <path>` connects, names a doc, exits. Inside a Tarmac PTY it reads `TARMAC_TERM_ID` (the daemon sets it per PTY) to attribute the doc to the calling terminal. `open` is the only verb.

The Rust side mirrors the same wire contract in `core/crates/tarmac-protocol` (the single `Msg` serde enum). Protocol grows **additive-only** (new optional keys / new message types; unknown keys and types ignored). Authoritative spec: `docs/protocol.md`; full engineering overview: `docs/architecture.md`.

## Build, run, test

Everything goes through the root `Makefile`:

- `make core` — `cargo build` the Rust workspace (daemon + CLI + protocol).
- `make app` — `npm run build` + `cargo build` for the Tauri app.
- `make test` — `cd core && cargo test` + `cd desktop && npm test` + app-cargo test.
- `make run` — launches the Tauri dev app with Vite HMR.
- `make bundle` — `scripts/bundle.sh`: unsigned arm64 `dist/Tarmac.app` via `tauri build`.
- `make release` — `scripts/release.sh`: sign + `.dmg` + notarize + staple. Requires env `DEVID_IDENTITY` and `NOTARY_PROFILE` (both hard-asserted); `VERSION` optional (default `0.1.0`).

**`make run` nuance**: it runs `desktop/` in Tauri dev mode with two env vars prefixed —
- `TARMAC_DAEMON=core/target/debug/tarmacd` — tells the Tauri backend which daemon binary to auto-spawn (spawns it and retries ~3s). The Rust daemon itself never reads this var.
- `PATH=core/target/debug:$PATH` — prepends the debug dir so the daemon (and the PTYs it spawns) resolve the fresh `tarmac` CLI. This is what makes `tarmac open <file>` work inside the app's xterm terminals.

Build outputs (gitignored): Rust → `core/target/{debug,release}/`, Tauri → `desktop/src-tauri/target/`, bundle/dmg → `dist/`.

## Repository layout

- `desktop/` — Tauri 2 app. `src/` (React + xterm.js frontend), `src-tauri/` (Rust backend, path-deps `tarmac-protocol`), `src-tauri/icons/` (app icons).
- `core/` — Cargo workspace. `crates/{tarmacd,tarmac-cli,tarmac-protocol}/`. Daemon source: `main.rs`, `conn.rs`, `docs.rs`, `state.rs`, `term.rs`, `persist.rs`. Daemon integration tests: `core/crates/tarmacd/tests/{m0,m1,m2,m3}_integration.rs` + `cjk_locale_integration.rs`.
- `docs/` — `architecture.md`, `protocol.md` (wire contract + conformance vectors), `backlog.md` (designed-but-unbuilt + deferred), `v4c/visual-crib.md` (next milestone: editable docs), `designs/`.
- `scripts/` — `bundle.sh`, `release.sh`.
- `packaging/` — `Tarmac.entitlements` (hardened-runtime entitlements for signing), `Casks/tarmac.rb` (Homebrew cask — bump version+sha256 after release), `icon/`.

## Conventions

- **Commits: Conventional Commits.** `type(scope): summary` (whole history conforms). Types in use: `feat`, `fix`, `refactor`, `perf`, `docs`, `chore`, plus bare `release:` for version bumps. Scopes are area tags, not paths (`feat(terminal)`, `fix(board)`, `feat(m3)`, `feat(protocol)`, …). PRs are squash-merged with `(#N)` suffix.
- **Where tests live.** Rust: inline `#[test]`/`#[tokio::test]` in `src/` + milestone-named integration suites under each crate's `tests/`. Desktop: Vitest unit tests in `desktop/` (`npm test`). `desktop/src-tauri/` has its own `cargo test`.
- **Formatting is convention-by-imitation.** No `rustfmt.toml`/`.swiftformat`/`.editorconfig`, no CI, no formatter command. Match surrounding code. `make` must pass before opening a PR.
- Note: `CONTRIBUTING.md` mandates a DCO `Signed-off-by` line, but the actual history uses `Co-Authored-By` trailers instead — follow the repo's de-facto pattern, not the literal CONTRIBUTING text.

## Gotchas

- **`make` is the source of truth, not the editor.** Always verify compilation with `make`, not IDE diagnostics.
- **A persistent installed `tarmacd` can hijack the dev app.** `make run` only points the dev app at the debug daemon via env — it doesn't kill an already-installed one. Kill any running/installed daemon before testing daemon changes.
- **Do NOT `cargo fmt` the Rust crates.** Local rustfmt disagrees with the whole committed repo and would create spurious churn.
- **Wire protocol is additive-keys-only and conformance-gated.** Never change/remove a key or alter encoding without regenerating the hex conformance vectors (V1–V8), which are mandatory tests in `tarmac-protocol` (exercised by both `core` and the desktop backend, which path-deps it). The frontend consumes already-decoded data over Tauri IPC, so there is no second-language codec to keep in lockstep. Rust must encode with `rmp_serde::to_vec_named` (plain `to_vec` emits arrays and breaks the contract); binary payloads use msgpack `bin` via `serde_bytes`.
- **Serde stack is pinned with `=`** (`serde =1.0.228`, `rmp-serde =1.3.1`, `serde_bytes =0.11.19`) — the tagged-enum + serde_bytes interaction is verified only on those versions.
- **`repo_color_index` (Rust, FNV-1a 64 mod 4) must stay byte-for-byte identical to the app's color logic** — changing it alters colors users already saw.
- **`socket_path()` is duplicated** in `tarmacd/src/main.rs` and `tarmac-cli/src/main.rs` (not shared) — keep them in sync.
- **Daemon lock discipline is load-bearing.** `std::sync::Mutex`es (watcher, term master, scrollback) are never held across `.await`; board-delete clones PTY handles and drops the lock before `kill()`. PTY kill signals the whole process group (`SIGHUP`).
- Tarmac is **not MCP / not an agent harness** on purpose — `tarmac open` is a plain CLI over a Unix socket so any caller can ring the doorbell. Don't propose MCP-based coupling.
