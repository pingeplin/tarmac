# Local images in markdown doc cards — manual QA (spec 2609.0014, #164)

S21–S26 of `.blueprint/specs/2609.0014_local_images_in_markdown_doc_cards.md`.
These are [Q] scenarios because each is a property of the running app: whether
WKWebView loads an `<img>` from `tarmac-card://img/` in the app's own document,
and the size it draws at inside the K× prose. The unit suites cover everything
that can be observed without a window: `localImagePath` / `docImageSrc`
(`desktop/src/kit/docImage.test.ts`), the image handler and its type table
(`desktop/src-tauri/src/image_protocol.rs`), and the scheme dispatch
(`desktop/src-tauri/src/lib.rs`). None of them draws an image.

Run against `make run` (S21–S24, S26) and a `make bundle` build (S25).

**CAUTION: do NOT `pkill tarmacd`.** It kills the installed Tarmac and every
terminal its daemon owns. `make run` pins `TARMAC_SOCKET` and `TARMAC_STATE` to
`.dev/` in the worktree, so the dev app and an installed app coexist.

## Build

Worktree `fix/164-local-images-doc-cards` at `34daf74` plus the uncommitted
implementation (fingerprint `9fd4f1fad4db`: sha256 of `git diff 34daf74` followed
by the three new files). macOS 26.6.2, display at scale 1, so a 1100 × 700 window
capture is 1100 × 700 CSS px.

After QA, a review pass changed only four things, none of them runtime
behaviour:
- It added test cases.
- It edited comments.
- `lib.rs` now reads the `tarmac-card://img/` prefix from
  `image_protocol::URI_PREFIX`, the same string.
- That constant became `pub(crate)`.

## Method

No scenario needed a click or a keystroke.

- **Opening docs.** `TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock core/target/debug/tarmac open <path>`.
- **Capturing.** `screencapture -x -o -l <window id>` of the dev window alone, which
  works while it is occluded. The id is the layer-0 window whose trimmed title ends
  with ` · 164-local-images-doc-cards`.
- **Placing cards.** Stop the dev app, stop the dev daemon, wait until both
  processes have exited, edit `.dev/state.json` (`boards[].board` for zoom and
  viewport centre, `w`/`h`/`x`/`y` on each doc's entry in `boards[].tiles[]`), re-read
  the file, relaunch. **Waiting for the daemon to exit matters.** The first attempt
  edited right after `make kill-daemon` returned and came back at
  `{zoom 1, cx 0, cy 0}`; with the wait, every later edit held (S23's zoom 2
  included). The daemon rewriting the file on its way down is the likely cause,
  inferred rather than proven.
- **Measuring widths.** The README's logo and screenshot are dark images on a dark
  card, so pixel edges are unreliable. Widths were measured on a **twin** of
  `README.md`: identical text, with `docs/images/logo.png` replaced by a solid
  400 × 400 magenta PNG and `docs/images/board.png` by a solid 1920 × 1037 orange
  PNG. Layout depends only on intrinsic size and attributes, so the twin lays out
  exactly like the real file, and the real README card was checked side by side in
  the same capture. The capture reproduced both colours exactly
  (`255,0,255` and `255,128,0`), and widths are bounding boxes of those colours.

**Deviations from the spec's recipe:**
- **S21, S22, S24, S26:** the viewport was left at `{1, 0, 0}` and the cards were
  placed near the world origin, instead of centring the viewport on each card.
  Each measured card was fully inside its capture.
- **S23:** zoom was confirmed by re-reading the saved state and by the doubled
  widths, not by measuring the card's border box.

Captures and fixtures were kept outside the repo and are not committed.

---

## S21 — README at 100%

Given `tarmac open README.md` at 100% zoom, tile `w` 392 (content width 348),
tile `h` 600 and the viewport on the card: the logo is 160 ± 1 px wide, and
`board.png` is 348 ± 1 px wide and not clipped.

- [x] **PASS.**

      **Observation (2026-09-15).** Saved viewport `{1, 0, 0}`. The real README
      tile sat at x −430 and the twin at x 40, both 392 × 600.
      - Twin logo: bbox x 707–866, y 116–275, so **160 × 160**.
      - Twin `board.png`: bbox x 613–960, y 418–604, so **348 × 187**. The card's
        border box spans x 590–982 and its prose content x 612–960, so the image
        ends exactly at the content edge and is not clipped.
      - Logo top to `board.png` top: 418 − 116 = **302 px**, the S23 reference.
      - The real README card in the same capture shows the actual logo and board
        screenshot, not broken placeholders, at the same positions as the twin's
        colour blocks.

## S22 — every `src` form and every rendering format

Given a fixture outside the repo at 100% zoom, tile `w` 392, with the viewport on
the card: every image loads, a 100 × 50 PNG with no attributes is 100 × 50 ± 1,
`width="50%"` is half the content width ± 1, and the trailing line is visible.

The fixture (`docs/fixture.md`, beside `docs/img/`, `docs/fmt/`, `docs/dot.png`,
and `../up.png` and `../abs/`). The absolute and `file://` paths are specific to
this machine:

```markdown
S22: ![rel](img/rel.png) ![dot](./dot.png) ![up](../up.png) <img src="/private/tmp/claude-501/-Users-eplin-workspace-tarmac/59d640c7-ffbd-4d90-bd1a-5002a9efcad7/scratchpad/qa164/fixture/abs/abs.png" alt="abs"> <img src="file:///private/tmp/claude-501/-Users-eplin-workspace-tarmac/59d640c7-ffbd-4d90-bd1a-5002a9efcad7/scratchpad/qa164/fixture/abs/file.png" alt="file"> ![cjk](<img/我的 圖.png>) <img src="https://github.githubassets.com/favicons/favicon.png" width="40" alt="https"> <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAAAoCAIAAADBrGu+AAAAXElEQVR4nNXOQREAIAzAsFLVyEAAYhGxB9coyNrnUiZxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEufvwNQDTcYB9GA6Q0AAAAAASUVORK5CYII=" alt="data">

<img src="fmt/sample.png" alt="png" title="png"> <img src="fmt/sample.apng" alt="apng" title="apng"> <img src="fmt/sample.jpg" alt="jpg" title="jpg"> <img src="fmt/sample.gif" alt="gif" title="gif"> <img src="fmt/sample.webp" alt="webp" title="webp"> <img src="fmt/sample.bmp" alt="bmp" title="bmp"> <img src="fmt/sample.tif" alt="tif" title="tif"> <img src="fmt/sample.ico" alt="ico" title="ico"> <img src="fmt/sample.avif" alt="avif" title="avif"> <img src="fmt/sample.heic" alt="heic" title="heic"> <img src="fmt/sample.heics" alt="heics" title="heics"> <img src="fmt/sample.svg" alt="svg" title="svg">

![nat](img/nat100x50.png) <img src="img/half.png" width="50%" alt="half">

END-OF-FIXTURE-LINE
```

The src-form images are 64 × 40 labelled swatches, each a different colour. The
format samples are the `file`/ImageIO/ffprobe-identified samples from the spec's
decode measurement: an animated APNG, a single-frame HEIC sequence, and an SVG.

- [x] **PASS.**

      **Observation (2026-09-15).** Tile 392 × 640, viewport `{1, 0, 0}`.
      - A first version of the fixture had a heading and one image per line. It
        was taller than 640 px, so the 50% image was cut off at the card bottom and
        the trailing line was hidden. The fixture above was then written over it
        with the card still open, and the card re-rendered live.
      - All six src-form swatches load at 64 × 40: relative, `./`, `../`,
        absolute path, `file://`, and the filename with a space and CJK. The https
        favicon and the `data:` image load too.
      - All 12 format samples render, none of them a broken placeholder: png, apng,
        jpg, gif, webp, bmp, tif, ico (32 × 20 natural), avif, heic, heics, svg.
      - The 100 × 50 PNG's longest same-colour run is **100 px**, over 49–50 rows.
      - The `width="50%"` image's longest same-colour run is **174 px** (348 / 2),
        over 86 rows.
      - `END-OF-FIXTURE-LINE` is fully visible inside the 640-px card once the
        images load, so the card's height followed the images without a scroll.

## S23 — 200% zoom, no reflow

Given the S21 card at 200% zoom: the logo is 320 ± 2 px, `board.png` is
696 ± 2 px, and the logo-top to `board.png`-top distance is twice S21's ± 2 px.

- [x] **PASS.**

      **Observation (2026-09-15).** Saved viewport `{zoom 2, cx 236, cy −80}`,
      re-read after launch. Tiles as in S21.
      - Twin logo: bbox x 392–711, y 39–358, so **320 × 320**.
      - Twin `board.png`: bbox x 204–899, so **696 wide**. Only its top 30 rows are
        inside the window, and the width was measured there.
      - Logo top to `board.png` top: 643 − 39 = **604 = 2 × 302** exactly, in one
        capture, so no Δ correction was needed.

## S24 — narrower card re-caps

Given the S21 card at tile `w` 300 (content width 256) and `h` 600: `board.png`
is 256 ± 1 px and the logo stays 160 ± 1 px.

- [x] **PASS.**

      **Observation (2026-09-15).** Twin tile x −540, y −300, 300 × 600,
      viewport `{1, 0, 0}`.
      - `board.png` bbox x 33–288, so **256 × 138**.
      - Logo **160 × 160**.

## S25 — bundled build

Given a `make bundle` build (origin `tauri://localhost`), repeat S21: both images
load at the S21 widths.

- [x] **PASS.**

      **Observation (2026-09-15).** `make bundle` assembled `dist/Tarmac.app`.
      It was launched by absolute path as
      `TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock TARMAC_STATE=<worktree>/.dev/state.json dist/Tarmac.app/Contents/MacOS/tarmac-app`.
      - The daemon it spawned was the bundle's own
        `dist/Tarmac.app/Contents/MacOS/tarmacd`, since no daemon was on the dev
        socket. `ps` showed that path, and `.dev/tarmacd.log` records
        `tarmacd (release) listening on …/.dev/tarmacd.sock` at 07:48:25Z, then
        `app connected (generation 1)`.
      - The window title is plain `board-0`, with no dev suffix, so this is a
        release build. It was captured as the layer-0 window of the bundled
        app's pid. The `tauri://localhost` origin follows from it being a
        release bundle with no dev URL; the origin was not probed at runtime.
      - The S21 layout was restored from `state.json`: viewport `{1, 0, 0}`, README
        and twin at 392 × 600.
      - Twin logo: bbox x 707–866, y 116–275, so **160 × 160**.
      - Twin `board.png`: bbox x 613–960, y 418–604, so **348 × 187**. Both are
        identical to the dev build.
      - The real README card shows the actual logo and board screenshot, loaded
        and not placeholders.

## S26 — missing image, then a live edit

Given a doc whose `src` names a missing local file: that image shows a broken
placeholder and the rest renders. After a line is appended, the line appears and
the other images still load.

The doc: `# S26 missing image`, `![gone](does-not-exist.png)`,
`![present](present.png)`, `body text renders`.

- [x] **PASS.**

      **Observation (2026-09-15).** Tile 340 × 310.
      - Before the edit, the missing file shows WebKit's broken-image placeholder,
        `present.png` renders (64 × 39 bbox), and the body text is visible.
      - `APPENDED-LINE-S26` was appended on disk. The card re-rendered, with the
        header change pulse. The appended line appears, `present.png` still renders
        (64-px run), and the placeholder is unchanged. The appended line sits at the
        310-px card's bottom edge but is fully legible.
