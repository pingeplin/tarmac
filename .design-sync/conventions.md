TarmacKit is the real Tarmac desktop-app UI, bundled as-is — 10 board-chrome
components, no rewrite. Two groups: `cards/` (`CardShell`, `DocCard`) and
`general/` (`BoardSwitcher`, `CycleHud`, `DockPane`, `MinimapOverlay`,
`OffscreenHints`, `StatusBar`, `ToastOverlay`, `ZoomControl`).

## Wrapping every component needs

None of these 10 are self-contained widgets — they're board chrome, and most
position themselves against their nearest positioned ancestor (`CardShell`/
`DocCard` fill it via `inset: 0`; `ZoomControl` pins `left/bottom: 12px`;
`BoardSwitcher`'s veil is `inset: 0` with a panel centered via
`top: 50%` + `translate(-50%,-50%)`). That collapses to nothing against a
zero-size ancestor. Always give a component an explicitly sized, positioned
host:

```html
<div class="board" style="position: relative; width: 360px; height: 520px;">
  <!-- component renders here -->
</div>
```

`class="board"` is DOM-shape parity only, not styling — the kit stylesheet
ships **zero** `.board` CSS by design (`src/theme/kit.css`'s @import closure
is tokens + card + chrome + preview-defaults only, no app-only.css
board-engine/world-layer/terminal rules). Supply `position: relative` plus a
real width/height yourself, sized to what the component needs (a card wants
its own frame size; a HUD wants clearance around its pinned corner).

## Runtime

React 19, no build step required on your side. Load once:

```html
<link rel="stylesheet" href="styles.css">
<script src="_ds_bundle.js"></script>
```

Every component lands on the single global `window.TarmacKit` (also carries
a `mount(name, props, el)` helper). Mount into your own dedicated node, not
the host page's React root:

```jsx
const { BoardSwitcher } = window.TarmacKit;
ReactDOM.createRoot(document.getElementById('ds-root')).render(<BoardSwitcher />);
```

None of the 10 read from React context — no router, i18n, or theme provider
needed.

## Styling idiom

Breeze tokens: CSS custom properties, not a utility-class system. Reach for
these (all defined in `_ds_bundle.css`, verbatim from `src/theme/tokens.css`):

- Backgrounds: `--bg0` `--bg1` `--bg2` `--bg3` `--term-bg`
- Borders/rings: `--line` `--line-soft` `--line-muted` `--lift-border` `--focus-border`
- Text: `--text` `--muted` `--faint`
- Accents/status: `--agent` `--agent-dim` `--amber` `--amber-dim` `--ok`
- Shadows: `--shadow-card-rest` `--shadow-card-prime` `--shadow-card-lift` `--shadow-hint` `--shadow-toast`
- Chrome font: `--chrome-font` (`"IBM Plex Mono", ui-monospace, SFMono-Regular, monospace`)

No spacing-scale token exists — the only layout var is `--grid-size: 24px`
(the board's background grid pitch, not a general spacing unit). Use plain
px for custom glue.

Component styling is class-based BEM-ish (`.card`, `.dock-pane`,
`.doc-card`, `.switcher-panel`, `.zoom-control`, `.tm-toast`, …) — don't
invent new component classes. Compose with the shipped components; reach for
token vars only for glue around them (the wrapper div above, spacing between
cards, etc.).

## Where the truth lives

`styles.css` is the real stylesheet closure (`@import`s `fonts/fonts.css`
then `_ds_bundle.css`) — link that one file, nothing else. Per-component
detail lives in `components/<group>/<Name>/<Name>.prompt.md` (usage) and
`<Name>.d.ts` (props contract) — read both before composing with a component
you haven't used yet.

## Idiomatic example

From `DocCard`'s `Selected` story (graded good):

```jsx
const { DocCard } = window.TarmacKit;

<div className="board" style={{ position: "relative", width: 360, height: 520 }}>
  <DocCard
    model={{
      kind: "doc",
      path: "/Users/dev/tarmac/docs/README.md",
      frame: { x: 0, y: 0, w: 360, h: 520 },
      z: 1,
      ownerTermId: "term-1",
      repoColor: 2,
      fresh: false,
      attached: true,
    }}
    markdown={readmeMarkdown}
    ownerName="agent-1"
    lastChangedMs={Date.now() - 4000}
    selected
    getZoom={() => 1}
    onMove={() => {}}
    onGrab={() => {}}
    onClose={() => {}}
  />
</div>
```
