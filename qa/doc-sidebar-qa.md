# Markdown card sidebar — manual QA (spec 2611.0022, #444)

S33–S47 of `.blueprint/specs/2611.0022_doc_sidebar.md`. They are [QA]
scenarios because each is a property of the laid-out page in WKWebView or of
the wiring between the page and `DocWebView`: where the sidebar and the column
sit, what a press, a drag or a wheel does, and what is drawn first. The rules
themselves are pinned by `DocFrontMatterTests`, `DocSidebarTests`,
`DocLayoutScriptTests`, `DocTemplateTests` and `ThemeCSSTests`; none of them
lays out a page.

**CAUTION: do NOT `pkill tarmacd`.** Run against `make run` only; it pins the
sockets, state and config to the worktree's `.dev/`.

## Runs

- **Run 1** at `98e8bef`: all of S33–S47, in three app launches (one per build
  step; steps 2 and 3 changed no code). macOS 26, main display at scale 1, so
  1 screenshot pixel is 1 point. The dev window was resized by pid with
  Accessibility to 1500 × 1100 so a 1280 card fits at zoom 1.
- **Run 2** at `4c04286` (the outline headings found without calling a doc
  element's method): S36 three times from a fresh launch, S47's re-wrap, the
  strip's tick clearance (D15), an open overlay across the 632 threshold
  (D5), and a doc whose raw HTML hides `getAttribute`.
- Presses, drags, double-clicks and wheels are real HID events from
  `scripts/qa/wheel-gesture.swift`; the Document size was set through the
  Settings window (`scripts/qa/settings-window.swift size 2 <n>`). Positions
  come from window captures (`screencapture -l`), measured per pixel.

All x positions are world px from the card body's left edge (1 px right of the
card's `screen_rect.x`, past its border); at zoom 1 a world px is a screen px.
Theme: standard dark. The QA doc has front matter (`title`, `status`, `date`,
`tags: [a, b, c]`, a block list `owners`, `note: <b>bold</b>`), an h1 and a
paragraph P, five h2 with two h3 under each of two of them, a code block
holding `# not a heading`, a raw `<h2>`, and about 2260 px of text. The plain
doc has no front matter and no heading. A third doc of 3000 lines (375 h2)
measures the drag on a long doc.

## Results

| Scenario | Result | Measured | Expected |
|---|---|---|---|
| S33 body | pass | the prose starts at the h1, with no `<hr>` and no setext heading; the sidebar has the six fields; `tags` shows chips a, b, c and `owners` alice, bob; `note` shows `<b>bold</b>` as text | |
| S34 wide card, 1280 | pass | panel 0–239 (240), the grip's line at 240; P's lines start at 442 (ink 441), column 442–1086, centre 764 | 240; centre 764 ± 2 |
| S35 narrow card, 392 | pass | strip 0–29 (30); `≡` opens an overlay 30–269 (240, its border at 269) and scrolls it to `OUTLINE`; the text right of the panel is pixel-equal in each row before and after (no line moved); a press on the text shows the strip; opened again, a second `≡` click shows the strip | 30; 240 after the strip; no line moves |
| S36 drag on an unselected card | pass | Run 2, from a fresh launch, three times (switch board, `focus board`, then the grip press is the first pointer event; before it `restore_card` is null, `active_element` BODY, `focused_card` null, the app frontmost): each press selects the card and the panel is 300 during the drag, 240 after the double-click. Run 1: 1280, zoom 1, no card selected: a press on the grip and +60 in 10 steps selects the card (`focused_card` set while the press is held) and shows the panel at 300 during the drag; P's ink moves from 441 to 471 (centre 764 → 794), each line the same width; the release and 0.6 s later: still 300. Zoom 0.5, from 240: +60 screen px gives a 180 screen px panel = 360. 800 card: 240 → 300 during the drag moves P's first line end from "…can follow, and the" to "…a reader can" | 300; 764 → 794; 360; a re-wrap |
| S37 collapse and reset | pass | from 300, a drag of −200 shows the strip (0–29) while held and after the release; `≡` opens it docked at 300; a double-click on the grip gives 240 | strip; 300; 240 |
| S38 outline | pass | zoom 1: a click on `Section 3` scrolls the doc to 995 and marks it; the heading's cap top is 13 px below the view's top (a 21 px h2's cap is 6.4 below its box: box at 8 ± 2). Zoom 0.5: `Section 2`, cap top 8 screen px below (3.2 + 4), marked. A wheel to 1505 marks `Section 4`; at the end `Section 6 added` (end rule). The raw `<h2>` and `# not a heading` are not in the outline | 8 (4 at 0.5) |
| S39 threshold | pass | docked at 300 on 1280; resized to 600: the strip (0–29); back to 1280: docked at 300 | |
| S40 zoom | pass | `scroll.total / zoom` 2470, 2462, 2461, 2461, 2460.7 at 0.1, 0.5, 1, 2, 3; an outline entry that wraps ("A long heading … more than one / line in the outline of the sidebar") breaks at the same word at 0.5, 1 and 2, as do the field rows | ±(1/zoom + 1) |
| S41 no sidebar | pass | the plain doc: no strip (the body's bg1 starts at 0); its lines start at 317 (ink) | 318–962 |
| S42 refresh | pass | docked at 300; an appended `## Section 6 added` re-renders the doc; the sidebar is still docked at 300 and the outline ends with `Section 6 added` | |
| S43 others unchanged | pass (part) | a drag on the text selects it (highlight); a press on a link (a relative one) does not select the card (`focused_card` stays null); the card's left handle resizes a strip card (`resize --handle left` delivery `window`, and a HID drag of −40 at x = 2: 392 → 432); the scroll thumb follows the doc (`thumb.y` 388 → 650 at offset 0 → 995). An http link was not clicked, to leave the browser alone: `docLink` is unchanged by this slice | |
| S44 sidebar scroll | pass | the 3000-line doc, selected: a wheel over the sidebar scrolls the outline (Heading 9 at its top after) and the doc's `scroll.offset` stays 0, the thumb shows and stays at y 388. The QA doc's outline fits: a wheel over it leaves the sidebar pixel-equal and the offset at 1740. Unselected: the wheel pans the board (viewport cy 245 → 565) | |
| S45 strip and header controls | pass | 1280 docked: `⇤` shows the strip, P's lines start at 332, column 332–976, centre 654.5; `{}` opens it docked at 240 with `FRONT MATTER` at the panel's top; closed, a click on `Section 3`'s tick scrolls to 995 (cap 13 px below the top, as S38) and lights that tick in `--agent` (#07c5ac) | 655 ± 2 |
| S46 open and narrow cards | pass | a 1280 plain card whose file gains front matter: 14 captures through the change show only the old page (no strip, lines at 317) or the new one docked (panel, lines at 441), never the new text at full width. A 200 card: the overlay is 150 wide and the system cursor at its inner edge is not the column-resize one, while at 392 it is (`NSCursor.currentSystem` matches `columnResize`) | no full-width frame; no grip |
| S47 Document size | pass | at 18 the outline's entry pitch is 28.5 px (22 at 14): 15.5 px × (1.45 line height + 0.4em padding). Run 2, at 240: the long entry breaks "…that wraps across / more than one line in the outline of the / sidebar" at 14 and "…that wraps / across more than one line in / the outline of the sidebar" at 18; back at 14 the sidebar's ink box is the one before (Run 1: 196–407 by 435–945, ±1 row; Run 2: equal) | 15.5 px at 18, a re-wrap |

## Run 4

At `c7961d1` (main merged in, then the /simplify changes: one inline text
walker, headings stamped per token, a drag laid out at most once a frame,
plain side borders, one width clamp). Same window, display and docs; the
captures are `r4-*` in the scratchpad. Positions are world px from the card
body's left edge, at zoom 1 unless named.

| Scenario | Result | Measured |
|---|---|---|
| S33 body | pass | no `<hr>`, the text starts at the h1; six fields; chips for `tags` and `owners`; `note` as text |
| S34 wide card | pass | panel 0–239, its line at 240; P starts at 441 (column 442–1086, centre 764) |
| S35 narrow card | pass | strip 0–29; the outline icon's three bars peak at rows 454, 458, 462 with background rows between (each bar now spans a third row at partial intensity, but the gaps are whole); `≡` opens the overlay (border at 269) and marks `≡`; `{}` keeps it open at `FRONT MATTER` and moves the mark to `{}`; `{}` again closes it; the text right of the panel is pixel-equal open and closed; a press on the text closes it |
| S36 drag | pass | unselected card: selected during the drag; panel 300 during the drag, in a capture taken at once after the release and 0.6 s later; P moves 441 → 471 (centre 764 → 794); a click on the grip with no move keeps 300. Zoom 0.5: +60 screen px gives 180 screen px = 360; a double-click gives 120 = 240. 800 card: a line's end moves from "…can follow, and the" to "…a reader can follow," during the drag |
| S37 collapse and reset | pass | a drag of −200: the strip (0–29) while held and after the release; `≡` docks at 300; a double-click gives 240 |
| S38 outline | pass | `Section 3`: offset 995, cap 13 px below the view's top (box at 8), entry marked; a wheel to 1505 marks `Section 4`; zoom 0.5 `Section 2`: offset 223, cap 8 screen px below (box at 4), marked |
| S39 threshold | pass | docked 300 at 1280; strip at 600; docked 300 at 1280 again |
| S40 zoom | pass | `scroll.total / zoom` 2550, 2548, 2547, 2546.5, 2546.3 at 0.1, 0.5, 1, 2, 3; the long outline entry breaks after "more than one" at 0.5, 1 and 2 |
| S41 no sidebar | pass | the plain doc: no strip; its lines start at 317 |
| S42 refresh | pass | an appended `## Section 7 run4`: still docked at 300, the outline ends with it |
| S43 others | pass (part) | a drag selects text (highlight); a press on the relative link leaves `focused_card` null; the left edge over the strip drags the card 392 → 432 (HID, x = 2); the thumb's y follows the offset (189 at 216, 592 at 1939 of 2547). The http link: not run, it would open the user's browser |
| S44 sidebar scroll | pass | the 3000-line doc, selected: a wheel over the sidebar changes the sidebar's pixels, the offset stays 63913, the thumb shows and stays at y 348; unselected: the board pans (cy 565 → 885); the hostile doc's short outline: pixel-equal, offset 0 |
| S45 controls | pass | `⇤`: the strip, lines at 332 (centre 654); `{}`: docked at 240, `FRONT MATTER` at the panel's top; a tick click on `Section 1`: offset 219, cap 14 px below the top (box at 8 ± 1), the tick lit |
| S46 open and narrow | pass | 14 captures as the 1280 plain card's file gains front matter: 4 old frames (lines at 317), 10 docked (lines at 441), none of the new text at full width; at 200 the overlay is 150 and the cursor at its edge is not column-resize, at 392 it is |
| S47 Document size | pass | the entry pitch is 28.5 px at 18 (22 at 14); back at 14 the sidebar is pixel-equal to the capture before. The long entry's re-wrap at 18 was measured in Run 2 (it is below the panel's fold in this run) |

Extra checks:

- **(i) Image path.** A 1280 card of a doc with a local image and no heading;
  its file is replaced by the same doc with a first `#` heading. 16 captures:
  4 old frames (no panel, lines at 317), then 12 docked with the heading at
  442 and the image loaded; no frame shows the new text at full width.
- **(ii) Reading position.** The 3000-line doc on a 1280 card, scrolled by
  its thumb to 63914 of 131177 (0.4872). Zoom 0.5, 1, 2, 1: 0.4872 each time;
  resized to 900: 68226 of 140028 (0.4872); back to 1280: 63913 of 131177
  (0.4872). It does not move, so origin/main was not compared.
- **(iii)** S41 as above: the template's defaults change nothing for a doc
  with no sidebar.
- **(iv) A release outside the window.** On the 1280 card docked at 300, a
  press on the grip, a drag of (+40, +420) that ends about 38 points below
  the dev window's bottom edge, then the release there: the panel is 340 while
  held and after the release, and a click on the grip with no move then keeps
  340. The release arrived as a `mouseup` (AppKit gives it to the window that
  took the press), so the `blur` path was not exercised.
- **(v) Drag cost.** The 3000-line doc on an 800 card, three drags of +60 in
  10 steps of 16 ms: a capture taken at once after the last move shows the
  panel's edge at 300 and the text at 308 + 22 each time. No millisecond
  figure: no driver verb reads the page's frame times.

A board switch brought the restore card back on some boards; it was closed
with `press tab` and `restore_card` read null before each scenario.

### Run 4 addendum (at `98c7fcc`, a fresh launch)

- **The outline icon's soft bars come from a board switch, not from a
  commit.** On a fresh launch the narrow card's bars are crisp: rows 454–455,
  458–459, 462–463 at full intensity, 2-row gaps. After `board board-1` and
  `board board-4` (no zoom change) the whole web view sits half a pixel up:
  the header's separator row 417 reads `#40474e` (blended with the page)
  instead of `#4e555c`, every bar spans a full row and two half rows, and the
  prose text moves up one row too. A zoom change on the board (0.5, then 1)
  puts it back; `zoom 1` when the board is already at 1 does not. This branch
  does not change the web view's frame code (its only lines in `CardView` are
  the sidebar choice and its wiring; in `DocWebView` none touch the host or a
  frame), so the shift is in code this slice did not change. It shifts the
  prose as much as the strip, so it is not a sidebar bug and the sidebar was
  not changed for it.
- **The `blur` end of a drag.** On the 1280 card at 240, a grip press held
  and dragged +60 (panel 300); then the dev app's own Settings window was
  opened (`settings-window.swift open`, ⌘, to the dev app), which takes the
  key status from the main window: the panel stayed 300; a further +80 move
  with the press still held, and then the release, changed nothing (the drag
  had ended); closing the panel by `⇤` and opening it by `≡` docks it at 300,
  so the blur's `resize` report reached the app.

## Run 2 checks outside the scenarios

- **Tick clearance (D15).** The 3000-line doc's strip on a 640-high 800 card:
  the ticks that fit are drawn and the last one's bar is at row 685, with
  the body's bottom edge at 706: 20 px clear.
- **Overlay across the threshold (D5, `overlayOpen`).** 392: `≡` opens the
  overlay (its border at 269); widened to 700 the card docks the sidebar at
  240; back at 392 it shows the strip (0–29), not the overlay.
- **Hostile raw HTML.** A doc holding `<form data-outline="x"><input
  name="getAttribute"><input name="querySelector"></form>` shows its front
  matter and both headings in the outline, `First` marked.

## Run 3

At `f90781f`: the page's drag end, section scroll, active icon and render
state from `doc-layout.js`, the layout state sent as arguments, the drawn
outline icon. Same window, display and docs as Run 1; on board 1 the 1280
card's body starts at x 434, y 168 in the capture, so only its left part is
in the window.

| Scenario | Result | Measured |
|---|---|---|
| S35 overlay icons | pass | the `≡` icon is three bars 2 px high with 2 px gaps at zoom 1 (rows 454–455, 458–459, 462–463), not a block. `≡` opens the overlay (border at 269) and marks `≡` in `--agent`; `{}` keeps it open, scrolls it to `FRONT MATTER` and moves the mark to `{}`; `{}` again closes it. Opened by `≡` again, an edit of the file (re-render) keeps it open and moves the mark to `{}` (the section is reset to the first icon); a press on the text closes it |
| S36 drag | pass | from an unselected card: selected and 300 during the drag; 300 in a capture taken at once after the release and 0.6 s later; a click on the grip with no move leaves 300 |
| S37 collapse and reset | pass | a drag of −200 shows the strip (0–29) while held and after the release; `≡` docks it at 300; a double-click gives 240; the text then starts at 441 (strip: 332) |
| S38 outline | pass | a click on `Section 3` scrolls to 995, its cap top 13 px below the view's top (box at 8), and marks that entry |
| S45 controls | pass | `⇤` shows the strip, the text at 332 (centre 654); `{}` docks it at 240 with `FRONT MATTER` at the panel's top; closed, a click on `Section 1`'s tick scrolls to 219 (cap 13 px below the top) and lights that tick in `--agent` |
| S46 open and narrow | pass | 14 captures while a 1280 plain card's file gains front matter: 4 old frames (no strip, text at 317), then 10 docked (text at 441), none with the new text at full width; at 200 the overlay is 150 and the cursor at its edge is not column-resize, at 392 it is |

A board switch brought the restore card back on board 4 and board 3 in this
run; it was closed with `press tab` and `restore_card` read null before each
scenario.

## Drag cost

On the 3000-line doc (166 606 px at zoom 1) on an 800 card, three drags of +60
in 10 steps of 16 ms: a capture taken right after the last move shows the
panel's edge at 300 and the text starting at 308 + 22 in each run, so the live
re-wrap keeps up with the pointer.

## Notes

- In Run 1 the first grip press after the third launch selected nothing and
  moved nothing. Run 2 shows why: `press tab` sent as soon as the driver
  answered left the restore card up (`restore_card` not null, the veil in the
  capture), and the first press closed it. With the restore card closed, the
  first press selected the card and dragged three times out of three.
- A first click that seems lost can be another card on top: a terminal card
  given the keys is raised over a doc card it overlaps. Run 2 moved the
  narrow card clear of the terminal before its overlay checks.
- The heading's top is measured from its glyphs: no `tarmac dev` verb reads
  the page. The cap offset inside the h2's box (6.4 px at 21 px) is from the
  font's metrics; zoom 1 (13 = 6.4 + 8 ± 1) and zoom 0.5 (8 = 3.2 + 4 ± 1)
  agree.
