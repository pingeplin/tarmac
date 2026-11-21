# Tarmac for coding agents

Tarmac is a terminal-first macOS cockpit. You run inside a real terminal on an
infinite, pannable, zoomable **board**. When anything runs `tarmac open <path>`,
that file surfaces as a live **card** next to the terminal that opened it, joined
by a dashed provenance edge.

Nothing here parses your output or infers your intent. A card appears because a
process called `tarmac open`; it pulses because the file's mtime changed. The
file is the entire interface.

This guide covers how to surface a file, how to say that you are blocked or
done, how to let the user resume your session after a restart, how to wait on what Tarmac sees,
how to open another terminal card, and how to write an HTML file that survives the board's sandbox and zoom model.
Read the part you need. Read all of *HTML cards* before you write one: a page
that breaks its rules fails with no error.

## Your terminal

Inside a Tarmac terminal the environment carries `TARMAC_TERM_ID`, your
terminal's id. Tarmac sets it; you do not. `report` and `resume` need it.
`open` and `term new` use it to join the new card to yours. Outside Tarmac it
is not set.

A shell in a Tarmac terminal inherits the daemon's open file limit, so
`ulimit -n` there is at least 10240 unless the hard limit is lower, not
launchd's 256. For another value, set `ulimit -n` in the shell's start-up file.

## Surfacing a file

```sh
tarmac open <path>
```

Fire-and-forget: it connects, names the doc, and exits. Rules:

- The path must be an **existing regular file**. A relative path works.
- Exit status: `0` the card was created, `1` rejected or no Tarmac running,
  `2` bad usage. A non-zero exit is never fatal to your work — Tarmac may simply
  not be running. Do not abort a task because `tarmac open` failed.
- Running it again on the same path does **not** duplicate the card.
- Inside a Tarmac terminal, `TARMAC_TERM_ID` (see *Your terminal*) attributes
  the card to your terminal and draws the provenance edge.
- `TARMAC_SOCKET` overrides the socket location. You rarely need it.

Open a file when it is worth a human's glance: a plan, a findings report, a diff
summary, a chart. Prefer one substantial card over a stream of small ones.

**Rewriting the file is the update path.** Write to the same path again and the
card reloads and pulses cyan. There is no update command, no partial patch, and
no need to re-run `tarmac open`. An HTML card can also take new data with no
reload: see *Data from a file* and *Events from a producer* below.

## Reporting blocked or done

```sh
tarmac report blocked ["<text>"]
tarmac report done ["<text>"]
tarmac report clear
```

Run inside a Tarmac terminal, it shows a small chip in that terminal card's
header: amber for `blocked`, green for `done`. The chip says when the report
came; the edge pill and the inbox quote your text. Tarmac does not claim who
sent it. Rules:

- The text is optional, at most 280 characters (a longer one is cut with `…`).
  It is shown as a quote. The edge pill and the inbox row draw its inline
  markdown on one line (**bold**, *italic*, `code`, a link's text), and the
  inbox's preview pane shows the whole text with its paragraphs, headings,
  lists and code blocks.
- It needs `TARMAC_TERM_ID`: outside a Tarmac terminal it exits `1` and sends
  nothing. Exit status otherwise as for `open`: `0` sent, `1` refused or no
  Tarmac running, `2` bad usage (`clear ""` is plain `clear`, not an error).
- A new report replaces the last one and is unread again; the user's next key
  in that terminal dims it.
- The report lasts while the process it belongs to runs. From a hook or a tool
  call of an agent, that is the agent: the chip goes within a second of the
  agent's exit. Typed at the prompt, it is the shell: the chip goes at the next
  command that runs for longer than 750 ms (a quicker one, such as `ls`, is not
  seen). `clear` removes it at once.
- Reports are not saved: a Tarmac restart forgets them.

## Reports from Claude Code

The user runs `tarmac hooks install` once. Both `install` and `uninstall`
change Claude Code's own settings, so leave them to the user. `install` adds
four hooks to those settings,
each a call to `tarmac hooks run claude || true`, and from then on every Claude
session in a Tarmac terminal reports on its own:

- a permission prompt (also a question or a plan to approve) shows `blocked`,
  with Claude's notification text;
- the end of a turn shows `done`, with the start of Claude's last message;
- the next prompt clears the chip;
- the start of a session records `claude --resume <session_id>` as the
  terminal's resume command (see *Resuming after a restart*).

The text is a claim, shown in quotes, cut to 280 characters with its line
breaks folded. Outside a Tarmac terminal the hooks do nothing. `tarmac hooks
status` shows whether the hooks are in place, and the first `tarmac` on the
`PATH` of `status` itself; a hook sees the `PATH` that `claude` started with,
which is the same only when both started from the same shell. `tarmac hooks
uninstall` removes them. You do not need to call `tarmac report`
yourself from Claude Code once the hooks are installed.

## Resuming after a restart

```sh
tarmac resume set "<command>"
tarmac resume clear
```

Run inside a Tarmac terminal, `set` records the command that resumes the agent
session running there. While the agent runs, the card shows a `resume` chip in
its header; a click copies the command. If Tarmac restarts while that agent
still runs, the terminal comes back in its folder, and the restore card and a
panel on the card offer the command; it runs only when the user chooses
`resume` there. Rules:

- The command is one line of at most 256 characters, with no control or
  invisible characters; any other is refused with exit `2`.
- It needs `TARMAC_TERM_ID`, as `report` does. Exit status as for `report`.
- It lasts while the process that set it runs: from an agent's hook, the agent.
  The agent's exit, or the terminal's, drops it.
- A later `set` replaces it; `clear` removes it. After a restart the user's
  choice, or the first key typed in that terminal, uses or drops the offer, once.
- The Claude Code hooks set it for you at each session's start.

## Waiting on Tarmac's facts

```sh
tarmac terms
tarmac events [--term ID] [--kind exit,bell,changed,report]
tarmac wait --exit ID [--timeout MS]
tarmac wait --bell ID [--timeout MS]
tarmac wait --report blocked|done --term ID [--timeout MS]
tarmac wait --changed PATH [--settle MS] [--timeout MS]
```

They read what Tarmac already sees (a terminal's exit, a bell, a doc change, a
report) and work from any shell, inside Tarmac or not. Your own terminal's id
is `$TARMAC_TERM_ID`; `tarmac terms` names the others:

```
{"term":"t7","board":"board-1","cwd":"/w/api","proc":"cargo"}
```

One line per live terminal, in board order, then by id as text (`t10` comes
before `t2`). `cwd` and `proc` are left out when Tarmac could not read them.

`tarmac events` prints one JSON line per fact until it is killed:

```
{"event":"exit","term":"t1","board":"board-0","code":3,"received_ms":1700000000123}
{"event":"exit","term":"t1","signal":true,"received_ms":...}
{"event":"bell","term":"t1","board":"board-0","received_ms":...}
{"event":"changed","path":"/abs/a.md","mtime_ms":1700000000000,"received_ms":...}
{"event":"report","term":"t1","board":"board-0","kind":"blocked","text":"May I?","proc":"claude","at_ms":1700000000000,"read":false,"received_ms":...}
{"event":"report","term":"t1","received_ms":...}
```

The last line is a report that went away. `board` is there when Tarmac sent it.
With `--term`, the terminal's current report and, for one that ended, its exit
come first, with `"snapshot":true` after `event`.

`tarmac wait` ends at one fact:

- `--exit ID` prints `{"code":3}`, or `{"signal":true}`; at once for one of the
  last 64 terminals that ended.
- `--bell ID` prints nothing.
- `--report KIND --term ID` prints `{"kind":...,"text":...,"proc":...,"at_ms":...,"read":...}`.
- `--changed PATH` prints `{"deleted":false}` or `{"deleted":true}`.

Exit status: `0` the fact came, `1` a failure (the line on stderr says which),
`2` usage, `124` the `--timeout` ran out.

Hazards:

- **`changed` covers open docs only**, and their data files: those on the
  active board, as Tarmac looks at them. A change of a doc on a board in the
  background comes when that board is shown. `changed` can repeat an
  `mtime_ms`: compare it with the last one you saw for that path.
- **`--term` alone gives no `changed` events.** A doc change has no terminal;
  `--term` with `--kind changed` is a usage error.
- **A report that ends at its terminal's exit has no `report` line.** Take
  `exit` with `report`. So a `wait --report` that starts after "report done,
  then exit" exits 1 with `terminal <id> exited`: Tarmac forgot the report at
  the exit.
- **`wait --report` takes a current report**, read or unread. In a loop, the
  same report returns at once on each pass: compare `at_ms` with the last one
  you saw.
- **`events | head -1` waits for the next event** after the first line: a
  closed pipe is seen only at the next write. `events` then exits 0.
- **Pass `--timeout` in an unattended script.** Each waiting `events` or `wait`
  holds one of the daemon's file descriptors.
- **`wait --changed` stats the file itself**, so it adds no watch to Tarmac.
  The stat runs in a helper process, so `--timeout` and Ctrl-C end the wait
  even on a volume that stopped answering. A helper stuck on such a volume can
  stay until the volume gives up.
- An older Tarmac does not answer these verbs: they exit 1 after 5 s, or `124`
  with a shorter `--timeout`. `wait --changed` works with any.

## Opening another terminal card

```sh
tarmac term new [--cwd DIR] "<command>"
```

Opens a terminal card beside yours, with a dashed edge from your card, and
types the command into its login shell. The shell stays after the command
ends. It prints the new terminal's id:

```
{"term":"t9"}
```

Open every new terminal with `tarmac term new`. Do not open Terminal, iTerm or
another window with `open -a` or `osascript`: that terminal runs outside
Tarmac, so the user does not see it on the board, and Tarmac cannot report its
exit, its bell or its agent's reports. Use a card for work the user should
see, or work that runs on its own: a second agent session, a dev server, a
long build or a watch. A short command whose output only you need runs in your
own shell. Open one card for each task, not one for each step.

The folder is yours, or `--cwd DIR` (a relative one is taken from yours). The
card goes on your terminal's board; outside Tarmac, on the active board. Your
card stays prime and keeps the keys. With `wait`, one agent can start a second
and wait for it:

```sh
id=$(tarmac term new "claude 'review the diff in this repo'" | jq -r .term)
tarmac wait --report done --term "$id" --timeout 3600000
```

Exit status: `0` the terminal runs and the command is typed when its shell
takes keys, `1` a refusal or a failure (the line on stderr says which), `2`
usage or a command that is refused.

Hazards:

- **One line, at most 4096 characters**, with no control or invisible
  characters. Give a long prompt by file:
  `tarmac term new 'claude "$(cat brief.md)"'`.
- **After `the app did not answer`, the card can still open.** Run
  `tarmac terms` before you retry, or you get two.
- **A board must be ready in the app.** It must have been shown once since
  the app started, and once more after the app reconnects to Tarmac, for a
  board in the background. Else: `board <id> is not ready in the app; show it,
  then retry`. Show that board, then run the command again.
- **The edge lasts for this app run.** After a relaunch the card is a plain
  terminal. It does not move when your card moves.
- **There is no limit on cards.** A loop that calls it fills the board.

## What renders how

| File | Rendered as |
| --- | --- |
| `.html`, `.htm` | A live, script-executing card in a sandboxed iframe |
| anything else | Markdown prose (`.md`, `.txt`, and every other extension) |

Extension decides, nothing else. A `.json` file is rendered as markdown, not
pretty-printed.

### Markdown cards

Ordinary markdown, rendered into the app's own DOM. Tables, code blocks, and
lists all work. Local images load from disk, whether the image source is relative
to the markdown file, an absolute path, or a `file://` URL. Scroll position is
preserved across rewrites, so a card the user is reading does not jump when you
update it.

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
  including Google Fonts. Put the CSS in an inline `<style>`, and take the
  text font from the user's (below) or from a system font stack. A custom font
  must be a `data:` URI.
- **No network requests.** `fetch`, `XMLHttpRequest`, `WebSocket`, and
  `sendBeacon` are all blocked. Embed your data in the file as a literal, or
  put it in a JSON data file in the card's directory (below).
- **No storage.** `localStorage`, `sessionStorage`, cookies, and IndexedDB are
  unavailable at an opaque origin.
- **Images and media must be `data:` or `blob:`.** A remote image URL, or even a
  local file path, will not load. Inline small images as `data:` URIs; prefer
  drawing with SVG.

So: one `.html` file, no assets directory, no build step. If you need data in
the chart, serialize it into a `const` at the top of the script, or, for data
that changes, name one JSON file in the card's directory (below).

### What you get for free

- `console.log`, `console.warn`, `console.error`, uncaught exceptions, and
  unhandled promise rejections are relayed to a per-card console behind a header
  badge. Logging is a genuine debugging channel — use it.
- The card is **look-don't-touch** by default: a transparent shield keeps
  pointer input out so clicking a card never steals the user's keystrokes. The
  user double-clicks to borrow interactivity and presses `Esc` to hand focus
  back. Scroll works through the shield without borrowing: a wheel over the
  selected card reaches the document as ordinary `wheel` events and scrolls
  whatever is under the pointer, so a handler that zooms or pans on wheel runs
  on a card that is selected and not borrowed. Tarmac draws the scroll
  position itself, for the document's root: let the page itself scroll, not a
  full-height inner element, or the card has no scroll thumb.
- The card **follows Tarmac's theme** unless you state a scheme. A document
  that says nothing about colour gets the system's dark page with light text
  under the dark theme, and a white page with dark text under the light one;
  `prefers-color-scheme` reports the theme, and a change reaches a loaded
  card with no reload. So set **both** the background and the text colour,
  or **neither**: a page with only `color: #222` is dark text on a dark
  page. To keep one look in both themes, state it:
  `:root { color-scheme: light; }` (or `dark`).
- Cards scrolled far off-viewport are **paused**: `requestAnimationFrame`,
  `setTimeout`, and `setInterval` stop firing. On return, held timeouts and
  frames flush once — an animation gets a **single** catch-up frame, not one per
  frame missed, and missed interval ticks are dropped entirely. Drive animation
  from the timestamp the frame callback receives, never from a counter you
  increment yourself, or a paused card will fall behind and stay behind.

### Standards mode or quirks mode

Tarmac gives your file the mode a browser gives it. A file that starts with a
doctype is in **standards mode**. A file with no doctype is in **quirks mode**.
So start the file with `<!doctype html>`. A comment, white space or a byte order
mark before the doctype is fine.

In standards mode:

- `body` is as tall as its content. `height: 100%` on a child of `body` needs
  `html { height: 100% }`.
- A table cell inherits the font size of the page.
- A unitless length, such as `width: 100`, is ignored.
- `document.body.scrollTop` does not scroll. Use `window.scrollTo`, or scroll
  `document.scrollingElement`.

Tarmac adds its own script before your first element, and the browser makes a
`<head>` for it. So attributes on your own `<head>` tag are dropped.
Attributes on `<html>` and `<body>` are kept.

### The user's fonts

The user picks a reading font, a code font and a reading size in Tarmac's
Settings. A card can follow them. Tarmac sets three CSS custom properties on
the document's root before any of your script runs, and changes
them in place, with no reload, when the user changes a setting:

| Property | Holds |
| --- | --- |
| `--tarmac-prose-size` | The reading size (Settings: Document size), a length in px (`14px` with nothing chosen). |
| `--tarmac-prose-font` | The reading font (Settings: Document), a `font-family` list that ends in the system sans-serif stack. |
| `--tarmac-mono-font` | The code font (Settings: Interface), a `font-family` list that ends in the system monospace stack. |

This is opt-in. A page that does not use the properties is not changed.

```html
<style>
  body {
    font-family: var(--tarmac-prose-font, ui-sans-serif, system-ui, sans-serif);
    font-size: var(--tarmac-prose-size, 14px);
  }
  code, pre { font-family: var(--tarmac-mono-font, ui-monospace, monospace); }
</style>
```

- **Give every use a fallback**, as above. Outside Tarmac (a browser, a
  preview) the properties are not set, and a use without a fallback is invalid.
- **Do not set these three names yourself.** Tarmac's value comes last, so a
  `:root { --tarmac-prose-size: ... }` or `html { ... }` rule of yours is
  ignored. To keep a value of your own, give it a name of your own.
- **A size in `rem` follows the reading size** if you set
  `:root { font-size: var(--tarmac-prose-size, 14px); }`. A layout with fixed
  `px` widths does not reflow when the size changes.
- A script can read a value at any time:
  `getComputedStyle(document.documentElement).getPropertyValue("--tarmac-mono-font")`.
- Tarmac adds up to three stylesheets (the media cap below, this one, and in
  a magnified card the list-marker sheet below), last in
  `document.styleSheets`, and they have no `ownerNode`. A script that loops
  over the sheets must check for that.

### Zoom: design for magnify

Board zoom is a **view transform, not a reflow**. HTML cards default to
**magnify**: the document lays out exactly once, at a frozen 3× reference, and
every subsequent board zoom is a pure `scale()` on the result. Layout runs once,
so a wrap point can never move and text can never reflow under the user's hands.

What follows from that:

- **Your canvas is the card.** A default card is **392 × 310** CSS pixels, and
  that is what ordinary layout resolves against: `width: 50%` fills half the
  card, and `px`, `rem`, and font sizes all behave normally — 15px text looks
  like 15px.
- **But `vw`, `vh`, `window.innerWidth`, and media queries report three times
  that.** The frozen reference is a real viewport 3× the card, so `100vw` is
  about 1176px on a 392px-wide card and overflows it badly, and
  `@media (min-width: 1000px)` matches on a card barely wider than a phone.
  **Lay out with percentages; never size anything in `vw`/`vh`, and do not write
  breakpoints.** This is about queries of size: a
  `@media (prefers-color-scheme: dark)` query is safe. If you need the card's width as a number, measure a full-width
  block element's `offsetWidth`: a plain `<div>` reports the card, while
  `innerWidth` reports the reference.
- **Tarmac draws the markers of plain lists.** At the frozen zoom, WebKit
  draws an `li`'s own marker, and the item's first line, too far to the left.
  So in a magnified card Tarmac marks each item whose marker it can draw
  (`data-tarmac-marker="disc"`, `"decimal"`, …) and draws that marker as the
  item's `::before`. Numbers keep `start`, `reversed` and `value`. Tarmac
  leaves alone a list you style yourself: `list-style: none`, your own
  `li::before`, `li::after` or `li::marker` content, a marker type other than
  the usual bullet, number, roman, latin and greek ones, an image or `inside`
  marker, a right-to-left or vertical list. Those keep WebKit's own marker, if
  they have one, too far left. A `li::marker` rule does not reach a marked
  item: to colour the marker, style `li::before` (with no `content`) as well.
- **Layout runs once, so nothing about the viewport changes.** `resize` and
  `ResizeObserver` fire at load and then effectively never again. Read
  dimensions at startup if you must; do not build a layout that waits for them
  to change. Resizing a card is the one thing that does re-lay it out.

**Layout that reads well at any card width.** A card can be 392 px wide or as
wide as the screen. Two rules keep a report readable at both, with no media
query:

```css
main { max-width: 1080px; margin: 0 auto; }
.duo {
  display: grid; gap: 20px; align-items: start;
  grid-template-columns: repeat(auto-fit, minmax(min(330px, 100%), 1fr));
}
.duo svg { display: block; width: 100%; height: auto; }
```

- **Cap the main column.** On a wide card, text that runs the full width is
  hard to read. `main` stops at 1080 px and stays in the middle.
- **Put a chart beside its text with `.duo`.** Where `main` has room for two
  330 px columns and the gap, the text and the chart sit side by side; on a
  narrower card they stack, the chart below the text. The grid decides from
  the width of `main` (the card's width, less your padding, at most 1080 px),
  so it is right at every board zoom. A media query would see the 3×
  reference instead (see above).

**Media are at most 560 px wide.** A wide image or chart is hard to read on a
wide card, so Tarmac caps the width of media:

- Every `img`, `canvas`, `video`, and `svg` with a `viewBox` is at most 560 px
  wide, and never wider than its container. The cap applies to a medium you
  set to `width: 100%` too.
- A capped medium is scaled, not cropped: it keeps its ratio. An `svg` with no
  `viewBox` cannot scale, so Tarmac does not cap it.
- To lift the cap, set `max-width` on the element: `max-width: none`, or
  `max-width: 100%` to fill its container. Any selector works (`img`, a class,
  an id, an inline `style`), but not `:where()`.
- With `main` at 1080 px, each `.duo` column is narrower than 560 px, so the
  `.duo` chart above needs no change. A chart that must fill the full width of `main` needs the lift:
  `.wide svg { max-width: 100%; }`.

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

### Data from a file

A card that shows data which changes, such as a dashboard you rewrite many
times a minute, can name one JSON file. Tarmac reads the file and gives the
content to the loaded document. When you rewrite the file, the document gets
the new content and is not loaded again: it keeps its script state, and the
card does not flash.

```html
<meta name="tarmac-data" content="stats.json">
<script>
  addEventListener("tarmac:data", e => render(e.detail));
  if (window.tarmac.data !== undefined) render(window.tarmac.data);
</script>
```

- **One file, in the HTML file's directory or in a directory under it.** The
  first `tarmac-data` meta in the document when it is parsed is the one read; a
  meta added later by a script is not seen. A relative name is taken from the
  HTML file's directory: `stats.json` and `data/stats.json` are both read. A
  name that leads out of that directory (`../stats.json`) is refused, and so
  is a symlink that leads out of it. A hidden name below that directory is
  refused too: no file or directory on the way may start with `.`
  (`.cache/stats.json`, `data/.stats.json`). A directory that does not exist
  yet can be made later. A directory more than one level down that is made
  one level at a time can be seen late: at the next change in a directory
  Tarmac watches, or the next load of the HTML file.
- **`tarmac:data`** is a `CustomEvent` on `window`, and `detail` is the parsed
  content. It fires after each load of the document, when the file exists
  and is valid, and after each change of the file. Tarmac does not compare the
  content with what it gave before: the same content can come again (after a
  reload, or after Tarmac reconnects to its daemon). Make the handler safe to
  run again with the same value.
- **`window.tarmac`** is defined before any of your script runs.
  `window.tarmac.data` is `undefined` until the first content comes, and then
  the last content given. If your page sets its own `window.tarmac`, it keeps
  it, and the event still fires.
- **Write the whole file each time.** Each change gives the whole file; the
  latest content wins. Changes that come faster than the watcher looks (about
  every 100 ms) give one event, with the content at the time of the read.
- **Strict JSON, at most 64 MiB.** Any JSON value is allowed at the top, with
  white space around it. Not given, and the document keeps what it has: a
  file that is not there, is not a regular file, is over 64 MiB, is not UTF-8,
  or is not strict JSON (a byte-order mark, a number too large for a double,
  more than 127 levels of arrays and objects). A refused name, and a file that
  could not be read or is not valid, is one line in the card's console. A file
  that is not there writes no line: the content comes when you make the file.
- **A card out of view gets no content.** It gets the latest content once,
  when it is back in view.

### Events from a producer

A card can also take single values, one at a time and in order, from anything
that runs `tarmac push`: a log line, a step that ended, a count.

```sh
tarmac push dash.html '{"step":"build","ok":true}'   # one value
producer | tarmac push dash.html -                    # one value per line of stdin
```

```html
<script>
  addEventListener("tarmac:push", e => apply(e.detail));
</script>
```

- **Open the file first.** A push goes to an HTML file that `tarmac open` has
  put on a board. A file that is not open is refused: `not an open doc`. A
  relative path works. A push to an open markdown file exits `0` and shows
  nothing.
- **`tarmac:push`** is a `CustomEvent` on `window`, and `detail` is the parsed
  value. The events come in the order they were sent. An event does not change
  `window.tarmac.data`.
- **No replay.** A value goes to the cards of that file that are loaded at that
  moment, also a card out of view and a card on another board. A card that is
  loading or reloading gets nothing, and so does a card on a board that was not
  shown since Tarmac started. Nothing is kept for later.
- **After a reload, take the state from a file.** A document that needs the
  whole picture reads it from its data file (`tarmac-data`, above) after each
  load, and takes the events for what comes after. The file and the events
  have no order between them: an event can come before or after the content of
  a file that was written first. Make `apply` safe for that.
- **One JSON value for each push.** Tarmac checks the text with a strict JSON
  parser: any value at the top, with white space around it, and nothing after
  it. It refuses a byte-order mark, a number out of the range of a double
  (`1e400`), an unpaired surrogate escape (`"\ud800"`), and more than 127
  levels of arrays and objects. At most 16 MiB for the whole frame: the path
  and the value together.
- **With `-`**, each line of stdin is one value, on one connection. A value
  written over more than one line is refused line by line. Blank lines are
  skipped. A refused line is one line on stderr, `tarmac: line <n>: <reason>`,
  and the stream goes on. Each line waits for Tarmac's answer before the next
  is sent, so a stream goes as fast as Tarmac takes it. The stream ends when
  the connection is lost, or when Tarmac does not answer in 5 s.
- **Exit status**: `0` the value is queued for the app, which is not proof
  that a card drew it; `1` a value was refused (with `-`, any line), no Tarmac
  is running, or no app is connected; `2` bad usage. Success prints nothing.
- A text that the card cannot parse gives no event and one error line in the
  card's console, `tarmac:push: not valid JSON`. This is rare: Tarmac and the
  browser do not agree on every text.

## Checklist before `tarmac open` on an HTML file

- [ ] One file. No external `src`, `href`, or `url()` that leaves the document.
- [ ] The file starts with `<!doctype html>`.
- [ ] All JS inline; no `eval` or `new Function`.
- [ ] Fonts: `var(--tarmac-prose-font, <system stack>)` to follow the user's, or
      a system stack. Every use has a fallback; you never set a `--tarmac-` name.
- [ ] All CSS in a `<style>` block.
- [ ] All data embedded as literals, or in one JSON file in the card's directory
      (or under it, with no hidden name) that a `tarmac-data` meta names, or
      pushed with `tarmac push`; no `fetch`.
- [ ] Images inline as `data:` URIs, or drawn as SVG.
- [ ] Sizes use `%`, `px`, `rem` — no `vw`/`vh`, no media queries of size.
- [ ] Colours: both a background and a text colour, or neither; a
      `color-scheme` if the card must keep one look.
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
  main { max-width: 1080px; margin: 0 auto; }
  h1 { font-size: 20px; margin: 0 0 16px; }
  .bar { height: 18px; background: #2f81f7; border-radius: 3px; }
</style>
<main>
<h1>Build report</h1>
<div id="out"></div>
</main>
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
