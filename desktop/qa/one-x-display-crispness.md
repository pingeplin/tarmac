# QA — card crispness on 1× displays

**Status: ACTIVE.** Records the investigation that produced the
`-webkit-font-smoothing` and device-pixel-snap changes, and what each step ruled
out. Read it before touching `docWrapperBox()` (shared by every card kind) or the
oversample constants — several plausible-sounding theories here were tested and
are wrong.

## Symptom

Cards looked correct on the built-in Retina panel (254 ppi) and visibly fringed
on an external BenQ EW2770QZ — 2560×1440 at 27", `UI Looks like: 2560 x 1440`,
i.e. a true 1× display at ~109 ppi with no macOS scaling in play. "Acceptable but
tiring to read." Both doc cards and HTML cards, header chrome and body alike.

## What was ruled out

**Not macOS display scaling.** `system_profiler SPDisplaysDataType` showed native
resolution with no "looks like" resample, so the softening was Tarmac's own.

**Not the Panel H 3:1 minification.** The first theory was that
`scale(zoom/K)` with `K = 3` minifies the prose 3:1 at board zoom 1, and that
downsampled glyphs lose the hinting that direct rasterization would apply. The
card *header* falsified it: the header lives in the translate-only wrapper and
never passes through `.doc-prose-scaler`, yet it fringed exactly as much as the
body. Whatever caused it was upstream of K.

**Therefore not a reason to revisit adaptive K.** Body text is not worse than
header text, so the oversample factor is not the differentiator. See #76 for the
separate, deferred case for replacing K× — it rests on raster memory and the
`MAX_ZOOM ≤ K` ceiling, not on crispness.

**Not irreducible display density.** 109 ppi will never match 254 ppi and chasing
Retina parity is chasing physics. But the same content in Safari on the same
BenQ was sharper than Tarmac, so a real gap existed independent of density.

## The discriminator

Three pieces of text, same screen, board at 100%, ordered by how much transform
machinery sits above them:

| Surface | Transform above it | Result |
|---|---|---|
| Status bar | none (outside `.board`) | sharp |
| Card header | translate-only wrapper | fringed |
| Card body | translate + `scale(zoom/K)` | fringed |

Status bar sharp and card header fringed isolates the cause to the one thing
that differs between them: the wrapper's translate.

## Causes and fixes

**1. `-webkit-font-smoothing: antialiased`** (`theme/app-only.css`, global on
`html, body, #root`). Forces thin grayscale AA. Conventional and fine on Retina;
on a 1× display the thinned strokes read as fringing. Changed to `auto`.
Improved 1×, no regression on Retina — so it is unconditional, not media-gated.

**2. Fractional device-pixel translate** (the dominant cause). Card wrappers
position themselves with

```
translate(calc(var(--world-tx) + var(--card-x) * var(--zoom)), …)
```

and `--world-tx = viewW/2 - cx*zoom` is a raw float, so the sum is essentially
never a whole device pixel. The card's raster lands off the device grid and
WebKit resolves it by filtering — softening every glyph and hairline in the
card. At DPR 2 the error is half as large in device pixels and invisible; at
DPR 1 it is not. Fixed by snapping both components with CSS `round()` to
`var(--device-px)`, which `BoardEngine.apply()` writes as `1px / devicePixelRatio`.

Three details that are load-bearing:

- The snap must wrap the whole per-card sum. Rounding `--world-tx` alone in JS
  leaves `card-x * zoom` fractional per card.
- `--device-px` needs a `matchMedia('(resolution: Ndppx)')` watcher, re-armed
  against the new ratio on each change. Dragging the window between displays
  changes `devicePixelRatio` without firing pan, zoom, or resize.
- `.board` carries a `--device-px: 1px` fallback. An undefined var makes
  `round()` invalid, which invalidates the whole transform and collapses every
  card to 0,0.

## Verified

macOS 26.6.1, BenQ EW2770QZ at 1×. After both changes the card header matches
the status bar, and the body follows. `make test` green (357 tests; S14 in
`docZoom.test.ts` covers the snap arithmetic at DPR 1 and 2 with fractional
input).

## Not verified

- Behaviour on any macOS older than 26.6.1.
- Whether the ≤0.5 device-px drift between a snapped card origin and the
  unsnapped `EdgeLayer` endpoints is ever visible. Edges terminate at card
  centres, behind the card, so it is expected not to be.
