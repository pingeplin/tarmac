# Backlog — unbuilt design features (post-M3)

> **Doc status: ACTIVE — but everything below is UNBUILT.** This is the audited
> list of things Tarmac does *not* do. Nothing in §1 exists in the code; §2 is
> explicitly out of scope; §3 records surfaces that were replaced so they don't
> get re-filed as bugs. For what Tarmac *does*, see
> [`architecture.md`](architecture.md). Docs index: [`README.md`](README.md).

M0–M3 + the v4 whiteboard migration closed on 2026-06-15; the UI was then rebuilt
on Tauri 2 + React + xterm.js (#27). The core experience (terminal-first cockpit,
`tarmac open` docs, honest signals, infinite board with gravity/provenance,
wayfinding, terminal primacy, multiple boards with ⌘K) is shipped.

This file tracks what the **original v3 design handoff** (the v3 README — now in
git history; the `design_handoff_tarmac/` bundle was removed once its content was
absorbed into `docs/`) specified that is **not yet built** — separated from the
parts the v4 migration deliberately replaced. "README §…" below cites a section
of that v3 handoff README.

**Re-verified against the Tauri app on 2026-08-04.** The original 2026-06-15 pass
cited Swift files (`app/Sources/`, `TitleBarChip.swift`, `DocTemplate.html`,
SwiftTerm bridges); none of those exist any more, so every "State:" line below was
re-checked against `desktop/src/` and `core/`. Each gap is still a gap.

Two larger pending items are tracked in more detail elsewhere, not fully
duplicated here:
- **Editable docs / conflict banner (v4c)** — a **proposal, not scheduled work**;
  needs a design round first (open questions remain). Captured spec:
  [`docs/proposed/v4c-editable-docs.md`](proposed/v4c-editable-docs.md); driving
  loop: `docs/archive/v4/migration-plan.md` §Deferred.
- **Zone labels** (user-typed text on the board, like any canvas tool) —
  nice-to-have after wayfinding (`docs/archive/v4/migration-plan.md` §Deferred).
  Geometry: `.tm-zonelab` = `font 600 10px mono`, `letter-spacing 0.18em`,
  `color --tm-faint`, `opacity 0.75`, `pointer-events: none`; `13px` in low-zoom.
  (The class is named only in the archived cribs — it is not in `desktop/src/`.)

---

## 1 · Genuine gaps (v3 features never carried into v4)

These were specified in the v3 README, are not superseded by a v4 decision, and
are confirmed absent in the code. Roughly ordered by value.

### 1.1 · `tarmac focus` verb + idle auto-switch banner
- **What:** the `tarmac focus <path>` CLI verb, and the idle-focus policy — if the
  user is idle ≥3 min (configurable), an agent `tarmac focus` call may switch the
  active view, but **must** show a banner `▞ agent switched to <doc> — you were
  idle 4 min` + `⌫ go back`. Never steals focus while typing.
- **Source:** README §Interactions "Focus-stealing policy"; the
  "Implementation decisions" verb list (`open · focus · attach`).
- **State:** CLI has **only** `open` (`core/crates/tarmac-cli/src/main.rs`); no
  `Focus` message in the protocol (`core/crates/tarmac-protocol/src/lib.rs`); no
  idle timer or banner in the app.
- **Scope:** protocol `Focus{path}` + daemon route + app idle-timer + banner UI +
  `⌫` go-back. Note the no-harness rule: focus is *requested* by any caller, never
  agent-arbitrated.

### 1.2 · Session restore card / overlay
- **What:** on relaunch, the desk renders dimmed (35%) under a veil with a centered
  card listing restore facts (`✓ 6 docs · 3 repos`, history-intact line, "agent was
  waiting since …"), "any key to continue". Detached strip shows a `$ tarmac attach
  <name>` empty state instead.
- **Chrome (README §Screens 8, exact):** centered card — `bg2` background, `12px`
  radius, `22×26px` padding — over the desk dimmed to **35%** under a veil. The
  three fact lines verbatim: `✓ 6 docs · 3 repos` · `✓ tmux attached · 2 windows,
  history intact` · `→ agent was waiting on you · since 13:47`; footer "any key to
  continue".
- **Source:** README §Screens 8 "Session restore".
- **State:** the app restores layout/viewport **silently** — no restore overlay
  exists (2026-08-04: no "any key to continue" anywhere in `desktop/src/`; the
  only restore machinery is `App.applyRestore` + `board/model.ts:didRestore`).
- **Scope:** a board-arrive overlay view + the restore-facts model. The detached
  empty-state depends on tmux/attach (see §2), so ship the attached-only card first.

### 1.3 · Doc-path linkification in terminal output
- **What:** any path in terminal output matching the open-doc set is linkified
  (cyan, dashed underline; hover = solid + tint; ⌘click → peek). Pure regex,
  iTerm-style semantic links.
- **Source:** README §Screens 1 "Doc links in output".
- **State:** only xterm.js's `WebLinksAddon` is wired
  (`cards/TerminalCard.tsx` → `openExternal(uri)`), which matches **URLs** and
  opens them in the OS browser; there is **no** match-against-open-docs path
  linkifier.
- **Scope:** a custom xterm.js link provider (`registerLinkProvider`) that matches
  known doc paths against the app's `docStore` and routes ⌘click to the doc card.
  Note the ⌘click destination in the v3 spec was *peek*, which itself is unbuilt
  (see §1.7) — target the existing card instead.

### 1.4 · Status-bar right-aligned process chip
- **What:** the chrome shows a right-aligned process chip (the active terminal's
  foreground process), alongside the left session chip.
- **Source:** README §Screens 1 "Titlebar".
- **State:** the Tauri app has no titlebar — the equivalent surface is the 27px
  `ui/StatusBar.tsx`, whose right slot holds only the card count. `TitleBarChip`
  was dropped as dead code in the UI-kit export
  ([`designs/2607.0001_…`](designs/2607.0001_tarmac_ui_kit_design_sync_export.md)).
- **Scope:** small — a right-slot chip in `StatusBar` fed by the prime terminal's
  `TermProc`. The card-header process name already carries this signal, so this is
  duplicate-surface polish; low priority.

### 1.5 · Doc-rewrite "your place kept" pill + changed-section highlight
- **What:** when a doc rewrites on disk, keep the reading position, tint changed
  sections (2px cyan left border + gradient fade), and show a bottom pill
  `✎ rewritten · your place kept · changes above`.
- **Source:** README §Interactions "Never move the user's scroll position".
- **State:** scroll-preserve **is** done (`cards/DocCard.tsx` saves a
  `scrollTop / scrollHeight` fraction and re-applies it after each re-render).
  The `.tm-changed` class no longer exists anywhere in `desktop/src/theme/` — it
  died with the Swift `DocTemplate.html`, so the changed-section highlight is now
  a from-scratch build, not a wiring-up. No rewrite pill.
- **Scope:** needs a diff between old/new markdown to mark changed sections — this
  is really part of the **v4c write-honesty model**. Defer to v4c rather than build
  standalone.

### 1.6 · Edge-split drop (drag card to edge → split placement)
- **What:** dragging a card to a board edge previews a dashed-cyan split zone and
  drops it into a split.
- **Source:** README §Screens 5 (note); v4 migration-plan calls it "designed but
  unbuilt".
- **State:** free move + full edge/corner resize ship; edge-split was never built
  (noted optional in both plans). No `split` code in `desktop/src/board/`.
- **Scope:** drop-zone hit-testing + preview + placement. Lowest priority — the
  infinite board's free placement largely covers the need.

### 1.7 · Peek (`⌘P`) — regressed, not merely unbuilt
- **What:** open a doc in a transient peek overlay and mark it read without
  moving focus. This **shipped in the Swift app** and was described as current in
  `architecture.md` until 2026-08-04.
- **State:** the wire type and the daemon route survive — `Msg::DocRead` /
  `conn.rs` handle it, and `ipc/daemon.ts:docRead()` exists — but **nothing in the
  app ever calls it**, and there is no peek overlay. The `fresh` (unread)
  highlight is cleared app-locally by `ESC` (`kit/clearFreshDoc.ts`), so the
  daemon's per-doc `read` flag is never set by the Tauri UI.
- **Scope:** either rebuild a peek surface and call `docRead`, or call `docRead`
  from the existing `ESC`/open path so the persisted read flag stops lying.
  The second is a few lines and worth doing regardless.

---

## 2 · Deferred by decision (out of scope, not gaps)

Tracked for completeness; these were explicit decisions, not omissions.

- **Real tmux / bare-terminal attach** (`tmux -CC`, `tarmac attach <strip>`,
  detached `$ tarmac attach` empty state) — M3 decision 1 ("no tmux"); daemon-native
  sessions only. Reconsidered only in isolation if real bare-attach is ever wanted.
  (Code: zero `tmux` references.)
- **Auto board-naming** (born `board-N`, auto-rename to the cwd repo) — M3 decision
  3; manual naming (⌘E) ships first. Unresolved cross-repo collision questions.
- **Daemon-restart PTY re-parenting** (true restart survival) — M3 decision 2;
  cold layout-only restore ships, reconnect-survival covers the common case.
- **libghostty renderer upgrade** — moot as written: the fed-surface is now
  **xterm.js with a WebGL renderer** (`kit/termRenderer.ts`), not SwiftTerm.
  A native renderer swap would be a fresh decision, not this one.

---

## 3 · Superseded by v4 (NOT backlog — recorded so they aren't re-filed)

The v4 whiteboard migration intentionally replaced these v3 surfaces; they are
done-differently, not missing:
- dock / index rails → **shelf** (itself since removed — see §4)
- grid desk + drag-swap → **infinite board**, free move + resize
- right rail (STRIPS / PROCESSES / FILE EVENTS) → **card-header signals + wayfinding**
  (minimap / zoom control / offscreen pills); no rail is built, by design
- terminal tabs + horizontal splits → **multiple terminal cards** (⌘T)
- strips = tmux sessions → **boards**

## 4 · Removed after the Tauri rebuild (gone on purpose — do not re-file)

These shipped once, are described in older docs, and were deliberately deleted.
An agent finding them referenced in `docs/archive/` is reading history:

- **The shelf** — parked/unplaced doc chips. Removed with the Tauri rebuild;
  `⌘W` on a doc card now removes the card outright rather than parking it.
  Residue: `Tile.shelf` survives on the wire as a **legacy field only** —
  `kit/layoutTiles.ts` drops incoming `shelf:true` tiles and never emits them.
- **The terminal dock pane** (dock/undock reparenting, `DockPane`, `DockContext`,
  `dockedTermId`) — removed in #74.
- **`TitleBarChip`** — dropped as dead code during the UI-kit export (#52).
