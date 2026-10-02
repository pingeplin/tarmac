# HTML card manual QA checklist (spec 2607.0004)

Companion to `sandbox-probe.html` (S18). These are the [QA]-tagged scenarios the
unit suites cannot cover (DOM/webview behavior; see repo testing convention).
Run against `make run` with a fresh dev daemon (`make kill-daemon` first).

Setup: in a Tarmac terminal, create a self-contained HTML file with inline JS
(e.g. a Canvas animation that also calls `console.log` during initial script
execution and on a timer), then `tarmac open <file>`.

## S6 — live render, fresh open

- [ ] The card lands next to the opening terminal with a dashed provenance edge.
- [ ] The content animates (JS is running), at every zoom level.
- [ ] Crisp at rest after a zoom settles (no persistent blur; brief softness
      mid-gesture is expected).
- [ ] No `read_doc` fetch for the file: `console.log` a marker in the Vite
      devtools or breakpoint `read_doc` — the html path must never trigger it.

## S7 — console capture, in order, from first byte

- [ ] Every `console.log/info/warn/error`, uncaught `throw`, and unhandled
      rejection in card JS appears in the card's console strip, in order.
- [ ] Logs issued during initial script execution are present (proves the shim
      ran before the file's own script).
- [ ] The header badge count equals the number of buffered entries; clicking it
      toggles the strip, entries shown in the same order.

## S11 — shielded card is look-don't-touch

- [ ] Press on the body: selects/raises the card (focus ring), nothing reaches
      the iframe content (no hover/click effects inside).
- [ ] Drag the header: moves. Drag a handle: resizes.
- [ ] Plain wheel over the card: no board pan AND no iframe scroll; ctrl+wheel
      still zooms the board.
- [ ] With the card selected, typing goes to the prime terminal; `⌥Tab` cycles
      terminals only, never the card.

## S12 — borrow and one-keypress Esc home

- [ ] Double-click the body: shield drops, amber borrow ring shows (visually
      distinct from the teal selection and fresh rings), card content is now
      clickable/scrollable/typeable.
- [ ] With focus **inside the iframe** (click into it first), press Esc once:
      shield restores, ring clears, prime terminal has keyboard focus.
- [ ] Borrow again, click the host chrome (e.g. board background), press Esc
      once: same result via the App Esc ladder.

## S13 — live reload drops in-page state

- [ ] Mutate JS state in the card (e.g. a counter), rewrite the file on disk:
      the card fully reloads within the daemon's 100ms debounce window, with a
      new `?v=<mtime>` (inspect the iframe src), and the mutated state is gone.
- [ ] A markdown card alongside keeps its scroll position on rewrite; the HTML
      card has no scroll persistence.

## S14 — restore routes by extension

- [ ] With an `.html` doc tile on the board, quit and relaunch the app: the card
      mounts as a live HtmlCard (running JS), not a markdown card, and no
      `read_doc` is issued for it.

## S19 — non-cloneable console args don't wedge the relay

- [ ] `console.log(function f(){}, window.document.body, (()=>{const o={};o.self=o;return o})())`
      in card JS: the entry lands as string placeholders (`function…`,
      `[BODY]`, `{"self":"[circular]"}`), no error, and subsequent
      `console.log("still alive")` still arrives.
