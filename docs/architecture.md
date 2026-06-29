# Tarmac — Architecture

This is the engineering overview of how Tarmac is built. For what Tarmac *is*
and how to run it, see the [root README](../README.md). For the exact wire
contract, see [`protocol.md`](protocol.md).

Tarmac is two programs that share nothing in-process and communicate only over a
Unix socket:

- **`tarmacd`** — a Rust/Tokio background daemon. The *observatory and PTY
  owner*: it spawns and owns every terminal, watches every opened doc, observes
  OS facts (process names, file changes, bells, exits), holds all the boards,
  and persists everything to disk.
- **`TarmacApp`** — a Tauri 2 + React + xterm.js application (`desktop/`). The
  *cockpit glass*: it renders the boards and cards, hosts terminal surfaces and
  doc cards, and turns human input into requests to the daemon.

A third tiny binary, the **`tarmac` CLI**, is the universal doorbell: `tarmac
open <path>` connects to the daemon, names a doc, and exits.

```
   +----------------------------+         +----------------------------------+
   |TarmacApp (Tauri 2 / React) |         |tarmacd (Rust / Tokio)            |
   |the cockpit glass           |         |Daemon (Arc, shared):             |
   |desktop/ (Vite + React)     |  unix   |  boards: Mutex<Boards>           |
   | - boards / cards           | socket  |  terms:  Mutex<HashMap>          |
   | - xterm.js terminals       |<------->|  term_boards: Mutex<...>         |
   | - doc cards                | msgpack |  watcher (notify / fswatch)      |
   | - Tauri backend (Rust)     | frames  |  persistence (state.json)        |
   +----------------------------+         +----------------------------------+
                                                       |
                                                       |  spawns ptys (sets TARMAC_TERM_ID)
                                                       v
   $ tarmac open <path>   ------------------->  tarmac CLI (Rust, std-only)
   (run inside a tarmac pty)                    names a doc, then exits
```

---

## 1 · Design principles

These constraints are load-bearing — the rest of the system is derived from
them. They survived intact from the v3 design into the shipped v4 build.

1. **No-harness honesty.** Tarmac never wraps, parses, or impersonates the
   agent. Every UI signal maps to one observable OS-level fact. The interface
   never claims "the agent is working / waiting"; copy is temporal-correlative
   ("during claude"), never causal. This is *why* `tarmac open` is a plain CLI +
   socket and not MCP — any caller can ring the doorbell, so the signal stays
   universal and single-sourced.

2. **The terminal keeps focus.** Typing always reaches the prime terminal.
   Agent-driven events, while you work, may only *mark* (dots, pulses, toasts) —
   they never switch your view or take your keystrokes.

3. **Position is memory.** Card frames, z-order, shelf membership, and the board
   viewport are persisted per board; the exact spatial layout returns on
   restart.

4. **The protocol grows by additive keys only.** Every key added after M0 is
   optional with a missing⇒nil/default decode, and both sides ignore unknown
   message *types* and unknown *keys*. So persistence and new features never
   break an older client, and a daemon restart produces a restore
   indistinguishable from no restart.

5. **Never block the user for performance.** There is no hard card cap per
   board. Cost is managed by offloading offscreen work (suspending inactive
   boards' doc webviews, semantic-zoom locards), never by refusing the user.

6. **The daemon owns facts; the app owns the moment.** Anything that must
   survive a restart, or is an observed OS fact, lives in the daemon. Live,
   in-the-moment view state lives in the app.

---

## 2 · The wire protocol

The full contract — with byte-exact conformance vectors — is
[`protocol.md`](protocol.md). The essentials:

**Transport.** One Unix stream socket, resolved identically by daemon, CLI, and
app **per build channel** (override `TARMAC_SOCKET`). A *release* build uses
`~/Library/Application Support/tarmac/tarmacd.sock` (unchanged); a *debug* build
uses `~/Library/Application Support/tarmac/dev/tarmacd.sock`, so a `make run` dev
build and the installed release app never collide. State (`state.json`) sits
beside the socket under the same per-channel dir. On startup the daemon tries to
connect to an existing socket file: success means a live daemon already owns it
(log and exit 1); failure means it is stale (unlink and rebind).

**Framing.** Every message is a 4-byte big-endian `u32` length prefix followed
by that many MessagePack bytes. Max frame is 16 MiB; anything larger is a
protocol error that closes the connection. (`tarmac-protocol::frame`, reused by
the desktop backend over the same path-dep.)

**Encoding.** Each message is a MessagePack **map with string keys** — Rust
encodes with `rmp_serde::to_vec_named` (plain `to_vec` would emit arrays and
break the contract). A `"t"` string tag identifies the type. Binary payloads
(`Input`/`Output` bytes) use the msgpack **bin** family via `serde_bytes`, never
arrays of ints. Decoders accept keys in any order, accept any integer width, and
treat a missing optional key as nil.

**Handshake & the single-app slot.** The first frame is
`Hello { role: "cli" | "app", v }`; the daemon replies `HelloOk { v }` (version
1) or `Err` and drops. The daemon serves a **single app at a time**: a newly
connecting app evicts the previous one (its cancellation token is fired). Every
daemon→app frame funnels through one bounded mpsc channel drained FIFO by one
writer task; with no app attached, `Daemon::push` drops the frame silently — so
the PTY pump keeps running and filling scrollback even with the UI gone.

**The message set** (one tagged `Msg` enum; unknown tags decode to `Unknown`):

| Group | Message | Dir | Purpose |
| --- | --- | --- | --- |
| Lifecycle | `Hello {role, v}` | C→D | handshake |
| | `HelloOk {v}` | D→C | accept |
| | `Ack` | D→cli | generic success (reply to `open`) |
| | `Err {msg}` | D→C | error notice (closes the link on a handshake error) |
| Docs | `Open {path, term_id?, board_id?}` | cli/app→D | surface a doc |
| | `DocRead {path}` | app→D | mark a doc read |
| | `DocOpened(DocEntry)` | D→app | a doc was opened/updated |
| | `FileEvent {path, mtime_ms}` | D→app | a watched doc changed on disk |
| Terminal I/O | `SpawnTerm {term_id, cols, rows, cwd?, cmd?, board_id?}` | app→D | create a PTY card |
| | `Input {term_id, bytes}` | app→D | keystrokes |
| | `Output {term_id, bytes}` | D→app | raw PTY output (≤64 KiB chunks) |
| | `Resize {term_id, cols, rows}` | app→D | resize the PTY |
| | `Exit {term_id, code?}` | D→app | the PTY exited (nil code = signal death) |
| | `TermProc {term_id, name, pid?}` | D→app | foreground process name changed |
| | `Bell {term_id}` | D→app | a BEL (0x07) was seen |
| Layout | `Layout {dock, tiles, board?, board_id?}` | app→D | layout snapshot for a board |
| | `Restore {docs, tiles?, board?, board_id?, live_terms?}` | D→app | full board state to mount |
| Boards | `BoardList {boards, active}` | D→app | all boards + active id |
| | `BoardSwitch {board_id}` | app→D | make a board active |
| | `BoardCreate` | app→D | mint a fresh board |
| | `BoardRename {board_id, name}` | app→D | set/clear display name |
| | `BoardDelete {board_id}` | app→D | remove a board (refuses the last) |

Supporting structs: `DocEntry`, `Tile` (kind + optional `path,x,y,w,h,z,loose,
shelf,term_id`), `BoardMeta {board_id, name?, running?}`, `BoardViewport {zoom,
cx, cy}`.

**Conformance vectors are the tripwire.** Both codebases carry the same
hex-encoded msgpack vectors as mandatory tests; each must decode to the same
structure and survive an encode→decode roundtrip on both sides. The serde stack
(`serde`, `rmp-serde`, `serde_bytes`) is pinned to exact versions because the
tagged-enum + `serde_bytes` interaction is fragile; the vectors catch any silent
encoder drift. Vectors only grow additively (V1–V8 frozen).

---

## 3 · The daemon (`tarmacd`)

### Process & connection model

`main()` claims the socket, builds one shared `Arc<Daemon>`, and accepts
connections on a `tokio::net::UnixListener`, spawning `conn::handle` per
connection. A SIGTERM/SIGINT handler removes the socket and `exit(0)`s (so live
shells die with a full daemon restart — see [§6](#6--what-survives-what)).

The CLI gets a short-lived `cli_session`. The app gets a long-lived
`app_session` that installs the single-app slot, creates the bounded
`mpsc::channel::<Msg>(256)`, and spawns the one writer task that owns the socket
write half. A monotonic generation guard ensures a late teardown of an evicted
connection can't clobber the new app's slot.

### State model

```
Daemon
 ├─ app:         Mutex<Option<AppSlot>>          single-app slot + writer tx
 ├─ boards:      Mutex<Boards>                   N boards, ONE coarse lock
 │                └─ Vec<Board { id, name?, Registry }>  + active: BoardId
 │                     └─ Registry { docs, dock, tiles, board: viewport }
 ├─ terms:       Mutex<HashMap<term_id, Arc<TermHandle>>>   all live PTYs, global
 ├─ term_boards: Mutex<HashMap<term_id, BoardId>>           which board owns a term
 └─ watcher:     std::sync::Mutex<WatcherState>             notify debouncer
```

A board is the unit that became N in M3. The N boards sit behind **one coarse
async mutex** (N is single-digit; a `Vec` preserves `⌘1`–`9` order). Terminals
live in a **global** map keyed by globally-unique `term_id`, with a separate
`term_id → board_id` index set at spawn — so terminal I/O stays board-agnostic
while `tarmac open` provenance, per-board teardown, and restore can all scope by
board. A board is never term-less (an empty layout is seeded with one terminal
tile). `delete()` refuses the last board and, if the deleted board was active,
fixes `active` to the board now at the clamped deleted index.

**Lock discipline (load-bearing).** Mutexes are taken **sequentially, one
statement at a time, dropped before the next — never nested**. The clearest
example is `BoardDelete`: snapshot the board's term_ids under `term_boards` and
drop; clone their `Arc<TermHandle>`s under `terms` and drop; **kill with no lock
held**; then `boards.delete()`; then recompute counts and re-push. The
per-terminal scrollback ring uses a `std::sync::Mutex` that is **never held
across an `.await`** — locked only for a synchronous push/snapshot.

### Terminal sessions

PTYs run on `portable-pty`. `term::spawn` builds the command (explicit `cmd`
argv, else `$SHELL -il`), sets `cwd`, `TERM=xterm-256color`, and
`TARMAC_TERM_ID=<term_id>` in the child env — which is exactly what the CLI reads
back for `open` attribution.

Each terminal fans out into blocking threads (reader → 64 KiB chunks, writer,
`child.wait()` → exit code via oneshot, a 750 ms process-name poll) plus one
async **pump** that owns the daemon handle. The pump is the only place with a
daemon reference, so it is where the three honest signals are sourced:

- **`TermProc`** — poll the master's `process_group_leader` pid, resolve the
  executable basename via `proc_pidpath` (macOS), push only when the name
  *changes*. This becomes the card's title.
- **`Bell`** — scan output chunks for `0x07`, debounced to one per ~250 ms.
- **`Exit`** — `child.wait()`; a signal death sends `code: None` (the protocol's
  nil marker), never a fabricated code. The app turns it into a *dead card*; the
  daemon does **not** auto-respawn.

`kill()` signals the whole **process group** (`libc::kill(-pid, SIGHUP)`) — the
child is its own group leader, so a SIGHUP lets a shell exit cleanly as on a
terminal close.

Each terminal keeps a byte-capped **scrollback ring** (256 KiB, front-eviction),
appended unconditionally even with no app connected. On (re)connect the daemon
replays it so the app can re-bind to the live shell instead of cold-spawning.

### Docs & file watching

`Daemon::new` builds a `notify` debouncer (100 ms) and watches the **parent
directory** (non-recursive) of every docked doc, filtering events to known doc
paths — editors and agents replace files atomically, so watching the inode
directly misses rewrites. Events are filtered by *path only, never by event
kind*. On a hit the daemon stats the file, records `last_changed_ms` **before**
pushing (so a crash never loses the fact), and pushes `FileEvent`.

`tarmac open` end-to-end: the CLI canonicalizes the path, connects, reads
`TARMAC_TERM_ID` from its env, and sends `Open`. The daemon re-canonicalizes
(FSEvents reports resolved paths), validates it's a regular file, ensures the
parent dir is watched, **resolves the target board** (explicit `board_id` →
caller term's board → active), upserts the doc into that board's registry,
derives repo metadata (walks parents for `.git`; FNV-1a color index, byte-identical
to the app's), and pushes `DocOpened`.

### Persistence

State is atomic JSON at `~/Library/Application Support/tarmac/state.json`
(override `TARMAC_STATE`). The shape is nested: `{ boards: [{ board_id, name?,
docs, tiles, board? }], active }`. Durable: the board set + active id + names;
each board's docs in dock order with read flags / timestamps / `term_id`
provenance; the tile layout (v4 geometry + per-term tile ids); the viewport.
Repo metadata is written for inspectability but **recomputed at load** — a `.git`
appearing or vanishing between runs is treated as an observed fact, not trusted
from disk.

The save loop waits on a `dirty` notify, sleeps 150 ms to coalesce a burst,
snapshots under the lock, and writes via a temp file + fsync + rename so a crash
never swaps in a truncated file. A missing/corrupt file is never fatal (fall
back to a default single board). A pre-M3 *flat* file (no `boards` key) is
migrated once into a single `board-0` verbatim; writes always emit the nested
shape — lossless and one-way.

---

## 4 · The desktop app (`TarmacApp`)

The cockpit glass is a Tauri 2 application in `desktop/`. The React frontend
(Vite, TypeScript) renders the infinite board, card chrome, and wayfinding
overlays. xterm.js backs each terminal card; doc cards render markdown in a
sandboxed webview. The Tauri Rust backend (`desktop/src-tauri/`) owns the
daemon connection, mirroring the wire framing from `tarmac-protocol` (path dep).

**DaemonClient** is the long-lived socket connection. On connect it sends
`Hello`, then starts a read loop delivering messages to the frontend via Tauri
events. If `TARMAC_DAEMON` is set it spawns the daemon binary and retries ~3 s.

Connection state is **app-local**: on disconnect, cards are marked detached
(not dead — the pty may still be alive daemon-side) and a bounded auto-reconnect
ramps 0.5→1→2→4→8 s capped at 15 s, up to 10 attempts. When `Restore` arrives
with `live_terms`, surviving terminal cards are rebound to live ptys (replayed
scrollback repaints cleanly); gone shells are cold-spawned under the same
`term_id`.

**Board & card model.** A `Viewport {zoom, cx, cy}` drives a world↔view
transform; pan / pinch-zoom / `fitToCards` reproject the card layer. Each card
carries a world-space `CardFrame {x,y,w,h,z}`. Card chrome states —
`prime/quiet/dead/detached/fresh/selected` — are mostly orthogonal flags.
**Gravity**: moving a terminal card drags its attached doc satellites; a user
move of a doc card detaches it. Below zoom 0.5 cards collapse to locards.

**Terminal cards** embed an xterm.js instance keyed by `term_id`. Input/resize
forward to the daemon; output routes to the owning board's buffer even when
backgrounded so the shell keeps progressing.

**Doc cards** render markdown (DocTemplate pattern). Inactive boards' doc views
are suspended on switch-away and resumed on switch-back. Peek (`⌘P`) marks a
doc read without moving focus. The shelf holds unplaced docs as chips. Provenance
edges (dashed cyan bézier) connect a doc card to its caller terminal.

**Multiple boards.** A `⌘K` switcher shows per-board running/bell/card counts,
supports type-to-filter, `⌘N` create, `⌘E` rename, `⌘⌫` delete. `⌘1`–`9` jump
directly. Switching suspends the leaving board's doc views and mounts the target.

---

## 5 · Key data flows

**`tarmac open` → a card.** Agent runs `tarmac open plan.md` inside a tarmac pty
→ CLI canonicalizes + reads `TARMAC_TERM_ID` + sends `Open` → daemon resolves the
caller's board, upserts the doc, ensures the parent dir is watched, derives repo
metadata, pushes `DocOpened` → app lands a `fresh` card right of the caller
terminal with a provenance edge → agent edits the file → daemon `FileEvent` →
card halos cyan.

**App disconnect → reconnect.** Daemon stays up; ptys keep running and filling
scrollback. App marks sessions detached, chip flips to *detached*, auto-reconnect
ramps. On reconnect the daemon sends `BoardList` + the active board's `Restore`
(stamped with `live_terms`) + replays each live term's scrollback as `Output`
frames. App revives each surviving card in place (re-bind, not respawn) and the
chip flips back to *attached*.

**Board switch (`⌘K` → Enter).** App suspends the leaving board's doc webviews,
undocks, detaches its view, and sends `BoardSwitch` → daemon sets active and
replies `BoardList` + that board's `Restore` (+ scrollback for its live terms) →
app mounts the target board, resumes its doc webviews, and re-binds chrome to its
viewport.

---

## 6 · What survives what

| Event | Terminals | Layout / docs / viewport |
| --- | --- | --- |
| **App reconnect** (daemon stays up) | **Survive** — re-bound to live ptys, scrollback replayed | Restored from daemon memory |
| **App relaunch** (daemon stays up) | **Survive** — re-bound on connect | Restored |
| **Daemon restart** | Re-spawned fresh (cold) — live shells died with the daemon | Restored exactly from `state.json` |

Daemon-restart PTY re-parenting (true live-shell survival across a daemon
restart) is designed but deliberately unbuilt; cold layout-only restore + the
app-reconnect re-bind cover the common cases. See `docs/archive/m3/plan.md`
decision 2.

---

## 7 · Milestones & status

Complete on `main` (2026-06-15):

- **M0** — walking skeleton: daemon + CLI + app over the v1 wire; `tarmac open`,
  ptys, file watching.
- **M1** — doc states + layout: additive doc-entry keys (repo/color/read/
  timestamps), normative dock order, desk tiles, `doc_read`/`layout`.
- **v4 whiteboard migration** (Phases 0–5b) — the pivot from a slot grid to a
  single infinite board: Breeze theme, world-space card frames + persisted
  viewport, gravity/shelf/provenance, wayfinding, terminal primacy, and N
  terminal cards keyed by `term_id`.
- **M2** — honest signals (absorbed as v4 Phase 3.5): `TermProc`, `Bell`, exit
  codes as new daemon→app message types.
- **M3** — strips = boards: N named boards, the `⌘K` switcher, `⌘1`–`9`, per-board
  restore, the titlebar session chip, an honest attached/detached signal, board
  rename/delete, reconnect re-bind, and inactive-board webview suspension. P5
  shipped a simplified "two honest signals" session model (app-local chip +
  additive `BoardMeta.running` + `Restore.live_terms`, no new session struct).

Unbuilt / deferred is audited in [`backlog.md`](backlog.md). The next milestone
is **editable docs (v4c)** — it needs a design round and the write-honesty model
first.

## 8 · Further reading

- [`protocol.md`](protocol.md) — the authoritative wire contract + conformance
  vectors.
- [`archive/m3/plan.md`](archive/m3/plan.md) — the "strips = boards" milestone,
  decisions, and phase acceptance.
- [`archive/v4/migration-plan.md`](archive/v4/migration-plan.md) — the
  grid→whiteboard migration.
- [`backlog.md`](backlog.md) — designed-but-unbuilt features and by-decision
  deferrals.
- [`v4c/visual-crib.md`](v4c/visual-crib.md) — captured spec for the next
  milestone (editable docs). The original v3/v4 design handoff (README + mocks +
  chat transcripts) is preserved in git history; its still-relevant details were
  absorbed into the cribs and `backlog.md`.
