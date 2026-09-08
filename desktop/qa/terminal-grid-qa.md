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

Fill in `Result` by running the steps above against `make run`. The `Pre-check`
column is what the offline harness in `.dev/term-clip-2609/` already showed for
the shipped code — useful context, **not** a substitute: the harness reproduces
the card's DOM and rules, not the app.

| Scenario | Pre-check (harness) | Result | Notes |
|---|---|---|---|
| Q1 | 0 clipping in 73 card heights × zoom 1/1.5/2/3 | | |
| Q2 | gutter exactly 16 × zoom, 0.0px variance across all heights | | |
| Q3 | — (needs a real drag) | | |
| Q4 | replay of mount → rs 1.5→2→2.5→3→2→1, running the layout effect AND the ResizeObserver at each step against the shipped kit rules: grid unchanged, 14/14 cases, both dprs (`harness/clamp-run.mjs`). Not a substitute for the app: the replay drives the rules directly, not React's own effect ordering | | |
| Q5 | — (needs a real pointer) | | |
| Q6 | — (needs a real IME) | | |
| Q7 | — (needs real scrolling) | | |
| Q8 | the *rule* rejects a 0×0 box (`termGrid.test.ts` S10). The RO's own 0×0 early-return and the rest grid surviving a hide/show round trip are **not** covered — this one needs the app | | |
