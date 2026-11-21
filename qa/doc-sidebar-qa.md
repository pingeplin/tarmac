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
| S36 drag on an unselected card | pass | 1280, zoom 1, no card selected: a press on the grip and +60 in 10 steps selects the card (`focused_card` set while the press is held) and shows the panel at 300 during the drag; P's ink moves from 441 to 471 (centre 764 → 794), each line the same width; the release and 0.6 s later: still 300. Zoom 0.5, from 240: +60 screen px gives a 180 screen px panel = 360. 800 card: 240 → 300 during the drag moves P's first line end from "…can follow, and the" to "…a reader can" | 300; 764 → 794; 360; a re-wrap |
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
| S47 Document size | pass | at 18 the outline's entry pitch is 28.5 px (22 at 14) and the text is larger, so 18 × 0.86 = 15.5 px with line height 1.45 and 0.4em padding; back at 14 the sidebar's ink box is the one at 14 before (196–407 by 435–945, ±1 row) | 15.5 px at 18 |

## Drag cost

On the 3000-line doc (166 606 px at zoom 1) on an 800 card, three drags of +60
in 10 steps of 16 ms: a capture taken right after the last move shows the
panel's edge at 300 and the text starting at 308 + 22 in each run, so the live
re-wrap keeps up with the pointer.

## Notes

- The first grip press after a launch selected nothing and moved nothing:
  the dev window had just been set up by `focus board`, and the next press,
  same point and same call, worked. The spec's note (the window must be key)
  covers it.
- The heading's top is measured from its glyphs: no `tarmac dev` verb reads
  the page. The cap offset inside the h2's box (6.4 px at 21 px) is from the
  font's metrics; zoom 1 (13 = 6.4 + 8 ± 1) and zoom 0.5 (8 = 3.2 + 4 ± 1)
  agree.
