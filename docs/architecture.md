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
- **`TarmacApp`** — a Swift/AppKit application. The *cockpit glass*: it renders
  the boards and cards, hosts the terminal surfaces and doc webviews, and turns
  human input into requests to the daemon.

A third tiny binary, the **`tarmac` CLI**, is the universal doorbell: `tarmac
open <path>` connects to the daemon, names a doc, and exits.

```
   +----------------------------+         +----------------------------------+
   |TarmacApp (Swift / AppKit)  |         |tarmacd (Rust / Tokio)            |
   |the cockpit glass           |         |Daemon (Arc, shared):             |
   |AppController (the spine)   |  unix   |  boards: Mutex<Boards>           |
   | - boards / cards           | socket  |  terms:  Mutex<HashMap>          |
   | - SwiftTerm surfaces       |<------->|  term_boards: Mutex<...>         |
   | - WKWebView doc cards      | msgpack |  watcher (notify / fswatch)      |
   | - DaemonClient             | frames  |  persistence (state.json)        |
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
protocol error that closes the connection. (`tarmac-protocol::frame`; mirrored
in Swift `Framing`.)

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

## 4 · The macOS app (`TarmacApp`)

### Two-target split

`app/Package.swift` declares **`TarmacKit`** (a pure, AppKit-free library — only
Foundation/CoreGraphics) and **`TarmacApp`** (the AppKit executable), plus
`tarmac-smoke` (a cross-language e2e client that drives a real daemon).

Everything deterministic lives in TarmacKit and is unit-tested there: the
transport codec (`Framing`, `MsgPack`, `Messages`), board math
(`BoardTransform` world↔view affine, `BoardWayfinding` fit/minimap/offscreen/
cascade), the rules and view-models (`BoardSwitcher`, `DocStore`, `DocRouting`,
`Provenance`, `Reconnect`, `TermRestore`, `DocSuspend`, `TermBoardIndex`,
`BootTerminal`). `DaemonClient` also lives in TarmacKit but, being the live
socket client, is exercised by the `tarmac-smoke` integration target rather than
unit-tested. The AppKit views deliberately delegate their math to
TarmacKit (e.g. `BoardView` calls `BoardTransform`; `Minimap` calls
`BoardWayfinding`) so the views stay thin.

`TarmacApp` holds the untestable AppKit half: `AppController` (the coordinator
spine), `Board` (per-board state container), `BoardModel` (view-layer frame
structs), the whiteboard/card/chrome views, `DocWebView`, and the wayfinding
overlays. **The GUI layer is not unit-tested by design** — pure logic is pushed
into TarmacKit; the reparent/focus behaviors are GUI-verified. (See the project
memory note on this.)

### DaemonClient, reconnect, and revive

`DaemonClient` is the long-lived socket connection, mirroring the Rust framing
and codec exactly. `connect()` is blocking: it tries once, and (if
`TARMAC_DAEMON` is set) spawns the daemon and retries for ~3 s; on success it
sends `hello` and starts a background read loop that hops to the main queue
before delivering `onMessage` / `onDisconnect`.

Connection state is **app-local**: the daemon can't tell a gone app that it
detached, so the attached/detached chip is driven by `DaemonClient`'s own state.
On disconnect, sessions are marked **detached** (faint, *not* dead — the pty may
still be alive daemon-side), each affected board is queued for revive, and a
**bounded auto-reconnect** is armed: `Reconnect.delay(forAttempt:)` ramps
0.5→1→2→4→8 s capped at 15 s, up to 10 attempts; `quitting`/`reconnecting`
latches keep it single-flighted and stoppable.

When the reconnect's `Restore` arrives carrying `live_terms`, `reviveTerminals`
swaps a *fresh empty SwiftTerm view* into each surviving card under the same
`term_id` (so the daemon's replayed scrollback repaints cleanly without
duplicating the old buffer), then re-binds without spawning (term is live) or
cold-spawns under the same id (shell gone). `maybeSpawn` is gated on the
awaiting-revive set so a detached prime is never cold-spawned over a surviving
shell. The pure rebind-vs-cold decision is `TermRestore.plan`.

### Board & card view model

`BoardView` is the infinite whiteboard. A `Viewport {zoom, cx, cy}` drives the
transform `view = (world − center)·zoom + viewportCenter` (delegated to
`BoardTransform`), the flipped view draws a world-space dot grid, and pan
(`scrollWheel`) / anchored pinch zoom (`magnify`) / animated `flyTo` /
`fitToCards` reproject the card layer.

`CardView` is a free card carrying a world-space `CardFrame {x,y,w,h,z}`; it
embeds a `TerminalBodyView` (`.term`) or a `DocWebView` (`.doc`). Card chrome
states are explicit, mostly-orthogonal flags with guarded setters:

- **`prime`** — the focused terminal (accent border, darker header, deeper
  shadow).
- **`quiet`** — any non-prime card while some terminal is prime (alpha 0.8).
- **`dead`** — the pty exited (alpha 0.55, header relabelled `exit N · ↵
  respawn`; absorbs/ignores other states to stay dead).
- **`detached`** — daemon link dropped (alpha 0.5, reversible).
- **`fresh`** — a just-landed CLI card (agent ring + `✚ now`, cleared on
  select/read).
- **`selected`** — agent border + 7px corner resize handles.

Free move + corner resize convert pointer deltas to world deltas via
`worldPerView` (= 1/zoom). **Gravity**: moving a terminal card drags its
attached doc satellites by the same world delta; a user move of a doc card
detaches it. esc cancels an in-flight gesture. `worldFrame.z` drives stacking;
selecting raises to front. Below the semantic-zoom threshold (0.5) every card
swaps its chrome for a compact locard (name + status + signal).

### Terminal cards

Each terminal card is backed by a `TerminalSession` owning a SwiftTerm
`TerminalView` and a per-terminal `TermDelegateBridge` — the **TerminalSurface
seam**. The bridge carries the card's `term_id` and routes SwiftTerm's delegate
callbacks onto the controller, so each surface self-identifies its pty with no
global "current terminal." Everything is keyed by `term_id`: input forwards via
`client.input(termID:)`, resize debounces via `client.resize`, and output routes
through the `TermBoardIndex` to the owning board's buffer — **even when that
board is backgrounded**, so its shell keeps progressing. `⌘T` mints a fresh
term_id and places a card cascade-offset from the prime; `⌥`-tab cycles prime to
the next live terminal with a HUD.

### Doc cards

A doc card's body is `DocWebView`, a `WKWebView` (subclassed non-focusable so a
click never steals focus from the terminal). It loads the bundled
`DocTemplate.html` and renders markdown by calling `window.tarmacRender(...)`,
which preserves the reading position across re-renders. For multi-board memory,
inactive boards' doc webviews are **suspended** (parked on `about:blank` to free
their web-content process) on switch-away and **resumed** on switch-back; the
guard logic is the pure `DocSuspend`. Terminals are *not* suspended.

**Peek** (`PeekPanel`, a slide-over) opens via `⌘P` or a shelf-chip click and
marks the doc read without moving focus. The **shelf** (`ShelfView`) holds
open-but-unplaced docs as chips; dragging one onto the board lands a card.
**Provenance**: each doc records the `term_id` that opened it; `DocRouting`
resolves the owner only when it's one of that board's live terminals, and an
attached doc card shows a `← <termname>` chip connected to its caller by a
dashed cyan bézier in `EdgeLayerView`.

### Wayfinding chrome

Four overlays, refreshed from real signals on every viewport/card change:
**minimap** (card rects colored by signal + the viewport rect, click-to-jump),
**zoom control** (`− % + ⊡ fit`), **offscreen hints** (a pill pinned to the
viewport edge toward each off-screen signalling card; bell outranks live; Return
flies to the top one), and the **status bar** (`▞ <board> · N boards`, the
attached/detached word, and `N cards on board · M in shelf`).

### Multiple boards

`AppController` holds `boards: [board_id: Board]` with one `activeBoardID`. A
`Board` owns its `BoardView`, `DocStore`, sessions, dock/shelf state, and
provenance map; `AppController` reaches the active board through computed shims,
so a switch automatically re-targets every read/write. Only the active board's
view is mounted; backgrounded boards keep their cards and live SwiftTerm views
detached so their ptys stay live.

The **`⌘K` switcher** (`BoardSwitcherView` is render-only) computes its rows from
the pure `BoardSwitcher` view-model: per-board running/bell/card counts (local
for visited boards, daemon `BoardMeta.running` for never-visited ones),
prefix-filtered rows, 86×54 thumbnails reusing the wayfinding projection. Keys:
type-to-filter, `↑/↓` + `⏎`/`⌘1`–`9` to open, `⌘N` to create, **`⌘E`** inline
rename (empty clears to slug), **`⌘⌫`** one-key-confirm delete (refused for the
last board, mirroring the daemon's authority).

### Focus model

The SwiftTerm view is the window's default first responder; the board takes
focus only when its background is clicked. Every keystroke passes through a
global key monitor that calls `reconcilePrimeToFocus` so prime tracks whatever
live terminal the user clicked into. Peek / dock / cycle all
reconcile-then-refocus the prime terminal, so focus is never moved off it.
Exactly one live terminal is prime; nothing is prime when no terminal is live.

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
