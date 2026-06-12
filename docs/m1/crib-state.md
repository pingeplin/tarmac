# Tarmac M1 — state & signal crib

The M1 state model and signal semantics, extracted so implementers (and the wire-protocol
designer) never interpret the design themselves. Sources: `design_handoff_tarmac/README.md`
("Core model", "Screens", "Interactions & Behavior", "State Management", "Cold start",
"Implementation decisions" ownership table + IPC sketch) and the interactive prototype
`design_handoff_tarmac/tarmac-proto/{app,data,desk,panels}.jsx` + `proto.css`, with
`tarmac/theme.css` + `converged.css` for the marks each state renders.

Precedence used throughout: **README > prototype > inference**. Conflicts are called out
inline. Where both sources are silent, the minimal behavior consistent with the no-harness
philosophy is proposed and marked `DECISION:` on its own line. Visual values (colors, px)
reuse `docs/m0/visual-crib.md` — its oklch→sRGB conversions are verified; never recompute.

M1 scope: dock + index (⌘E), pin tiles, drag-swap, provenance dots + pulses. **No** process
correlation exists in M1 (that is M2): every "during &lt;process&gt;" meta in the design
degrades to just its time part — each occurrence is flagged below.

---

## 1. Doc identity & per-doc state (daemon registry)

The registry is daemon-owned (README ownership table: "repo-color hash, doc registry,
provenance (cli vs user)" and "durable session state (strips, dock list, layout,
lastChangedAt) + disk" → `tarmacd`). One entry per doc, keyed by **canonical absolute
path** (CLI canonicalizes before sending and the daemon canonicalizes again —
`docs/protocol.md` "CLI session", `core/crates/tarmacd/src/docs.rs:19`; symlinked
duplicates collapse to one entry).

| Field | Type | Set by | Semantics |
|---|---|---|---|
| `path` | string | registration | canonical absolute path; registry key |
| `repo_root` | string \| nil | daemon, at registration | absolute path of enclosing git repo root; nil if none |
| `repo_name` | string | daemon, at registration | display name + color-hash input (see §1.2) |
| `color_index` | uint 0–3 | daemon, at registration | FNV-1a(repo_name) % 4 → repo-a..d (see §1.3) |
| `via` | "cli" \| "user" | daemon, every open | most recent opener (M0 wire semantics kept: `docs/protocol.md` "upsert doc-registry entry {path, via…}") |
| `read` | bool | daemon (`open` clears, `doc_read` sets) | false = unread; **only cli opens may clear it** (§2) |
| `last_changed_ms` | uint \| nil | daemon, on file event | mtime_ms from the `file_event` stat (`docs/protocol.md` File watching); nil until first change |
| `last_opened_ms` | uint | daemon, every open | wall-clock ms of the most recent `open` (cli or user) |

`last_opened_ms` is new state with no design-source counterpart; it exists so ⌘P recency
(§6) survives daemon restarts and app relaunches.

DECISION: the daemon records `last_opened_ms` on every open; ⌘P recency is derived from
`max(last_opened_ms, last_changed_ms ?? 0)` rather than from a separate recency list.

### 1.1 Repo derivation

The prototype never derives repos — they are fixtures (`data.jsx` `PDOCS`, e.g.
`"pay-handoff": { repo: "payments-api", c: "a", name: "docs/handoff.md" }`). README says
only "Per doc: path, repo, repo color index" (State Management) and "stable hash of repo
name → 4-hue palette" (Design Tokens). So derivation is specified here:

DECISION: the daemon derives the repo by walking up from the doc's directory toward `/`
looking for a `.git` entry (directory **or** file — worktrees/submodules use a `.git`
file). `repo_root` = that directory; `repo_name` = its basename (e.g. `payments-api`);
the doc's display path = `repo_name + "/" + path relative to repo_root` (matches the
prototype's `{repo}/{name}` rendering in `panels.jsx` `PPeek` and `desk.jsx` `DocTile`,
e.g. `payments-api/docs/handoff.md`).

DECISION: for a doc outside any git repo, `repo_root` = nil, `repo_name` = basename of the
doc's parent directory, and the display path = `<parent-dir-basename>/<filename>`. This
matches M0's placeholder behavior (`app/Sources/TarmacApp/PeekPanel.swift:133–134` hashes
the parent directory's last path component), so existing peek-header dot colors do not
shift when M1 lands.

DECISION: grouping identity (index §5, and any future per-repo logic) is `repo_root` when
present, else the parent directory path — **not** `repo_name` — so two distinct repos both
named `api` form separate groups. They will share a color (hash input is the name); README
explicitly accepts collisions ("collision acceptable", Design Tokens).

DECISION: repo fields are computed once at registration and recomputed at daemon startup
when the persisted registry loads; the daemon does not watch for a `.git` appearing later.

### 1.2 Repo color index (daemon must own it, same algorithm as the app)

README ownership table assigns "repo-color hash" to `tarmacd`. The existing app-side
implementation is `app/Sources/TarmacApp/Theme.swift` `repoColor(for:)` — **FNV-1a 64-bit**
over the UTF-8 bytes of the name:

- offset basis `0xcbf29ce484222325`
- prime `0x100000001b3` (wrapping multiply)
- `index = hash % 4` → 0=repo-a, 1=repo-b, 2=repo-c, 3=repo-d

The daemon must implement this byte-for-byte (continuity: colors users saw in M0 peek
headers must not change). The app keeps `Theme.repoColors` only as the index→NSColor map
(values in `docs/m0/visual-crib.md`: repo-a `#d78e88`, repo-b `#81b482`, repo-c `#89a4de`,
repo-d `#be92c8`) and consumes the daemon's `color_index` instead of hashing locally.

Note: the prototype's fixture letters are hand-assigned and do **not** match the hash
(FNV-1a gives payments-api→d, search-svc→c, infra→b; fixtures say a, b, c). Prototype
screenshots are not hue-for-hue ground truth; the hash is.

---

## 2. Read/unread — exact transitions

The cyan provenance dot means **"opened via `tarmac open` and unread"** (README screen 2:
"cyan dot top-right if opened-via-CLI and unread"; Core model table: "cyan dot on doc
icon/tab | doc was opened via tarmac open"). The prototype's render condition is
`st.openedByCli && !st.read` (`panels.jsx` `PDock` and `PIndex`).

### 2.1 Transition table

| Event | `read` | Source / rationale |
|---|---|---|
| `tarmac open` (via cli), new doc | → false (dot appears) | prototype `app.jsx` openDoc sets `openedByCli: true`, `read` stays falsy |
| `tarmac open` (via cli), doc already registered | → false (dot reappears) | DECISION below |
| app `open` (via user), new doc | → true (no dot, ever) | DECISION below |
| app `open` (via user), doc already registered | unchanged | DECISION below |
| peek presented (any entry point: ⌘P, dock click, index click, toast "⏎ peek" click) | → true (dot clears) | `app.jsx` `openPeek` sets `read: true`; every entry point routes through `openPeek` (dock `onClick={() => onPeek(id)}`, index item ditto, toast peek chip, ⌘P handler) |
| pin (⌘⏎) | no direct effect | `app.jsx` `pinPeek` never touches `read`; pinning is only reachable from a peek, which already cleared it |
| unpin (tile ✕) | no effect | `app.jsx` `unpin` only edits tile order |
| file change (`file_event`) | **unchanged** — a change does NOT re-mark a read doc unread | `app.jsx` fileChange sets only `changedAt`/`lastDuring`; the "something changed" signal is the pulse + ✎ meta (§3), not the dot |
| drag/swap, index toggle, esc | no effect | not in any prototype code path |

DECISION: re-running `tarmac open` on an already-registered doc re-marks it unread
(`read` → false). The prototype's literal code keeps `read: true` on re-open (`app.jsx`
openDoc spreads `...prev[e.doc]` and only sets `openedByCli`), but that path is never
exercised — the sim opens each doc exactly once — so it is incidental code shape, not
demonstrated behavior. Each `open` is a new doorbell ring; "opened via tarmac open and
unread" must hold for the *latest* open. Re-open does **not** move the doc in the dock
(§5) — the dock-order early-return in the same handler *is* deliberate.

DECISION: opens via `"user"` never mark a doc unread (new user-opened docs register with
`read = true`). A user-initiated open implies awareness; the dot exists to flag what the
CLI did while you weren't looking. With this rule the prototype's two-flag condition
(`openedByCli && !read`) collapses to a single flag: **dot ⇔ `read == false`**, because
only cli opens can clear `read`. Implementers may render `!read` directly; it is provably
equivalent under these transitions. `via` is still stored (wire compat + future meta copy).

DECISION: if a `doc_opened` arrives for a doc whose content is currently visible (peeked,
or pinned as a tile), the app immediately sends `doc_read` — the user is looking at it, so
no dot. The daemon still applies its normal clear-then-set sequence; the app suppresses
any one-frame dot flash locally (rendering is app-side anyway).

### 2.2 Ownership of `read`

The daemon is the durable source of truth (task: read flags survive daemon restarts and
app relaunches). The app marks read **optimistically** at the moment it presents the doc
(so the dot clears in the same frame, like the prototype's synchronous `openPeek`), and
sends `doc_read` (§8) to persist it. `doc_read` is idempotent; the app may send it on
every peek presentation, including re-peeks of already-read docs.

---

## 3. Pulse — "file changed on disk"

The only trigger is a `file_event` for a registered doc (README Core model: "cyan halo
pulse (2.4s, ~30s decay) | file changed on disk | FSEvents/fswatch mtime"). `doc_opened`
does **not** pulse (prototype openDoc never sets `changedAt`).

### 3.1 Exact values

- Dock-icon halo: `@keyframes dockPulse { 0% { box-shadow: 0 0 0 0 var(--tm-agent-dim); }
  60% { box-shadow: 0 0 0 6px transparent; } 100% { box-shadow: 0 0 0 0 transparent; } }`,
  applied as `animation: dockPulse 2.4s ease-out 3` (`proto.css` `.tm-dock .doc.pulse`).
  `--tm-agent-dim` = `#4eccd3` @ 16% (verified table, `docs/m0/visual-crib.md`).
- Halo runs 2.4 s × 3 = **7.2 s of animation**; the *recent window* is
  **30 000 ms exactly** — `st.changedAt && Date.now() - st.changedAt < 30000` (`panels.jsx`
  `PDock`/`PIndex`/`PPeek`, `desk.jsx` `DocTile`). README's "~30s of being noticeable"
  = this window. After 7.2 s the doc shows only the static recent markers for the rest of
  the window; after 30 s all recent markers disappear.
- Static recent markers during the window:
  - index item: 7 px round dot, solid `var(--tm-agent)` `#4eccd3` (`panels.jsx` `PIndex`
    inline style; static, no animation),
  - peek header meta: `✎ {N}s` in agent cyan at 0.85 opacity, where
    `N = max(1, round((now - changedAt)/1000))`, live-updating (`panels.jsx` `PPeek`),
  - doc tile header meta: same `✎ {N}s`, mono 9.5px agent cyan (`desk.jsx` `DocTile`).
- **M1 degradation**: the prototype renders `✎ {N}s · during claude` via `st.lastDuring`
  (`app.jsx` fileChange sets `lastDuring: true`). "during &lt;process&gt;" is process
  correlation = M2. In M1 the meta is exactly `✎ {N}s` — no `lastDuring` state is tracked
  at all. Same for the rail's `14:02 · during claude` (the rail itself is M2).

### 3.2 Who tracks "recently changed"

Split per the one rule (README: daemon = observed fact / survives restart; app = live view
state):

- **Daemon**: stores `last_changed_ms` (the `mtime_ms` it stat'ed and pushed in the
  `file_event`) in the registry, durably. It has no concept of "recent".
- **App**: derives `recent = now - last_changed_ms < 30_000` and owns all animation state
  (which iteration the halo is on, the live `✎ Ns` counter). Both are recomputable from
  `last_changed_ms` at any time.

DECISION: every new `file_event` restarts the ×3 halo cycle and resets the 30 s window.
The prototype literally fails to do this (the `.pulse` class is still applied when a second
change lands inside the window, so the finished CSS animation never restarts — at sim
t=18.4 s the second `pay-handoff` change produces no new halo). That is a CSS limitation,
not intent: README's table maps the pulse to "file changed on disk", every time. Native
code restarts the animation explicitly.

DECISION: on restore (app relaunch) within 30 s of `last_changed_ms`, the app shows the
*static* recent markers (index dot, ✎ meta) for the remainder of the window but does not
replay the halo — the halo announces an event you were present for; the static markers
carry the fact.

Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`): suppress the
halo animation only (`proto.css` `.tm-app.still .tm-dock .doc.pulse { animation: none; }`);
the static recent dot and ✎ meta still render — state is unaffected by the motion setting.

---

## 4. State → surface matrix

What each piece of state renders, with selectors (visual px/colors live in the M0 crib and
the M1 layout crib; listed here so no state lacks a surface and no mark lacks a state):

| State | Dock icon (46px strip) | Index item (⌘E) | Peek header | Doc tile header |
|---|---|---|---|---|
| repo identity | 6px dot, top-left 4,4 (`converged.css` `.tm-dock .doc .rd`) | 7px `.tm-repodot` on the group header (`theme.css`) | 7px dot (`PeekPanel.swift` parity) | 7px `RepoDot` (`desk.jsx`) |
| unread (cli) | 5px agent dot, top-right 4,4 (`.tm-dock .doc .ad`) | 5px `.tm-agentdot` (`theme.css`) | — | — |
| recent (<30s) | `dockPulse` halo ×3 then static (`proto.css`) | static 7px agent dot (`panels.jsx`) | `✎ Ns` cyan @0.85 (`panels.jsx` `PPeek`) | `✎ Ns` mono 9.5px cyan (`desk.jsx`) |
| peeked / pinned | `.on` (bg2 + line border): `activePeek === id \|\| pinned.includes(id)` (`panels.jsx` `PDock`) | `.on` when peeked (`PIndex`) | n/a | n/a |
| bell (amber `.wd`) | **M2 — do not build** | M2 | — | M2 |

The unread dot and the recent marker are independent and may show simultaneously
(`PIndex` renders both spans side by side).

Terminal tile: M1 has no process names, so the prototype's `claude · payments-api` header
and ⠧ spinner (`desk.jsx` `TermTile`) are M2.

DECISION: in M1 the terminal tile header is `›_` + the spawned shell's basename (e.g.
`zsh`) — an observable fact (what the daemon spawned), with no spinner, elapsed, or bell
mark. The tile order always contains the terminal slot, and the desk renders tile chrome
even at n=1 (the prototype's `order = ["term"]` solo tile still has a `.thd` header).

### 4.1 Derived display strings

- Peek/tile path: `repo_name + "/" + relpath` (`panels.jsx` `PPeek`, `desk.jsx` `DocTile`).
- Dock icon tooltip: same full display path (`panels.jsx` `PDock` `title=`).

DECISION: index item label = the doc's basename (the prototype's
`name.replace("docs/", "")` in `PIndex` is fixture cosmetics that amounts to basename for
every fixture); on a basename collision within one group, fall back to the repo-relative
path for the colliding items. Full display path stays available as the tooltip.

---

## 5. Dock order, index grouping, tile order

### 5.1 Dock order (daemon-owned, durable)

README State Management: "dock doc list (ordered)" — but no ordering rule anywhere. The
prototype's insertion (`app.jsx` openDoc: `[...dock.slice(0, 2), e.doc, ...dock.slice(2)]`)
splices the new doc into index 2 — a demo-staging artifact that positions `infra-runbook`
between the fixture repo groups for the screenshot; it generalizes to nothing.

DECISION: dock order = **insertion order**; a newly registered doc appends at the end.
Re-opening an already-registered doc does not move it (this part *is* deliberate prototype
code: the openDoc handler early-returns when `dock.includes(e.doc)`). The dock never
shrinks in M1 — there is no `doc_removed` (carried from `docs/protocol.md` M0 file-watching
note; a deleted file just stops emitting events and keeps its dock slot).

Dock existence is derived state: the dock does not render until the registry is non-empty
(README screen 2: "Dock is absent entirely until the first doc opens"; cold start step 3:
"first tarmac open → dock is born (slides in)"; `tarmac/coldstart.jsx` F3 board: not an
empty dock — *no* dock).

DECISION: the dock-birth slide-in uses the standard motion (220 ms
`cubic-bezier(0.2, 0.8, 0.2, 1)`, translateX(-100%) → 0), gated on Reduce Motion — no
source specifies it; this reuses the peek curve from the verified motion table. When a
restore already carries ≥1 doc, the dock is present from first paint, no animation.

### 5.2 Index grouping (derived, never stored)

Groups are built by iterating the dock order and bucketing by repo (`panels.jsx` `PIndex`):
group order = order of first appearance of each repo in the dock; items within a group in
dock order. Grouping key per §1.1 is `repo_root` (or parent dir for non-repo docs); the
group header renders the repo dot + `repo_name` (mono 10.5px, `theme.css` `.tm-sgroup .hd`).
Index open/closed is app live state, not persisted (README per-app prefs list accent / peek
width / rail visibility only). M1 omits the prototype's strip-name footer (strips = M3);
the `⏎ peek · ⌘⏎ pin` footer hint stays.

### 5.3 Tile order (daemon-owned, durable)

The desk order array is `["term", ...pinnedDocIds]` (`desk.jsx` header comment;
`app.jsx` `initialStripState` `order: ["term"]`). Semantics:

- **pin** (`app.jsx` `pinPeek`): appends the peeked doc at the **end** of the order and
  closes the peek. No-op if no peek is open.
- **unpin** (`app.jsx` `unpin`, tile ✕): removes the doc from the order. The doc stays in
  the dock (dock list and tile order are independent; the ✕ tooltip is "unpin (back to
  dock)", `desk.jsx`). Does not open a peek.
- **swap** (`app.jsx` `swapTiles`): exchanges the two keys' positions in the order; the
  terminal slot participates like any doc (README screen 5: "Terminal tile drags too").
  A drag released over no target changes nothing (`desk.jsx` `up` handler: swap only
  `if (d && d.over)`). Drag-in-progress (dx/dy, hovered target) is app live state and
  never crosses the wire; only the committed post-swap order does.
- Clicking a pinned doc's dock icon opens a **peek** of it over the desk (the prototype's
  dock `onClick` is unconditionally `onPeek`); it does not focus or flash the tile.
- Grid geometry by tile count is `desk.jsx` `deskGridStyle`/`slotStyle` (1 → `1fr`;
  2 → `1.35fr 1fr`; 3 → `1.35fr 1fr` × `1fr 1fr`, first tile spans both rows;
  4 → `1.25fr 1fr` / `1.3fr 1fr`) — exact values for the layout crib; cited here only
  because the order array drives slot assignment in array order.

DECISION: no hard cap on pinned tiles in M1. The prototype never caps `order`; counts >4
fall through to the 4-tile template with CSS auto-placement. The wire shape must not
assume ≤4 tiles.

Layout persists across daemon restarts and app relaunches (README screen 5: "Layout
persists per strip" — M1 has exactly one implicit strip, so: persists, full stop).

---

## 6. Recency & ⌘P

README Interactions: "⌘P peek most-recently-changed doc". Cold start step 3: the
first-doc toast advertises `⌘P peek` at a moment when zero file events exist — so "opened"
must count as a recency event or the toast lies.

- **Prototype** (`app.jsx` keyboard handler):
  `const latest = fileEvents[0] ? fileEvents[0].doc : dock?.[0]` — strict file-event
  priority, dock-front fallback.
- **M0 app** (`AppController.swift` `recentDocs` + `bumpRecent`): ordered list, seeded
  from restore order, bumped by both `doc_opened` and `file_event`; ⌘P takes the last.

These disagree in one window: after a cli open that follows the last file change (sim
t∈[11.8 s, 18.4 s): prototype ⌘P → `pay-handoff` (last change), M0 → `infra-runbook` (last
open). Conflict resolution — the M0/openness rule wins:

DECISION: ⌘P targets the doc with the highest recency key, where recency = latest of
`doc_opened` and `file_event` (daemon fields: `max(last_opened_ms, last_changed_ms ?? 0)`),
seeded at restore by sorting the restore docs ascending on that key (ties broken by dock
order). The prototype's strict file-event priority loses because (a) README's own first-doc
toast and M0's per-open toast (`⌘P to peek`) require a just-opened doc to be ⌘P-reachable,
and (b) the prototype's `dock[0]` fallback only worked because cold start makes the first
doc `dock[0]`. Every registered doc has `last_opened_ms` by construction (registration *is*
an open), so ⌘P with a non-empty registry is always well-defined; with an empty registry
⌘P is a no-op (M0's beep is fine).

DECISION: ⌘P never closes the peek. The prototype re-targets the open peek to the most
recent doc (`openPeek(latest)` unconditionally) and only `esc` dismisses; README is silent,
so the prototype is the spec. **This changes M0**: `AppController.togglePeek()` currently
hides a visible peek — M1 replaces toggle with re-target (pressing ⌘P with the
most-recent doc already peeked is a visible no-op and keeps the peek open).

---

## 7. Ownership split (authoritative, per README table)

One rule (README Implementation decisions): *the daemon is source-of-truth for anything
that must survive a restart or is an observed OS fact; the app is source-of-truth for
live, in-the-moment view state.*

**Daemon (`tarmacd`) — durable, survives daemon restarts (disk) and app relaunches
(restore push):**

- doc registry: path, via, `read`, `repo_root`/`repo_name`/`color_index`,
  `last_changed_ms`, `last_opened_ms` (§1)
- dock order (insertion order, §5.1)
- pinned tile order including the terminal slot (§5.3)
- plus the M0 facts it already owns: pty ownership, file watching, the CLI socket

DECISION: the daemon persists registry + layout to
`~/Library/Application Support/tarmac/state.json` (sibling of `tarmacd.sock`), written
debounced after each mutation and loaded at startup. File format/atomic-write strategy is
the daemon's choice; only the durability contract is normative. (No design source names a
location; README only mandates "+ disk".)

**App — live view state, lost on relaunch by design:**

- which doc is peeked (restore never reopens a peek; see note below)
- peek width (user pref 36–62%, default 47% — persisted app-side e.g. UserDefaults, per
  README per-app "tweakable prefs (accent, peek width, rail visibility)"; *not* daemon
  state)
- index open/closed (§5.2)
- drag-in-progress (key, dx/dy, hover target — §5.3)
- animation state: pulse iteration, live `✎ Ns` counters, toast queue
- first-responder/focus

Note: README State Management lists "peeked doc" under *per-strip* state, which belongs to
M3 strips. For M1 the peeked doc is app live state and is not restored; when strips land,
it migrates into strip state per the README. (This is the assigned M1 ownership split;
recording the M3 forward pointer so the move isn't read as a contradiction later.)

Restore choreography: on app connect (after `hello_ok`) the daemon pushes one restore
message carrying *everything needed to rebuild the desk* — the full doc entries in dock
order plus the tile order. The app rebuilds dock, index data, tiles, recency (§6), and
recent markers (§3) from it, opens no peek, and replays no animations.

---

## 8. Wire-protocol requirements (checklist for the protocol designer)

Field/message names below are suggestions; the protocol doc (`docs/protocol.md`) makes the
final call. Requirements are normative:

1. **Extended doc entry** (used in both `restore.docs[]` and `doc_opened`): `path`,
   `via:"cli"|"user"`, `read:bool`, `repo_root:string|nil`, `repo_name:string`,
   `color_index:uint(0..3)`, `last_changed_ms:uint|nil`, `last_opened_ms:uint`. M0 fields
   (`path`, `via`, `last_changed_ms`) keep their names/types — M0's decoder rules
   ("decoders MUST ignore unknown keys") make this additive.
2. **`restore` is now ordered**: `docs[]` array order = dock order (M0 sent HashMap
   order — undefined; M1 must define it). Add the tile order: e.g.
   `tiles:[{kind:"term"} | {kind:"doc", path}]` — `kind` first, so M2/M3 can add
   `term_id`, splits, or per-strip arrays without reshaping (forward-compatible per §5.3
   no-cap DECISION).
3. **`doc_opened` carries the full doc entry** (not just `path`+`via`): the app must
   render the dot, repo dot color, and dock/index rows for a brand-new doc without a
   round-trip.
4. **App→daemon `doc_read {path}`** — fire-and-forget like the app's `open` (no reply
   frame), idempotent (`read := true`). No daemon echo needed (single app connection,
   M0 rule).
5. **App→daemon layout snapshot** `layout {dock:[path…], tiles:[{kind,…}…]}` — full
   state, last-writer-wins; sent after every committed pin, unpin, and swap. It carries
   the dock array even though no M1 gesture reorders the dock, so the shape doesn't churn
   when dock drag arrives. Daemon merge rules: paths it doesn't know are ignored;
   registered docs missing from the snapshot keep their previous relative order, appended
   at the end (this makes the open-vs-snapshot race converge: a doc the daemon registered
   mid-snapshot lands at the end — exactly where insertion order puts it).
6. **`file_event` unchanged** (`path`, `mtime_ms`); the daemon updates the registry's
   `last_changed_ms = mtime_ms` *before* pushing, so a crash between the two never loses
   the fact.
7. **Open sequencing**: on a cli `open` the daemon upserts (set `via`, `last_opened_ms`;
   clear `read` per §2; append to dock if new) *before* pushing `doc_opened`, so the
   pushed entry already reflects the new state.
8. **Persistence**: registry + dock order + tile order written to disk (§7 DECISION) and
   reloaded at daemon startup; a daemon restart followed by an app connect must produce a
   `restore` indistinguishable from one without the restart.
9. **No `doc_removed`** in M1 (unchanged from M0).

DECISION: the protocol stays `v:1`. All M1 changes are additive (new keys on existing
messages, two new app→daemon types); M0's mandatory ignore-unknown rules make old parties
safe, and no M0 message changes meaning.

---

## 9. Keyboard map & focus rules (M1)

From README Interactions, filtered to M1 scope (⌘K switcher = M3; ⌫ return-after-autoswitch
depends on `tarmac focus` = not M1; bell = M2):

| Key | Action |
|---|---|
| ⌘P | peek the most-recent doc (§6 recency); re-targets an open peek; never closes it; no-op (beep) with empty registry |
| ⌘E | toggle index (dock 46px ↔ index 224px). No-op while the registry is empty (no dock exists to expand — DECISION below) |
| ⌘⏎ | toggle pin of the **peeked** doc (see conflict below); closes the peek either way; no-op when no peek is open |
| esc | precedence, one surface per press: **peek → toasts** (clear *all* toasts at once, `app.jsx` `setToasts([])`). esc does **not** close the index — in the prototype the esc handler only knows switcher/peek/toasts; the index is a sidebar mode, not an overlay. M3 inserts the switcher at the top of the chain. |

**⌘⏎ conflict — README wins**: README says "⌘⏎ pin/unpin peeked doc"; the prototype's
`pinPeek` only closes the peek when the doc is already pinned
(`if (!ss.peek || ss.order.includes(ss.peek)) { closePeek(); return; }`). Spec: peeked doc
not pinned → pin (append to tile order) + close peek; peeked doc already pinned → **unpin**
(remove from tile order) + close peek. The tile ✕ label `⌘⏎ ✕` (`desk.jsx` `DocTile`)
corroborates the unpin reading. Note the prototype divergence when verifying against it.

**Focus rules** (README screen 4 + Interactions; `AppController.openPeek` already
implements the first):

- Opening a peek never moves keyboard focus out of the terminal; `esc` dismisses.
- Agent-driven events (doc_opened, file_event) only mark — dots, pulses, toasts. Nothing
  in M1 may switch the active view or move focus on a daemon push (`tarmac focus` + the
  idle-≥3min banner are out of M1 scope; `focus` frames, if received, are ignored as
  unknown types per protocol rules).
- Never move the user's scroll position: peek live-reload keeps the reading position (M0's
  `tarmacRender` already records/restores `scrollTop` — `docs/m0/visual-crib.md`).

DECISION: after any mouse interaction on dock, index, toast chips, or tile headers, the
app returns first responder to the terminal view (generalizing M0's peek focus rule —
these surfaces contain no text input, and the terminal is "the body").

DECISION: no keyboard list-navigation in M1. The index footer's `⏎ peek` hint implies a
selection model the prototype never implements (items are click-only) and ⏎ cannot be
intercepted globally while focus stays in the terminal. Dock/index/toast interaction is
mouse + the global shortcuts above. Revisit with M3's switcher.

---

## 10. Toasts in M1 (doc lifecycle only)

Mechanics are M0-crib-verified (max 3 via keep-last-2+new, 7 s auto-dismiss, esc clears
all; `app.jsx` `pushToast`). M1 state-relevant rules:

- **Trigger**: `doc_opened` with `via:"cli"`. Process-exit toasts are M2.
- Every cli open toasts, including re-opens of already-registered docs (the prototype's
  `pushToast` sits outside the dock-membership early-return — deliberate: the doorbell
  rang again even if the dock didn't change).
- **First-doc toast** (registry transitioned 0→1, README cold start step 3): icon `✚`,
  title `first doc · <display path>`, kbd chip `⌘P peek`.
- **Subsequent opens** (prototype `app.jsx` openDoc): icon `✚`, title
  `tarmac open <repo_name>/<basename>` (the prototype hand-writes `infra/runbook.md` —
  repo + basename, not the full relpath). Body `called from claude · payments-api` is
  process correlation = **M2; M1 renders no body line**. Chips: `⏎ peek` (click → peek
  that doc + dismiss that toast, `app.jsx` toast render) and `esc` (dismiss that toast).
  The chips are clickable buttons only — the ⏎ key is not intercepted (focus rule §9).

DECISION: no toast for `via:"user"` opens (the user did it themselves; M1 has no
user-open UI anyway, so this only constrains the protocol path). This supersedes M0's
toast-on-every-`doc_opened`.

DECISION: M1 drops the toast body line entirely rather than substituting other copy; the
⏎ peek chip already carries the action, and inventing copy ("opened via CLI") would
restate the title.

---

## 11. M2+ marks that must NOT be built in M1

So no one "helpfully" implements them off the same fixtures: amber bell dot (`.wd` in
`converged.css`, `wdot`/bell in `app.jsx`/`desk.jsx`), foreground-process tile/tab labels
+ ⠧ spinner + elapsed, exit toasts, `during <process>` meta and the `lastDuring` flag,
right rail (PROCESSES / FILE EVENTS), status-bar doc counts (no status bar exists), strips
/ ⌘K / detached card / tmux line, edge-split drop preview. The protocol additions in §8
must not reserve fields for any of these — M2 adds its own keys under the ignore-unknown
rule.
