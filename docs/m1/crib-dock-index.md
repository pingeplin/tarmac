# Tarmac M1 — visual crib: dock + index

Exact values for the Swift/AppKit implementer. Sources: `design_handoff_tarmac/README.md`
(§2 Dock, §3 Index, §9 Cold start, "Interactions & Behavior"), `tarmac-proto/panels.jsx`
(`PDock`, `PIndex`), `tarmac-proto/app.jsx` (state + keyboard), `tarmac-proto/proto.css`,
`tarmac/converged.css` (`.tm-dock`, `.tm-peek`), `tarmac/theme.css` (`.tm-side`, dots, kbd),
`tarmac/coldstart.jsx` (dock birth), `tarmac/converged.jsx` (`LeftDock`, `R4Index` static
variants), `tarmac/parts.jsx` (`RepoDot`, `AgentDot`, `Toast`, `SideGroup`).

Precedence used throughout: README > interactive prototype (`tarmac-proto/`) > static screens
(`tarmac/*.jsx`). Conflicts are flagged `CONFLICT`. Where every source is silent, the minimal
no-harness-consistent behavior is proposed and flagged `DECISION:` on its own line.

All oklch→sRGB conversions are **reused verbatim from `docs/m0/visual-crib.md`** (already
pixel-verified) — never recompute.

## Colors used by these surfaces

| Token | sRGB (from M0 crib) | Used here for |
|---|---|---|
| bg0 | `#0c0e12` | dock + index background |
| bg2 | `#191d24` | active icon / active index row |
| bg3 | `#20252e` | hover |
| line | `#262c36` | active/hover icon border |
| line-soft | `#1d222b` | dock/index right hairline, sep, footer top border |
| text | `#d8dbe2` | active icon glyph / active row text |
| muted | `#8c93a0` | rest icon glyph, index rows, group headers, footers |
| faint | `#5a616d` | hints, caps row, ▾ chevron |
| agent | `#4eccd3` | cyan unread dot, recent-change dot, pulse, ▞ glyph |
| agent-dim | `#4eccd3` @ 16% (`#4eccd329`) | dockPulse halo color |
| amber | `#e1ad63` | bell dot slot (M2 — render nothing in M1) |
| repo-a/b/c/d | `#d78e88` / `#81b482` / `#89a4de` / `#be92c8` | repo identity dots |

Repo color = stable hash of repo name → a..d, assigned by `tarmacd` (README "Implementation
decisions" table: "repo-color hash, doc registry, provenance" → daemon).

---

## 1. Dock

### 1.1 Existence — cold-start rule

- **The dock does not exist until the first doc is opened.** Not an empty dock — *no* dock
  (README §2 "Dock is absent entirely until the first doc opens"; §9.3; coldstart.jsx rules
  board: "dock 在第一份文件出現前不存在 — 不是空的 dock,是沒有 dock").
- Before the first doc, the terminal spans the full main-row width (M0 layout unchanged).
- Once born, the dock never disappears: the design has **no doc-close affordance** — unpin
  returns a doc to the dock (`app.jsx` `unpin`), nothing removes one from the dock list.
- The one-time hint line under the prompt (`docs appear when anything runs tarmac open <path>
  — you or your tools`, README §9.1, coldstart.jsx `CS1`) is a terminal-area surface, not part
  of the dock; it is **not specced in this crib** and is not in the M1 dock/index scope.

DECISION: the dock list (ordered doc ids + provenance) lives in `tarmacd` memory (per README
ownership table "doc registry" → daemon), so it survives app reconnects within a daemon
lifetime; disk persistence/restore is M3. The app re-derives the dock from the daemon's
`Restore`/doc messages on connect.

### 1.2 Birth choreography

Trigger: first successful `tarmac open` ever received for this session (the dock list goes
0 → 1).

1. Desk reflows: main row becomes `dock(46px) + desk` (terminal resizes **once**, immediately).
2. Dock slides in (README §9.3: "dock is born (slides in)").
3. First-doc toast appears (standard M0 toast geometry/timing — see M0 crib "Toasts").

No source authors the slide-in animation (the coldstart frames are static; the interactive
prototype starts with a populated dock; no CSS transition exists on `.tm-dock`).

DECISION: dock birth animation = layer transform `translateX(-46px) → 0`, **220ms
`cubic-bezier(0.2, 0.8, 0.2, 1)`** (the house curve, same as peek slide, proto.css `.tm-peek`);
the desk reflow is *not* animated (terminal resizes once before the slide starts). Under
Reduce Motion the dock simply appears.

**First-doc toast wording** (coldstart.jsx `CS3` `<Toast …>`; README §9.3):

| Part | Design value | M1 value |
|---|---|---|
| icon | `✚` (agent cyan, 13px) | same |
| title | `first doc · payments-api/docs/handoff.md` = `first doc · <repo>/<repo-relative path>` | same |
| body | `opened via tarmac open, called from claude` | `opened via tarmac open` — process attribution is M2 |
| kbd chips | `⌘P peek` · `esc` | same (chips clickable per M0 toast spec) |

**Subsequent-open toast** (app.jsx `pushToast` in the `openDoc` sim event):
icon `✚`, title `tarmac open infra/runbook.md`, body `called from claude · payments-api`,
chips `⏎ peek` (click → peek that doc + dismiss this toast) · `esc` (dismiss).

DECISION: in M1 the subsequent-open toast title is `tarmac open <repo>/<repo-relative path>`
(full path, matching the first-doc toast and peek header convention — the prototype's
`infra/runbook.md` strips `docs/` as fixture cosmetics) and the **body is omitted** (its only
content was process attribution, which is M2; the title already states the observable fact).
The `⏎ peek` chip is a click target only — physical Enter belongs to the terminal (see §4).

### 1.3 Strip geometry

`converged.css .tm-dock`:

- Width **46px**, full main-row height, `flex: none`.
- Background bg0 `#0c0e12`; **border-right 1px line-soft** `#1d222b`.
- Vertical flex column, `align-items: center`, padding **10px 0**, child gap **4px**.
- Child order top→bottom (`panels.jsx PDock`, coldstart.jsx `CS3`):
  1. doc icons (one per dock-list entry, in list order)
  2. separator `.sep`: **22×1px**, bg line-soft, margin **6px 0** (plus the 4px flex gap ⇒
     ~10px visual space each side)
  3. vertical `⌘E index` hint (directly below the sep — see §1.7)
  4. footer `.foot`: `margin-top: auto` ⇒ pinned to the bottom; flex column centered, gap 8px.

The dock is a **flat ordered list** — the strip's `dock` array order (README "State
Management": "dock doc list (ordered)").

CONFLICT (static screens vs prototype): `converged.jsx LeftDock` groups dock icons by repo
with `.gap` spacers (`converged.css .tm-dock .gap`: height **8px**); the interactive prototype
(`panels.jsx PDock`, the behavioral spec) renders no gaps.

DECISION: M1 renders the flat ungrouped list (behavioral-spec prototype wins over the older v2
static screen; grouping lives in the index). `.gap` geometry recorded above in case grouping
is ever revisited.

DECISION: new docs **append to the end** of the dock list in open order. (The prototype's sim
inserts at index 2 — `app.jsx` `dock.slice(0, 2), e.doc, …` — a fixture placement, not a rule.)
Re-opening an already-listed path neither duplicates nor reorders it (`app.jsx`:
`if (iw.dock.includes(e.doc)) return prev`). There is no user reordering affordance in M1.

DECISION: if icons overflow the available height, the icon region (children 1 above) scrolls
vertically with no visible scrollbar; sep/hint/footer stay fixed. (All sources silent; the
prototype would simply overflow.)

### 1.4 Icon anatomy (30×30)

`converged.css .tm-dock .doc` + `proto.css` hover:

- **30×30px**, border-radius **7px**, content centered (flex), `position: relative`.
- Glyph: `¶`, mono **400 12px**.
- Tooltip: full `"<repo>/<repo-relative path>"` (`panels.jsx` `title={d.repo + "/" + d.name}`).
  AppKit: `toolTip` on the icon view.

| State | bg | border (1px) | glyph color | Source |
|---|---|---|---|---|
| rest | transparent | transparent | muted `#8c93a0` | `.tm-dock .doc` |
| hover | bg3 `#20252e` | line `#262c36` | muted (unchanged) | proto.css `.tm-dock .doc:hover` |
| active `.on` | bg2 `#191d24` | line `#262c36` | text `#d8dbe2` | `.tm-dock .doc.on` |

`.on` is applied when the doc is **currently peeked OR pinned** (`panels.jsx PDock`:
`activePeek === id || pinned.includes(id)`). States compose: an icon can be `.on` and pulsing
simultaneously (coldstart.jsx `CS3`: `className="doc on pulse"`).

Cursor: pointer (proto.css). No pressed/active-click style is authored — none in M1.

### 1.5 Provenance dots on the icon

All dots are absolutely positioned children of the 30×30 icon.

**Repo dot** `.rd` — top-left, `left: 4px; top: 4px`, round, background `var(--tm-repo-{a..d})`.

CONFLICT: README §2 says the repo dot is **7px**; `converged.css .tm-dock .doc .rd` authors
**6×6px**. README wins ⇒ render **7×7px** at left/top 4px. (Note the prototype renders 6px;
the 1px delta is invisible at a glance. Everywhere else — index group header, peek header —
the repo dot is the standard 7px `.tm-repodot`.)

**Cyan unread dot** `.ad` — top-right, `right: 4px; top: 4px`, **5×5px**, round, background
agent `#4eccd3`.

- Exact meaning (README §2 + no-harness table): **doc was opened via `tarmac open` (the CLI
  socket call) AND the user has not yet read it.**
- Shown when `openedByCli && !read` (`panels.jsx PDock`).
- `read` flips true the first time the doc is peeked — from any path: dock click, index row,
  toast `⏎ peek` chip, `⌘P` (`app.jsx openPeek` sets `read: true`). Pinning happens from a
  peek, so pinned docs are always read.
- A later `tarmac open` of an already-read doc does **not** re-arm the dot (`app.jsx` `openDoc`
  spreads existing state, `read` stays true) — prototype is the spec here.
- In M1 every doc arrives via `tarmac open` (terminal doc-links / user-open paths are not in
  M1), so `openedByCli` is true for all docs; the dot's lifecycle is effectively "unread".

**Amber bell dot** `.wd` — **M2 — render nothing in M1.** Geometry for the record
(`converged.css .tm-dock .doc .wd`): top-right, `right: 4px; top: 4px`, **5×5px**, round,
amber `#e1ad63` — the **same slot as the cyan dot** (collision behavior unspecified in all
sources; `PDock` never renders `.wd`; only the static `converged.jsx LeftDock` does, on a doc
without a cyan dot). Resolve when M2 lands. The index has no amber affordance in any source.

### 1.6 dockPulse — file-change halo

proto.css, verbatim:

```css
@keyframes dockPulse {
  0%   { box-shadow: 0 0 0 0   var(--tm-agent-dim); }
  60%  { box-shadow: 0 0 0 6px transparent; }
  100% { box-shadow: 0 0 0 0   transparent; }
}
.tm-dock .doc.pulse { animation: dockPulse 2.4s ease-out 3; }
```

- Trigger: FSEvents change for that doc (the daemon's `FileEvent`) — the prototype applies
  `.pulse` while `now − changedAt < 30000` (`panels.jsx` `recent`).
- One cycle = **2.4s ease-out**: a ring grows from 0 to **6px spread** while fading
  agent-dim (#4eccd3 @ 16%) → transparent over the first 60% (1.44s), then ~0.96s rest.
- **Repeat count 3** ⇒ 7.2s of visible animation, then the animation ends with no fill —
  **the icon returns exactly to its rest/`.on` appearance; no static residue remains on the
  dock icon itself.** The "~30s of being noticeable" (README "Pulse decay") is carried by the
  *other* surfaces during the 30s recency window: the index's static 7px cyan dot (§2.4) and
  the peek header `✎ Ns` meta.
- Do not confuse with `theme.css @keyframes tmPulse` (7px spread, **infinite**, scoped to
  `.tm-tab .upd` doc tabs) — different surface, not the dock.
- Reduce Motion: no pulse at all (proto.css `.tm-app.still .tm-dock .doc.pulse { animation:
  none; }`; gate on `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` per M0 crib).
  No static substitute is authored — recency still shows in the index dot.

DECISION: each new file event for a doc **restarts** the ×3 halo (and resets the 30s recency
window). The prototype fails to restart when a second change lands inside an active window
(the `.pulse` class never toggles, a React class-diff artifact, visible in the sim's t=9.2s /
t=18.4s double-write) — treat that as an artifact, not intent: the halo means "file changed
on disk", and it just did. AppKit: remove/re-add the animation (or `beginTime` reset) to
restart.

### 1.7 Vertical hint + footer

**`⌘E index` hint** — `converged.css .tm-dock .hint`:
mono **400 9px**, color faint, `writing-mode: vertical-rl` (reads top→bottom), letter-spacing
**0.1em**. Clickable: opens the index (`panels.jsx PDock` `onClick={onToggleIndex}`, cursor
pointer). Position: directly below the sep, under the icons — *not* bottom-pinned.
(README §2 says "hint at bottom"; the prototype + coldstart frames place it right after the
sep with only the `.foot` bottom-pinned. The prototype's concrete structure is followed;
README's phrasing reads as a loose summary of the hint+footer cluster, not a conflict of
values.)

**Footer** — `.tm-dock .foot`: bottom-pinned (`margin-top: auto`), flex column centered, gap
8px. Contains one glyph `.glyphbtn`: `▞`, mono **500 13px**, color agent `#4eccd3`. No click
handler anywhere in the prototype (`PDock` foot has no `onClick`) — **non-interactive in M1**;
it is the reserved strip affordance (M3).

### 1.8 What clicking an icon does

`panels.jsx PDock`: `onClick={() => onPeek(id)}` → `app.jsx openPeek(docId)`:

1. Opens (or retargets) the peek slide-over to that doc.
2. Marks the doc read ⇒ cyan unread dot clears.
3. Keyboard focus **stays in the terminal** (see §4).

Notes, all prototype-as-spec:
- Clicking the icon of the **currently peeked** doc is a no-op (peek stays open; no toggle).
- Clicking while another doc is peeked **swaps the peek content in place** — the 220ms slide
  plays only on closed→open (`proto.css` transitions `transform` on the `.open` class toggle;
  content swap doesn't re-trigger it).
- Clicking a **pinned** doc's icon also opens a peek of it (PDock's handler is unconditional;
  the doc is then visible both as tile and peek).
- The icon never moves, removes, pins, or unpins anything.

---

## 2. Index (⌘E)

### 2.1 Open/close + expansion

- `⌘E` **toggles** the index (`app.jsx`: `meta && key === "e"` → `setIndexOpen(v => !v)`,
  `preventDefault`). Also opened by clicking the dock's `⌘E index` hint; also closed by
  clicking the index's caps header row (`panels.jsx PIndex` cap `onClick={onToggleIndex}`).
- The index **replaces** the dock wholesale: the left strip goes 46px → **224px**
  (README §3; `panels.jsx` `<div className="tm-side" style={{ width: 224 }}>` — the inline
  224 overrides `theme.css .tm-side`'s base `width: 212px`, which is the older direction-B
  sidebar; **224 wins**, README and prototype agree).
- **Animation: none.** The prototype swaps `<PDock/>` ↔ `<PIndex/>` instantly (`app.jsx`
  conditional render); no width transition is authored in any stylesheet; README is silent.
  Instant swap is the spec — the terminal reflows exactly once per toggle (do not animate the
  width; that would stream resize events to the pty).
- `esc` does **not** close the index — it is absent from both the prototype's esc chain
  (`app.jsx`: switcher → peek → toasts) and README's list ("esc close peek/switcher/toasts").
- Clicking a row does **not** close the index (§2.6).
- Strip-switch also closes it (`app.jsx switchStrip`) — M3, n/a in M1.

DECISION: before the first doc exists (no dock), `⌘E` is a no-op — there is no surface to
expand and "interface grows from facts" (README §Core model 3). Both sources are silent (the
prototype always has docs).

### 2.2 Container

`theme.css .tm-side` (width overridden to 224):

- Width **224px**, `flex: none`, background bg0, **border-right 1px line-soft**.
- Flex column, padding **10px 8px**.
- Child order: caps row → repo groups → footer-hints row → strip footer (bottom-pinned).

DECISION: the group list scrolls vertically (hidden scrollbar) on overflow; caps row and the
two footer rows stay fixed. (Sources silent.)

### 2.3 Caps row + repo grouping

**Caps row** — text `OPEN DOCS · ⌘E` (`panels.jsx PIndex`; same in `converged.jsx R4Index`).
`theme.css .tm-side .cap`: mono **500 9.5px**, letter-spacing **0.12em**, color faint, padding
**4px 8px 8px**. Clickable → closes the index (cursor pointer).

**Grouping** — docs group by repo (`panels.jsx PIndex` builds `groups` by walking the dock
list): group order = order of each repo's **first appearance in the dock list**; items within
a group keep dock-list order. Group container `.tm-sgroup`: `margin-bottom: 10px`.

**Group header row** — `theme.css .tm-sgroup .hd`: flex, gap **7px**, mono **500 10.5px**,
color muted, padding **4px 8px**. Contents: standard repo dot (`parts.jsx RepoDot` →
`theme.css .tm-repodot`: **7×7px** round, `var(--tm-repo-{c})`) + repo name. Not interactive.

**Item row** — `theme.css .tm-sgroup .it`:

- Flex, gap **7px**, mono **400 11px**, color muted.
- Padding **4px 8px 4px 22px** ⇒ the **22px indent** of README §3.
- Border-radius **5px**.

| State | Style | Source |
|---|---|---|
| rest | transparent, muted text | `.tm-sgroup .it` |
| hover | bg3 | proto.css `.tm-sgroup .it:hover` |
| active `.on` | bg2, text color | `.tm-sgroup .it.on` |

`.on` here means **currently peeked only** (`panels.jsx PIndex`: `activePeek === id`) —
deliberately narrower than the dock icon's `.on` (peeked **or** pinned). Pinned docs get no
active state in the index.

**Item label** — file **basename** (`converged.jsx R4Index` items are `handoff.md`,
`plan.md`, …; `panels.jsx` `name.replace("docs/", "")` produces the same on the fixtures,
whose docs all live under `docs/`).

DECISION: if two docs in the same repo group share a basename, those rows fall back to the
repo-relative path (single line, middle-truncated). (Sources never exhibit a collision.)

### 2.4 Provenance dots in item rows

Appended after the label, in this order (both can coexist — `converged.jsx R4Index`
`runbook.md` has `agent` + `upd`):

1. **Cyan unread dot** — `parts.jsx AgentDot` → `theme.css .tm-agentdot`: **5×5px** round,
   agent `#4eccd3`. Same condition as the dock (`openedByCli && !read`), same clearing rules
   (§1.5).
2. **Recent-change dot** — **7×7px** round, agent `#4eccd3`, **static** (no animation: the
   `tmPulse` keyframe is scoped to `.tm-tab .upd` only; `panels.jsx PIndex` styles this dot
   inline, `parts.jsx SideGroup` likewise). Shown while `now − changedAt < 30000` — i.e. for
   the full **30s** recency window, outliving the dock's 7.2s halo. This is the "static state"
   the pulse decays into (README "Pulse decay").

Repo identity is carried by the group header dot; item rows have no repo dot.

No amber dot exists in any index source — bell-in-index is unspecified, and bells are M2
regardless: render nothing.

### 2.5 Footer rows

**Hints row** (directly above the strip footer; `panels.jsx PIndex` inline style): mono
**400 10px**, color faint, padding **6px 8px**. Text: **`⏎ peek · ⌘⏎ pin`** (README §3).

CONFLICT: the older static screen `converged.jsx R4Index` shows `⏎ peek · ⌘⏎ pin · ⌫ close`;
README §3 and the interactive prototype both omit `⌫ close`. README wins: `⏎ peek · ⌘⏎ pin`.

DECISION: the hints row renders verbatim, but in M1 plain `⏎` has **no global binding** — the
terminal owns Enter (focus never leaves it), and the prototype implements no index keyboard
navigation or selection cursor (only `meta+Enter` exists in `app.jsx`). Clicking a row is the
pointer realization of "⏎ peek"; `⌘⏎ pin` is the real global binding (pins the currently
peeked doc). A future index navigation mode (arrow keys + Enter) can honor the hint literally;
do not invent one in M1.

**Strip footer** — `theme.css .tm-side .foot`: bottom-pinned (`margin-top: auto`), flex, gap
**7px**, mono **500 11px**, color muted, padding **7px 8px**, **border-top 1px line-soft**.
Full design (`panels.jsx PIndex`): `▞` glyph in agent cyan (`.foot .glyph`) + strip label
(e.g. `infra-week`) + right-aligned `▾` chevron in faint (`margin-left: auto`).

DECISION: M1 has no strips (M3), so the footer renders the `▞` glyph **only** — no label, no
`▾`, not interactive (mirroring the dock footer). The row itself stays so the geometry is
stable when strips land. (README's "strip name at bottom" describes the full design; showing
a session name before sessions exist would claim a fact the app doesn't have.)

### 2.6 Index ↔ peek interaction

- Row click → `openPeek(id)`: peek opens (or swaps content in place if already open), doc
  marked read, **index stays open** (`openPeek` never touches `indexOpen`). The row gains
  `.on`; the previously peeked doc's row loses it.
- Peek and index coexist: index sits in-flow at the left; peek is an overlay anchored right
  (`converged.css .tm-peek`: absolute right 0, **width 47% of the main row**, z-index 4) — at
  sane window widths they never overlap.
- `esc` closes the peek first (slide-out is the same 220ms transition reversed); the index
  remains open. A second `esc` clears toasts. (`app.jsx` esc chain; switcher precedes peek
  but is M3.)
- `⌘E` while a peek is open toggles only the index; the peek is untouched (independent state).
- `⌘⏎` pins the peeked doc (peek closes, tile appears — desk crib's territory); the index
  stays open and the row's `.on` clears (no peek), while the *dock* icon for that doc would
  show `.on` (pinned) — remember the asymmetry in §2.3.

---

## 3. Keyboard additions (M1) + esc order

`app.jsx` `onKey` (its `metaKey || ctrlKey` is a web-demo convenience; native = ⌘ only):

| Key | Action | M1 status |
|---|---|---|
| `⌘E` | toggle index (no-op before first doc — §2.1 DECISION) | **new in M1** |
| `⌘⏎` | pin the peeked doc; if already pinned/no peek, just closes peek (`app.jsx pinPeek`) | new in M1 (pin scope) |
| `⌘P` | peek the most-recently-changed doc: `fileEvents[0].doc`, else first dock doc (`app.jsx`) | exists in M0; in M1 the no-event fallback is the dock list (append order ⇒ `dock[0]` = oldest/first-opened — prototype-literal) |
| `esc` | chain: ~~switcher (M3)~~ → close peek → clear toasts. **Never closes the index.** | unchanged from M0 (`AppController.swift` esc monitor already implements peek → toasts) |

All bindings `preventDefault`/swallow the event so nothing reaches the pty.

---

## 4. Focus rules

README §4 / Core model: **focus never leaves the terminal.** Extended to these surfaces
(per design brief): *clicking the dock or index must never move keyboard focus out of the
terminal.*

How the prototype "handles" it: trivially — every dock icon, index row, caps row, hint, and
kbd chip is a plain `<div>`/`<kbd>` (non-focusable), and all keyboard handling hangs off a
`window` keydown listener (`app.jsx`). Nothing is ever focused; clicks only fire handlers.

AppKit translation:

- Dock/index views and every subview: `acceptsFirstResponder == false`; any `NSControl`-based
  piece gets `refusesFirstResponder = true`. Handle clicks in `mouseDown`/click recognizers
  **without** calling `makeFirstResponder`.
- Never call `window.makeFirstResponder(...)` from dock/index/toast code paths; the terminal
  view stays first responder at all times (M0's invariant).
- `⌘E`/`⌘⏎` via the M0 pattern (menu items or the existing `NSEvent.addLocalMonitorForEvents`
  in `AppController.start()`), not via responder chain on the dock/index.
- Opening/closing the peek from any of these surfaces keeps the M0 focus rule (M0 crib:
  "opening a peek never moves keyboard focus out of the terminal").

---

## 5. M1 degradation of process-correlated copy

M1 has no foreground-process correlation (that is M2). Everywhere a design string carries
"during <process>" or "called from <process>", M1 renders **only the factual/time part**:

| Surface | Design copy | M1 copy |
|---|---|---|
| peek header meta (M0 surface) | `✎ 5s · during claude` | `✎ 5s` |
| first-doc toast body | `opened via tarmac open, called from claude` | `opened via tarmac open` |
| subsequent-open toast body | `called from claude · payments-api` | omitted (DECISION §1.2) |
| doc state `changed-during-process name` (README State Mgmt) | stored + rendered | not collected in M1 |

The index itself contains no "during" copy — nothing to degrade there.

---

## 6. Motion summary (these surfaces)

| Motion | Spec | Source |
|---|---|---|
| dock birth slide | 220ms `cubic-bezier(0.2, 0.8, 0.2, 1)`, translateX(−46px)→0 | DECISION §1.2 (house curve from proto.css `.tm-peek`) |
| dockPulse halo | 2.4s ease-out × **3** (7.2s total), ring 0→6px spread, agent-dim→transparent by 60% | proto.css `@keyframes dockPulse` |
| recency window | 30,000ms — drives `.pulse` class, index 7px dot, peek `✎ Ns` meta | panels.jsx `recent`; honest.jsx board "30s 後安靜" |
| index expand/collapse | **none** — instant 46↔224px swap, single terminal reflow | app.jsx conditional render; no transition authored |
| first-doc toast entry | 180ms house curve, +8px rise + fade (M0 spec) | proto.css `toastIn` |

All gated on Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`);
reduced = no pulse, no slides, things appear in place.
