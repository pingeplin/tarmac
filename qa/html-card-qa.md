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

## S18 — the sandbox probe

- [ ] `tarmac open qa/sandbox-probe.html`: the card reads
      `VERDICT: SEALED (0/11 escapes)`.
- [ ] A listener on `127.0.0.1:8737` that is up before the card opens gets no
      connection while the card loads.

**Run:** 2026-10-10 (#234), macOS 26.7, debug builds of `72b4c43` from
`make run DEV_DIR=<new dir under .dev/>`. The listener logged each TCP
connection, also one with no bytes. A new load of the card was made by a write
of the file, with a run number in the heading.

| Build | Probe | Loads | Verdict on the card | Connections |
| --- | --- | --- | --- | --- |
| `72b4c43` | before #234 | 6 | `LEAKY (1/11 escapes)`, the one is `navigator.sendBeacon`; read on loads 1, 3 and 6 | 0 |
| `72b4c43` | after #234 | 4 | `SEALED (0/11 escapes)`; read on loads 1 and 4 | 0 |
| `72b4c43` + `connect-src http://127.0.0.1:8737` in `CardProtocol.csp` | after #234 | 2 | `LEAKY (3/11 escapes)`: fetch, XMLHttpRequest, sendBeacon; read on load 2 | 3 on each load: `GET /probe-fetch`, `GET /probe-xhr`, `POST /probe-beacon` |
| the same | before #234 | 1 | `LEAKY (3/11 escapes)`, the same three | the same 3 |

So no request left the card, and the old verdict was wrong: WebKit's
`sendBeacon` returns `true` also when the content policy refuses the request.
The probe now reads the refusal from the `securitypolicyviolation` event
(`connect-src`). The third row is the control: with the policy opened for that
one origin the listener gets the beacon, and the probe still calls it an escape.
The policy change was local and was taken out again.
