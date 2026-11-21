# Markdown card reading column — manual QA (spec 2611.0021, #443)

S15–S24, S27–S32 and S37 of `.blueprint/specs/2611.0021_doc_reading_column.md`.
They are [QA] scenarios because each is a property of the laid-out page in
WKWebView: where the column and the wide blocks sit, what scrolls, and what a
line looks like on screen. The unit suites pin the declarations and the table
markup (`DocTemplateTests`, `DocLayoutScriptTests`, `ThemeCSSTests`); none of
them lays out a page.

**CAUTION: do NOT `pkill tarmacd`.** Run against `make run` only; it pins the
sockets, state and config to the worktree's `.dev/`.

## Runs

- **Run 1** at `b60aad3`: S15–S24, S27–S32. macOS 26, main display at scale 1,
  so 1 screenshot pixel is 1 point. The dev window was resized by pid with
  Accessibility to 1600 × 1366 so a 1280 card fits at zoom 1.
- **Run 2** at `31dfed9` (app source equal to the PR head): after `a8be9cb`
  (the `hr` rule) and `93eff9d` (`--gutter` in the padding and the breakout
  cap), S37 and the box edges of S15, S16, S19, S27 and S28 again.
- An independent check decoded four Run 1 screenshots (S15, S19, S28, S24) and
  measured the same numbers.

All x positions are from the card body's left edge (1 px right of the card's
`screen_rect.x`, past its border), at zoom 1. Theme: standard dark unless
named. The test doc holds P (a 400+ character paragraph), H (a heading), R (a
thematic break), L (a list), T2 (2 columns, short cells), T7 (7 columns, one
prose column), TC (one prose column among 30-character code cells), T12 (12
columns of 20-character code), TA (`:--- | :---: | ---:`), TH (header only),
TR (a raw HTML table with a `colspan`), C1 (a 200-character code line), C2 (a
short code block) and N (T12 in a list item, C1 in a blockquote).

## Results

| Scenario | Result | Measured | Expected |
|---|---|---|---|
| S15 centred column, 1280 | pass | C2 318–962; P and H start at 318; the longest P line ends at 954 | 318–962 |
| S16 standard card, 392 | pass | C2, T2 and T12 22–370; a sideways wheel scrolls only inside T12 | 22–370 |
| S27 mid card, 900 | pass | C2 128–772; T12 and C1 22–878 | 128–772; 22–878 |
| S17 small blocks | pass | T2 318–962; no scroll bar on T2 or C2 | 318–962 |
| S18 wide table | pass | T7 178–1102 (924 wide), centre 640 | > 644, ≤ 1040, centre 640 |
| S29 text column | pass | the header after `Notes` starts exactly 220 to its right; TC scrolls in its box | ≥ 220 |
| S19 too-wide table | pass | T12 120–1160 with a scroll bar before any scroll; a sideways wheel moves only pixels inside the box (border fixed, doc offset fixed); a vertical wheel scrolls the doc (660 → 760); no page scroll bar | 120–1160 |
| S20 long code line | pass | C1 120–1160, one line; a sideways wheel scrolls inside it | 120–1160 |
| S30 alignment | pass | left column starts 333/332/332; middle centres 640.5; right ends 948/949/949 | ±2 per column |
| S31 header only, raw HTML | pass | TH 318–962 with rounded corners; TR as on `main` (no box, same positions) | |
| S32 nested wide blocks | pass | 1280: nested T12 358–962, C1 358–922; 392: 62–370 and 62–330; all content reached by a sideways scroll; the page does not scroll sideways | in the container |
| S21 zoom moves no wrap, 900 | pass | `scroll.total / zoom` 2410, 2408, 2407, 2406.5, 2406.3 at 0.1, 0.5, 1, 2, 3; P and T7 `Does` lines break at the same words at 0.5, 1 and 2 | ±(1/zoom + 1) |
| S22 block spacing, 392 vs `main` | pass | P, H, C2, L and the label after R within ±1 row of `main` | ±1 |
| S23 Document size 18 | pass | C2 226–1054 | 226–1054 |
| S28 Document size 24 | pass | C2, T2 and T12 88–1192 (Run 1 and Run 2) | 88–1192 |
| S24 light theme | pass | header fill `#dee0e2`; border and row lines `#b4b9be`, 1 px; no line above the first body row but the header's; T12's sideways position and the doc offset unchanged (no reload) | |
| S37 thematic break | pass | a 1 px `#474e55` line on 392/14px, 1280/14px and 1280/24px (Run 2); on Run 1 (before `a8be9cb`) it was missing on 392/14px and 1280/24px | 1 px, `line` |

## Notes

- Before `a8be9cb` the `hr` was the browser's default 1 px border, which the
  K = 3 layout draws a third of a pixel thick; it showed or vanished by where
  it fell on the pixel grid (faint on `main` too). S37 came from this run.
- S29 passes with no margin: `min-width` includes the cell padding under the
  page's `box-sizing: border-box`, so the `Notes` cell is exactly 220.
