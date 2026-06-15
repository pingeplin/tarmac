# M3 — Strips = Boards (implementation plan)

The v4 whiteboard migration (Phases 0–5b) is complete on `main`: a single
infinite board with Breeze theme, persisted layout, gravity/shelf/provenance,
honest signals, wayfinding, terminal primacy, and multiple terminal cards.

**M3 generalizes the single implicit board into N named boards** ("strips =
boards") with a ⌘K switcher, per-board layout/viewport/terminal restore, a
titlebar session chip, and an honest attached/detached session signal. Design
reference: `design_handoff_tarmac/tarmac/board-v4.jsx` mock **B5** (boards
switcher), the **TitleBar** session chip and **StatusBar** board state, and the
deferral notes in `docs/archive/v4/migration-plan.md` (lines 28–33, 152–208).

This plan was produced by a scout→design→synthesis pass (5 scouts over the
design refs + current daemon/app/protocol; 3 independent design lenses;
synthesis) on 2026-06-14.

## Status — M3 COMPLETE (2026-06-15, branch `feat/m3-strips`)

All five phases shipped; full TarmacKit + Rust + conformance suite green (Swift
146, Rust 35 protocol / 13 daemon-lib / 7 m3-integration); app-layer behaviors
GUI-verified. Merged to `main` (fast-forward; final commit `e182f9f`).

- **P1** ✅ board-keyed record + nested persist + lossless board-0 migration.
- **P2** ✅ board CRUD/list on the wire + two real boards (BoardList/Switch/Create).
- **P3** ✅ app multi-board ownership refactor (`Board` model + thin coordinator).
- **P4** ✅ ⌘K switcher (B5) + titlebar session chip + status-bar board state.
- **P5** ✅ session liveness + reconnect re-bind + rename/delete + webview suspension
  (final commit `e182f9f`).

**P5 shipped a simpler session model than written below** — see the
implementation note under §P5. The optional daemon-restart PTY re-parenting
stayed deferred (cold layout-only restore ships), as decision 2 allowed.

## 1 · The shape of M3 — two orthogonal axes

M3 is two generalizations that share a milestone name. Keeping them separate is
the central planning insight:

- **Identity axis** — make a *board* a `board_id`-keyed first-class entity
  across the daemon `Registry`, the on-disk state, the wire protocol, and the
  app. This is the bulk of M3 and is well-specified: multiple boards, ⌘K
  switcher, per-board restore.
- **Lifetime axis** — whether shells survive disconnect / daemon restart, and
  what the titlebar **attached / detached** chip actually means. This is the
  uncertain part; it is sequenced last and deliberately decoupled so it can
  never block the multiple-boards promise.

## 2 · Resolved decisions (2026-06-14)

1. **Daemon-native sessions, no tmux.** "tmux" appears in the migration notes
   but only ever surfaces as a status-bar *word*; there is no mock for an attach
   gesture, a detach trigger, or attach-from-elsewhere. tmux's only unique wins
   are daemon-restart survival and bare-terminal attach — the latter is a
   non-goal for a board-first GUI, the former is far cheaper daemon-side.
   Against those thin wins, tmux would rewrite the most fragile path in the
   daemon: `term.rs` owns the pty master and re-sources **all three** M2 honest
   signals from owning the child — process name via `process_group_leader` +
   `proc_pidpath` (`term.rs:231,254`), bell via scanning `BEL` (0x07) in the
   pump (`term.rs:154`), exit code via `child.wait()` (`term.rs:124`). The
   moment tmux owns the child, all three go dark and must be re-sourced from
   tmux facilities. **Redefinition:** *attached* = the app is connected with
   this board active; *detached* = the app is gone but its ptys keep running
   daemon-side. `BoardSession.tmux` is always nil. tmux is reconsidered only in
   isolation, later, if real bare-attach is ever wanted — **out of M3**.
2. **Cold layout-only restore on daemon restart is acceptable for M3.** The
   daemon `std::process::exit(0)`s on SIGTERM/SIGINT (`main.rs:76`), so live
   shells die with it. Reconnect-survival (app disconnect, daemon stays up) +
   the scrollback ring cover the common case and are strictly better than
   today. On a full daemon restart, shells re-spawn and layout/viewport
   reproduce exactly. PTY re-parenting (true restart survival) is **optional**
   and later, never a gate.
3. **Manual board naming.** A new board gets a slug (`board-N`) until the user
   names/renames it. The chat2 auto-naming heuristic (born `strip-N`,
   auto-rename to the cwd repo on first cd+run, freeze once multi-repo) has
   unresolved cross-repo collision questions — **deferred out of M3**.
4. **Full lifecycle CRUD incl. delete.** `BoardDelete` refuses to delete the
   last board and tears down that board's terminals (via the term→board index).
   A detached board renders as a faint switcher row — no separate screen.

## 3 · Recommended architecture

The board — today's `Registry` (`docs` / `dock` / `tiles` / `board` viewport) —
is the unit that becomes N.

### Daemon (`tarmacd`)
- Wrap `Registry` in `Board { id, registry, name, order, session }`.
- Replace `Daemon.registry: Mutex<Registry>` with
  `Daemon.boards: Mutex<Boards { IndexMap<BoardId, Board>, active }>` — **one
  coarse global lock** (matches today's single-mutex model; N is single-digit;
  `IndexMap` preserves ⌘1..9 order). Every lock site (`restore_msg`,
  `apply_layout`, doc read, watcher dock-scan, `save_loop`) selects the board by
  id.
- `Daemon.terms` stays a global `HashMap` keyed by globally-unique `term_id`,
  but gains a **`term_id → board_id` ownership index** set at spawn time, so
  restore, teardown, and `tarmac open` provenance scope per board.
- The file watcher stays global; its dock-scan unions dock dirs across all
  boards.

### Persistence (`persist.rs`)
- Today `PersistedState` is **flat**: `{ docs, tiles, board }`
  (`persist.rs:40`). It becomes
  `{ boards: Vec<PersistedBoard { board_id, name, order, docs, tiles, board,
  session }>, active }`.
- **Lossless board-0 migration:** on load, if `boards` is absent and the legacy
  flat `docs`/`tiles`/`board` are present, synthesize one `PersistedBoard`
  `board-0` copying the legacy fields verbatim (byte-for-byte what the old load
  produced). Snapshot writes only the nested shape (one-way idempotent). Atomic
  write + corrupt-tolerant load preserved.

### Protocol (`tarmac-protocol`, additive — `v` stays 1)
- Optional **top-level** `board_id` on `Layout`, `Restore`, `SpawnTerm`, `Open`
  (absent ⇒ `board-0`). **No per-Tile `board_id`** — the board owns the tiles.
- New `struct BoardMeta { board_id, name, order?, active? }`.
- Five new message **types**: `BoardList` (daemon→app, pushed on connect +
  change); `BoardSwitch` / `BoardCreate` / `BoardRename` / `BoardDelete`
  (app→daemon).
- Session chip rides `BoardSession { name?, tmux?, attached? }` on
  `Restore`/`Layout`, plus a `BoardSessionState` push for live attach/detach.
- Connect handshake: `hello_ok`, then `BoardList`, then a `Restore` for the
  **active board only**. `BoardSwitch` replies with that board's `Restore`.
- All 8 frozen conformance vectors keep decoding byte-identically; new vectors
  grow additively (V9 in P1, V10 in P2, V11 in P5).

### App (`TarmacApp`)
- Introduce a `Board` (workspace) class owning the ~12 board-scoped properties
  that today live directly on the 1252-line `AppController` god-object:
  `{ BoardView, sessions, sessionOrder, primeTermID, docked, shelfPaths,
  docOwner, freshCardPath, preFlightViewport, boardID, name, session }`.
- `AppController` becomes a thin coordinator over `boards` + `activeBoardID` +
  the `DaemonClient` + the key monitor + the chrome singletons, delegating to
  the active `Board`.
- A switch detaches the active `BoardView`, mounts the target's, and re-binds
  chrome: Minimap / Zoom / Offscreen repoint off `board.viewport`; Shelf and the
  cockpit Dock save/restore per board (the docked terminal is a **live
  reparented SwiftTerm view** — leave = undock without fly-back, arrive =
  re-dock).
- **Background boards keep their daemon-backed ptys live**, with `TerminalView`s
  detached and reattached on switch (needed for honest ⌘K running-counts; the
  real memory cost is doc `WKWebView`s, not shells — suspend those per board).
- Terminal I/O routes via the `term_id → board` index; `tarmac open` lands on
  the caller's board (fallback: active).
- Pure logic (term→board index, doc-routing, switch-time shelf/dock
  save/restore, boot-term minting, active-board selection, count derivation,
  switcher view-model) is **pushed into TarmacKit and unit-tested** — the
  `TarmacApp` layer itself has no unit tests (see memory:
  `tarmac-app-layer-not-unit-tested`).

The existing single board becomes `board-0` by migration with **zero data loss
and zero user-visible change**; the daemon record + migration land in P1 while
the product still behaves as one board, and the app keeps driving one board
until the P3 refactor.

## 4 · Phases (each ships a working app; tests stay green)

### P1 ✅ — Board-keyed record + nested persist + board-0 migration *(invisible)*
Introduce board identity end-to-end as a no-op. The daemon holds a board map
keyed by `board_id`; the old flat `state.json` migrates losslessly to
`board-0`; `Layout`/`Restore` carry an optional `board_id` (absent ⇒ `board-0`).
The app still drives one board — nothing changes visually.
- **Daemon:** `Board` wrapper; `Daemon.boards` coarse-locked `IndexMap` (default
  `board-0`); every lock site selects `board-0`. `PersistedState` → nested;
  legacy flat file hydrates as `board-0` verbatim; snapshot writes nested only.
  **Probe** (de-risks the lifetime axis cheaply): add a per-term bounded
  scrollback ring (~256 KiB) to `TermHandle`; assert app-disconnect leaves terms
  running and reconnect can replay.
- **Protocol:** optional `board_id` (serde default + skip-if-none) on
  `Msg::Layout` + `Msg::Restore`; mirror `boardID: String?` on the TarmacKit
  layout/restore cases (nil default so every call site compiles unchanged). Unit
  test: a `board_id`-less layout decodes `None` and re-encodes byte-identically.
- **App:** thread an optional active `boardID` through `DaemonClient.layout` and
  restore decode, defaulting nil. `persistLayout` / `applyRestoredLayout`
  tag/read `board-0`. Add a `term_id → board` index (1 entry today). No `Board`
  extraction, no UI.
- **Acceptance:** a checked-in real pre-M3 `state.json` loads to exactly one
  `board-0` with identical docs/dock/tiles/viewport; load→snapshot round-trips
  to the nested shape, restore frame byte-identical. All 8 frozen vectors pass;
  V9 (board_id layout) added; V6/V8 still decode `board_id = None`. Disconnect
  leaves terms in the map. App behavior identical.
- **Risk:** MEDIUM. The flat→board-0 migration is highest-stakes (a bug corrupts
  every user's desk). Mitigate with a **golden-file byte-identity test** against
  a real fixture, and exactly one board at runtime.

### P2 ✅ — Board CRUD/list on the wire + two real boards *(crude switch, no chrome)*
Make N>1 boards real end-to-end behind a deliberately ugly **throwaway keybind**
before the real ⌘K panel. Lands the **entire wire** before the app refactor, so
P3 is a pure refactor against a stable N-board daemon.
- **Daemon:** connect → `hello_ok`, `BoardList`, `Restore` for active.
  `BoardSwitch` sets active + re-sends that board's `Restore` (reuses
  `restore_msg`), persists active. `BoardCreate` mints slug `board-N`, seeds a
  fresh `Registry` with a default term tile, replies `BoardList`. `SpawnTerm`
  gains optional `board_id` (default active); record term→board at spawn.
  `handle_open` routes the doc into the board owning the caller's
  `TARMAC_TERM_ID` (fallback active). Watcher dock-scan unions across boards.
  Background boards keep shells live. (Rename/Delete deferred to P5.)
- **Protocol:** `BoardMeta` + three new types `BoardList` (daemon→app),
  `BoardSwitch` + `BoardCreate` (app→daemon). Optional `board_id` on `SpawnTerm`
  + `Open`. Mirror in TarmacKit. Term I/O stays `term_id`-keyed, unchanged. Add
  V10; V1–V8 untouched.
- **App:** decode `BoardList` into a board-registry stub (ids/names/order/
  active). Stamp the active `board_id` on outgoing `Layout`. Throwaway key
  branch (e.g. Ctrl-⌘-→ next, Ctrl-⌘-N new). Still renders one `BoardView` but
  knows the list — de-risks P3 before the palette.
- **Acceptance:** daemon integration test — create `board-1`, layout each, spawn
  a shell on each, restart the daemon, assert each board restores its own docs/
  tiles/viewport and term_ids independently; switching exits no shell; a
  `tarmac open` from a term on `board-1` lands on `board-1` even when `board-0`
  is active. V10 round-trips. App: `BoardList` decodes; outgoing `Layout`
  carries the active `board_id`.
- **Risk:** MEDIUM. The Open-routing rule is the one genuinely new semantic —
  pin it to the caller-term's board with explicit fallback. Spawn-into-non-active
  ownership must be recorded **at spawn**, not derived later. Both daemon-side,
  integration-tested.

### P3 ✅ — App multi-board ownership refactor *(the big lift, pure refactor)*
Lift the ~12 board-scoped properties off the 1252-line `AppController` into a
per-board `Board` model; `AppController` becomes a thin coordinator. Largest,
riskiest, least-testable phase — deliberately **after** the daemon + wire are
N-board-capable, so it is a pure refactor against a stable substrate.
- **Daemon / Protocol:** NONE.
- **App:** `Board`/`Workspace` class owning the board-scoped state.
  `AppController` keeps `boards` / `activeBoardID` + `DaemonClient` + key monitor
  + chrome singletons, delegating to the active board. Switch detaches the
  active `BoardView`, mounts the target's, re-binds chrome (Minimap/Zoom/
  Offscreen off `board.viewport`; Shelf + Dock save/restore per board; cockpit
  Dock = live reparented SwiftTerm view, leave undock-without-fly-back, arrive
  re-dock). Inactive boards keep ptys live with views detached. Routing gains a
  real `term_id → board` lookup; `docOpened`/`fileEvent` route by the doc's
  owning board. Boot mints `board-0` + boot term; `BoardCreate` mints `board-N`
  + its own boot term. Repoint the P2 throwaway hotkey at the real switch path.
- **Acceptance:** two boards, switch, each keeps its own terminals, scrollback,
  layout, viewport across an app restart **and** a daemon restart (manual verify
  via the run/verify skill — app layer untested). Switching while a terminal is
  docked preserves dock state on both boards. A backgrounded board's mid-output
  does not leak into the active board. Prime-terminal focus does not leak across
  boards. All TarmacKit + Rust tests green.
- **Risk:** **HIGHEST, invisible to the suite** (app layer has no unit tests).
  The cockpit-dock live-view reparent and focus scoping
  (`boardHasFocus`/`reconcilePrimeToFocus` must target the active board's view +
  sessions) are subtle. MITIGATION: push pure logic into TarmacKit (term→board
  index, doc-routing, switch-time shelf/dock save/restore, boot-term minting,
  active-board selection, count derivation); verify reparent/focus via the
  verify skill (switch while docked; switch mid-output; ⌘T into a non-active
  board).

### P4 ✅ — ⌘K boards switcher (B5) + titlebar session chip + status-bar board state
Replace the throwaway hotkey with the real B5 ⌘K palette and surface board /
session identity in the chrome. Pure presentation over a model that already
round-trips.
- **Daemon:** mostly none — `BoardList` already carries the per-board facts.
  **Prefer app-derived** meta-line counts (running/bell/cards) to avoid daemon
  churn; only add optional count fields to `BoardMeta` if the app can't derive
  them locally.
- **Protocol:** additive only (optional `BoardMeta` count fields *iff* needed).
  Session-name chip rides `BoardMeta.name`. V1–V11 untouched.
- **App:** switcher overlay templated on `CycleHUD`: a centered ~540px panel
  over a dimmed/veiled board; board rows; the **86×54 thumbnail** rendering each
  board's tiles' world frames as colored rects (cyan live, amber bell, gray
  neutral — a static mini-projection, **not** live views); the strip glyph (cyan
  live, faint detached); the meta line. Add the ⌘K branch (none today); Enter
  opens (`BoardSwitch`); ⌘1..9 jump by order; `n` creates (`BoardCreate`);
  prefix type-to-filter (fuzzy deferred). Titlebar: adopt `fullSizeContentView`
  + a transparent accessory hosting the chip (net-new; `main.swift` is plain
  native today; dim it + the traffic lights in ⌘K). `StatusBar.setCounts`
  extends to the active board name + `N boards`.
- **Acceptance:** ⌘K opens the B5 panel over a dimmed/veiled board; rows show
  correct thumbnails (cyan live, amber bell), name, and meta counts matching
  live state; Enter/⌘1..9/`n`/prefix all trigger the right `BoardSwitch`/
  `BoardCreate`; the panel captures keys while the board behind is inert. The
  titlebar shows the active board name and updates on switch; the status bar
  shows the board name + `N boards`. Switcher view-model logic (prefix filter,
  ⌘1..9 → board_id by order, count formatting, world-frame → 86×54 rect
  derivation) is extracted to TarmacKit and unit-tested.
- **Risk:** LOW-MEDIUM. Visual-fidelity + the dim/veil/focus interaction. The
  titlebar approach (`fullSizeContentView` + accessory vs
  `NSTitlebarAccessoryViewController`) is a real AppKit fork but a layout risk,
  not a data risk. Thumbnails must use persisted/in-memory frames, not live
  views.

### P5 ✅ — Session liveness + reconnect re-bind + rename/delete + multi-board perf
Make the chip and switcher honest about session liveness (attached/detached)
from a daemon-native session abstraction (**no tmux**), make reconnect
**re-bind** to live shells instead of respawning, and finish board-lifecycle
CRUD + memory hardening. Last, because session survival is orthogonal to board
identity and must never block the multiple-boards promise.

> **Implementation note (shipped 2026-06-15, commit `e182f9f`).** The
> session-liveness model was simplified to **"two honest signals"**, dropping the
> `BoardSession`/`BoardSessionState`/`PersistedSession` types and the V11
> session-bearing restore the bullets below describe:
> - The attached/detached **chip + status word are app-LOCAL** — driven by the
>   `DaemonClient` connection state, not a wire `BoardSession.attached` (the daemon
>   can't tell a gone app it detached; reconnect flips it back).
> - **Switcher liveness rides an additive `BoardMeta.running`** (the daemon's live
>   pty count per board, re-pushed on term exit) — honest even for a never-visited
>   board — and cross-launch identity rides an additive **`Restore.live_terms`**
>   (the live `term_id`s the app re-binds to + replays scrollback for). No new
>   session struct; both are additive keys, so no V11 vector was needed.
> - P5.3 added a **bounded app auto-reconnect** (detached→attached recovery with a
>   capped backoff) — beyond the written plan but in its spirit.
> - **Deferred as planned:** daemon-restart PTY re-parenting — cold layout-only
>   restore ships (decision 2).
>
> Everything else below shipped as written. The bullets are kept as the original
> design intent; the shipped wire is `BoardMeta.running` + `Restore.live_terms` +
> `BoardRename`/`BoardDelete`.
- **Daemon:** per-board session state `{ name, tmux: nil, attached }` the daemon
  owns; `attached` reflects whether the app is connected with that board active.
  On reconnect, after `Restore`, replay each live term's scrollback ring (the P1
  probe) as `Output` frames and include the live `term_id` list per board so the
  app **re-binds** to running ptys instead of cold-spawning (fixes
  `restoreTerminals`, which today mints fresh ptys for all-but-boot —
  `state.rs:72-78` omits live term_ids). `BoardRename` + `BoardDelete` (refuse
  the last board; deleting tears down its terms via the term→board index;
  re-emit `BoardList`). `save_loop` snapshots all boards atomically.
  **OPTIONAL/deferred:** daemon-restart survival via PTY re-parenting under a
  detached reaper — ship reconnect-survival first; fall back to cold
  layout-only restore.
- **Protocol:** `BoardSession { name?, tmux?, attached? }` as an optional
  `session` field on `Restore` **and** `Layout` (persisted: `PersistedBoard`
  gains optional `PersistedSession { name }`; `attached` is runtime-only).
  `BoardSessionState` push (TermProc pattern) for attach/detach mid-session.
  `BoardRename`/`BoardDelete` types. V11 (session-bearing restore) + a test that
  a session-less restore decodes `session = None` byte-identically. V1–V10
  untouched.
- **App:** on `Restore`, if a `term_id` is live, **re-bind** the card to the
  running pty (consume replayed scrollback) instead of minting a fresh
  session+pty. Render the chip attached (green) / detached (faint) and the
  switcher detached rows from `BoardSession.attached` + `BoardSessionState`.
  Status bar regains the attached green word where the B1–B4 mocks show it. Wire
  Rename/Delete into the switcher. Suspend inactive boards' doc `WKWebView`s.
- **Acceptance:** app disconnect leaves shells running; reconnect re-binds to
  live term_ids and replays scrollback (re-bind, not re-spawn) — daemon test.
  The chip flips attached/detached live per board; a detached board renders a
  faint row with no running count. Delete-last refused; a deleted board's shells
  torn down. Multi-board RSS bounded with K boards × M doc cards (inactive
  webviews suspended). V11 round-trips; session-less restore byte-identical. Full
  per-board restart-indistinguishability as final acceptance.
- **Risk:** Highest-uncertainty (why it is last + split). The cheap part (honest
  app-connection attached state + scrollback re-bind, no tmux) ships
  independently. The optional daemon-restart PTY re-parenting is delicate
  (`child.wait()` at `term.rs:124`, proc-name at `term.rs:231/254` all assume
  the daemon is the parent) — its fallback is cold layout-only restore, and the
  milestone never depends on it. Residual risk is multi-board memory
  (`WKWebView`s), mitigated by board-granular offscreen offload.

## 5 · Sequencing rationale

P1 is the hard dependency for everything: `board_id` must be a first-class
optional key and the flat→board-0 migration must be lossless **before** any
second board exists. P2 lands the **entire wire** (board_id keying +
BoardList/Switch/Create + SpawnTerm/Open board_id) deliberately **before** the
P3 app refactor, so P3 is a pure app-side refactor against a stable,
already-N-board-capable daemon — the single most important ordering choice. P3
(the 1252-line AppController extraction) is the riskiest and least-testable step
and is gated behind a throwaway P2 keybind so a regression there cannot ship a
half-built ⌘K palette. P4 is pure presentation over data that already
round-trips. P5 is last because session survival is orthogonal to board
identity; its hardest sub-piece (daemon-restart PTY re-parenting) is optional
with a cold-restore fallback. The scrollback-ring probe is folded into P1 rather
than a milestone-gating Phase 0. Conformance vectors grow additively (V9 in P1,
V10 in P2, V11 in P5) with V1–V8 never mutated; rerun the full TarmacKit + Rust
+ conformance suite green at every phase boundary, and use the verify/run skills
for the app-layer behaviors the suite cannot cover.

## 6 · Open engineering questions (resolved during implementation, not blocking)

1. `board_id` rides on `SpawnTerm`/`Open` as an optional additive key (so a
   non-active board can be targeted, e.g. `tarmac open` from a backgrounded
   board's term), with the daemon's active board as fallback.
2. ⌘K filter prefix vs fuzzy, and whether ⌘1..9 map to row order or a pinned
   order. Plan ships **prefix + row-order**; refine later.
3. `board_id` format: an ordered slug `board-<counter>` (recommended — naturally
   ordered for ⌘1..9, readable in `state.json`) vs a UUID; display name is
   separate from the id.
4. Restore for a board whose shells were killed externally vs a never-attached
   board: live ⇒ re-bind, gone ⇒ cold layout-only restore + a faint detached
   row.
5. Teardown rule when a board with live shells is deleted: `BoardDelete` kills
   the board's terms via the term→board index (confirmed by decision 4 above).
6. Whether board-granular `WKWebView` suspension is sufficient for multi-board
   memory or a per-board card cap is needed: relies on the existing
   offscreen-offload decision applied per board.

## 7 · Out of scope (tracked, not in M3)

- **Real tmux / bare-terminal attach** — reconsidered only in isolation later if
  ever wanted (decision 1).
- **Daemon-restart PTY re-parenting** — optional, cold-restore fallback ships
  (decision 2).
- **Auto board-naming heuristic** — manual naming ships first (decision 3).
- **Editable docs (v4c)** — the milestone *after* M3 (needs the write-signal
  honesty model); driving notes in `docs/archive/v4/migration-plan.md` lines 154–190.
- **Zone labels** (user-typed board text) — nice-to-have after wayfinding.

## 8 · Definition of done

A user can hold multiple named boards, switch between them with ⌘K (and ⌘1..9),
create / rename / delete boards, and each board independently persists and
restores its own cards, layout, viewport, and terminals across app restart and
daemon restart (cold layout-only restore on the latter). The titlebar shows the
active board's session chip and an honest attached/detached signal; the status
bar shows the board name and board count. No tmux. Single-board users see zero
change until they create a second board; their existing desk migrates to
`board-0` losslessly.
