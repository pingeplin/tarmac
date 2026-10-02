# Terminal grid manual QA checklist (spec 2609.0011)

The `[QA]` half of spec [2609.0011](../../.blueprint/specs/2609.0011_terminal_grid_from_content_box.md)
— the scenarios the Vitest suites cannot reach, because they need a real layout,
a real renderer and a real PTY. The pure rules are covered by
`src/kit/termGrid.test.ts` (S1–S10a, S13–S17) and the CSS declarations by
S11/S12; what follows is the behaviour those rules and declarations are supposed
to produce.

Run against `make run`. Kill any installed daemon first with `make kill-daemon`
(socket-scoped — do **not** `pkill tarmacd`, that kills the user's installed
Tarmac too).

Setup: one terminal card, filled with enough output to reach the bottom of the
card (`seq 1 200`), and a second card at a different height so each check covers
two sizes.

## Q1 — the last row survives a zoom sweep

- [ ] Step the board 100% → 150% → 200% → 250% → 300% and back down, pausing at
      each step for the raster to settle (~150ms).
- [ ] **Pass iff** the bottom row of text is complete at every step, on both
      cards. A row cut horizontally at any step is the regression this spec
      exists to remove.

## Q2 — the gutter below the last row is stable

- [ ] At each zoom step, look at the gap between the last row and the card's
      bottom border.
- [ ] **Pass iff** it looks the same at a given zoom on both cards, and grows
      proportionally with zoom (it is `16·rs` layout px = `16·zoom` screen px).
      It must not visibly jump between the two card heights — that jump (14–35px
      at 100%) is what the bottom anchor removes.

## Q3 — dragging the height never leaves a half row

- [ ] Drag one card's bottom edge slowly down through ~30px (more than one text
      row) and back up, at 100% zoom.
- [ ] **Pass iff** the bottom row is complete at every point of the drag: the
      row count steps down/up cleanly and the remainder is absorbed above.

## Q4 — zoom does not reflow the running program

- [ ] Run `vim` (or `htop`) in a card, note the column count (`:set columns?` in
      vim).
- [ ] Zoom 100% → 300% → 100%.
- [ ] **Pass iff** on a Retina (dpr 2) display the column count is unchanged
      throughout. On a 1× external display a **shrink** is expected and allowed
      (the oversampled cell genuinely stops fitting — see the spec's Trade-offs);
      it must come back on the way down. A column count that *grows* above the
      starting value, or a clipped row, is a fail.

## Q5 — selection still lands on the right cells

- [ ] At 150% and 250%, drag-select a word in the middle of the card, then near
      the last row.
- [ ] **Pass iff** the highlighted cells are the ones under the cursor. The
      `getBoundingClientRect` override that makes this work divides by
      `zoom / rasterScale`; the grid change must not disturb it.

## Q6 — the IME candidate window still tracks the cursor

- [ ] With a CJK IME active, type a few characters into a card at 100% and again
      at 200%.
- [ ] **Pass iff** the candidate window appears at the cursor, not at the card's
      top-left corner. (`.xterm-helpers` is positioned against `.xterm`, whose
      height this change alters.)

## Q7 — scrollback and the scrollbar

- [ ] Scroll the card's scrollback with the wheel and by dragging the scrollbar.
- [ ] **Pass iff** it scrolls, the bar is draggable and tracks position, and no
      horizontal bar appears. `.xterm` no longer fills the host, so the bar now
      spans the painted grid — starting below the top remainder and ending at the
      last row. A bar that overhangs the grid at either end, or one that cannot
      be grabbed, is a fail (fall back to the custom-property variant in the
      spec's Alternatives).

## Q8 — a hidden board must not resize the PTY

- [ ] With a program running in a card, switch to another board (⌘1/⌘2 or the
      board switcher), wait a beat, and switch back.
- [ ] **Pass iff** the program is unchanged and its cols×rows are the same as
      before the switch. A backgrounded board is `display:none`, so the card
      measures a 0×0 box; the grid must be left alone rather than proposed as
      2×1 (the S10 path).

## Results

Run by **EP Lin, 2026-09-08**, against `make run` on the `fix/130-term-grid-clip`
worktree (dev app), after the top-padding tuning (`b8e0ae7`). **All eight pass.**

Q1/Q2/Q3/Q5 were observed in ordinary use — they are the ones a broken build shows
you without being asked (a clipped row, a jumping gutter, a half row mid-drag, a
selection landing on the wrong cell). Q4/Q6/Q7/Q8 were then run deliberately, because
none of them is visible by just looking at a card.

The `Pre-check` column is what the offline harness in `.dev/term-clip-2609/` showed
for the shipped code — context, not evidence about the app.

| Scenario | Pre-check (harness) | Result | Notes |
|---|---|---|---|
| Q1 last row survives a zoom sweep | 0 clipping, 73 card heights × zoom 1/1.5/2/3 | **PASS** | The symptom under investigation; gone |
| Q2 gutter stable below the last row | gutter exactly 16 × zoom, 0.0px variance | **PASS** | The *top* gap was flagged here and fixed separately (`b8e0ae7`) — it was the declared padding, not the anchor |
| Q3 dragging the height leaves no half row | — (needs a real drag) | **PASS** | Observed while resizing cards in normal use |
| Q4 zoom does not reflow the running program | replay of mount → rs 1.5→2→2.5→3→2→1 with both observers: grid unchanged, 14/14, both dprs (`harness/clamp-run.mjs`) | **PASS** | Checked with the SIGWINCH trap below — the PTY is not resized by a board gesture |
| Q5 selection lands on the right cells at zoom ≠ 1 | — (needs a real pointer) | **PASS** | The `getBoundingClientRect` override still holds under the new `.xterm` height |
| Q6 IME candidate window tracks the cursor | — (needs a real IME) | **PASS** | CJK typed into a dev-app card; `.xterm-helpers` still anchors to the cursor |
| Q7 scrollback and the scrollbar | — (needs real scrolling) | **PASS** | The likeliest quiet breakage — `.xterm` no longer fills the host — and it holds |
| Q8 hidden board must not resize the PTY | the *rule* rejects a 0×0 box (`termGrid.test.ts` S10) | **PASS** | Board switch away and back with a program running: no resize |

### How Q4 and Q8 were checked (and how to re-check them)

Neither is visible on screen: both are about whether the PTY was resized, i.e. a
SIGWINCH. This one-liner prints a line only when that actually happens:

```sh
trap 'echo "$(date +%T) SIGWINCH → $(stty size)"' WINCH; echo "start → $(stty size)"; while sleep 1; do :; done
```

- **Q4:** zoom 100% → 300% → 100%. Pass = no `SIGWINCH` lines. (On a 1× external
  display a shrink and its matching restore are allowed — see the spec's Trade-offs —
  but a *grow* above the starting size is a fail.)
- **Q8:** switch to another board, wait, switch back. Pass = still no lines, and
  `stty size` unchanged.

Worth re-running after any change to `kit/termGrid.ts`, the `.term-host` rules, or the
rasterScale path — those are the three places that can put a board gesture back on the
PTY without any visible sign.
