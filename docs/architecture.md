# Tarmac — Architecture

> **Doc status: ACTIVE** — normative. Describes Tarmac as it is on `main`; keep
> it in sync with the code. Anything designed-but-unbuilt belongs in
> [`backlog.md`](backlog.md) or [`proposed/`](proposed/), never here. See the
> [docs index](README.md) for how the doc set is classified.

This is the engineering overview of how Tarmac is built. For what Tarmac *is*
and how to run it, see the [root README](../README.md). For the exact wire
contract, see [`protocol.md`](protocol.md).

Tarmac is two programs that share nothing in-process and communicate only over a
Unix socket:

- **`tarmacd`** — a Rust/Tokio background daemon. The *observatory and PTY
  owner*: it spawns and owns every terminal, watches every opened doc, observes
  OS facts (process names, file changes, bells, exits), holds all the boards,
  and persists everything to disk.
- **`TarmacApp`** — a native Swift/AppKit application (`app/`, a SwiftPM
  package). The *cockpit glass*: it renders the boards and cards, hosts terminal
  cards (libghostty-vt for emulation and key/mouse encoding; drawing, IME and
   event handling are Tarmac's own) and
  doc cards, and turns human input into requests to the daemon.

A third tiny binary, the **`tarmac` CLI**, is the universal doorbell: `tarmac
open <path>` connects to the daemon, names a doc, and exits. `open` and
`--version` are its two verbs that talk to the daemon (`--version` only completes
the handshake, to report the daemon's and the connected app's versions);
`tarmac skill` is a purely local third verb that
prints the agent-facing guide (`core/crates/tarmac-cli/src/GUIDE.md`, embedded in
the binary); `tarmac skill install` copies a shim (`SKILL.md` beside it) into
each supported agent's skills directory, which tells the agent to run
`tarmac skill` and so cannot go stale with the guide.
A fourth family, `tarmac dev <verb>`, talks to the **app** rather than the daemon,
over a second socket the app owns (`tarmac-dev.sock`, beside the daemon's in the
same per-channel dir; override `TARMAC_DEV_SOCKET`). It is the in-app QA driver
from issue #166 — `snapshot`, `zoom`, `resize`, `focus`, `type`, `key` and
`press` — so an agent or a script can drive and read the cockpit without a
keyboard ([§4](#the-qa-driver-tarmac-dev)). It is compiled out of release builds
at two gates: `#[cfg(debug_assertions)]` on the CLI verb
(`core/crates/tarmac-cli/src/main.rs`) and `#if DEBUG` on the app's endpoint
(`app/Sources/TarmacApp/Dev/DevDriver.swift`) — the same predicate that maps a
build to its channel, so availability and channel cannot disagree. Its requests
are a separate `DevRequest` enum in `tarmac-protocol`'s `dev` module —
deliberately **not** `Msg` variants, so the wire contract below is untouched. Its
scenario suite is `scripts/qa/smoke.mjs`, run by `make qa` against a live
`make run` app and never by `make test`.

```
   +----------------------------+         +----------------------------------+
   |TarmacApp (Swift / AppKit)  |         |tarmacd (Rust / Tokio)            |
   |the cockpit glass           |         |Daemon (Arc, shared):             |
   |app/ (SwiftPM package)      |  unix   |  boards: Mutex<Boards>           |
   | - boards / cards           | socket  |  terms:  Mutex<HashMap>          |
   | - terminal cards           |<------->|  term_boards: Mutex<...>         |
   |   (libghostty-vt)          | msgpack |  watcher (notify / fswatch)      |
   | - doc / HTML cards (WebKit)| frames  |  persistence (state.json)        |
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

3. **Position is memory.** Card frames, z-order, each doc's attachment to its
   terminal, and the board viewport are persisted per board; the exact spatial
   layout returns on restart.

4. **The protocol grows by additive keys only.** Every key added after M0 is
   optional with a missing⇒nil/default decode, and both sides ignore unknown
   message *types* and unknown *keys*. So persistence and new features never
   break an older client, and a daemon restart produces a restore
   indistinguishable from no restart.

5. **Never block the user for performance.** There is no hard card cap per
   board. Cost is managed by offloading offscreen work (viewport culling hides
   far-offscreen cards without removing them, skips their chrome layout, and
   pauses a culled HTML card's schedulers), never by refusing the user.

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
protocol error that closes the connection. (`tarmac-protocol::frame` in Rust;
`Framing` in `app/Sources/TarmacKit/Framing.swift` on the app side.)

**Encoding.** Each message is a MessagePack **map with string keys** — Rust
encodes with `rmp_serde::to_vec_named` (plain `to_vec` would emit arrays and
break the contract). A `"t"` string tag identifies the type. Binary payloads
(`Input`/`Output` bytes) use the msgpack **bin** family via `serde_bytes`, never
arrays of ints. Decoders accept keys in any order, accept any integer width, and
treat a missing optional key as nil.

**Handshake & the single-app slot.** The first frame is
`Hello { role: "cli" | "app", v, app_version? }`; the daemon replies
`HelloOk { v, daemon_version?, daemon_pid?, app_version?, app_connected? }` (version
1) or `Err` and drops. The daemon serves a **single app at a time**: a newly
connecting app evicts the previous one (its cancellation token is fired). Every
daemon→app frame funnels through one bounded mpsc channel drained FIFO by one
writer task; with no app attached, `Daemon::push` drops the frame silently — so
the PTY pump keeps running and filling scrollback even with the UI gone.
`HelloOk.daemon_version` carries `env!("CARGO_PKG_VERSION")` — the workspace
version in `core/Cargo.toml`, which `scripts/dmg.sh` stamps before the build —
so the app can detect a stale daemon after a brew upgrade and restart it.
(`make dmg`, and `make release` through it, is the only path that stamps this
version; ad-hoc builds stay at the committed dev value.) The app names the same string in `Hello.app_version`
(`AppVersion`, `app/Sources/TarmacKit/AppVersion.swift`): a bundle reads its
`CFBundleShortVersionString`, which `scripts/bundle.sh` stamps with the version
of the daemon it carries; `make run` passes `TARMAC_APP_VERSION` to the unbundled
binary; an app that has neither names no version and never restarts a daemon.
The daemon keeps the app's version on the app slot and hands it back to `cli`
clients as `HelloOk.app_version`, alongside `app_connected` — slot occupancy
reported separately so a connected app that named no version is never rendered as
no app. Neither key is sent to an `app` client. This is what `tarmac --version`
reports.

**The message set** (one tagged `Msg` enum; unknown tags decode to `Unknown`):

| Group | Message | Dir | Purpose |
| --- | --- | --- | --- |
| Lifecycle | `Hello {role, v, app_version?}` | C→D | handshake |
| | `HelloOk {v, daemon_version?, daemon_pid?, app_version?, app_connected?}` | D→C | accept |
| | `Ack` | D→cli | generic success (reply to `open`) |
| | `Err {msg}` | D→C | error notice (closes the link on a handshake error) |
| Docs | `Open {path, term_id?, board_id?}` | cli/app→D | surface a doc |
| | `DocRead {path}` | app→D | mark a doc read |
| | `DocOpened(DocEntry)` | D→app | a doc was opened/updated |
| | `FileEvent {path, mtime_ms}` | D→app | a watched doc changed on disk |
| | `DocRefresh {path}` | app→D | re-stat a doc now and push its `file_event` |
| Terminal I/O | `SpawnTerm {term_id, cols, rows, cwd?, cmd?, board_id?, inherit_cwd_from?}` | app→D | create a PTY card |
| | `Input {term_id, bytes}` | app→D | keystrokes and mouse reports |
| | `Output {term_id, bytes}` | D→app | raw PTY output (≤64 KiB chunks) |
| | `Resize {term_id, cols, rows}` | app→D | resize the PTY |
| | `Exit {term_id, code?}` | D→app | the PTY exited (nil code = signal death) |
| | `TermProc {term_id, name, pid?}` | D→app | foreground process name changed |
| | `Bell {term_id}` | D→app | a BEL (0x07) was seen |
| | `ScrollbackRequest {term_id}` | app→D | re-send one term's scrollback ring now |
| | `Scrollback {term_id, bytes}` | D→app | that ring, one frame per request |
| Layout | `Layout {dock, tiles, board?, board_id?}` | app→D | layout snapshot for a board |
| | `Restore {docs, tiles?, board?, board_id?, live_terms?}` | D→app | full board state to mount |
| Boards | `BoardList {boards, active}` | D→app | all boards + active id |
| | `BoardSwitch {board_id}` | app→D | make a board active |
| | `BoardCreate` | app→D | mint a fresh board |
| | `BoardRename {board_id, name}` | app→D | set/clear display name |
| | `BoardDelete {board_id}` | app→D | remove a board (refuses the last); a directory that only its docs were in is no longer watched, and a doc of the active board that changed while the watches were dropped gets its `file_event` then |
| Teardown | `TermClose {term_id}` | app→D | kill a terminal's pty and forget it |
| | `DocClose {path}` | app→D | drop a doc from the active board; its directory stays watched while any board has a doc there |

Supporting structs: `DocEntry`, `Tile` (kind + optional `path,x,y,w,h,z,loose,
shelf,term_id`), `BoardMeta {board_id, name?, running?}`, `BoardViewport {zoom,
cx, cy}`.

**Conformance vectors are the tripwire.** Two codecs implement this contract —
`tarmac-protocol` (Rust, serde) and the hand-written `MsgPack` / `Message` codec
in `TarmacKit` (Swift) — and both carry the same hex-encoded msgpack vectors
(V1–V13) as mandatory tests: in `core/crates/tarmac-protocol/src/tests.rs`
and in `app/Tests/TarmacKitTests/ConformanceTests.swift`. Each vector must decode
to the same structure and survive an encode→decode roundtrip on both sides. The
Swift encoder is additionally pinned byte-for-byte to what
`rmp_serde::to_vec_named` emits
(`app/Tests/TarmacKitTests/RustEncoderParityTests.swift`), so a frame the app
sends is one the daemon's own suite already exercises. The serde stack (`serde`,
`rmp-serde`, `serde_bytes`) is pinned to exact versions because the tagged-enum +
`serde_bytes` interaction is fragile; the vectors catch any silent encoder
drift. Vectors only grow additively; an existing one is never edited.

---

## 3 · The daemon (`tarmacd`)

### Process & connection model

`main()` claims the socket, builds one shared `Arc<Daemon>`, and accepts
connections on a `tokio::net::UnixListener`, spawning `conn::handle` per
connection. A SIGHUP/SIGTERM/SIGINT handler removes the socket and `exit(0)`s (so live
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
 └─ watcher:     std::sync::Mutex<WatcherState>             notify debouncer + docs per directory
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
held**; then `Daemon::delete_board`; then `docs::push_missed_changes`; then
recompute counts and re-push. The
per-terminal scrollback ring uses a `std::sync::Mutex` that is **never held
across an `.await`** — locked only for a synchronous push/snapshot. The watcher's
mutex is a `std::sync::Mutex` too and is never held across an `.await`, but it
is held for the notify call that starts or drops a watch. The `boards` lock is
never held during a watcher call.

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

The watch set is one per daemon, not per board. The watcher counts the
registered docs in each directory (`WatcherState.doc_counts`), one for each
board that has the doc, and a directory is watched from its first doc to its
last. `Daemon::new` counts each restored doc. After that, three `Daemon`
methods are the only code that changes the count, each
under the watcher's own lock and with the `boards` lock released:
`open_doc` adds one **before** it registers the doc (and takes it off again
when the doc was already on that board), `close_doc` and `delete_board` take
one off for each doc **after** they removed it. So the count is never below
the number of registered docs, and an open and a close in one directory end
with the same watch in each order. A count stands when the watch itself
fails at startup (the directory is gone): the doc is still registered, and it
must hold the watch that a later open in that directory starts.

Each `watch` and `unwatch` restarts the FSEvents stream, and the stream
reports nothing from the gap. A board delete can drop many watches in a row,
so it then runs `docs::push_missed_changes`: each doc of the active board
whose file is newer than its last reported change (or, with none reported,
than its open) gets a `file_event`. A `doc_close` and an open in a new
directory have the same gap for one restart and run no such check.

`tarmac open` end-to-end: the CLI canonicalizes the path, connects, reads
`TARMAC_TERM_ID` from its env, and sends `Open`. The daemon re-canonicalizes
(FSEvents reports resolved paths), validates it's a regular file, **resolves
the target board** (explicit `board_id` → caller term's board → active), counts
the doc toward its parent dir's watch, upserts the doc into that board's registry,
derives repo metadata (walks parents for `.git`; an FNV-1a color index, which
the app maps onto its palette without hashing anything itself), and pushes
`DocOpened`.

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

## 4 · The app (`TarmacApp`)

The cockpit glass is a native AppKit application built from the SwiftPM package
in `app/` (Swift 6, macOS 26). There is no storyboard and no nib: `main.swift`
starts the application, and `AppDelegate` reads the preferences and builds one
window (1100×700, also its minimum content size), the menu bar, and an
`AppController`. The app carries no font file: every face is one the Mac has.

### Layering

Three targets with one-way dependencies (`app/Package.swift`):

| Target | What it holds | Tests |
| --- | --- | --- |
| `TarmacKit` | No AppKit, no WebKit. The msgpack codec and `Message` types, `DaemonClient`, and every decision that can be a pure function — one small module per rule (`KeyLadder`, `ReconnectRestore`, `Placement`, `Cull`, …). | `app/Tests/TarmacKitTests/` |
| `TarmacTerm` | The terminal card, usable without the rest of the app: `TerminalEngine`, `FrameReader`, `TerminalRenderer`, `TerminalView`. Links `GhosttyVt`. | `app/Tests/TarmacTermTests/` |
| `TarmacApp` | The AppKit shell: wiring, views, event routing. Depends on both. | none, by design — see [`coding-style.md`](coding-style.md) |

Two more executables live beside them: `tarmac-smoke` drives a real daemon over
the socket and asserts the M0 contract end to end, and `tarmac-term-demo` binds
one `TerminalView` to a daemon PTY so the terminal card can be checked alone.

`GhosttyVt` is libghostty-vt as a prebuilt XCFramework — a binary target at
`app/Vendor/` (gitignored), staged by `scripts/fetch-ghostty-vt.sh`
(`make ghostty-vt`). Where it comes from and what pins it:
[The libghostty-vt dependency](#the-libghostty-vt-dependency).

`AppController` is the coordinator: it owns the `DaemonClient`, the event
monitors and the `Board`s. It gathers facts, asks a `TarmacKit` rule, and
applies the answer; the rule is where the test is.

### The libghostty-vt dependency

libghostty-vt is the terminal-emulation library of
[Ghostty](https://github.com/ghostty-org/ghostty) (MIT), and the Swift
package's only dependency outside the SDK. Tarmac does not build it: it
downloads the archive Ghostty's own CI compiled.

**What is linked.** The XCFramework holds static archives. The package links
its macOS slice (`libghostty-vt.a`, arm64 and x86_64; the bundle is arm64-only)
into the executable, so a built `Tarmac.app` has no `Contents/Frameworks` and no
dynamic reference to the library; nothing is fetched at install or run time.
Every build stages it through the one script — `make app`, `make test`, CI
(`.github/workflows/test.yml`, cached on the script's hash) and
`scripts/dmg.sh` by way of `scripts/bundle.sh` — so a released `.dmg`
carries object code Ghostty compiled.

**Where it comes from.** Ghostty's `release-tip.yml` workflow builds the
XCFramework for each tip release and publishes it in two places, both named as
consumer channels by the commit that added them
([90b706b97](https://github.com/ghostty-org/ghostty/commit/90b706b97),
[PR #12149](https://github.com/ghostty-org/ghostty/pull/12149)):

- the `ghostty-vt.xcframework.zip` asset of the
  [`tip` GitHub release](https://github.com/ghostty-org/ghostty/releases/tag/tip),
  replaced on every tip build, so it cannot be pinned;
- `https://tip.files.ghostty.org/<commit>/ghostty-vt.xcframework.zip`, keyed by
  the full commit hash. The script downloads this one. A commit whose tip run
  skipped the build — one that changed nothing that ships — has no file.

**Why a commit and not a version.** Ghostty's README says libghostty has no
version yet, and no tagged release publishes the library. The latest tag,
`v1.3.1` (2026-03-13), predates the terminal, render-state, mouse and selection
headers: of the 69 `ghostty_*` functions `TarmacTerm` calls, its headers declare
13, all key encoding (counted 2026-10-02). The headers call the C API not yet
stable, with breaking changes expected. So the pin is one commit on `main`:
`GHOSTTY_COMMIT` and `GHOSTTY_VT_SHA256` in the script move together, a bump can
break `TarmacTerm`, and one is to be followed by `make test` and a live
`make qa`. No bump has happened yet.

**What is checked.** The zip's SHA-256 against the value recorded in the
script, at download time, and nothing else; an `app/Vendor/` that is already
staged is trusted on its commit stamp. Ghostty signs the zip with minisign
(public key in its `PACKAGING.md`), but publishes the `.minisig` only beside the
`tip` release asset, not at the per-commit address. The signature is therefore
reachable only while the pinned build is still the tip asset, so the repo keeps
it: `scripts/ghostty-vt-33da6848d63b.xcframework.zip.minisig`, taken from the
tip release on 2026-10-02 while that asset was still the pinned build — the
same SHA-256. The hash says the file is the one the pin was made against; the
signature says Ghostty's key signed that file:

```sh
minisign -Vm ghostty-vt.xcframework.zip \
  -x scripts/ghostty-vt-33da6848d63b.xcframework.zip.minisig \
  -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
```

The script does not run this — minisign is not a build requirement — and the
signature here was checked with a plain Ed25519 verification, not with that
command. A bump replaces the signature file, or removes it when the new pin's
signature is no longer published.

**How long the file stays.** No retention period was found in Ghostty's README,
`PACKAGING.md`, workflow or release notes. Observed on 2026-10-02: of 18
sampled commits that got a tip build between 2026-04-06 and 2026-09-30, all 18
still served the zip, the first one ever published among them. If the pinned
file goes, a machine that already holds `app/Vendor/` keeps building; a fresh
checkout does not, and CI only until its cache entry is evicted (seven days
unused) or the script changes.

**What would replace the download** — none of it done
([`backlog.md`](backlog.md) §5): mirroring the same zip, which keeps the hash;
building it, since Ghostty publishes `libghostty-vt-source.tar.gz` at the same
per-commit address and its workflow runs
`zig build -Demit-lib-vt -Doptimize=ReleaseFast` in its Nix dev shell (Zig
0.16.0 at this pin) — Tarmac has never built it that way; or pinning a tag once
a Ghostty release publishes libghostty-vt.

### The daemon link

`DaemonClient` (`app/Sources/TarmacKit/DaemonClient.swift`) is the one long-lived
connection. It runs on a thread of its own and delivers `Message`s and
`ConnectionStatus` changes to the main queue, in order.

- **Connect.** Resolve the socket (`ChannelPaths`: `TARMAC_SOCKET`, else the
  per-channel default); a path too long for `sockaddr_un` fails with a reason
  instead of being truncated. On a miss, spawn the daemon — `TARMAC_DAEMON`
  verbatim, else the `tarmacd` beside the running executable — and retry every
  100 ms for 3 s. A daemon this client started that is still alive is never
  doubled.
- **Spawn.** `DaemonSpawner` uses `posix_spawn` with `POSIX_SPAWN_SETSID`: the
  daemon gets its own session, none of the app's descriptors, a clean signal
  state, stdin from `/dev/null`, and stdout/stderr in `tarmacd.log` beside the
  socket (truncated per launch). Its `PATH` has the daemon's own directory
  prepended, which is how `tarmac open` resolves inside a terminal card even
  under a Finder launch (`DaemonLaunch`). The daemon outlives the app.
- **Handshake.** `Hello {role: "app", v: 1, app_version?}`, then `HelloOk`.
- **Version-mismatch restart.** If `HelloOk.daemon_version` differs from the
  app's own version (or is absent), the client reports
  `version mismatch / restarting`, SIGTERMs `daemon_pid` (falling back to the
  child it spawned), waits up to 2 s for the socket file to disappear, and
  reconnects with no backoff. At most once per process: a respawn that still
  mismatches is proceeded against. An app that knows no version of its own never
  restarts a daemon.
- **Backoff.** After a drop or a failed connect: 0.5 → 1 → 2 → 4 → 8 s, then
  15 s, ten attempts in all (`Reconnect`); then `could not reconnect to tarmacd`
  and nothing more.
- **Requests** are fire-and-forget. While no handshake has completed they are
  queued, unbounded and in order, and go out after the next one does.
- A frame that does not decode is skipped; only a stream that can no longer be
  read ends the connection.

`ConnectionStatus.connected` turns true as soon as the socket connects; the
controller's own `connected` flag — what gates a spawn — turns true on
`HelloOk`. Connection state is app-local: the status bar prints `attached`, or
the reason. On a drop the app toasts `tarmacd connection lost` and changes no
card — there is no "detached" card state. The reconnect's `Restore` is what
reconciles the cards ([*Restore and reconnect*](#restore-and-reconnect)).

### The board

A board is one `BoardView` (`app/Sources/TarmacApp/BoardView.swift`). The app
holds one `Board` per daemon board; only the active board's view is in the
window. A backgrounded board keeps its cards and terminal views alive
off-window, so its shells keep taking output and are current on switch-back.

**Viewport.** `Viewport {zoom, cx, cy}` is a zoom and the world point at the
middle of the view: `view = (world − center)·zoom + viewportCenter`, both spaces
top-down. Zoom is clamped to 0.1…3.0 on every path. The surface is a flat fill.
A board with no persisted viewport opens at 100 % on its boot terminal
(`Placement.openingViewport`).

**Zoom is a pure view transform.** A card's `frame` is its rect on screen. Its
chrome — border, header, shadow, ring — is laid out at zoomed metrics
(`CardScale`, `CardBox`), so it is drawn sharp at every zoom rather than
stretched. The body alone is not: it keeps its world size inside a container
whose frame is the body's place on screen and whose bounds are the body's world
size. So a terminal's cols×rows and a doc's wrap points never change with the
zoom; only a card resize changes them. Above 100 % the body's layers are
rasterised denser by the zoom, up to 3× (`CardRaster`).

**Device-pixel snapping.** Each card's on-screen origin and size are rounded to
whole device pixels (`backingAlignedRect`) — the size by itself, so a pan never
changes it. A border is whole device pixels and never thinner than one
(`CardScale`). Moving the window to a display of another density re-snaps
everything.

**Culling.** A card whose world frame does not intersect the viewport grown by
one full viewport on every side is hidden (`Cull`) but stays in the hierarchy: a
terminal keeps taking output, a doc keeps its scroll. A culled card takes only
its place and its body size; its chrome is not laid out until it is shown
again. A board that is not in the window has no viewport and culls every card.
Each flip is reported once (`CullLedger`), and a culled HTML card's document is
told, so that it pauses.

**Pan, zoom, fly.** The wheel is routed before it is dispatched (`BoardWheel`):
over the body of the *selected* card it scrolls that card's content; anywhere
else on the board it pans; with `⌃` held, or as a trackpad pinch, it zooms about
the pointer. A fly eases the viewport over 300 ms (`BoardFly`; instant under
Reduce Motion) and is cancelled by any pan, zoom or viewport jump; only a fly
that lands is persisted.

### Cards

A card (`CardView`) is a 30-high header over a body inside a 1-wide border
(`CardBox`), identified as a terminal by `term_id` or a doc by path (`CardID`),
and placed by a world-space `CardFrame {x, y, w, h, z}`.

- **Selection.** One card per board can be selected: it wears the teal border
  and its body takes the wheel. A press on a card selects and raises it —
  except on a header control or a doc's link, which act by themselves
  (`CardPress`); a press on the bare board clears the selection. Raising sets `z` above every other
  card and re-sorts the card views in place — a card is never taken out of the
  hierarchy to restack, which would resign its first responder, sever a press in
  flight and reload a web view.
- **Move.** Dragging the header moves the card: it follows the pointer from the
  first point of travel. The press counts as a *move* — the card lifts, and on
  release a doc detaches — only once the pointer has gone more than 3 points on
  either axis (`CardDrag`); short of that it is a click, which selects. **Gravity:** moving a terminal carries its attached docs (`CardCarry`);
  a completed move of a doc detaches it (persisted as `loose`) and clears its
  fresh mark. A resize never detaches.
- **Resize.** Eight invisible handles — corners and edges — that keep a fixed
  size on screen at every zoom (`CardHandles`); the cursor is the affordance.
  The minimum is 160×90 world units (`CardResize`). A doc card has no top-right
  handle: its `✕` is there.
- **States.** `prime` (the board's prime terminal: tinted header, deeper
  shadow), `quiet` (a live non-prime terminal steps back while a prime exists;
  docs are never dimmed), `dead` (an exited terminal held open), `fresh` (a doc
  an agent just opened: a teal ring and `✚ now`), `selected`, and `borrowed` (an
  HTML card holding the keyboard: amber border and ring). `CardChrome`,
  `CardDim` and `CardRing` decide how they combine.
- **Scroll thumb.** Every card kind says where its content is scrolled to as
  one value, `ScrollMetrics {offset, visible, total}`, in its own unit — a
  terminal's rows, a page's pixels — and the card draws one thumb from it, the
  same on all three (`ScrollIndicator`). It is chrome, laid out on screen like
  the header: 10 wide and 2 in from the body's right edge, never shorter than
  24, clear of the rounded bottom corner; a dark fill with a light hairline,
  both opaque, so it is the same on every page. It shows when the wheel router
  gives the card a wheel and fades a second after the last; a pointer over it,
  or a press on it, holds it, and the hold starts again when the last of the
  two lets go (`ScrollIndicator.Visibility`). Hover alone shows nothing,
  deselecting the card hides it at once, and a card whose content fits has
  none. While it shows it can be dragged: a point on it is the thumb's ahead
  of the resize strip (`CardHit`), and a faded thumb is not there at all. A
  drag keeps how far below the thumb's top the press landed and asks the
  content for the offset that holds the thumb there (`ScrollDrag`, the
  inverse of the thumb's place); the content scrolls and reports, and the
  thumb is drawn from the report, as for a wheel. A wheel over the thumb is
  still the card's (`BoardWheel.route`), and the thumb hands it to the body
  under it. A press on it reaches nothing under it and takes no keyboard
  focus.
- **Doc header.** Glyph, repo dot (only when the daemon gave a `repo_color`),
  the file's basename, `← <owner>` chip, `✚ now`, `✎ Ns` recency (for 30 s after
  a change), `↻`, the console badge (HTML cards), `✕`. A terminal header has a
  glyph and a label; it has no close button.

### Terminal cards

`TarmacTerm` is four pieces with one job each.

- **`TerminalEngine`** wraps one libghostty-vt terminal: feed bytes, resize,
  read modes, and encode host events — keys, mouse, paste, focus — from the
  terminal's live state. Through `TerminalEffects` it also answers what
  libghostty-vt leaves to the embedder: device attributes, size and
  colour-scheme reports, title, working directory, bell, clipboard writes and
  the synchronized-output hold. Shells block on some of those replies.
- **`FrameReader`** copies the render state into a value `TerminalFrame`,
  re-reading only the rows the library marks dirty, and every row when a
  default colour changed: a program that sets one (`OSC 10`, `OSC 11`) makes
  no row dirty.
- **`TerminalRenderer`** draws a frame with CoreText. Layout is in points and
  every fill is snapped to the context's device pixels, so the grid is seamless
  at any zoom. A character the terminal face lacks is shaped as a CoreText
  line, which brings font fallback (CJK, emoji). The terminal face is the
  family the user chose, or the system's monospaced font (`TerminalFonts`). A
  family with no italic has its upright face slanted, and one with no bold
  gives its regular face; box-drawing, block and Powerline characters are
  never set italic, so their rules still meet. Setting `fontFamily` or
  `fontSize` rebuilds the renderer, and the new cell size reaches the program
  as a resize.
- **`TerminalView`** is the `NSView`. It owns no PTY: output comes in through
  `feed`, and everything the user does leaves through `onInput`. Policy stays
  out of it — key bindings, link opening and clipboard permission are closures
  the host sets.

**Grid.** The view lays out in its own bounds (`TerminalGridLayout`): the whole
cells that fit inside the padding, anchored to the bottom. Because the board
scales the body's container and not the view, zoom never changes cols×rows. The
daemon is told a size only when the measured grid differs from the last one sent
and the card is on screen (`TermGrid`), so a backgrounded board never shrinks a
live PTY; its terminals are caught up when the board is shown.

**Keys.** `keyDown` first offers the chord to the host's `keyOverride` — the
line-editing keys `⌘⌫`, `⌘←`, `⌘→`, `⌥←`, `⌥→`, `⌥↑`, `⌥↓` (`TermKeyBinding`) —
then runs the input context and hands the result to libghostty-vt's key
encoder, which speaks the kitty keyboard protocol when a program asks for it.
`⌥` is Alt: the key's letter is read from the ASCII-capable layout, so
`ESC`-prefixed chords work under a CJK input source. `⌘` chords belong to the
menu — except plain `⌘C` with nothing selected while a kitty-keyboard program
runs, which is that program's own key.

**IME.** `TerminalView` is an `NSTextInputClient`: the input context composes
into marked text, drawn as a preedit at the cursor, and a commit goes out as one
key event. Control chords and `⌥`-as-Alt skip the input method unless a
composition is in flight. The preedit carries the input method's own caret, and
the candidate window is anchored at that caret whatever range the input method
asks about — Zhuyin asks about the whole composition, which would leave the
window at its start. A key is named to the program by the Latin letter on it
(`KeyTranslation`), so `⌥B` is alt+b under a non-Latin input source too.

**Mouse and selection.** While the program tracks the mouse it gets the reports
(libghostty-vt's mouse encoder); `⌥` hands a drag back to selection. Otherwise
libghostty-vt's selection gesture decides what a click sequence selects —
cells, a word, a line, a rectangle with `⌥` — and the selection is the
terminal's own, so it tracks its text through scrolling. A drag past the edge
autoscrolls. Copy, Paste and Select All are the Edit menu's; a right-click
selects the word under it and offers the same three. The wheel scrolls the
scrollback (5000 lines), walks the alternate screen as arrow keys, or is
reported to a mouse-tracking program. The view tells its card where the
viewport is in the scrollback whenever that changes (`onScrollChanged`), for
the scroll thumb; the alternate screen has no history, so no thumb. A dragged
thumb sends the viewport to a row (`scroll(to:)`, the engine's absolute-row
scroll); at the last row it can start at, the viewport follows output again. A click on an OSC 8 hyperlink or a
spelled-out URL opens it in the browser — `http(s)` only in both cases; a URL the
terminal wrapped over several rows is one link, from any of them. So is one the
program broke over rows itself, which nothing marks and Claude Code always does:
the one place the terminal reads layout rather than a fact (`TerminalLinks`) — a
row that ends in a word at its last column goes on with the next row's first
word when the two are too long to have fitted on one row. Two words that happen
to lie that way are taken for one, so a URL nearly as wide as its row that ends
at the edge can take the word below it; a row that stops short of the edge is
never joined. A link opens
under a program that tracks the mouse too, which is still reported the click;
a `⌃` or `⇧` click is that program's alone (Claude Code opens a `⌃`-clicked URL
itself), and so is a drag.

**Honest signals.** The label starts as `shell`; each `TermProc` and each
non-blank OSC title overwrites it, last writer wins (`TermLabel`). `Bell` turns
the header's glyph amber and shows an amber `●` there until bytes leave for that PTY or the card becomes prime by a
press. The view's own bell and OSC 52 clipboard hooks are left unset
on purpose: the daemon's `Bell` is the observed fact, and a program may not
overwrite the user's clipboard.

**Exit.** `TermExit` decides: a non-zero or signal `Exit` toasts and holds the
card open *dead* — dimmed, taking no input, never persisted; a clean exit
removes the card; a clean exit of the board's last live terminal replaces it
with a fresh shell at the same frame. Nothing is respawned after a failure.
`⌘W` on the selected terminal card removes it at once, sending `TermClose`
unless the shell had already exited, and — as with a clean exit — replaces the
board's last live terminal with a fresh shell (`FocusedClose`).

**Scrollback restore.** Every terminal card, when it is created, sends
`ScrollbackRequest` and holds that terminal's live `Output` — up to 256 KiB —
until the `Scrollback` reply arrives (`ScrollbackGate`, run by
`app/Sources/TarmacApp/ScrollbackRestore.swift`). The ring *replaces* what the
card shows: the view is reset, then the ring is *replayed* — fed with the PTY
reply, bell and clipboard hooks muted, since its queries were answered when
they were live. What was held is discarded, because the ring is a superset. An empty ring —
the daemon's answer for a terminal that has exited — replaces nothing, so a dead
card keeps its screen. No
reply within 2 s (a daemon that predates the request) releases the held bytes
in order instead. On a board's first `Restore` on a new connection — the active
board at the reconnect, any other when it is next switched to — the gate is
armed again for each of its surviving terminals, so the daemon's one-time
`Output` replay is never appended to history the card already shows.

### Doc cards (markdown)

A markdown doc card's body is `DocWebView`: one `WKWebView` per doc, loading a
bundled page (`DocTemplate.html`) whose content policy forbids script. The doc's
raw HTML is kept as written and never runs. The app's own scripts — `marked`
and `doc-render.js` — are injected into a separate content world
(`CardWebView`), where nothing the doc carries can reach them or the message
handlers they post to. No cookies, cache or storage outlive the app.

- **Render.** The app reads the file off the main thread — a read error renders
  as an inline message — and the page renders it with `marked` on arrival, on
  restore, and on every `FileEvent` for that path, on every board that has the
  doc.
- **Zoom.** The web view is kept at the card's on-screen size
  (`ScreenSpaceHost` undoes the body container's scale for it), so WebKit lays
  out and rasterises at real screen points. The page carries the zoom itself:
  prose is laid out once at a fixed 3× and scaled by `zoom/3`, so a board zoom
  never moves a wrap point and the scale is never an upsample. While the zoom
  is changing the web view is left alone; it takes its new size once the zoom
  has held still for 150 ms.
- **Scroll.** The reading position is kept as `scrollTop / scrollHeight`, so it
  survives a re-render, a zoom and a card resize. The page reports the
  scroller's position to the card on every scroll and layout, for the scroll
  thumb, and its own scrollbar is hidden. A dragged thumb sets the scroller's
  position (`tarmacDoc.scrollTo`).
- **Images.** A local `<img src>` — doc-relative, absolute, or `file://` — is
  re-addressed (`DocImage`) to the `img` host of `tarmac-card://` before it is
  fetched; other schemes are left as written. Only the doc's own top frame
  loads from that host: every doc web view carries a content rule
  (`DocFrameRule`, compiled once by `DocFrameRules`) that blocks
  `tarmac-card://img/` in child frames, and the page is not loaded until the
  rule is attached.
- **Links.** Only an absolute `http(s)` link opens, in the system browser; the
  page itself never navigates (`CardNavigation`, `ExternalLink`). A frame the
  doc's raw HTML embeds may hold an `http(s)` page or inline content
  (`about:blank`, `srcdoc`), never a local file or a `tarmac-card://` document,
  and nothing in a frame loads a local image. If WebKit refuses the content
  rule, no `http(s)` page is framed at all
  (`CardNavigation.doc(_:framesGuarded:)`).
- **Header.** `↻` sends `DocRefresh`; the daemon's `FileEvent` is what reloads.
  `✕`, or `⌘W` on the selected doc, removes the card, its registry entry and any
  borrow, and sends `DocClose`.

### HTML cards

A doc whose path ends `.html`/`.htm` is an HTML card (`DocKind` — derived from
the path, never stored, so the wire protocol knows nothing about it). Its body
is `HTMLCardView`: a web view holding a small host page (`card-host.html`) whose
one element is `<iframe sandbox="allow-scripts" allow="">` pointed at
`tarmac-card://doc/<percent-encoded path>?v=<mtime>`. The document runs real
JavaScript at an opaque origin: no network, no forms, popups or top navigation,
no permission-policy feature, and no handle on the app.

- **Scheme handler.** `CardSchemeHandler` answers `tarmac-card://`; what to
  serve is `CardSchemeRouter`'s decision, and the file is read off the main
  thread. The `doc` host serves the file as `text/html` with a strict response CSP
  (`CardProtocol`: `default-src 'none'`, inline script and style only,
  `data:`/`blob:` media) and the shim's `<script>` at `ShimPlacement`'s offset,
  after the file's leading doctype. A file with a doctype is in the mode that
  doctype gives, and one with none is in quirks mode, as in a browser.
  A request that carries an `Origin` header — XHR, `fetch`, a `crossorigin`
  load — is answered 403 on either host before the disk is touched: no page
  the app loads reads the scheme by script. The `img` host serves bytes for
  allow-listed image types only, never HTML (`ImageProtocol`); the path is
  resolved with `realpath` and the file it leads to is the one judged, typed
  and read, so a name that is an image's and leads to anything else is refused
  unopened. A file over 64 MiB is refused on either host
  (`FileBytes.sizeCap`), from its size at open and again while it is read.
  Each web view is served only its own host — an HTML card's
  the `doc` host, a markdown doc's the `img` host — so a markdown doc cannot
  frame a local file as an unsandboxed card document.
- **The shim** (`card_shim.js`) is everything a document can observe of its
  host: it gives the document a default colour scheme, so that a document
  that states none follows the app's appearance (one
  `<meta name="color-scheme" content="light dark">`, which any `color-scheme`
  in the author's CSS beats, and which the shim removes when the author's own
  meta is parsed); it tells its parent that the document has started
  (`started`, its second act, before any author script runs); it
  relays `console.log`/`info`/`warn`/`error`, uncaught errors, unhandled
  rejections and `Escape` to its parent,
  declares `--tarmac-prose-size`, `--tarmac-prose-font` and
  `--tarmac-mono-font` on the root, in one `:root` rule of a constructed
  stylesheet (so that the author's `<html style>` is kept and the author's own
  `:root` rule does not win), from values filled in at load and from `fonts`
  messages (from the parent only; `started` stays its second act),
  applies the zoom, gates the document's schedulers, scrolls the root where
  the host says while the card's scroll thumb is dragged (`scrollTo`, a
  finite number, from the parent only), and reports where the
  document's root is scrolled to — as the event happens, with no frame or
  timer asked for — while hiding the root's own scrollbar. A document can
  forge that report as it can a console line; `ScrollMetrics` refuses what
  describes no scroller. Its parent is the host
  page, whose script (`card-host.js`, in the app's content world) carries
  messages and bounds them: a console entry is cut to the 1000-character line
  the app keeps and posted with the count of what was cut, and any other
  message is carried only if its JSON is at most 1000 characters. What they
  mean is `HTMLCardSession`'s. Two messages are the host page's own business:
  `started` stops there, and `shown` is carried from no card.
- **First paint.** Before its document is on screen a card's web view has
  white to show, whatever the theme: the host page for a frame or two before
  it is first drawn, then the frame with no document in it. So `HTMLCardView`
  keeps the web view out of sight, and the card shows its own `bg1`, from the
  moment the host page or a document is asked for (a first load, a live
  reload, a web process that died) until the host page says `shown`. The host
  page says it two of its own frames after the document started — the
  shim's `started`, or the frame's `load` for what is served with no shim (a
  file that cannot be read) — and not for a source that was replaced in
  between. A culled card's page draws no frames, so its word comes when the
  card is in view again. A request that is never answered leaves the card at
  `bg1`.
- **Shield and borrow.** A transparent shield covers the document: a press
  selects the card, a wheel over the selected card is handed on to the web
  view, and nothing else reaches it. A double-click *borrows* the card —
  app-wide, one at a time (`CardBorrow`): the shield comes off and the document
  takes the keyboard. `ESC` un-borrows and
  returns the keyboard to the prime terminal, whether the document (through the
  shim's relay) or the app saw the key.
- **Wheel.** The document scrolls natively, shielded or borrowed. The card's
  web view (`HTMLCardWebView`) rewrites each wheel event's delta into the
  document's own units before WebKit sees it (`CardWheel`): `3 / zoom` units a
  screen point under magnify, whole units with the residue carried for a
  trackpad, scaled lines for a notched wheel; in reveal the event passes as it
  is. So the content moves with the finger at every zoom, and what scrolls is
  what is under the pointer, a nested scroller included. A selected card's
  document therefore sees `wheel` events; it sees no press and no key until it
  is borrowed.
- **Zoom.** Two modes, chosen per document load from
  `<meta name="tarmac-zoom">` (`ZoomMode`). **Magnify**, the default: the
  document is laid out once at root zoom 3 in a box 3× the card's and shown
  scaled by `zoom/3`, so a board zoom never re-wraps it. **Reveal**
  (`content="reveal"`): the document is laid out at the card's real on-screen
  pixels and sized again once the zoom has settled.
- **Live reload.** A `FileEvent` with a new mtime changes `?v=` and reloads the
  document — its JS state is lost, its console kept; an unchanged mtime reloads
  nothing.
- **Cull pause.** A culled card's document is sent `cull`, and the shim pauses
  its `requestAnimationFrame`, `setInterval` and `setTimeout` schedulers until
  the card is shown again.
- **Console.** Relayed output collects in a per-card buffer of the last 500
  entries (`CardConsole`), each kept to a 1000-character line that ends in
  `… (+N more)` when it was cut; the badge and the panel catch up at most every
  0.1 s. Once the buffer is non-empty the header shows a badge that toggles a
  panel over the bottom of the body, at most 40 % of it high; its text can be
  selected and copied.

### Provenance edges

One edge per doc card whose owner terminal card is on the same board, whether
or not the doc is still attached (`Provenance`): a straight dashed teal segment
between the two cards' centres, drawn in a layer beneath every card
(`EdgeLayerView`), so only the gap between them shows. Edges are rebuilt from
the cards' on-screen frames on every pan, zoom and drag.

### Focus and keys

Three notions are kept apart: the **selected** card (border, wheel target, `⌘W`
target), the **prime** terminal (one per board — home for focus, cwd
inheritance and doc placement), and the view that holds **keyboard focus** (the
window's first responder).

- A press on a live terminal card — body or header — selects it, makes it prime
  and gives it the keyboard. A press on a doc card selects it — except on a
  link or a header control (`CardPress`); a markdown doc's web view takes the
  keyboard, so its text can be selected and copied the usual
  way. A press in an HTML card's console gives its text the keyboard for the
  same reason; the next key that is typing hands it back (rung 7). A press on
  the bare board clears the selection and leaves the keyboard
  with the board.
- Keyboard focus is put on the board's prime terminal after the active board's
  first restore, on arriving at a board, after un-borrowing an
  HTML card, and when a key is typed while a console holds the keys and no card
  is borrowed. `⌘T` makes the new terminal prime but moves neither focus nor
  selection.
- Prime falls to the first live terminal in card order when the prime exits or
  dies (`TermPrime`).

**The key ladder.** One local key-down monitor sees every key before the focused
view; `KeyLadder` says which ones the app takes, in this order:

1. An IME composition in flight, or a borrowed HTML document holding the keys →
   the key passes through.
2. `⌘K` toggles the switcher. `⌘W` closes the selected card, after closing an
   open switcher — always consumed, so it never reaches Close Window.
3. While the switcher is open it owns the keyboard (`SwitcherKeys`); an
   unhandled `⌘` chord is left for the menu.
4. `⌘T` opens a terminal, cascaded from the prime one and inheriting its
   current directory (`inherit_cwd_from`).
5. Plain `Return`, when no terminal holds the keys, no text control in a
   markdown doc's raw HTML is being typed into, and a signalling card is off
   screen, remembers the viewport and flies to that card.
6. `ESC` climbs `EscLadder`; the first rung that applies consumes it: dismiss
   toasts → fly back to the remembered viewport → un-borrow → clear `fresh` on
   every doc of the board → deselect a selected doc. With none, `ESC` reaches
   the terminal.
7. While an HTML card's console holds the keys, a `⌘` chord and a shifted
   arrow, Home, End or Page key stay with its text. Any other key first returns
   the keyboard — to the borrowed card's document, else the prime terminal —
   and is then dispatched there.

Everything else goes to the first responder and then the menu. AppKit's menu,
not a character comparison, decides which chord is Quit, Copy or Paste.

### Boards and the ⌘K switcher

The app follows `BoardList`: it stores the list, follows the daemon's `active`,
and drops local state for any board no longer listed. A switch flushes the
leaving board's pending layout, takes its view out of the window, sends
`BoardSwitch`, and mounts the target when its `Restore` arrives; focus lands on
the target's prime terminal. Each visited board keeps its own live viewport and
cards across switches.

The switcher (`BoardSwitcherView`; rules in `BoardSwitcher` and `SwitcherKeys`)
lists boards in daemon order, filtered by a case-insensitive prefix as you type,
each with running / bell / card counts — local facts for a visited board,
`BoardMeta.running` for one never visited. `↑`/`↓` move, `Return` switches,
`⌘1`–`9` jump to the *visible* rows, `⌘N` sends `BoardCreate`, `⌘E` renames
(`BoardRename`), `⌘⌫` twice deletes (`BoardDelete`; never the last board), `ESC`
closes. It holds first responder while it is open, so the menu's Paste cannot
land in the terminal behind it.

### Wayfinding and overlays

Layered over the board, back to front (`OverlayStack`): offscreen hint pills
(one per signalling terminal whose centre is off screen, on the edge it
overshoots; a pill that cannot clear a card is drawn under the cards), the zoom
control (bottom-left: `−`, percent, `+`, fit — steps of ×1.2 about the viewport
centre; fit frames every card with a 10 % margin), the minimap (bottom-right;
cards coloured by signal, click to re-centre), toasts (at most three, 7 s
each), and the switcher. A 27-point status bar sits below
the board: `attached` or the link's reason, and the card count. The window
title names the active board.

Only terminals signal: `bell` while the bell is lit, else `live` while the PTY
is alive — whatever runs in it.

### Quitting and closing

**The ⌘Q guard** (`QuitGuard`, wired by `QuitGuardController`). The Quit menu
item's target is the guard, so only the Quit *shortcut* is held: a mouse click
on Quit, Dock ▸ Quit and logout terminate at once. A keyboard `⌘Q` shows a
centred "Hold ⌘Q to Quit" notice. Holding the key 500 ms, or pressing it
again within 1 s, commits the quit: the window hides at once and the app exits
when the key is released. Release is detected by polling the triggering key's
state every 50 ms, since its keyUp never arrives while `⌘` is held. The app
menu carries *Warn Before Quitting (⌘Q)*, on by default and saved in
`app-prefs.json` in the config directory (`AppPrefs`, below); a file that
cannot be read means the guard is on.

**Fonts and the Settings window** (`FontSettings`, `SettingsWindowController`).
*Settings…* (`⌘,`) in the app menu opens one window. A sidebar lists its
panes (`SettingsPane`): *Fonts* and *Theme*. The window opens on *Fonts* the
first time in a session and later on the pane it last showed. The *Fonts*
pane has a row for each `FontRole`:

| Role | What it sets | With nothing chosen |
| --- | --- | --- |
| `terminal` | terminal cards | the system's monospaced font |
| `interface` | card headers, status bar, switcher, zoom control, toasts, hints, the HTML card console; the chrome and code of doc cards; `--tarmac-mono-font` of HTML cards | the system's monospaced font |
| `document` | the prose of markdown doc cards; `--tarmac-prose-font` and, with the Document size, `--tarmac-prose-size` of HTML cards | the system UI font |

Each row lists the Mac's font families, *System Default* first; Terminal and
Interface list only fixed-pitch ones (`FontMenu`). The Terminal and Document
rows also have a size, a number field with a stepper, in half steps: 8 to 32
for Terminal (16 with nothing chosen) and 10 to 24 for Document (14).
Interface has none. A size and a family are independent: a change of one
keeps the other. A typed number goes to the nearest size the role has, and
text that is no number puts the field back (`FontSizeRule`). A choice is
saved in `app-prefs.json`, whose keys are `warn_before_quit`, a family name
in `terminal_font`, `interface_font` and `document_font`, a number in
`terminal_font_size` and `document_font_size`, and `theme`, `theme_light` and
`theme_dark` (below); a size
the role does not have reads as nothing chosen. `AppPrefsStore` is the
one owner of the file and saves all of it each time, so no preference drops
another's key. A saved family the Mac does not have, or one a fixed-pitch role
cannot take, is not used: the role falls back to its default and the file is
left as it is (`FontRole.familyInEffect`). The families and the sizes in
effect sit in `Theme.fontFamilies` and `Theme.fontSizes`, which every view
reads. A change is broadcast down the view tree of the window and of every
board that is not mounted (`FontFollowing`): terminals rebuild their
renderer, chrome takes `Theme.mono` again, and doc cards are handed their
chrome and prose families and their prose size (`FontCSS`) as script
arguments. An HTML card is given the same three values as CSS custom
properties (`--tarmac-mono-font`, `--tarmac-prose-font`,
`--tarmac-prose-size`; `CardFontVariables`): the scheme handler fills them
into the shim for each request, and a `fonts` message carries a change, which
the card's session sends only when the values differ, so a Terminal size step
sends an HTML card nothing. The whole font list is read only when the window
opens; launch asks the Mac for the saved families alone.

**Theme** (`ThemeSettings`, `ThemeCatalog`, `Palette`). The *Theme* pane has
three groups. *Appearance* has three tiles in the order of `ThemeChoice`:
*Auto*, *Light* and *Dark*. Under it is a list of all the themes and, beside
it, a showcase of the theme that is selected in the list (`ThemeList`,
`ThemePicture`). Under that is one line about the user's theme files. A row of the list has a swatch, the theme's title and a mark
*Light* or *Dark*, or both, when the theme is the one chosen for that
appearance. A selected row changes the showcase and nothing else. The
showcase has the theme's title, the words "light theme" or "dark theme" (and
then ", from a file" for a theme of the user), a picture of a board drawn from
the theme's palette, two boxes and a note about contrast, which has the room
of two lines. The boxes, *Apply to Light* and *Apply to Dark*, choose the
shown theme for an appearance; a cleared box gives the appearance its
standard theme back. Any theme can be chosen for either appearance, and one
theme for both. The state of a box, the theme it gives, the marks of a row
and the words are the pure rules of `ThemeBrowser`. The theme that is shown
is the pane's own state: it is not saved, and it is the theme in effect each
time the window opens.

*Light* is the theme chosen for the light appearance and *Dark* the one
chosen for the dark appearance; *Auto* is the one of the two that fits the
macOS appearance, and changes when macOS does (`ThemeLibrary.inEffect`). The
*Light* and *Dark* tiles draw the theme chosen for them. The appearance is
the key `theme` of `app-prefs.json`: `"auto"`, `"light"` or `"dark"`. No key,
and any other value, is `dark`, and `dark` is not written. The theme of each
appearance is the key `theme_light` or `theme_dark`: the id of a theme. No
key is the standard theme of that appearance, Breeze Light or Breeze Dark,
and a standard theme is not written under its own key. An id that no theme
has also gives the standard theme, and it stays in the file: an id is
resolved when it is used (`ThemeLibrary.entry`), so a theme whose file is
away for a time keeps its key.

The built-in themes are the entries of `ThemeCatalog`, in `TarmacKit`, in the
order of the list: Breeze, Catppuccin (Latte, Mocha), GitHub and Solarized, a
light and a dark one of each. An entry is an id, a title and a `Palette`. Every
colour of a theme is in that one value: the chrome tokens, the four repo
colours and the terminal's colours. A theme is light or dark by what its
terminal reports to a program (`Palette.variant`, the rule of
`TerminalTheme.isDark`). That variant says what a theme is, not where it can
be chosen. The terminal colours of a theme that is not Breeze are the
upstream values, with no change for contrast; its chrome tokens are Tarmac's
choice. `PaletteCheck.findings` is the detector that lists the pairs
of a palette with less contrast than their floor. The tests hold every built-in theme
to no finding in its chrome, and the showcase's contrast note
(`ThemeBrowser.contrastNote`) gives the number of terminal colours of the
shown theme that have a finding, and then the number of chrome colours when
there is one. Its tooltip names each finding (`ThemeBrowser.contrastDetail`).
The note warns and blocks nothing.

**A theme from a file** (`ThemeFile`, `ThemeLibrary`, `ThemeFolder`). Tarmac
ships no theme file. It reads the files the user put in `themes/` of its
config directory, and each file that can be read is one more theme, in the
list after the built-in ones, by title. The config directory is
`TARMAC_CONFIG_DIR`, or else `$XDG_CONFIG_HOME/tarmac` when that variable is
an absolute path, or else `~/.config/tarmac`; a debug build adds `/dev` to
the last two, and never to `TARMAC_CONFIG_DIR` (`ChannelPaths.configDir`).
`make run` pins it to `<worktree>/.dev/config`.
Only the app uses it.

`app-prefs.json` is there too (issue #220). Up to release 0.16.0 that file
was beside the daemon socket. At launch, when the config directory has no
`app-prefs.json` and there is one beside the socket, its bytes are copied
(`AppPrefs.migrate`), and the config directory is made for it. The file in
the config directory wins when both exist, also when it is damaged. A copy
that fails is logged: the standard settings are then in effect, and the old
file is not read.

The old file is not removed and is not written again, so an older build that
is started again has the settings as they were at the first launch of a
build with the move. A change that is made in the older build stays in the
old file: a build with the move that has its own file does not read it.

One launch keeps the file beside the socket: one that pins `TARMAC_SOCKET`
and not `TARMAC_CONFIG_DIR` (`ChannelPaths.prefsDir`). It is taken as a
scratch launch. Its config directory is the installed app's, or the one that
all debug builds share, and it must not write its preferences there; it
reads the theme files of that directory, as before. A pin can be inherited:
a terminal of an app that was started with these variables, as a `make run`
app is, carries them. So a scratch launch from such a terminal that does not
set `TARMAC_CONFIG_DIR` itself uses that app's file: the launch recipes set
all three.

A theme file is a Ghostty theme file. The keys that are read:

| Key | Gives |
| --- | --- |
| `background`, `foreground` | The terminal's two colours. A file must have both |
| `cursor-color` | The cursor; not set, it is the foreground |
| `palette = N=colour` | ANSI colour `N`, 0 to 15; an entry for 16 to 255 is read and not used |
| `tarmac-bg0`, `tarmac-bg1`, `tarmac-bg2`, `tarmac-bg3`, `tarmac-line`, `tarmac-line-soft`, `tarmac-lift-border`, `tarmac-prime-header-bg`, `tarmac-text`, `tarmac-muted`, `tarmac-faint`, `tarmac-prose`, `tarmac-agent`, `tarmac-amber`, `tarmac-ok`, `tarmac-console-error` | That chrome token |
| `tarmac-repo = N=colour` | Repo colour `N`, 0 to 3 |

A colour is `#rrggbb`, `rrggbb`, `#rgb` or `rgb`. Every other key is ignored,
the file's selection colours among them: the selection is the theme's `agent`
at 0.3, as in a built-in theme. The lines are read as Ghostty 1.3.1 reads
them (`ThemeFile.parse`). A used key with a value that is not read refuses
the whole file, and so does a file with no `background` or no `foreground`, a
file of more than 64 KiB and one that is not UTF-8 text. A file whose name
starts with `.` or ends with `~` is not read at all, and neither is a
subfolder.

A colour that the file does not give is derived (`ThemeFile.palette(from:)`):
a missing ANSI colour is Breeze's, each fill and line is a fixed mix of the
terminal background and foreground, and each text and mark that has a floor
in `PaletteCheck` (`text`, `muted`, the four marks, and the repo colours with
the marks' floor) starts from the foreground or from an ANSI colour and is
moved towards white (a dark theme) or black (a light one) until it has that
floor on the three fills. A colour the file gave is never changed. The detector warns about a
theme and never refuses one. The scroll thumb and the terminal colours 16 to
255 do not come from a file.

The id of a file theme is `file:` and then the file's name, and its title is
the name, so a file with the title of a built-in theme is a second row with
an id of its own. `ThemeSettings` reads the folder before the first view is
made, and again at each change in it (`ThemeFolderWatch`, an `FSEventStream`
on the folder's path): a file that is added shows in the list, a file that is
changed draws every view again when its palette differs, and a file that is
removed or refused gives its appearance the standard theme while
`app-prefs.json` keeps the id. Nothing is saved when the folder changes. A
line under the list says how many themes came from files and how many files
were not read, with the reason for each in its tooltip, and *Open Themes
Folder* makes the folder and shows it in the Finder: the launch makes none.

Each colour token of `Theme` reads the palette in effect. `ThemeSettings`
resolves the entry in effect and sets `NSApp.appearance` from that entry's
variant, under *Auto* too. So the Settings window, a menu opened in a window
and what a page sees as `prefers-color-scheme` follow the theme in effect:
with a dark theme chosen for the light appearance, the choice *Light* gives a
dark app. No window sets an appearance of its own. With an appearance set on
the app, the app no longer reports the Mac's, so the Mac's appearance is read
from the global preference `AppleInterfaceStyle`
(`ThemeChoice.systemIsDark`), and `ThemeSettings` observes that key of
`UserDefaults.standard`. When the entry changed, `ThemeSettings` tells the
views by the same walk a font change uses (`ThemeFollowing`): the window's
view tree, then every board that is not mounted. Each view takes its colours again, with
the colours of the state it is in. A theme chosen for the appearance that is
not in effect is saved and changes its tile and its mark, and no view.

- A terminal card sets `TerminalView.theme`. The text on screen is drawn in
  the new palette with nothing fed, the grid does not change, and a program
  is answered from the new theme: `OSC 10`, `OSC 11` and `OSC 4` queries by
  libghostty-vt, and `CSI ? 996 n` as light or dark. A program that set mode
  2031 is sent one report when dark and light change. A colour a program set
  itself stays until the program resets it, and indices 16 to 255 are the
  same in every theme.
- A doc card's page is loaded with the theme's CSS declarations in place
  (`ThemeCSS.page` fills a marker in `DocTemplate.html`), and a change hands
  a loaded page the new declarations as script arguments, with no reload,
  when the palette is not the one the page has (`PageTheme`).
  The page also states its `color-scheme`.
- An HTML card's native chrome follows the theme. Its document follows it
  too, unless the author states a colour scheme (see the shim, above): the
  app sends the document nothing.

The shadows, the board switcher's veil, the scroll thumb and the quit notice
are the same in every theme.

**The red button hides the window** (`WindowCloseHider`): terminals keep
running, and the window returns on the next activation or Dock click, once per
close. `⌘Q` stays guarded while it is hidden.

Quitting sends nothing but the flushed layout. The daemon and its terminals
outlive the app.

### Layout persistence

Any change to a board — a card's frame or stacking, the card set, the viewport —
schedules a `Layout` snapshot for *that* board on a 200 ms trailing debounce,
one timer per board (`PendingPersists`), so a background board's change is
neither lost nor delayed. Pending snapshots are flushed on a board switch, when
the app resigns active, and at quit. A board is never persisted before its first
restore. The snapshot (`LayoutTiles`) carries `dock` (doc paths in open order),
live terminal tiles with `x, y, w, h, z, term_id` (dead cards are left out), doc
tiles with `loose` = not attached, the live viewport, and `board_id`.

### Restore and reconnect

The daemon sends `Restore` for its active board on connect, and after every
`BoardSwitch`, `BoardCreate` and successful `BoardDelete`.

- **First visit** (`BoardRestore`). A terminal tile whose `term_id` is in
  `live_terms` is re-bound to that PTY; any other gets a freshly minted id and a
  cold spawn at the same frame and `z` — a persisted id is never reused for a
  new shell. A board always ends up with at least one terminal. Doc tiles are
  joined with `restore.docs`; a doc follows its recorded owner to whatever that
  terminal was restored as, and an owner that was not restored leaves it
  ownerless. The newly minted ids are persisted by that restore,
  through the usual debounce.
- **Later restores** — a switch back, or a reconnect (`ReconnectRestore`).
  Terminals still in `live_terms` stay as they are; the rest become dead cards;
  nothing is respawned. An empty `live_terms` for a board that had a live
  terminal is a daemon restart: one toast (`daemon restarted — terminals lost`),
  and every other visited board's live terminals are marked dead too.
- **Spawn gating.** Nothing is spawned for a board before its restore on the
  current connection: that restore lists the live terminals, and a shell
  spawned just ahead of it would be taken for lost.
- **Version-mismatch restart.** The first-visit restore after one toasts
  `tarmacd restarted: <from> → <to>` when a persisted terminal id came back not
  live (`RestartNotice`).

### The QA driver (`tarmac dev`)

Debug builds bind a second socket (`DevSocket`: `TARMAC_DEV_SOCKET`, else
`tarmac-dev.sock` in the channel dir) and serve one request per connection,
strictly one at a time (`DevRelay`), so each reply describes the state its own
verb produced. A live sibling's socket is never stolen: the app logs and runs
without a driver.

`DevRouting` decides what each verb acts on and every refusal;
`app/Sources/TarmacApp/Dev/DevVerbs.swift` carries the route out and reads back
what it observed. Where a verb can inject real input it does — `NSEvent`s
through the application's event path (the key monitor, the hit test,
first-responder handling) — so a scenario exercises the paths a user does. The
rest go around that path, and a reply's `delivery` key says which way a pointer
press went: `window` (the event path); `target` — a press whose target the hit
test cannot reach, off the window or under another view, is handed to the
target view after the app's own press handling; or `handling` — the app's press
handling alone, with no click, where a click is unsafe: a markdown card and an
already-borrowed HTML card (a click would land in the user's document; `focus`
then moves the keys itself, to the board or to the document), a culled terminal
(selected, but the keys stay where they were) and a terminal with a link under
every point tried. Borrowing an HTML card is a real double-click on its shield.
Two inputs go to the terminal view directly: `type`'s printables through
`insertText`, and `key`'s `contextmenu` through the view's own menu request. `zoom`
goes through the board's own viewport commit. A reply also says whether the app
had to be activated to take the input (`activated`). If `accept` fails the
driver closes the socket and removes its file, so callers fail at once. `press`
posts a native `⌘` chord to the application's event queue, with a debug-only
"held" override for the ⌘Q guard's release poll.

`snapshot` reports the active board (`DevSnapshot`): the viewport, each card's
world `board_rect` and measured `screen_rect`, `content_origin` — where those
window-content coordinates start on the display — each card's `scroll`
(`{offset, visible, total, shown, thumb}`, or `null` before its content has
reported; `thumb` is the scroll thumb's rect beside `screen_rect`, or `null`
when none is laid out), the selected card, keyboard
focus, per-terminal `cols`/`rows`/`proc`/`selection`/`scrollback_tail`, the
quit guard's state, `fonts`: for each font role the family saved in
`app-prefs.json` and what the role resolved to (a PostScript `face`, or the
`css` value for doc prose), and for `terminal` and `document` the `size` in
effect; and `theme`: the `choice`, the variant `in_effect` and the `name` (the id) of the theme in effect, the `folder` the theme files are read from, the ids of the themes that are `available`, each file that was `refused` with its reason, and the detector's `findings` for the theme in effect. `--until` re-evaluates an expression every 50 ms
(`DevUntil`). The scenario suites are `scripts/qa/smoke.mjs` (`make qa`) and
`scripts/qa/quit.mjs` (`make qa-quit`).

---

## 5 · Key data flows

**`tarmac open` → a card.** Agent runs `tarmac open plan.md` inside a tarmac pty
→ CLI canonicalizes + reads `TARMAC_TERM_ID` + sends `Open` → daemon resolves the
caller's board, counts the doc toward its parent dir's watch, upserts the doc, derives repo
metadata, pushes `DocOpened` → app lands a `fresh` card in the first free slot
right of the caller terminal, with a provenance edge → agent edits the file →
daemon `FileEvent` → the card re-renders and its header shows `✎ Ns`.

**App disconnect → reconnect.** Daemon stays up; ptys keep running and filling
scrollback. The app toasts, the status bar prints the reason, and the client
ramps its reconnect; the cards are left as they are. On reconnect the daemon
sends `BoardList` + the active board's `Restore` (stamped with `live_terms`) +
each live term's scrollback as `Output` frames. The app leaves each surviving
card in place, arms its scrollback gate again so the ring replaces — rather than
repeats — the history it shows, marks any terminal the daemon no longer lists
dead, and the status bar reads `attached` again.

**Board switch (`⌘K` → Enter).** App flushes the leaving board's layout, takes
its view out of the window and sends `BoardSwitch` → daemon sets active and
replies `BoardList` + that board's `Restore` (+ scrollback for its live terms,
the first time on a connection) → app mounts the target board, builds it on a
first visit, and re-binds the chrome to its viewport.

---

## 6 · What survives what

| Event | Terminals | Layout / docs / viewport |
| --- | --- | --- |
| **App reconnect** (daemon stays up) | **Survive** — the cards stay bound to their ptys; history is replaced from the scrollback ring | Untouched — the app's own state stands; only terminals are reconciled |
| **App relaunch** (daemon stays up) | **Survive** — re-bound on the first restore, history from the scrollback ring | Restored from daemon memory |
| **Daemon restart** | Lost — live shells died with the daemon. A running app marks their cards dead and toasts; a freshly launched app cold-spawns new shells at the persisted frames | Restored exactly from `state.json` |
| **Red button / hide** | **Survive** — the app keeps running with its window hidden, and comes back on the next activation or Dock click | Untouched |
| **Version-mismatch restart** (brew upgrade) | Cold-spawned on the new daemon (same as above). The app toasts the version change (`tarmacd restarted: <from> → <to>`) when a first-visit board has lost terminals; otherwise the existing reconnect toast is what the user sees | Restored from `state.json` via `Msg::Restore` on reconnect |

Daemon-restart PTY re-parenting (true live-shell survival across a daemon
restart) is designed but deliberately unbuilt; cold layout-only restore + the
app-reconnect re-bind cover the common cases. See `docs/archive/m3/plan.md`
decision 2.

---

## 7 · Milestones & status

**Milestone names are historical labels, not a roadmap.** `M0`–`M3` and `v4` are
*done*; they survive only as archived plans — the integration suites that once
carried their names are subject-named
(`tests/{daemon_basics,restore,honest_signals,boards}_integration.rs`). `v4c` is
a **proposal that was never
started**. Nothing named `M4`/`v5` exists. Since the v4 milestones ended, work is
tracked per GitHub issue (see [`workflow.md`](workflow.md)), not by milestone.

### Shipped milestones (all closed)

| Milestone | Closed | What it delivered |
| --- | --- | --- |
| **M0** | 2026-06 | Walking skeleton: daemon + CLI + app over the v1 wire; `tarmac open`, ptys, file watching. |
| **M1** | 2026-06 | Doc states + layout: additive doc-entry keys (repo/color/read/timestamps), normative dock order, desk tiles, `doc_read`/`layout`. |
| **v4 whiteboard** (Phases 0–5b) | 2026-06 | Slot grid → one infinite board: Breeze theme, world-space card frames + persisted viewport, gravity/provenance, wayfinding, terminal primacy, N terminal cards keyed by `term_id`. |
| **M2** | 2026-06 | Honest signals (absorbed as v4 Phase 3.5): `TermProc`, `Bell`, exit codes as new daemon→app types. |
| **M3** | 2026-06-15 | Strips = boards: N named boards, the `⌘K` switcher, per-board restore, the session chip, an honest attached/detached signal, board rename/delete, reconnect re-bind. P5 shipped a simplified "two honest signals" session model (app-local chip + additive `BoardMeta.running` + `Restore.live_terms`, no new session struct). |

### After the milestones (issue-tracked, on `main`)

The two largest changes post-M3 are **not** numbered milestones: the UI was
rebuilt twice. First from Swift/AppKit + SwiftTerm onto Tauri 2 + React +
xterm.js (#27, 2026-06-29); then from Tauri onto the native Swift/AppKit app of
[§4](#4--the-app-tarmacapp)
([`designs/2610.0001_native_swift_ui.md`](designs/2610.0001_native_swift_ui.md),
2026-10). A HISTORICAL doc can therefore describe either of two apps that no
longer exist: anything naming `desktop/`, Tauri, React, xterm.js or Vitest is
the Tauri app, and anything naming `SwiftTerm`, `ShelfView` or `PeekPanel` is
the pre-Tauri Swift app. The current package shares `app/Sources/` and some file
names (`DocWebView`, `BoardView`) with that older Swift app, so judge a doc by
its banner and date, never by a `.swift` path in it.

Also shipped since M3, none of it covered by a milestone plan: per-channel
socket + state namespacing, the notarized-`.dmg` / Homebrew-cask release
pipeline, daemon auto-restart on version mismatch, `TermClose` / `DocClose`
teardown, `⌘W` close + the `ESC` focus ladder, full edge/corner resize, `⌘T` cwd
inheritance, OS-browser card links, sandboxed HTML cards, on-demand doc refresh
and scrollback replay, the `⌘Q` guard, and the `tarmac dev` QA driver. Each has
a record in [`designs/`](designs) or `.blueprint/specs/`.

Three surfaces were **removed** after M3 and no longer exist despite older docs
describing them: the **shelf** (parked/unplaced doc chips — `⌘W` now just removes
the doc card), the terminal **dock pane** (#74), and **peek (`⌘P`)**. All three
were deliberate; see [`backlog.md`](backlog.md) §4. Peek leaves residue: `DocRead`
is still routed by the daemon but has **no caller in the app**, so the persisted
per-doc `read` flag is never set.

### Not built

Audited in [`backlog.md`](backlog.md). **Editable docs (v4c)** remains the
largest proposed-but-unstarted piece — captured in
[`proposed/v4c-editable-docs.md`](proposed/v4c-editable-docs.md), still needing a
design round and the write-honesty model. It is a proposal, not scheduled work.

## 8 · Further reading

Start at the [docs index](README.md) — it classifies every doc as ACTIVE,
PROPOSED, or HISTORICAL, which is the difference between "this is how Tarmac
works" and "this is how someone once planned it".

- [`README.md`](README.md) — the docs index + classification rules. **ACTIVE**
- [`protocol.md`](protocol.md) — authoritative wire contract + conformance
  vectors. **ACTIVE**
- [`backlog.md`](backlog.md) — designed-but-unbuilt features and by-decision
  deferrals, re-verified against the native app. **ACTIVE (describes unbuilt work)**
- [`proposed/v4c-editable-docs.md`](proposed/v4c-editable-docs.md) — the editable-docs
  proposal. **PROPOSED — none of it is implemented.**
- [`archive/m3/plan.md`](archive/m3/plan.md),
  [`archive/v4/migration-plan.md`](archive/v4/migration-plan.md) — closed
  milestone records. **HISTORICAL — the pre-Tauri Swift app; do not cite as
  current.**

The original v3/v4 design handoff (README + mocks + chat transcripts) is
preserved in git history; its still-relevant details were absorbed into the
cribs and `backlog.md`.
