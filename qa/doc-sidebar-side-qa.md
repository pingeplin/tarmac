# Markdown card sidebar side — manual QA (spec 2611.0025, #446)

S11–S26 of `.blueprint/specs/2611.0025_doc_sidebar_side.md`. They are [QA]
scenarios because they test the shell: the Documents pane, `DocumentSettings`,
the broadcast, `DocWebView` and the page's mirrored rules. The rules are pinned
by `DocSidebarTests`, `AppPrefsTests`, `DocLayoutScriptTests` and
`DocTemplateTests`. None of those runs the app.

**CAUTION: do NOT `pkill tarmacd`.** Run against `make run` only.

## Run 1

- **Build:** `6a363a5`, macOS 26.7.2.
- **Channels:** one for each part, as the spec's *Order* says. Each started
  from an empty directory, after `make kill-daemon DEV_DIR=<dir>` had found no
  daemon there.
  - `.dev/qa-side-bytes`: S15.
  - `.dev/qa-side-smoke`: `make qa`.
  - `.dev/qa-side`: S11–S14, S16–S19, S21 and S23–S26.
  - `.dev/qa-side-control`: S20.
  - `.dev/qa-side-main`: the S11 size baseline.
  The CLI was `env -u TARMAC_TERM_ID TARMAC_SOCKET=<dir>/tarmacd.sock
  TARMAC_DEV_SOCKET=<dir>/tarmac-dev.sock core/target/debug/tarmac`. The app's
  pid was `lsof -t <dir>/tarmac-dev.sock`. No other dev app was up during any
  run.
- **Windows:** the board window opened on the built-in Retina display. After
  each launch it was moved and resized by pid with Accessibility to 2440 × 1129
  at (60, 40), on the main display (scale 1). One capture pixel is then one
  point. The Settings window was moved by `settings-window.swift move 2700 100`
  onto the Retina display, off the board window, before any HID event.
- **Docs** (`.dev/qa-side-docs/`):
  - A, B, C, D, F and G each have front matter (`title`, `status`, `tags`, a
    block list `owners`) and 22 `#` with 22 `##` headings.
  - For S19, 80 more headings were added to B, so that its ticks fill the
    strip. With 44 ticks the strip ends at body y 367, because a tick is 7 px.
  - E has no front matter and no heading. H is an HTML file.
- **Board 1** (`board-0`, zoom 0.5): A, B and E are 1280 × 700, at world
  (−2050, −780), (−700, −780) and (650, −780). C is 392 × 700 at (−2050, −40),
  and H is 392 × 310 at (−1600, −40). The boot terminal is at (80, 80).
  - No card overlaps another, and all are in view at zoom 0.5. No `tarmac dev`
    verb moves a card, so each card was moved by two `tarmac dev resize --handle`
    calls: grow from one corner, then shrink from the other.
  - Setup: A's grip was dragged from 240 to 300. B was closed by `⇤`. C's
    overlay was opened by `≡`. A wheel took A to offset 1560 of 3494, B to 1600
    of 3494 and C to 2240 of 4843.
- **Board 2** (`board-1`): made by `tarmac dev board --new`, with zoom 0.5 and D
  at 1280 × 700, docked at 240. Then `tarmac dev board board-0` was run, so
  board 2 was not mounted.
- **Input:** every press, click, drag and wheel is a real HID event from
  `scripts/qa/wheel-gesture.swift`.
  - Before each one, `tarmac dev focus board` (or `focus <card>`) ran. The
    script refuses to post unless the top window under the aim is the dev
    app's.
  - `restore_card` read null before every click.
  - After every board switch and every pan, the zoom was changed once and set
    back before a pixel capture (#450).
- **Measuring:** `screencapture -l <board window id>`.
  - Each capture was read along body row 6, a blank row in the panel, the strip
    and the prose's top padding. Some scenarios used other rows, as stated.
  - x is world px from the card's left outer edge. At zoom 0.5 one capture
    pixel is 2 world px. Panel `#353b41`, text area `#2b3036`, line and border
    `#474e55`.
  - "Text unchanged" was checked by the line bands of the text column: each
    line's y range and ink extent, measured from the column's start. They had to
    be the same before and after, with the same non-zero `scroll.offset`.
  - `state.json` and `app-prefs.json` were read only, never edited.

## Results

| Scenario | Result | Measured | Expected |
|---|---|---|---|
| S11 pane | pass | **Sidebar:** Fonts, Theme, Documents, with the `doc.text` icon (capture). `pane=Documents`. **Labels:** `Markdown cards`, `Sidebar side`, `The sidebar holds the front matter and the outline.` **Tiles:** `tile Left value=1`, `tile Right value=0`. **Capture:** the accent ring on Left only. Each picture's sidebar band is on its own side. The help text's left edge (x 3275) is the Left tile's (3275). **Window:** 873 × 530 on the Fonts, Theme and Documents panes. **Baseline** (see Notes): 873 × 530 | same size on every pane; width = main; height ≤ main + 40 |
| S12 switch to Right | pass | **Capture right after `side Right`:** under 1.1 s, all cards in view at zoom 0.5. A panel 980–1278. B strip 1250–1278. C border 122–124, with panel and strip 124–390. No sidebar part at the left edge. E has no sidebar. H unchanged. **A:** panel 980–1278; grip hairline at 978 (seen at zoom 1); text column 166–800, centre 487. **B:** strip 1250–1278; column starts at 304, centre 626. **C:** strip and panel to 390, border at 122 (panel 121–361), no hairline on the grip. **Text:** A's 19 line bands are the same at offset 1560, B's 19 at 1600. C shows only 118 px of text beside the overlay; every line band of its right part before is in its left part after, at offset 2240. **`state.json`:** whole file byte-equal before and after | A 979–1279, centre 487; B 1249–1279, centre 626; C strip 361–391, panel 121–361; text and tiles unchanged |
| S13 unmounted board | pass | First capture after `tarmac dev board board-1`: D panel 1040–1278, text starts at 196, so the centre is 518. After a zoom nudge it is the same | D 1039–1279, centre 517 |
| S14 back to Left | pass | `side Left`. **D (board 2):** panel 2–242. **Board 1:** A panel 2–302, line 302–304. B strip 2–32. C panel 2–270, border 270–272. **Text:** A's line bands are the same as before S12. **`state.json`:** tiles the same | A 1–301; B 1–31; C 31–271 + strip |
| S15 bytes | pass | **Fresh channel:** `config/app-prefs.json` was absent. **`side Right`:** `{"warn_before_quit":true,"doc_sidebar_side":"right"}`. **`side Left`:** `{"warn_before_quit":true}`. **`side Left` again:** mtime `1795265825.786625918` before and after | exact bytes; no write |
| S16 restart | pass | **Quit:** `side Right`, then the app was quit (`kill` by the driver socket's pid). The daemon stayed up. **`make run`:** after a zoom nudge, A panel 980–1278 (300), B strip 1250–1278, C strip 362–390 (its overlay not kept). **C:** `≡` opened the overlay at 240 on the right, border at 122. **Board 2:** D panel 1040–1278 in its first capture. **Settings:** `tile Right value=1`. | A 979–1279; B 1249–1279; C 361–391, then panel 121–361; D 1039–1279 |
| S17 new cards | pass | **F** (opened on board 1, 392 wide): strip 362–390. After `resize 1280x700`: panel 1040–1278. **G** (on a new `board-2`): strip 362–390 in its first capture. After the resize: panel 1040–1278 | strip on the right; then panel 1039–1279 |
| S18 drag on the Right | pass | **At zoom 1, A selected, from 300:** a double-click at 974,334 gave 240 (hairline 1038, panel 1039–1279). Press at 1034,334 and `--drag -60,0`: the panel was at 979–1279 while held (capture), kept on release; `sidebar_w 300`. Press at 974,334, `--drag 150,0` and release: strip 1249–1279; `sidebar_w 300`, `sidebar_open false`. `≡` at 1257,41: docked at 300 (979–1279). Double-click: 240. **At zoom 0.5:** press at 517,167 and `--drag -60,0`: 360 (panel 920–1278); `sidebar_w 360`. **C at zoom 1:** overlay 240, grip 113–121. Press at 116,334 and `--drag -40,0`: border at 81, so 280; `sidebar_w 280` | 240, 300, strip, 300, 240, 360, 280 |
| S19 clear of the thumb | pass | **B (strip), zoom 1, after a wheel:** thumb 1267–1277 (`shown` true). Icons 1251–1264, ticks 1251–1265. Within x ≥ 1266 the only ink is the thumb (body y 19–50) and the card's rounded corner (y 661–668). Lowest tick ends at body y 645, 23 above the bottom (668). **Thumb drag:** after a wheel, a press on the thumb and `--drag 0,40`; the offset went from 365 to 1330, and `sidebar_open` stayed false. `≡` at 1257,41 opened the panel (1039–1279). **A:** from 360, press at 914,334 and `--drag 60,0` gave 300. The panel's ink ends at 1264: `⇥` 1257–1264; none at x ≥ 1267. With the thumb hidden, a press at 1276,334 and `--drag 40,0` made A 1320 wide; `resize` set it back to 1280. **At zoom 0.5:** the icons end at card x 1266, 13 world = 6.5 screen px from the body's right edge | thumb 1267–1277; icons 1249–1267; ticks 1251–1265; nothing at ≥ 1267; ≥ 20 above bottom; +40 width; ≥ 6 screen px |
| S20 control (broadcast) | recorded | **Setup:** the `tellEveryView { $0.broadcastDocSidebarSideChanged() }` line was commented out (the line only) and the app run in `.dev/qa-side-control`, with S12's setup. **After `side Right`:** A, B and C stayed on the left, in the first capture and again 2 s later (A panel 2–302, B strip 2–32, C panel 2–270). **Board 2:** after the switch, D showed its panel on the right (1040–1278) in its first capture. So the broadcast moves mounted cards, and S12 proves it. S13 proves only the outcome: the mount lays D out again with the side in effect, with or without the broadcast. The line was restored, and `git status` showed no change | record |
| S21 other behaviour on the Right | pass | **C at zoom 1:** the overlay was set to 240 by a grip double-click (border at 121). A press on the text at 60,334 closed it, leaving only the strip, 361–391. **B, docked at 240:** a click on the entry "B part 8" (1078,555) brought that heading to the top of the view (glyph top at body y 16) and marked the entry (capture). A click on `⇥` (1259,22) gave the strip; `sidebar_open false`. **B's panel, zoom 0.5 → 2:** the same 23 line bands, at the same y within ±2 world px, with the same ink widths | close; scroll and mark; strip; no re-wrap |
| S22 Theme tiles unchanged (offline) | pass | See *S22* below. All 6 images byte-equal; both controls found | byte-equal; control differs |
| S23 tiles in both appearances | pass | **Light:** ground `eff1f1`, header `dfe0e1`, sidebar band `dee1e2`, agent line `3c826f`. **Dark:** ground `2c3036`, header `363b40`, band `363c40`, agent `58b99e`. The capture's profile is Display P3; the palette's sRGB values in P3 are light `eff0f1`/`dee0e2`/`3d826f` and dark `2c3035`/`363b40`/`58b99d`. All are within ±1. Only the selected (Right) tile has the ring: `3478f7` at the ring room; the other tile shows `f7f7f7`/`343638` there. The two captures differ. The theme was set back to Dark | bg1, bg2, agent ±6; ring on the selected only |
| S24 prefs survive other changes | pass | With Right: after Document size 15 the file was `{"warn_before_quit":true,"document_font_size":15,"doc_sidebar_side":"right"}`; after theme Light, `{…,"theme":"light","doc_sidebar_side":"right"}`; after Dark, `{…,"document_font_size":15,"doc_sidebar_side":"right"}` | key kept |
| S25 grip at the upper end | pass | **Right:** C dragged to 339 (border 22, grip 14–22). A wheel on the text, then a press on the grip within 0.5 s (the thumb shows about 1.4 s after a wheel), and `--drag 40,0`: 299. **Left:** C dragged to 339 (border 369, grip 370–378). A wheel, then `shown` true with the thumb at card x 379–389. A press on the grip at 374 and `--drag -40,0`: 299. A press on the thumb would have scrolled the page and left the width as it was | width changes on each side |
| S26 first frame | pass | **New G:** the first capture after it appeared in the snapshot, and the 6 after it, all show the strip on the right (362–390). **D:** the first capture after its board's first mount shows the panel on the right (S16). **A, B and C after the restart:** the first capture after the window was moved onto the main display shows them on the right, 2 world px off until a zoom nudge (#450) | sidebar on the right from the first frame |

## S22 (offline)

The drawing compare harness from memory `offline-drawing-compare-harness`, with
the real palettes (`ThemeCatalog.standard(for:)`).

- **Build:** `swiftc` built one executable per version, compiling every
  `TarmacKit` source and a stub `Theme` (`srgb` only) into one module.
  - "Before" is `ThemeTile.swift` at `4189423`.
  - "After" is `PictureTile.swift` and `ThemeTile.swift` at `6a363a5`.
- **Output:** each executable draws, for Auto, Light and Dark,
  `ThemeTile.button` + `ThemeTile.picture`. It writes `image` and
  `alternateImage` as PNG at 2×, and the button's titles, AX role, AX subrole
  and image position as text.
- **Result:** after against before, all 6 PNGs are byte-equal, and the 3 texts
  are equal once pointer addresses are removed.
- **Control 1:** ring width 2.5 → 3. The 3 selected images differ and the
  unselected ones do not.
- **Control 2:** corner 7 → 6. All 6 images differ.

## `make qa`

In `.dev/qa-side-smoke`, a fresh `make run`, where the Settings window was
never shown (#207). `make qa DEV_DIR=…` ran once the boot terminal's `proc`
was `zsh`. **Result: 33/33 checks passed.**

## Teardown

Each channel's app was quit by `kill` of its driver socket's pid. Then
`make kill-daemon DEV_DIR=<dir>` stopped that channel's daemon. No process
was left on any QA socket. No `tarmacd.log` of the five channels has an
`ERROR` or a panic.

## Notes

- **S11 baseline.** The spec measures `main`'s size from a `main` worktree.
  This run could not touch any other worktree, so the baseline is a knockout
  in this worktree instead.
  - The Documents pane was left out of the window (`for pane in
    SettingsPane.allCases where pane != .documents` in `makeContent`) and run
    in `.dev/qa-side-main`. It measured 873 × 530 on Fonts and Theme.
  - The Fonts and Theme panes do not differ from `main` in this branch:
    `ThemePane`, `FontsPane` and `SettingsGroup.box` are unchanged, and the
    Theme tiles' images are byte-equal (S22).
  - The knockout was reverted, and `git status` was clean.
- **S21:** the spec names A for the `⇥` click and the outline entry. Here they
  were done on B, docked at 240, which was in view. C's overlay was first set
  to 240, because S25 had left it at 299 and the spec's point 60,334 would
  then be on the grip.
- **S12** captures were at zoom 0.5, with all cards in view, so no pan came
  between the change and the capture. A's grip hairline is too thin to show at
  0.5; at zoom 1 it is at 978 (S18).
- **#450:** after the restart and after the window move, every sidebar edge
  read 2 world px (1 screen px) off until one zoom change. After the change,
  every value was within ±1 world px of the spec's.

## Follow-up #456

The Documents pane's tiles moved from the box's trailing edge to a 150 pt
label column (the mockup's `150px 1fr`, gap 16, label 4 px down). Channel
`.dev/qa-456`, same machine, same window origin (847, 250). "Before" is
`0489444` (main), "after" the change, both run in that channel by `make run`
and driven by `scripts/qa/settings-window.swift` (`open`, `pane`, `rows`);
captures by window id (`screencapture -x -o -l`).

| Check | Before | After | Expected | Result |
|---|---|---|---|---|
| `Sidebar side` label x, y | 1066, 336 | 1066, 340 | label 4 down from the tiles' top | pass |
| Left tile x | 1422 | 1232 | label x + 150 + 16 = 1232 | pass |
| Right tile x | 1504 | 1314 | Left + 82, as before | pass |
| Help text x, y | 1422, 410 | 1232, 410 | Left tile x, under the tiles | pass |
| Window, Fonts / Theme / Documents | 873 × 530 each | 873 × 530 each | unchanged | pass |
| Fonts and Theme panes | — | `rows` output identical; captures byte-equal (`cmp`) | unchanged | pass |
| `side Right`, `side Left` | — | `tile Right value=1`, then `tile Left value=1` | tiles still choose | pass |

Teardown: the app was quit by `kill` of the pid on the channel's driver
socket, and `make kill-daemon DEV_DIR=.dev/qa-456` stopped its daemon.
