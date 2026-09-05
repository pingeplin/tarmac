# Tarmac for coding agents

> **Doc status: ACTIVE** — normative, and the only doc that is also a shipped
> product artifact: `tarmac skill` embeds this file and installs it as a
> `SKILL.md`. Everything from the title down is what an agent reads, so keep it
> self-contained — no repo-internal paths a reader outside this checkout cannot
> resolve, and no relative links.

Tarmac is a terminal-first macOS cockpit. You run inside a real terminal on an
infinite, pannable, zoomable **board**. When anything runs `tarmac open <path>`,
that file surfaces as a live **card** next to the terminal that opened it, joined
by a dashed provenance edge.

Nothing here parses your output or infers your intent. A card appears because a
process called `tarmac open`; it pulses because the file's mtime changed. The
file is the entire interface.

This guide covers the two things worth knowing: how to surface a file, and how to
write an HTML file that survives the board's sandbox and zoom model.

## Surfacing a file

```sh
tarmac open <path>
```

Fire-and-forget: it connects, names the doc, and exits. Rules:

- The path must be an **existing regular file**. It is canonicalized, so
  relative paths work.
- Exit status: `0` the card was created, `1` rejected or no Tarmac running,
  `2` bad usage. A non-zero exit is never fatal to your work — Tarmac may simply
  not be running. Do not abort a task because `tarmac open` failed.
- Running it again on the same path does **not** duplicate the card.
- Inside a Tarmac terminal the environment carries `TARMAC_TERM_ID`, which
  attributes the card to your terminal and draws the provenance edge. You do not
  set it; the app does.
- `TARMAC_SOCKET` overrides the socket location. You rarely need it.

Open a file when it is worth a human's glance: a plan, a findings report, a diff
summary, a chart. Prefer one substantial card over a stream of small ones.

**Rewriting the file is the update path.** Write to the same path again and the
card reloads and pulses cyan. There is no update command, no partial patch, and
no need to re-run `tarmac open`.

## What renders how

| File | Rendered as |
| --- | --- |
| `.html`, `.htm` | A live, script-executing card in a sandboxed iframe |
| anything else | Markdown prose (`.md`, `.txt`, and every other extension) |

Extension decides, nothing else. A `.json` file is rendered as markdown, not
pretty-printed.

### Markdown cards

Ordinary markdown, rendered into the app's own DOM. Tables, code blocks, and
lists all work. Scroll position is preserved across rewrites, so a card the user
is reading does not jump when you update it.

Board zoom never re-wraps prose: it is laid out once and scaled. Write for a
narrow column and let the user zoom.

## HTML cards

An HTML card is a **fully self-contained document** running at an opaque origin
with a strict Content-Security-Policy:

```
default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline';
img-src data: blob:; font-src data:; media-src data: blob:
```

### Hard rules

Everything below fails **silently** — no error, just a blank or broken card.

- **No external scripts.** `<script src="https://...">` is blocked. Inline every
  line of JS you need directly in the file. A CDN chart library is not
  available; write the drawing code yourself against Canvas, SVG, or the DOM.
- **No `eval`, no `new Function`.** The policy grants `'unsafe-inline'` but not
  `'unsafe-eval'`. Any library that compiles templates or expressions at runtime
  will not work.
- **No external stylesheets or web fonts.** `<link rel="stylesheet">` is blocked,
  including Google Fonts. Use an inline `<style>` and a system font stack. A
  custom font must be a `data:` URI.
- **No network of any kind.** `fetch`, `XMLHttpRequest`, `WebSocket`, and
  `sendBeacon` are all blocked. Embed your data in the file as a literal.
- **No storage.** `localStorage`, `sessionStorage`, cookies, and IndexedDB are
  unavailable at an opaque origin.
- **Images and media must be `data:` or `blob:`.** A remote image URL, or even a
  local file path, will not load. Inline small images as `data:` URIs; prefer
  drawing with SVG.

So: one `.html` file, no siblings, no assets directory, no build step. If you
need data in the chart, serialize it into a `const` at the top of the script.

### What you get for free

- `console.log`, `console.warn`, `console.error`, uncaught exceptions, and
  unhandled promise rejections are relayed to a per-card console behind a header
  badge. Logging is a genuine debugging channel — use it.
- The card is **look-don't-touch** by default: a transparent shield keeps
  pointer input out so clicking a card never steals the user's keystrokes. The
  user double-clicks to borrow interactivity and presses `Esc` to hand focus
  back. Scroll works through the shield without borrowing.
- Cards scrolled far off-viewport are **paused**: `requestAnimationFrame`,
  `setTimeout`, and `setInterval` stop firing. On return, held timeouts and
  frames flush once — an animation gets a **single** catch-up frame, not one per
  frame missed, and missed interval ticks are dropped entirely. Drive animation
  from the timestamp the frame callback receives, never from a counter you
  increment yourself, or a paused card will fall behind and stay behind.

### Zoom: design for magnify

Board zoom is a **view transform, not a reflow**. HTML cards default to
**magnify**: the document lays out exactly once, at a frozen 3× reference, and
every subsequent board zoom is a pure `scale()` on the result. Layout runs once,
so a wrap point can never move and text can never reflow under the user's hands.

What follows from that:

- **Never depend on live viewport dimensions.** `window.innerWidth`, `resize`
  events, and `ResizeObserver` fire once at load and then effectively never
  again. Read them at startup if you must, but do not build a responsive layout
  that expects them to change.
- **Media queries are decided once**, at the frozen reference size. Treat the
  card as a fixed canvas, not a responsive page.
- Percentage and viewport units work fine — they simply resolve once.

Your canvas is the **card**, not the screen: a default card is **392 × 310**, and
percentage and viewport units resolve against that. The 3× reference is a
rendering device for crispness — your CSS never sees it. Resizing a card is the
one thing that does re-lay it out.

If your document genuinely needs honest, changing viewport dimensions — a
self-contained D3 or Canvas dashboard that recomputes its scales on resize — opt
out:

```html
<meta name="tarmac-zoom" content="reveal">
```

**reveal** gives real-pixel sizing that re-lays out as the board zoom settles.
The cost is that text reflows while zooming. Only reach for it when the layout is
genuinely a function of the viewport; magnify is the right default for a report,
a table, a diagram, or a static chart.

## Checklist before `tarmac open` on an HTML file

- [ ] One file. No external `src`, `href`, or `url()` that leaves the document.
- [ ] All JS inline; no `eval` or `new Function`.
- [ ] All CSS in a `<style>` block; system font stack.
- [ ] All data embedded as literals; no `fetch`.
- [ ] Images inline as `data:` URIs, or drawn as SVG.
- [ ] Layout does not depend on resize events (or you set `reveal` deliberately).
- [ ] Animation reads the frame timestamp rather than counting frames.

## A minimal card

```html
<!doctype html>
<meta charset="utf-8">
<title>Build report</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; padding: 24px;
    font: 15px/1.5 ui-sans-serif, -apple-system, system-ui, sans-serif;
  }
  h1 { font-size: 20px; margin: 0 0 16px; }
  .bar { height: 18px; background: #2f81f7; border-radius: 3px; }
</style>
<h1>Build report</h1>
<div id="out"></div>
<script>
  const DATA = [["parse", 42], ["typecheck", 118], ["emit", 67]];
  const max = Math.max(...DATA.map(([, ms]) => ms));
  document.getElementById("out").innerHTML = DATA.map(
    ([name, ms]) =>
      `<p>${name} — ${ms}ms</p>
       <div class="bar" style="width:${(ms / max) * 100}%"></div>`,
  ).join("");
  console.log("rendered", DATA.length, "stages");
</script>
```

Write it, then `tarmac open build-report.html`.
