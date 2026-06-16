# Tarmac v4c (editable docs) — visual crib

Exact values + mock structure for the **v4c editable-docs** milestone (doc cards
become editors; focus is borrowed; write conflicts are reported, never
arbitrated). This is the next milestone after M3 — see
[`docs/archive/v4/migration-plan.md`](../archive/v4/migration-plan.md) §Deferred
for the driving loop (design round → implement in three layers → near-zero daemon
work) and the load-bearing invariants; this crib carries the **exact geometry,
copy, and mock layouts** that the prose plan does not.

Provenance: transcribed from the original v4c design handoff —
`design_handoff_tarmac/tarmac/board-v4c.jsx` (rules board + E1/E2 mocks),
`board.css` §v4c (`.edit` / `.tm-caret` / `.tm-homechip` / `.tm-conflict`), and
the design rationale in `chats/chat2.md` — before that bundle was removed from
the working tree (originals remain in git history). The mocks were authored in
zh-TW; UI copy is transcribed verbatim with an English gloss. The shipped app's
strings are English (cf. the M2 exit toast / idle banner in
[`backlog.md`](../backlog.md)).

> ⚠️ The v4c mocks are **2 screens + a rules board** and `chat2.md` ends with
> open questions the mocks don't answer (see §5). The migration plan calls for a
> fresh design round before implementing; treat this crib as the captured
> starting point, not a settled spec.

Tokens referenced below are the **Breeze** set (see
[`archive/v4/visual-crib.md`](../archive/v4/visual-crib.md) §1 for the full table).
Key ones here: `--tm-agent` `#1abc9c`, `--tm-agent-dim` `rgba(26,188,156,0.16)`,
`--tm-amber` `#fdbc4b`, `--tm-amber-dim` `rgba(253,188,75,0.16)`,
`--tm-text` `#eff0f1`, `--tm-faint` `#7f8c8d`, `--tm-line` `#474e55`,
`--tm-line-soft` `#3d434a`. Mono = IBM Plex Mono.

## 1 · The rule upgrade (why editing is allowed)

v3's invariant was **"docs never take focus."** That blocks editing, so v4c
replaces it with a stronger one:

> **focus's home is the terminal** — editing is an explicit *borrow*.

The four borrowed-focus rules (from the `V4cIntro` rules board):

- **Entering edit is a deliberate act:** `⏎` or click into the text → the card
  lights up (`edit` state) and a caret appears.
- **`esc` always goes home** — one key back to the focused terminal (vim
  normal-mode feel; the user never has to think "where is focus right now").
- **`⌥tab` is unchanged** — it cycles *terminals only*; a doc being edited never
  enters the cycle.
- **Gravity is unchanged** — editing does not change ownership; a satellite doc
  stays a satellite of the terminal that opened it.

## 2 · The honest model gains one row: **write**

Tarmac used to only *read* the disk. Now the user's save is itself a file event
— but this adds **no new signal kind** (it's the existing fswatch mtime stream).

- **Signals still never guess.** Card/peek meta distinguishes
  `✎ you · editing` from `✎ 5s · during claude` — both are facts (local
  unsaved-edit state vs. an observed mtime correlation), never causation.
- **New conflict case:** the user is mid-edit and claude rewrites the same file
  on disk. **Tarmac does not arbitrate** — it reports the `mtime` fact in an
  amber banner and offers three exits (`diff` / `reload` / `keep`); the user
  decides whether claude's version comes in.
- **Editing while the agent still runs:** the card header keeps the `⠧` spinner,
  so the user knows the file may be rewritten again at any moment.

## 3 · Exact chrome (`board.css` §v4c)

### Edit-state card — `.tm-bcard.edit`
- `border-color: var(--tm-agent)` (`#1abc9c`)
- `box-shadow: 0 0 0 2px var(--tm-agent-dim), 0 16px 38px rgba(0,0,0,0.5)`
  — note the ring is **2px** (vs. `.fresh`'s 3px ring), so an actively-edited
  card reads as distinct from a freshly-landed one.
- `.tm-bcard.edit .bhd { color: var(--tm-text); }` — header brightens to primary.

### Text caret — `.tm-caret`
- `display: inline-block; width: 1.5px; height: 14px; vertical-align: -2px;`
- `background: var(--tm-text); margin-left: 1px;`
- `animation: tmBlink 1s steps(1) infinite alternate;` (the existing `tmBlink`
  keyframe; gate on `prefers-reduced-motion`).

### Home chip — `.tm-homechip` (the `⌂ esc` affordance on the focused terminal card)
- `display: inline-flex; align-items: center; gap: 5px;`
- `font: 400 9.5px var(--tm-mono); color: var(--tm-faint);`
- `border: 1px dashed var(--tm-line); border-radius: 5px; padding: 1px 6px;`
- `white-space: nowrap;`
- Copy in E1: `⌂ esc 回這裡` ("⌂ esc back here"); E2 shortens it to `⌂ esc`.

### Conflict banner — `.tm-conflict` (sits at the top of the doc card body, `flex: none`)
- `display: flex; align-items: center; gap: 8px;`
- `padding: 7px 12px; background: var(--tm-amber-dim);`
- `border-bottom: 1px solid var(--tm-line-soft);`
- `font: 400 10px var(--tm-mono); color: var(--tm-text);`
- `.tm-conflict .ic { color: var(--tm-amber); }` — the `◉` icon.
- `.tm-conflict .keys { margin-left: auto; display: flex; gap: 5px; }` — the
  right-aligned exit keys.

## 4 · The two mock screens

### E1 · Borrowed focus (`E1Edit`, label "v4 · Editing a doc card")
- Prime terminal card (`claude · payments-api` + blinking `⠧` agent glyph),
  header right = `<span class="tm-homechip">⌂ esc 回這裡</span>`.
- Doc card in `edit` state (`handoff.md — editing`), header right =
  `<span class="owner">← claude</span>` (owner chip: this doc is a satellite of
  the claude terminal).
- A quiet third doc card (`infra/docs/runbook.md`) for context.
- Board pill: `⏎ / 點進文字 = 借走 focus · esc 永遠回 terminal · ⌥tab 照樣只巡 terminal`
  ("⏎ / click into text = borrow focus · esc always returns to terminal ·
  ⌥tab still only cycles terminals").
- Status bar right: `editing: handoff.md · esc → claude`.

### E2 · Write conflict (`E2Conflict`, label "v4 · Edit conflict (honest)")
- Same prime terminal card, header right `⌂ esc`; terminal log shows claude
  `wrote docs/handoff.md` then `working …`.
- Doc card in `edit` state with a `.tm-conflict` banner at the top:
  `◉ 磁碟上的檔變了 · ✎ 14:06 · during claude — 你的編輯尚未存`
  ("◉ the file on disk changed · ✎ 14:06 · during claude — your edit isn't saved
  yet"), keys: `d diff` / `r 重載` (reload) / `照舊` (keep / leave as-is).
- Board pill: `Tarmac 不仲裁 — 只報告 mtime(事實)+ 給 diff;要不要讓 claude 的版本進來,你決定`
  ("Tarmac does not arbitrate — it only reports mtime (a fact) + offers a diff;
  whether claude's version comes in is your call").
- Status bar right (amber): `conflict: handoff.md changed on disk`.

### Doc body in edit mode (`EditDocBody`)
- Meta row: repo dot + path + `<span class="ag">✎ you · editing</span>`; when
  there's no conflict it also shows `· saved 12s ago` (faint).
- Rendered markdown body (h1/h2/p/ul) with a `.tm-caret` placed inline at the
  edit point — i.e. the mock shows a **rendered** surface with a caret, not a
  raw-source editor (this is one of the open questions, see §5).

## 5 · Open questions (unresolved in the mocks — `chat2.md`)

The mocks deliberately stop short of these; resolve them in the design round
before implementing:

1. **Diff-view shape** — when the user picks `d diff` on a conflict, is the diff
   an in-card split, or does it land as a **new diff card** on the board?
   (`chat2.md` flags this explicitly as the "next step".)
2. **Edit mode** — rendered/WYSIWYG vs. raw source. `EditDocBody` hints a
   *rendered* surface with an inline caret, but it's undecided.
3. **Save semantics** — autosave vs. explicit `⌘S`. The conflict banner assumes
   an "unsaved changes" state exists, which implies non-autosave (or a debounce).
4. **Editability scope** — are peek and shelf docs editable, or only docs placed
   as cards on the board?

## 6 · Implementation shape (from migration-plan §Deferred step 4)

Three layers, cheapest first:

- **(a) Edit-state chrome + borrowed-focus mechanics** — cheap: the card ring,
  the caret, the `⌂ esc` home chip, and `esc`-home focus routing. Mostly the
  values in §3 plus key handling.
- **(b) The editor surface itself** — the real tech decision. `DocWebView` is a
  read-only `WKWebView`, so "editable" means either `contenteditable`/CodeMirror
  inside the webview, or a native text view. Tied to open questions 1–2.
- **(c) Conflict banner + diff exit** — the `.tm-conflict` banner (§3) plus the
  chosen diff-view shape (open question 1).

**Daemon: near-zero.** No new signal kinds — a conflict is the intersection of
the existing fswatch mtime watch and app-local unsaved-edit state. The one open
daemon-adjacent item: attributing a file event to *the user's own just-saved
write* so meta can say `✎ you` rather than a generic change — app-side
bookkeeping, decide it here when the milestone starts.
