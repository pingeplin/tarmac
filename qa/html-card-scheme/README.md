# HTML card default scheme: probe pages

Probe pages for spec 2610.0007, scenarios S62 to S66
(`.blueprint/specs/2610.0007_theme_setting.md`, *HTML cards*). An HTML card
follows Tarmac's theme unless its author states a colour scheme. Each page
here states one thing about colour, or nothing, so that the rule can be
checked one case at a time.

These are permanent QA files. Open a page as a card, so that it loads through
the real card pipeline with the shim before its first byte:

```sh
tarmac open qa/html-card-scheme/p0.html
```

## What each page has

- **A label** at the top: the page's number and a random id, then what the
  page states.
- **A random id**, made one time when the page loads. A page that shows a new
  id was loaded again (S63).
- **A block**, 120 px wide and 60 px high, below the label. It is a border
  with no colour of its own, so it is drawn in `currentColor`. Sample it for
  the default text colour.
- **An empty area**, 150 px high, below the block. It has no text. Sample it
  for the canvas.
- **A console line** at load, and one more each time `prefers-color-scheme`
  changes:

  ```
  [scheme] P0 id=zounaua5 color-scheme=normal matches=true
  ```

  `color-scheme` is `getComputedStyle(document.documentElement).colorScheme`.
  `matches` is `matchMedia('(prefers-color-scheme: dark)').matches`.

The block and the empty area are at the same place on every page. In the
page's own CSS pixels, before the card's zoom: the block is at x 12 to 132,
y 74 to 134; the empty area is at y 134 to 284, the full width of the page.

A page states nothing about colour but the line its label quotes. The layout
rules name no colour and no background.

## The pages

*Dark* is the system's dark canvas with the system's light text: `1e1e1e` and
`ffffff`. *Light* is `ffffff` and `000000`. Each cell gives the canvas, then
the block.

| Page | The page states | Under the dark theme | Under the light theme |
| --- | --- | --- | --- |
| `p0.html` | no scheme and no colour | `1e1e1e`, `ffffff` | `ffffff`, `000000` |
| `p1.html` | `:root { color-scheme: light dark }` | `1e1e1e`, `ffffff` | `ffffff`, `000000` |
| `p2.html` | `:root { color-scheme: light }` | `ffffff`, `000000` | `ffffff`, `000000` |
| `p3.html` | `html { color-scheme: dark }` | `1e1e1e`, `ffffff` | `1e1e1e`, `ffffff` |
| `p4.html` | `:root { color-scheme: only light }` | `ffffff`, `000000` | `ffffff`, `000000` |
| `p5.html` | `<html style="color-scheme: light">` | `ffffff`, `000000` | `ffffff`, `000000` |
| `p6.html` | `<meta name="color-scheme" content="light">` | `ffffff`, `000000` | `ffffff`, `000000` |
| `p7.html` | `<meta name="color-scheme" content="dark">` | `1e1e1e`, `ffffff` | `1e1e1e`, `ffffff` |
| `p8.html` | `body { color: #222 }` and nothing else | `1e1e1e`, `222222` | `ffffff`, `222222` (not in the spec) |
| `p9.html` | `body { background: #fff }` and nothing else | `ffffff`, `ffffff` | `ffffff`, `000000` (not in the spec) |
| `p10.html` | `@layer base { :root { color-scheme: light } }` | `ffffff`, `000000` | `ffffff`, `000000` |
| `p11.html` | `:where(html) { color-scheme: dark }` | `1e1e1e`, `ffffff` | `1e1e1e`, `ffffff` |

On every page, `matches` is `true` under the dark theme and `false` under the
light theme.

The spec gives P8 and P9 under the dark theme only (S66): they are the cost
that the user accepted. Their pairs under the light theme are not in the spec.
They follow from the row of P0.

## Which scenario uses which page

| Scenario | Pages |
| --- | --- |
| S62: the table, under each theme | P0 to P7, P10, P11 |
| S63: a change of the theme, with no reload | P0, P1, P2, P7 |
| S64: a culled card, and a card opened off the viewport | P0 |
| S65: no white frame at open | P0 |
| S66: a page that sets half of its colours | P8, P9 |
