# Backlog — unbuilt design features (post-M3)

> **Doc status: ACTIVE — but everything below is UNBUILT.** This is the audited
> list of things Tarmac does *not* do. Nothing in §1 exists in the code; §2 is
> explicitly out of scope; §3 and §4 record surfaces that were replaced or
> removed so they don't get re-filed as bugs; §5 lists known shortfalls of the
> app as built. For what Tarmac *does*, see
> [`architecture.md`](architecture.md). Docs index: [`README.md`](README.md).

M0–M3 + the v4 whiteboard migration closed on 2026-06-15. The core experience
(terminal-first cockpit, `tarmac open` docs, honest signals, infinite board with
gravity/provenance, wayfinding, terminal primacy, multiple boards with ⌘K) is
shipped.

This file tracks what the **original v3 design handoff** (the v3 README — now in
git history; the `design_handoff_tarmac/` bundle was removed once its content was
absorbed into `docs/`) specified that is **not yet built** — separated from the
parts the v4 migration deliberately replaced. "README §…" below cites a section
of that v3 handoff README.

**Re-verified against the native app on 2026-10-02.** Every "State:" line below
was re-checked against `app/` and `core/`. Each gap is still a gap.

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
  (The class is named only in the archived cribs — nothing in the app draws it.)

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
- **State:** the CLI's daemon verbs are `open` and `--version`
  (`core/crates/tarmac-cli/src/main.rs`); there is no `Focus` variant in `Msg`
  (`core/crates/tarmac-protocol/src/lib.rs` — the `focus` there is the QA
  driver's `DevRequest`, an unrelated verb); no idle timer or banner in the app.
- **Scope:** protocol `Focus{path}` in both codecs + daemon route + app
  idle-timer + banner UI + `⌫` go-back. Note the no-harness rule: focus is
  *requested* by any caller, never agent-arbitrated.

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
- **State:** the app restores layout/viewport **silently** — `applyRestore` in
  `app/Sources/TarmacApp/AppController+Layout.swift` builds the board and shows
  no overlay.
- **Scope:** a board-arrive overlay view + the restore-facts model. The detached
  empty-state depends on tmux/attach (see §2), so ship the attached-only card first.

### 1.3 · Doc-path linkification in terminal output
- **What:** any path in terminal output matching the open-doc set is linkified
  (cyan, dashed underline; hover = solid + tint; ⌘click → peek). Pure regex,
  iTerm-style semantic links.
- **Source:** README §Screens 1 "Doc links in output".
- **State:** a terminal card links OSC 8 hyperlinks and spelled-out `http(s)`
  URLs only (`app/Sources/TarmacTerm/TerminalLinks.swift`), and the host opens
  only `http(s)` targets in the OS browser; there is **no**
  match-against-open-docs path linkifier.
- **Scope:** a second matcher beside `TerminalLinks` for known doc paths, fed
  the board's `DocStore`, with the host's `onOpenLink` routing a hit to the doc
  card. Note the ⌘click destination in the v3 spec was *peek*, which was
  deliberately dropped (§4) — target the existing card instead.

### 1.4 · Status-bar right-aligned process chip
- **What:** the chrome shows a right-aligned process chip (the active terminal's
  foreground process), alongside the left session chip.
- **Source:** README §Screens 1 "Titlebar".
- **State:** the equivalent surface is the 27-point status bar
  (`app/Sources/TarmacApp/StatusBar.swift`), whose right slot holds only the
  card count.
- **Scope:** small — a right-slot chip in `StatusBar` fed by the prime terminal's
  `TermProc`. The card-header label already carries this signal, so this is
  duplicate-surface polish; low priority.

### 1.5 · Doc-rewrite "your place kept" pill + changed-section highlight
- **What:** when a doc rewrites on disk, keep the reading position, tint changed
  sections (2px cyan left border + gradient fade), and show a bottom pill
  `✎ rewritten · your place kept · changes above`.
- **Source:** README §Interactions "Never move the user's scroll position".
- **State:** scroll-preserve **is** done (the doc page keeps a
  `scrollTop / scrollHeight` fraction and re-applies it after each re-render).
  There is no changed-section highlight and no rewrite pill.
- **Scope:** needs a diff between old/new markdown to mark changed sections — this
  is really part of the **v4c write-honesty model**. Defer to v4c rather than build
  standalone.

### 1.6 · Edge-split drop (drag card to edge → split placement)
- **What:** dragging a card to a board edge previews a dashed-cyan split zone and
  drops it into a split.
- **Source:** README §Screens 5 (note); v4 migration-plan calls it "designed but
  unbuilt".
- **State:** free move + full edge/corner resize ship; edge-split was never built
  (noted optional in both plans). Nothing in `app/Sources/TarmacApp/` places a
  card by a split.
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
- **The full libghostty surface** (GhosttyKit: Ghostty's Metal renderer and its
  input handling) — terminal cards take libghostty-vt for emulation only and
  draw with CoreText, because the board has to scale, clip and composite a
  terminal card like any other view and decide key routing itself
  ([`designs/2610.0001_native_swift_ui.md`](designs/2610.0001_native_swift_ui.md)).

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

## 4 · Removed on purpose (gone — do not re-file)

These shipped once, are described in older docs, and were deliberately deleted.
An agent finding them referenced in `docs/archive/` is reading history:

- **The shelf** — parked/unplaced doc chips. `⌘W` on a doc card now removes the
  card outright rather than parking it. Residue: `Tile.shelf` survives on the
  wire as a **legacy field only** — `LayoutTiles`
  (`app/Sources/TarmacKit/LayoutTiles.swift`) drops incoming `shelf:true` tiles
  and never emits the key.
- **The terminal dock pane** (dock/undock reparenting) — removed in #74.
- **`TitleBarChip`** — dropped (#52); the window title carries the board name.
- **Peek (`⌘P`)** — the transient read-without-focus overlay. Doc cards on an
  infinite board already give you the content without moving focus, so the
  overlay was a second surface for the same job. Residue: `Msg::DocRead` and its
  daemon route survive on the wire with **no caller** in the app
  (`DaemonClient.docRead` is never called), so the daemon's per-doc `read` flag
  is never set. Either wire `docRead` into the existing open/`ESC` path or
  retire the flag — but do not re-file peek itself as a missing feature.
- **The design-sync UI-kit export** (`make kit`, and the `.design-sync/` previews
  it fed) — it bundled the web frontend's components and went with them.
- **The `⌥Tab` terminal cycle and its HUD** — removed 2026-10-03: unused, and
  what it did with a terminal that was off screen depended on whether that
  card had been shown since launch. `⌥Tab` now reaches the terminal like any
  other key. Prime still moves by a press on a terminal card.

## 5 · Open after the native rebuild

Known shortfalls of the native app, each with the file a fix would start in.
Verified against the code on 2026-10-02.

- **OSC 52 clipboard writes are ignored.** `TerminalView.onClipboardWrite` is
  left unset on purpose — a program may not overwrite the user's clipboard — so
  there is no opt-in either. `app/Sources/TarmacApp/AppController+Terminals.swift`.
- **Grapheme clustering (mode 2027) is not enabled by the app.** A program gets
  it only by setting the mode itself. `app/Sources/TarmacTerm/TerminalEngine.swift`.
- **Scrollback is fixed at 5000 lines**, the `scrollbackLines` default; there is
  no setting. `app/Sources/TarmacTerm/TerminalView.swift`.
- **`tarmac dev key` loses ⌃C, ⌃F and ⌃R once the app has shown a second
  window.** The system's tiling items in the Window menu then claim those
  chords from the driver's constructed events; a real keyboard is not
  affected. Found with the Settings window (spec 2610.0005); the same
  happens on a build without it once the Window menu is read through
  Accessibility. `app/Sources/TarmacApp/Dev/DevInput.swift`.
- **The Interface font has no size setting.** The Settings window sets a size
  for Terminal and for Document; the chrome is set at many fixed sizes (8 to
  13 pt), so one size does not fit it and a scale factor is not built. A role
  takes a family's regular face, so one weight of a family cannot be chosen
  over another. `app/Sources/TarmacApp/SettingsWindowController.swift`.
- **The size field of the Settings window reads `.` as the decimal mark** in
  every locale, and Escape does not cancel a typed text: it is applied, or
  dropped, when the field's editing ends.
  `app/Sources/TarmacKit/FontSizeRule.swift`.
- **Prompt and Powerline icons need a Nerd Font chosen in Settings.** The app
  ships no font, and no system font has those glyphs.
- **The Settings window's font list is read when the window opens**, about
  190 ms on the main thread, and no test covers that it is read again: a font
  installed while the window is open shows the next time it opens.
  `app/Sources/TarmacApp/InstalledFonts.swift`.
- **Synthesised italic slants more than a real italic would.** Where no italic
  of the terminal face is installed, the slant also shears fallback characters
  (CJK, emoji), Braille and geometric shapes, and Latin ink overhangs its cell
  by up to 2.5 pt. Only box drawing, blocks and the Powerline separators are
  kept upright. `variant` and `joinsItsNeighbours` in
  `app/Sources/TarmacTerm/TerminalFonts.swift`.
- **A focused terminal that gets culled loses the keys.** AppKit hands the
  keyboard to the window, the board swallows the keys, and typing is dropped
  until a click. `app/Sources/TarmacApp/AppController+Keys.swift`.
- **Reconnect loses terminal modes older than the ring.** A surviving terminal's
  history is replaced — reset, then replay — from the daemon's 256 KiB
  scrollback ring, so a mode a program set before the ring's first byte is gone.
  `showOutput` in `app/Sources/TarmacApp/AppController+Terminals.swift`.
- **A terminal that dies inside the scrollback wait keeps a blank dead card.**
  The output held for it is dropped when the daemon answers with an empty ring.
  `app/Sources/TarmacKit/ScrollbackGate.swift`.
- **A zoom step costs more with every visible card.** Chrome is laid out at
  zoomed metrics, so each step re-lays out the header of every card on screen.
  `project` in `app/Sources/TarmacApp/CardView.swift`.
- **A press on a terminal card's header gives that terminal the keyboard.**
  Prime and focus move together; a header press cannot make a terminal prime
  without focusing it. `select` in `app/Sources/TarmacApp/AppController+Focus.swift`.
- **A markdown doc can tell a server about a local image it names.** With no
  frame and no script, its own markup — a lazy remote image below a local one,
  or container queries around it — reveals whether the image exists and how
  wide it is; never its content.
  `app/Sources/TarmacApp/Resources/DocTemplate.html`.
- **The img host resolves a path, then opens it.** A local process that swaps
  the path in between is served the swapped file under an image type; a hard
  link named like an image is served too, and so is an image named with a
  trailing slash. `resolved` and `openRegular` in
  `app/Sources/TarmacKit/FileBytes.swift`.
- **The 64 MiB cap is per file.** A doc that names one large image by many
  addresses has each read and held whole at once — about 0.5 GB for eight, for
  the seconds WebKit keeps a served answer. Reading them one at a time does not
  help: the answers are WebKit's by then. `reads` in
  `app/Sources/TarmacApp/CardSchemeHandler.swift`.
- **A console entry of many small args is costly.** The host page bounds an
  entry's characters, not its arg count. `cutArgs` in
  `app/Sources/TarmacApp/Resources/Web/card-host.js`.
- **Closing the console while its text holds the keys drops typing until a
  click.** Same path as the culled terminal above. `toggleConsole` in
  `app/Sources/TarmacApp/HTMLCardView.swift`.
- **The link-hover report goes stale when a card moves under a resting
  pointer**, until the pointer next moves.
  `app/Sources/TarmacApp/Resources/Web/doc-render.js`.
- **No in-repo test drives `CardSchemeHandler` or compiles `DocFrameRule` with
  WebKit**; the address-reuse rule and the content rule were checked only with
  an off-screen harness.
- **Nothing checks `NOTICE` against what the bundle ships.** Its lists — what
  Ghostty builds into libghostty-vt, the Rust crates linked into the two
  binaries (`cargo tree -e normal,no-proc-macro`) — were written by hand on
  2026-10-02, so a new dependency or a Ghostty bump needs them updated by
  hand. Two things it does not cover: the
  copy of `tarmac` at the root of the `.dmg` has its notices only inside
  `Tarmac.app`, and an x86_64 build would link simdutf's CPU detection, which
  carries a BSD notice of its own. `NOTICE`, `THIRD-PARTY-LICENSES`.
- **libghostty-vt is a download that only Ghostty keeps.** The build fetches one
  pinned commit's prebuilt archive, its retention is undocumented, and the build
  checks its hash but not Ghostty's signature, which the repo keeps for a check
  by hand. Kept as is by decision on 2026-10-02; the ways out — mirror the zip,
  build it from source, or pin a tag once a Ghostty release publishes the
  library — are in
  [`architecture.md`](architecture.md#the-libghostty-vt-dependency).
  `scripts/fetch-ghostty-vt.sh`.
