# Backlog — unbuilt design features (post-M3)

As of 2026-06-15, M0–M3 + the v4 whiteboard migration are complete on `main`. The
core experience (terminal-first cockpit, `tarmac open` docs, peek, honest signals,
infinite board with gravity/shelf/provenance, wayfinding, terminal primacy,
multiple boards with ⌘K) is shipped.

This file tracks what the **original v3 design handoff**
(`design_handoff_tarmac/README.md`) specified that is **not yet built** —
separated from the parts the v4 migration deliberately replaced. Verified against
the code on 2026-06-15 (file references are where the feature *would* live / where
its absence was confirmed).

Two larger pending milestones live in `docs/archive/v4/migration-plan.md` §Deferred, not
duplicated here:
- **Editable docs / conflict banner (v4c)** — the next milestone; needs a design
  round first (no implementation spec exists).
- **Zone labels** (user-typed board text) — nice-to-have after wayfinding.

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
- **Source:** README §Screens 8 "Session restore".
- **State:** the app restores layout/viewport **silently** — no restore overlay
  exists (grep: no `restore card` / "any key to continue" in `app/Sources/`).
- **Scope:** a board-arrive overlay view + the restore-facts model. The detached
  empty-state depends on tmux/attach (see §2), so ship the attached-only card first.

### 1.3 · Doc-path linkification in terminal output
- **What:** any path in terminal output matching the open-doc set is linkified
  (cyan, dashed underline; hover = solid + tint; ⌘click → peek). Pure regex,
  iTerm-style semantic links.
- **Source:** README §Screens 1 "Doc links in output".
- **State:** only SwiftTerm's built-in URL/OSC-8 click is wired
  (`TermDelegateBridge.requestOpenLink` → opens in browser); there is **no**
  match-against-open-docs path linkifier.
- **Scope:** a SwiftTerm output scanner (or post-feed pass) that matches known doc
  paths and routes ⌘click to `openPeek(path)`. Interacts with the terminal surface
  abstraction — check whether SwiftTerm exposes the hooks or it needs a daemon-side
  annotation.

### 1.4 · Titlebar right-aligned process chip
- **What:** the runway titlebar shows a right-aligned process chip (the active
  terminal's foreground process), alongside the left session chip.
- **Source:** README §Screens 1 "Titlebar".
- **State:** only the **left** session chip exists (`TitleBarChip.swift`); no
  right-side process chip.
- **Scope:** small — a second titlebar accessory (trailing) fed by the prime
  terminal's `term_proc`. The card-header process name already carries this signal,
  so this is duplicate-surface polish; low priority.

### 1.5 · Doc-rewrite "your place kept" pill + changed-section highlight
- **What:** when a doc rewrites on disk, keep the reading position, tint changed
  sections (2px cyan left border + gradient fade), and show a bottom pill
  `✎ rewritten · your place kept · changes above`.
- **Source:** README §Interactions "Never move the user's scroll position".
- **State:** scroll-preserve **is** done (`window.tarmacRender` in
  `DocTemplate.html`); the `.tm-changed` CSS class is defined but **not applied**;
  no rewrite pill.
- **Scope:** needs a diff between old/new markdown to mark changed sections — this
  is really part of the **v4c write-honesty model**. Defer to v4c rather than build
  standalone.

### 1.6 · Edge-split drop (drag card to edge → split placement)
- **What:** dragging a card to a board edge previews a dashed-cyan split zone and
  drops it into a split.
- **Source:** README §Screens 5 (note); v4 migration-plan calls it "designed but
  unbuilt".
- **State:** free move + corner resize ship; edge-split was never built (noted
  optional in both plans).
- **Scope:** drop-zone hit-testing + preview + placement. Lowest priority — the
  infinite board's free placement largely covers the need.

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
- **libghostty renderer upgrade** — SwiftTerm ships as the fed-surface; libghostty's
  C API is public-alpha (~late-2026 stable). Swap is behind the `TerminalSurface`
  seam when/if VT fidelity proves limiting.

---

## 3 · Superseded by v4 (NOT backlog — recorded so they aren't re-filed)

The v4 whiteboard migration intentionally replaced these v3 surfaces; they are
done-differently, not missing:
- dock / index rails → **shelf**
- grid desk + drag-swap → **infinite board**, free move + resize
- right rail (STRIPS / PROCESSES / FILE EVENTS) → **card-header signals + wayfinding**
  (minimap / zoom control / offscreen pills); no rail is built, by design
- terminal tabs + horizontal splits → **multiple terminal cards** (⌘T)
- strips = tmux sessions → **boards**
