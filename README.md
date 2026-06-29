<p align="center">
  <img src="docs/images/logo.png" width="160" alt="Tarmac logo">
</p>

# Tarmac

**A terminal-first cockpit for working alongside CLI coding agents.**

![A Tarmac board: a Claude Code agent (left) ran `tarmac open` on several project docs, which surface as live cards on the right — each tied back to the terminal that opened it by a dashed provenance edge.](docs/images/board.png)

You run `claude` (or any agent) in a real terminal inside Tarmac. When that
agent — or you, or a Makefile, a git hook, CI — runs `tarmac open <path>`, the
referenced markdown doc appears as a card on an infinite, pannable, zoomable
**board**, placed right next to the terminal that called it and tied to it by a
dashed provenance edge. The terminal stays the center of gravity; the docs your
tools produce gather around it.

Tarmac is deliberately **not an agent harness**. It never sits between you and
the tool, never parses the agent's output to guess what it's doing, and never
claims "the agent is working / waiting." Every mark on screen is backed by
something the operating system can actually observe — a running process, a
file's mtime changing, a `tarmac open` socket call, a terminal bell. The
workspace grows out of facts, not configuration: there is no welcome screen, no
import step, no setup. Surfaces appear the moment a real event produces them.

> Status: **working prototype.** Milestones M0–M3 and the v4 whiteboard
> migration are complete on `main`, and the UI has since been rebuilt on
> Tauri 2 + React + xterm.js (replacing the original Swift/AppKit app).
> See [Status](#status).

---

## The idea

- **The terminal is the body; docs are summons.** Tarmac is "a terminal that
  grows docs," not "a doc app with a terminal attached." It opens as a bare
  shell; everything else materializes from what actually runs.

- **An infinite board of free cards.** A *board* is an infinite canvas you pan
  and zoom. The terminal and every opened doc are free cards carrying a
  world-space position — **position is memory**, persisted per board, restored
  exactly on relaunch. There is no grid, no slot cap.

- **`tarmac open` is a universal doorbell.** Any caller can ring it — the agent,
  you, a Makefile, a hook, CI. The cyan dot *means* "someone ran `tarmac open`,"
  full stop. That universality is why the integration is a plain CLI over a Unix
  socket and not MCP, which would re-couple Tarmac to one agent runtime.

- **Honest signals, never a harness.** Four marks, each one observable fact: a
  spinner + foreground process name + elapsed time (the process table), a cyan
  dot (`tarmac open` was called), a cyan halo pulse (the file changed on disk), an
  amber dot (the terminal rang its bell). Copy is temporal — `✎ 5s · during
  claude` — never causal. Tarmac reports; it does not arbitrate.

- **The terminal keeps focus.** Typing always goes to the focused ("prime")
  terminal regardless of where the pointer is. Selecting a card, opening the
  switcher, an agent firing an event — none of them steal your keystrokes.

## What it feels like

```
  board: api                                       [ attached ]
  -------------------------------------------------------------

   +- claude  4m12s ----+         +- plan.md ---------+
   | $ claude           |   open  | # Migration plan  |
   | > writing plan...  | ------> | ## Phase 1 ...    |
   | * opened plan.md   |  edge   | * edited 5s ago   |
   +--------------------+         +-------------------+

   [-] 100% [+]   fit                          ( minimap )
```

Run an agent. It writes a plan and calls `tarmac open plan.md`. The doc lands
beside it with a provenance edge. The agent edits the file; the card halos cyan.
You drag the terminal somewhere quieter and the plan follows it (gravity). You
press `⌘T` for a second shell and `⌘K` to flip to another board, all without
leaving the keyboard.

## Status

Built and shipped on `main`:

- **Infinite board** with Breeze theme, world-space card frames, pan/zoom, and
  per-board persisted layout + viewport.
- **`tarmac open` → cards** with gravity (docs follow their terminal) and dashed
  **provenance edges**.
- **Honest signals**: foreground process name, file-change pulse, terminal bell,
  exit codes — each from a real OS fact.
- **Wayfinding**: minimap, zoom control, and offscreen signal pills.
- **Terminal primacy**: a prime card, multiple terminal cards (`⌘T`), `⌥`-tab
  cycling, dead cards on exit (no auto-respawn).
- **Multiple boards**: a `⌘K` switcher with live thumbnails, `⌘1`–`9` jump,
  create / rename (`⌘E`) / delete (`⌘⌫`, refuses the last board).
- **Session liveness**: an honest attached/detached chip, bounded
  auto-reconnect, and in-place re-bind to surviving shells with scrollback
  replay (no respawn) when the app reconnects to a still-running daemon.

Not built yet — see [`docs/backlog.md`](docs/backlog.md) for the full audit:
the `tarmac focus` verb + idle-switch banner, the session-restore overlay,
in-terminal doc-path linkification, the titlebar process chip, the doc-rewrite
"place kept" pill, and edge-split drop. **Editable docs (v4c)** is the next
milestone. Real tmux/bare-attach, auto board-naming, daemon-restart PTY
re-parenting, and a libghostty renderer swap are deferred by decision.

## Architecture at a glance

Two processes over one Unix socket, length-prefixed MessagePack:

```
   +--------------------------+       +------------------------------+
   |TarmacApp (Tauri 2 +React)|       |tarmacd (Rust/Tokio)          |
   |the cockpit glass         | <---> |the observatory + PTY owner   |
   | - boards / cards         | unix  | - boards, docs, terminals    |
   | - xterm.js surfaces      |socket | - fswatch, process polling   |
   | - DOM doc cards (marked) |msgpack| - persistence (state.json)   |
   | - Rust bridge (socket)   |frames |                              |
   +--------------------------+       +------------------------------+
                                                  |
                                                  |  spawns ptys
                                                  v  (sets TARMAC_TERM_ID)
   $ tarmac open <path>   --------------->  tarmac CLI (Rust)
   (run inside a tarmac pty)                rings the doorbell over the socket
```

The daemon owns everything durable or observed (boards, docs, PTYs, file
events, persistence). The app renders facts and takes human input. They share
nothing in-process — only the wire protocol, which grows by **additive keys
only** so old and new clients always interoperate.

Full design: **[`docs/architecture.md`](docs/architecture.md)**. Wire contract:
**[`docs/protocol.md`](docs/protocol.md)**.

## Build & run

Requires macOS 14+, a Rust toolchain with edition 2024, and Node.js (for the
Tauri 2 + Vite + React frontend). Everything goes through the `Makefile`:

```sh
make core    # cargo build the daemon, CLI, and protocol crate
make app     # npm build the frontend + cargo build the Tauri Rust backend
make test    # cargo test (core) + npm test (frontend) + cargo test (Tauri backend)
make run     # launch the Tauri dev app (Vite HMR + the Rust backend)
```

`make run` sets `TARMAC_DAEMON` (so the app auto-spawns the freshly built
daemon) and prefixes `PATH` with the debug build dir (so `tarmac open` inside
the app's own terminals resolves the freshly built CLI). The CLI itself is just:

```sh
tarmac open <path>     # surface a markdown file as a card on the active board
```

`open` is currently the only verb. Inside a Tarmac terminal it auto-attributes
the doc to the calling terminal card via `TARMAC_TERM_ID`.

## Repo layout

| Path | What it is |
| --- | --- |
| `core/` | Rust cargo workspace (edition 2024): `tarmac-protocol` (wire types + codec + conformance vectors), `tarmacd` (the daemon), `tarmac-cli` (the `tarmac` CLI). |
| `desktop/` | Tauri 2 app (macOS 14+): `src/` (the React + xterm.js frontend, with pure unit-tested logic in `src/kit/`), `src-tauri/` (the Rust backend, which path-deps the `tarmac-protocol` crate). |
| `docs/` | Engineering docs — see the [docs map](#docs) below. |
| `scripts/` | `bundle.sh` (unsigned `.app`) and `release.sh` (sign + notarized `.dmg`). |
| `Makefile` | The build / test / run entrypoint. |

## Tests

Three suites, all run by `make test`: **Rust** in `core/` (protocol roundtrip +
frozen conformance vectors, daemon-lib, daemon integration over real sockets,
CLI), **Vitest** over the frontend's pure logic in `desktop/src/kit/`, and a
**Rust** suite in the Tauri backend (`desktop/src-tauri/`). The React/Tauri GUI
layer is not unit-tested by design — pure logic is extracted into
`desktop/src/kit/` and tested there; the UI behaviors are GUI-verified. The
conformance vectors live in `tarmac-protocol` and are exercised by both the
`core/` daemon and the Tauri backend (which path-deps the crate), pinning the
wire contract. The frontend consumes already-decoded data over Tauri IPC, so
there is no second-language codec to keep in lockstep.

## Docs

Current — the live set at the `docs/` root:

- [`docs/architecture.md`](docs/architecture.md) — the high-level design (this
  repo's engineering overview).
- [`docs/protocol.md`](docs/protocol.md) — the authoritative wire contract
  (transport, framing, every message, the frozen conformance vectors).
- [`docs/backlog.md`](docs/backlog.md) — what's designed but unbuilt, and what's
  deferred by decision.

History — milestone plans and visual cribs under [`docs/archive/`](docs/archive),
kept for provenance and superseded by the docs above:

- [`docs/archive/m3/plan.md`](docs/archive/m3/plan.md) — the "strips = boards"
  milestone record.
- [`docs/archive/v4/migration-plan.md`](docs/archive/v4/migration-plan.md) — the
  v3-grid → v4-whiteboard migration record.
- `docs/archive/m0/`, `docs/archive/m1/` — visual cribs from the earliest
  milestones.

The original v3 design handoff (README + mocks + design-chat transcripts) is
preserved in git history; the surfaces it described (dock/index rails, grid desk,
tabs/splits) were intentionally replaced by the v4 whiteboard and are recorded as
such in [`docs/backlog.md`](docs/backlog.md). Its still-relevant unbuilt details
were absorbed into `docs/` (e.g. the next milestone's
[`docs/v4c/visual-crib.md`](docs/v4c/visual-crib.md)).

## License

Tarmac is licensed under the [Apache License 2.0](LICENSE). Contributions are
welcome under the project's [contribution guidelines](CONTRIBUTING.md), which
require a Developer Certificate of Origin (DCO) sign-off.
