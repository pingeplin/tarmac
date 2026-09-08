# Tarmac

Tarmac is a terminal-first macOS cockpit for working alongside CLI coding agents. You run an agent (or anything) in a real terminal inside Tarmac; when that process — or you, a Makefile, a git hook, CI — runs `tarmac open <path>`, the referenced markdown doc surfaces as a live card on an infinite, pannable, zoomable **board**, placed next to the terminal that opened it and tied by a dashed provenance edge. It is deliberately **not an agent harness**: every on-screen mark is backed by an observable OS fact (a running process, an mtime change, a `tarmac open` socket call, a terminal bell), never by parsing agent output. Status: working prototype (M0–M3 + the v4 whiteboard migration complete on `main`).

## Architecture

Two processes that share nothing in-process, plus a tiny CLI, talking over **one Unix stream socket** (`~/Library/Application Support/tarmac/tarmacd.sock`, override `TARMAC_SOCKET`) with **length-prefixed MessagePack** frames (4-byte big-endian u32 length + msgpack map with string keys; `"t"` field tags the type; 16 MiB max frame).

- **`tarmacd`** (Rust / Tokio) — the PTY owner + observatory. Spawns and owns every terminal (`portable-pty`), watches opened docs (`notify` on the parent dir), tracks OS facts (foreground process name, file changes, bells, exits), holds all boards, persists to atomic JSON (`state.json`, override `TARMAC_STATE`). In `core/` (Cargo workspace, edition 2024): crates `tarmacd`, `tarmac-cli`, `tarmac-protocol`.
- **`TarmacApp`** (Tauri 2 + React + xterm.js, macOS 26+) — the cockpit glass. Renders boards/cards, hosts terminal surfaces (xterm.js) and doc cards, turns input into daemon requests. In `desktop/` (Vite + React frontend, Rust/Tauri backend via `desktop/src-tauri/`).
- **`tarmac` CLI** (Rust, std-only) — the universal doorbell. `tarmac open <path>` connects, names a doc, exits. Inside a Tarmac PTY it reads `TARMAC_TERM_ID` (the daemon sets it per PTY) to attribute the doc to the calling terminal. `open` and `--version` are the two verbs that talk to the daemon — `--version` completes the handshake only, to report the cli, daemon, and connected-app versions plus the resolved channel and socket; `tarmac skill` is a purely local third verb that prints `core/crates/tarmac-cli/src/SKILL.md` — the agent-facing guide, embedded verbatim — and copies it into each supported agent's skills directory.

The Rust side mirrors the same wire contract in `core/crates/tarmac-protocol` (the single `Msg` serde enum). Protocol grows **additive-only** (new optional keys / new message types; unknown keys and types ignored). Authoritative spec: `docs/protocol.md`; full engineering overview: `docs/architecture.md`.

## Build, run, test

Everything goes through the root `Makefile`:

- `make core` — `cargo build` the Rust workspace (daemon + CLI + protocol).
- `make app` — `npm run build` + `cargo build` for the Tauri app.
- `make test` — `make docs-check` + `cd core && cargo test` + `cd desktop && npm test` + app-cargo test. Every line of it also runs on CI (`.github/workflows/test.yml`), but `make test` stays the local entry point.
- `make docs-check` — deterministic doc tripwires (`scripts/docs-check.mjs`, plain node, sub-second): status banners, link rot, ACTIVE docs citing paths that don't exist, and `Msg` variants missing from `architecture.md`/`protocol.md`. Runs on every PR as its own workflow (`.github/workflows/docs-check.yml`), kept separate from `test.yml` so it never queues behind a cargo build.
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
- `docs/` — **read [`docs/README.md`](docs/README.md) first**: it classifies every doc as ACTIVE / PROPOSED / HISTORICAL. ACTIVE (trust as current): `architecture.md`, `protocol.md` (wire contract + conformance vectors), `backlog.md` (the audited *unbuilt* list), `workflow.md`. PROPOSED (**zero lines implemented**): `proposed/`. HISTORICAL (frozen, mostly Swift-era): `archive/`, `designs/`.
- `scripts/` — `bundle.sh`, `release.sh`.
- `packaging/` — `Tarmac.entitlements` (hardened-runtime entitlements for signing), `Casks/tarmac.rb` (Homebrew cask — bump version+sha256 after release), `icon/`.

## Conventions

- **Commits: Conventional Commits.** `type(scope): summary` (whole history conforms). Types in use: `feat`, `fix`, `refactor`, `perf`, `docs`, `chore`, plus bare `release:` for version bumps. Scopes are area tags, not paths (`feat(terminal)`, `fix(board)`, `feat(m3)`, `feat(protocol)`, …). PRs are squash-merged with `(#N)` suffix.
- **Where tests live.** Rust: inline `#[test]`/`#[tokio::test]` in `src/` + subject-named integration suites under each crate's `tests/`. Desktop: Vitest unit tests in `desktop/` (`npm test`). `desktop/src-tauri/` has its own `cargo test`.
- **Formatting is convention-by-imitation.** No `rustfmt.toml`/`.swiftformat`/`.editorconfig`, no formatter command, and no CI check on style — the CI workflows run docs-check and the test suites only. Match surrounding code. `make test` must pass before opening a PR.
- **Commit trailers: both.** A DCO `Signed-off-by:` (`git commit -s`) is required by `CONTRIBUTING.md` and enforced on PRs by `.github/workflows/dco.yml`; the `Co-Authored-By:` trailer the history uses is attribution and is kept alongside it. `make dco-check` verifies the branch. (Commits before that workflow are unsigned and were not rewritten.)
- **TDD is mandatory.** Red → green → refactor: write the failing test, *watch it fail on the unmodified tree*, then make it pass with the smallest change. A test that would pass before your change is not a test of your change. For the React/Tauri shell — which has no unit tests by design — extract the decision into `desktop/src/kit/` and TDD that, leaving the component as wiring. Placement table, the closed exception list, and what each exception owes instead: [`docs/coding-style.md`](docs/coding-style.md).
- **Coding style: SOLID, ultra-concise, no line-noise comments.** Keep modules/functions single-responsibility and depend on narrow interfaces (protocol types, plain function signatures) rather than reaching across layers. Prefer the smallest correct diff over a more "thorough" one. Don't add comments that restate what the code already says line-by-line; a comment earns its place only by explaining a non-obvious *why* (a hidden constraint, a workaround, an invariant) — see the Gotchas below for the kind of thing that's worth a comment. The full reference — naming, error handling, lock discipline, the `kit/` layering, per-language test idioms — is [`docs/coding-style.md`](docs/coding-style.md).

## Gotchas

- **Milestone names are history, not a roadmap.** `M0`–`M3` and `v4` are *closed*; they survive as archived plans only — the integration suites that carried their names are now subject-named (`tests/{daemon_basics,restore,honest_signals,boards}_integration.rs`). `v4c` (editable docs) is a **proposal that was never started** — doc cards are read-only, and none of its chrome (`.edit`, `.tm-caret`, `.tm-homechip`, `.tm-conflict`) exists in the code. There is no `M4`/`M4c`/`v5`. Work since M3 is per-issue (`docs/workflow.md`).
- **Anything naming a `.swift` file, `SwiftTerm`, `WKWebView`, `DocWebView`, or `app/Sources/` is describing the deleted Swift app** (replaced by Tauri + React + xterm.js in #27). Such references survive in `docs/archive/`, `docs/designs/`, `.blueprint/specs/`, and in code comments that cite the Swift original as the port's provenance — none of them are current file paths. Also gone on purpose (`docs/backlog.md` §4 — don't re-file these as missing): the **shelf**, the terminal **dock pane**, and **peek (`⌘P`)**; `doc_read` still exists on the wire but has no caller in the app.
- **`make` is the source of truth, not the editor.** Always verify compilation with `make`, not IDE diagnostics.
- **A persistent installed `tarmacd` can hijack the dev app.** `make run` only points the dev app at the debug daemon via env — it doesn't kill an already-installed one. Kill any running/installed daemon before testing daemon changes.
- **Do NOT `cargo fmt` the Rust crates.** Local rustfmt disagrees with the whole committed repo and would create spurious churn.
- **Wire protocol is additive-keys-only and conformance-gated.** Never change/remove a key or alter encoding without regenerating the hex conformance vectors (V1–V8), which are mandatory tests in `tarmac-protocol` (exercised by both `core` and the desktop backend, which path-deps it). The frontend consumes already-decoded data over Tauri IPC, so there is no second-language codec to keep in lockstep. Rust must encode with `rmp_serde::to_vec_named` (plain `to_vec` emits arrays and breaks the contract); binary payloads use msgpack `bin` via `serde_bytes`.
- **Serde stack is pinned with `=`** (`serde =1.0.228`, `rmp-serde =1.3.1`, `serde_bytes =0.11.19`) — the tagged-enum + serde_bytes interaction is verified only on those versions.
- **`repo_color_index` (Rust, FNV-1a 64 mod 4) must stay byte-for-byte identical to the app's color logic** — changing it alters colors users already saw.
- **`socket_path()` is duplicated** in `tarmacd/src/main.rs` and `tarmac-cli/src/main.rs` (not shared) — keep them in sync.
- **Daemon lock discipline is load-bearing.** `std::sync::Mutex`es (watcher, term master, scrollback) are never held across `.await`; board-delete clones PTY handles and drops the lock before `kill()`. PTY kill signals the whole process group (`SIGHUP`).
- Tarmac is **not MCP / not an agent harness** on purpose — `tarmac open` is a plain CLI over a Unix socket so any caller can ring the doorbell. Don't propose MCP-based coupling.
