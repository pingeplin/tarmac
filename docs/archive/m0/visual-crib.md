# Tarmac M0 — visual crib

Exact values for the Swift/AppKit implementer. Sources: `design_handoff_tarmac/tarmac/theme.css`
(canonical token sheet), `converged.css`, `tarmac-proto/proto.css`, README "Design Tokens" /
"Peek" / type scale. Where the design authors oklch, the sRGB hex below was computed via the
CSS Color 4 / OKLab (Ottosson) matrices and pixel-verified against a browser's own oklch
rasterization (max channel delta 0).

## Color tokens

All hex values are sRGB. AppKit: `NSColor(srgbRed:green:blue:alpha:)` — not `calibratedRed`.

| Token | oklch | sRGB hex | rgb | Use |
|---|---|---|---|---|
| bg0 | — (authored hex) | `#0c0e12` | 12 14 18 | window/desk backdrop |
| bg1 | — | `#12151a` | 18 21 26 | panes, doc viewer |
| bg2 | — | `#191d24` | 25 29 36 | raised: tabs, cards, chips, toasts, peek header |
| bg3 | — | `#20252e` | 32 37 46 | hover |
| term-bg | — | `#0a0c10` | 10 12 16 | terminal body |
| line | — | `#262c36` | 38 44 54 | strong borders, kbd chip border |
| line-soft | — | `#1d222b` | 29 34 43 | hairlines |
| text | — | `#d8dbe2` | 216 219 226 | primary text |
| muted | — | `#8c93a0` | 140 147 160 | secondary |
| faint | — | `#5a616d` | 90 97 109 | tertiary / hints |
| prose | — | `#b9bec8` | 185 190 200 | doc body paragraphs/lists (`.tm-doc p`) |
| agent (accent) | `oklch(0.78 0.11 200)` | `#4eccd3` | 78 204 211 | cyan — anything CLI/file-event touched |
| agent-dim | `oklch(0.78 0.11 200 / 0.16)` | `#4eccd3` @ 16% (`#4eccd329`) | rgba(78,204,211,0.16) | tints, pulses |
| doclink edge | `oklch(0.78 0.11 200 / 0.45)` | `#4eccd3` @ 45% (`#4eccd373`) | rgba(78,204,211,0.45) | dashed link underline |
| amber | `oklch(0.78 0.11 75)` | `#e1ad63` | 225 173 99 | bell / waiting |
| amber-dim | `oklch(0.78 0.11 75 / 0.16)` | `#e1ad63` @ 16% (`#e1ad6329`) | rgba(225,173,99,0.16) | tints |
| ok | `oklch(0.75 0.1 150)` | `#7fc08c` | 127 192 140 | success / exit 0 |
| repo-a | `oklch(0.72 0.09 25)` | `#d78e88` | 215 142 136 | repo identity dot |
| repo-b | `oklch(0.72 0.09 145)` | `#81b482` | 129 180 130 | repo identity dot |
| repo-c | `oklch(0.72 0.09 265)` | `#89a4de` | 137 164 222 | repo identity dot |
| repo-d | `oklch(0.72 0.09 320)` | `#be92c8` | 190 146 200 | repo identity dot |
| window border | — | `#2a3039` | 42 48 57 | 1px window edge (web mock; native chrome may own this) |

Repo color assignment: stable hash of repo name → one of repo-a..d; collisions acceptable.

## Fonts

Mono fallback chain (CSS: `"IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace`):

1. **IBM Plex Mono** (weights 400/500/600) — if installed
2. **SF Mono** — `NSFont.monospacedSystemFont(ofSize:weight:)`
3. **Menlo**

```swift
let mono = NSFont(name: "IBMPlexMono", size: size)
    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)  // SF Mono
    ?? NSFont(name: "Menlo", size: size)!
```

UI sans = system SF Pro stack (`NSFont.systemFont`). Doc headings use SF weight 650 (h1) /
600 (h2); 650 is expressible in WKWebView CSS (variable SF); native chrome uses `.semibold`.

## Type scale (px)

| px | Use |
|---|---|
| 9.5 | caps labels (weight 500, letter-spacing 0.12em) |
| 10 | kbd chips (weight 500), toast body |
| 10.5 | status bar / meta / tile & terminal-tab labels |
| 11 | rail/sidebar items, peek header path, toast title |
| 11.5 | doc tabs |
| 12 | terminal body, doc inline/fenced code |
| 13.5 | doc body (sans, line-height 1.75) |
| 14.5 | doc h2 |
| 21 | doc h1 (weight 650, letter-spacing −0.01em) |

## Radii (px)

4 kbd · 5 session chip · 6 doc tab · 7 dock icon, link hint · 8 fenced code, strip row ·
9 tiles, toast · 10 window · 12 cards/palette · 999 pill.

## Window / desk

- Backdrop: bg0 `#0c0e12`. Window radius 10px, 1px `#2a3039` border (web mock values).
- Titlebar 40px, bg1, 1px line-soft bottom hairline.
- Status bar 27px, bg1, 1px line-soft top hairline; mono 10.5px faint; padding 0 12px.
- Desk grid: 12px padding, 10px gap, bg0.

## Terminal

- Background `#0a0c10` (term-bg).
- Body padding **12px 16px**; font mono **400 12px / 1.75** (21px line box).
- Default output color muted `#8c93a0`; emphasized text `#d8dbe2`; dim `#5a616d`;
  accents agent/ok/amber per tokens.
- Cursor: 7×13px block, agent cyan at 0.9 opacity, 1s steps(1) blink.
- Tabs (M1+): mono 10.5px, padding 5px 10px 7px, radius 6 6 0 0; active tab bg term-bg +
  1px line-soft border, shifted down 1px to join the body.

## Peek panel

- Width **47%** of the desk by default; user-resizable **36–62%**. Anchored right, full
  height of the main row, z-order above desk.
- Body bg1; border-left 1px line `#262c36`.
- Shadow: `-26px 0 60px rgba(0,0,0,0.55)` (offset x −26 y 0, blur 60, black @ 55% = `#0000008c`).
- Slide-in: `translateX(102%) → 0`, **220ms `cubic-bezier(0.2, 0.8, 0.2, 1)`**; no animation
  under Reduce Motion.
- Header: **36px**, bg2, 1px line-soft bottom border, padding 0 12px, item gap 8px,
  mono 400 **11px**, color muted. Contents left→right:
  - 7px repo dot (round)
  - full doc path (e.g. `payments-api/docs/handoff.md`)
  - honest meta in agent cyan at **85% opacity** (e.g. `✎ 5s · during claude`)
  - right-aligned group (gap 6px, mono 10px faint): kbd chips `⌘⏎ pin` and `esc`
- kbd chip: mono 500 10px, color muted, bg2, 1px line border with **2px bottom edge**,
  radius 4, padding 1px 5px; hover bg3 + text color, clickable.
- Body: WKWebView hosting `docs/archive/m0/DocTemplate.html`, bg1.
- **Focus rule: opening a peek never moves keyboard focus out of the terminal.** `esc` dismisses.

## Toasts

- Position: bottom-right inside the window — right **14px**, bottom **38px**; vertical stack,
  gap 8px, right-aligned; **max 3** stacked.
- Auto-dismiss **7s**; `esc` clears.
- Entry: **180ms `cubic-bezier(0.2, 0.8, 0.2, 1)`**, `translateY(8px) → 0` + fade 0→1;
  none under Reduce Motion.
- Box: bg2, 1px line border, radius **9px**, padding 9px 12px,
  shadow `0 10px 28px rgba(0,0,0,0.5)`.
- Content: icon agent cyan 13px · title mono 11px text · body mono 10px faint (2px top
  margin) · kbd chips (gap 5px, 6px left margin).
- M0 uses: doc opened via CLI; first-doc moment (`first doc · <path>` + `⌘P peek`).

## Doc viewer (DocTemplate.html)

- Page bg bg1 `#12151a`; column max-width 720px centered, padding 26px 36px 72px.
- Body sans 400 **13.5px / 1.75**, color text; paragraphs/lists `#b9bec8`.
- h1 21px/650 (ls −0.01em); h2 14.5px/600 + 1px line-soft underline (5px gap).
- Inline code: mono 400 **12px**, bg2 chip, 1px line-soft border, radius 4, padding 1px 5px.
- Fenced code: term-bg, 1px line-soft border, radius 8, padding 13px 16px,
  mono 400 12px/1.7, color muted.
- Links: agent cyan, no underline decoration, 1px dashed bottom border at 45% alpha;
  hover: solid border + agent-dim tint, radius 3.
- Tables: 12.5px, collapsed 1px line-soft borders, 6px 10px cell padding, th on bg2.
- Blockquote: 2px line `#262c36` left border, 14px indent, muted. hr: 1px line-soft.
- Changed-section mark `.tm-changed`: 2px agent left border, −14px margin / 12px padding pull,
  horizontal agent-dim gradient fading to transparent at 55%, radius 0 6 6 0.
- `window.tarmacRender(mdText)` re-renders and preserves scroll position
  (records `scrollTop`, swaps innerHTML, restores). Zero network requests (marked.js inlined).

## Motion summary

| Motion | Spec |
|---|---|
| peek slide | 220ms `cubic-bezier(0.2, 0.8, 0.2, 1)` |
| toast entry | 180ms same curve, +8px rise + fade |
| file-change pulse | 2.4s ease-out halo, ×3 max (~30s noticeable), then static |
| blink (spinner/cursor) | 1.3s ease alternate / 1s steps(1) |

All gated on Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`).
