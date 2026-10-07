---
name: dev-channel
description: Bring up, drive, inspect and tear down Tarmac's dev channel — `make run`, the per-worktree sockets it pins, the `tarmac dev` QA driver, `make qa`, and the rules that keep a dev build from touching the user's installed app. Use when the user says "run the app", "start a dev build", "drive the app", "take a snapshot", "check the UI", "run the QA scenarios", "why is my dev app not answering", or when hand-testing anything that needs a live window.
---

# Tarmac's dev channel

A dev build and an installed Tarmac **coexist on purpose**. Everything below
exists so a dev build can be driven and inspected without ever reaching the app
the user actually works in.

## The two rules that matter

**Never `pkill tarmacd`, `pkill tarmac-app`, or `killall` anything by name.**
Every daemon is called `tarmacd`, and a `make bundle` build has the installed
app's executable name (`tarmac-app`) and bundle id (`com.tarmac.desktop`), so a
name-based kill takes down the user's real app and every terminal its daemon
owns.

- Stop the dev **daemon**: `make kill-daemon` — it resolves the pid with `lsof`
  on *this worktree's* socket and cannot touch anything else.
- Stop the dev **app**: stop the task running `make run` (the app is its
  foreground process), or kill the pid that owns this worktree's driver socket:
  `lsof -t "$PWD/.dev/tarmac-dev.sock"` (the path must be absolute).
- Addressing a window with a GUI tool: **always by pid**, never by name. The
  `make run` binary is an unbundled `TarmacApp` with no bundle id at all; its
  window title ends in ` · <worktree>`.

**Never launch `dist/Tarmac.app`, or a release build of the app, without
`TARMAC_SOCKET` and `TARMAC_STATE` pinned.** A release build resolves the
*installed* channel: it attaches to the user's real daemon and, if its version
differs, SIGTERMs and replaces it — every terminal the user has open dies with
it. `make run` is the only launch that pins them for you.

## Bringing it up

```sh
make run          # builds core + the Swift package, then runs the debug app in the foreground
```

In a fresh worktree the first build downloads the pinned libghostty-vt
XCFramework into the gitignored `app/Vendor/` (`make ghostty-vt`); nothing else
needs staging.

`make run` sets these, which is what makes a dev build harmless:

| env | what it does |
| --- | --- |
| `TARMAC_SOCKET` | the daemon socket, under `.dev/` — a dev app never joins the installed daemon |
| `TARMAC_STATE` | `state.json`, under `.dev/` — boards and layout, never the user's |
| `TARMAC_DEV_SOCKET` | the QA driver's socket, under `.dev/` (issue #166) |
| `TARMAC_CONFIG_DIR` | the config directory, `.dev/config` — its `themes/` holds the theme files a dev build reads, never the user's `~/.config/tarmac` (issue #218). A fresh channel that replaces `DEV_ENV` must set it too |
| `TARMAC_DAEMON` | `core/target/debug/tarmacd`: the daemon binary the app auto-spawns (the daemon itself never reads it) |
| `TARMAC_APP_VERSION` | the version in `core/Cargo.toml` — an unbundled binary has no `Info.plist`, and the app must name the daemon's own version or it would replace that daemon as stale |
| `TARMAC_DEV_LABEL` | the worktree name, shown as the window-title suffix — the only way to tell two dev windows apart |
| `PATH` | prefixed with `core/target/debug`, so `tarmac open` inside the app's own terminals resolves the freshly built CLI |

The app's stderr is the `make run` output. The daemon's is `.dev/tarmacd.log`,
truncated each time the app spawns one.

**There is no hot reload.** After a change, stop the app and `make run` again.
The daemon is detached and survives; the new app reconnects and re-binds the
terminals it finds alive.

**A rebuilt daemon is not picked up while the old one is alive.** The app
replaces a daemon only when its *version string* differs, and a rebuild keeps
the version. After changing anything under `core/crates/tarmacd`:
`make kill-daemon`, then `make run`.

**A screenshot without a GUI tool** (debug builds): `TARMAC_DEV_SHOT=<path.png>`
writes the window's content view to that file `TARMAC_DEV_SHOT_AFTER` seconds
after launch (default 4); `TARMAC_DEV_SHOT_QUIT=1` then quits.

## Driving it — `tarmac dev`

Debug builds only. A release CLI exits 1 with `driver unavailable in release
builds` and does not document the family at all; a release app binds no driver
socket.

```sh
tarmac dev snapshot [--until <expr>] [--timeout <ms>]
tarmac dev zoom <z>
tarmac dev resize <card> <w>x<h>
tarmac dev focus <card>|board
tarmac dev type <card> "<text>"
tarmac dev key <card> "<combo>"
tarmac dev press <combo> [--hold <ms>] [--age <ms>] [--busy <ms>]
```

Use the debug CLI with the socket pinned, or nothing will answer:

```sh
export TARMAC_DEV_SOCKET="$PWD/.dev/tarmac-dev.sock"
core/target/debug/tarmac dev snapshot | jq .
```

- `<card>` is a terminal's **term id** or a doc's **absolute path** — the bare
  wire ids.
- `snapshot` prints the active board's live state: viewport, every card's
  `board_rect` and measured `screen_rect`, `content_origin` (where the content
  coordinates `screen_rect` is in start on the display, in global top-left
  points, or `null` with no window — `content_origin` plus a point of a
  `screen_rect` is where a tool outside the app finds it, as
  `scripts/qa/wheel-gesture.swift` does; that script posts a wheel at a card
  and, after it, can move the pointer to the card's scroll thumb, press, drag
  in steps, sample the snapshot, release and type Escape —
  `--then`, `--press`, `--drag`, `--sample`, `--release`, `--stay`,
  `--key escape`: see its header), every card's `scroll` (`offset`,
  `visible` and `total` in the content's own unit — a terminal's rows, a page's
  pixels — `shown`, whether its scroll thumb is up, and `thumb`, the thumb's
  rect in `screen_rect`'s coordinates or `null` when none is laid out; the
  whole `scroll` is `null` until the content has reported, so wait with
  `--until 'cards[<id>].scroll.shown == true'`), `focused_card` (the *selected* card),
  `active_element` (keyboard focus), `fonts` (for `terminal`, `interface` and
  `document`: `saved`, the family in `app-prefs.json` or `null`, and what the
  role resolved to — the PostScript `face`, or for `document` the `css`
  value its prose is given; `terminal` and `document` also have `size`, the
  size in effect), `theme` (`choice`: `auto`, `light` or `dark`, and
  `in_effect`: `light` or `dark`, the variant of the theme in effect and
  not the choice, `name`: the id of the theme in effect, as
  `catppuccin-mocha`, or `file:<name>` for a theme from a file of the
  themes folder, `folder`: where the theme files are read from, `available`:
  the id of every theme, `refused`: each file that is no theme, with the
  reason, and `findings`: what the contrast detector found in the theme in
  effect), per-terminal
  `cols`/`rows`/`proc`/`selection`/`scrollback_tail`, per-doc-card `borrowed`
  (the HTML card whose shield is lifted), and `quit_guard` — the ⌘Q guard's hold
  on the Quit item (`retargeted`, `enabled`, which `make qa`'s D11 asserts) plus
  what it last did: `phase` (`idle` | `showing` | `confirming`), `notice`
  (`visible`, `alpha`; alpha reads 0 while not visible) and `last_press`
  (`press_ms`, `route` of `guard` | `terminate`, `age_ms`, or `null` before the
  first keyboard press).
- **`active_element` speaks DOM.** The scenario suite predates the native app,
  so keyboard focus is reported in the vocabulary it reads: a focused terminal
  is `tag: "TEXTAREA"`, `classes: ["xterm-helper-textarea"]`, `selection_type`
  `Caret` (or `Range` when the terminal has a selection); a borrowed HTML
  document is `IFRAME` / `html-frame`; anything else — the board, a markdown
  card — is `BODY`. `active_element.card` is the card holding the keys.
- Every other verb prints a small JSON object describing **what it observed**,
  not what you asked for — `zoom 99` answers `{"zoom": 3}` because the board
  clamps.
- **Replies say how the input got in.** A verb that injects input adds
  `activated` (the app had to be brought forward to take it) and, for a pointer
  press, `delivery`: `window` when the press went through the application's
  event path, hit test included; `target` when the point was off the window or
  under another view and the press was handed to the target view after the
  app's own press handling; or `handling` when the app's press handling ran for
  the card and **no click was sent** — every `focus` on a markdown card, on an
  HTML card that is already borrowed, on a culled terminal, and on a terminal
  with a link under every point the driver tries. `target` and `handling` are
  still passes; they tell you the hit test (and, for `handling`, the view's own
  mouse handlers) was not exercised.
- **The app logs each verb.** Its stderr (the `make run` output) gets one line
  per request, `tarmac: dev <request> -> <reply>` — `snapshot` excepted.
  `make qa` prints the `delivery` of every `focus` and `resize` under its
  scenario (`focus d17.md → handling`); the log has the whole reply.
- A failure prints JSON on **stderr** and exits 1: `no_such_card`,
  `not_focused`, `unsupported_card_kind`, `card_hidden`, `unsupported_combo`,
  `bad_combo`, `empty_buffer`, `unsupported_verb`, `bad_expr`, `bad_request`,
  `timeout`, `not_retargeted`, `not_key`, `app_not_ready`, `app_unresponsive`,
  `driver_threw`. CLI-side failures (no app, a too-long socket path) stay
  one-line plain text.

### Input verbs take the app forward

`focus`, `resize`, `key` and `press` — and `type` when it has to press a key —
first make the dev window key, calling `NSApp.activate(ignoringOtherApps:)` if
it is not. That **steals focus** from whatever you were using, and the reply
says `activated: true`. So **do not type in other apps while a run is in
progress** — those keys land in the dev app's focused terminal. If activation is
refused (a **locked screen** refuses every activation call) the verb answers
`not_key` after 1 s and nothing is injected: the suites need an unlocked
session. `snapshot`, `zoom` and `key <term> contextmenu` never activate.

### Typing and keying

`type` and `key` require the card to **already** hold keyboard focus — they
answer `not_focused` rather than establishing it, so a passing verb proves focus
was right. `focus <term>` establishes it (a press on the terminal's body:
select, prime, keyboard). A **culled** terminal is the exception: `focus`
selects it and makes it prime, but the keys stay where they were (its view is
hidden; `delivery: handling`), so `type`/`key` on it still answer `not_focused`
— `zoom` out first. The suite's `reset` runs `zoom 1`, `focus board`,
`focus <term>` so every scenario starts from the same state.

```sh
tarmac dev focus board && tarmac dev focus t-1
tarmac dev type t-1 $'printf hello\n'    # $'…': the CLI sends the text verbatim, so the shell must make the newline
tarmac dev key t-1 ctrl+c
```

- `type` commits printables one code point at a time through the terminal's
  text-input path (`insertText`, where an input method's commit lands), and
  sends control characters as key events: LF/CR → Enter, TAB → Tab, ESC/DEL →
  Escape and Backspace, and `\x01`–`\x1a` → their ctrl chords, so `\x03` is
  ctrl+c. (`\x00` and `\x1c`–`\x1f` have no spelling in the combo grammar and
  take the insert path.) Its reply counts what landed:
  `{"chars": 6, "inserted": 6, "dropped": [], "mode": "insert"}`. A character is
  `dropped` when its insertion left no bytes for the PTY.
- `key` takes a closed set: `enter`, `tab`, `escape`, `backspace`, the four
  arrows, a lowercase letter or digit **as the base of a ctrl/alt chord**, or
  `contextmenu`. Lowercase only. A bare printable is refused with
  `unsupported_combo` — use `type`. So are ⌘ chords: they are menu key
  equivalents, and `press` is the verb that posts one.
- A `key` goes through the app's key ladder like a real one: `key <t> escape`
  climbs the ESC ladder.
- `contextmenu` right-clicks the last written cell of the viewport, which
  selects the word under it (`selection_type` reads `Range`); no menu is popped.
  It answers `empty_buffer` when the viewport holds no text, and also when the
  program tracks the mouse and would take the right button as a report.
- **Kitty flag 8 is a trap.** A program that pushes it (`ESC[>8u`) puts `type`
  on the key path — the reply reads `"mode": "key"`, and a character no US key
  types is dropped — and while it is set, `key ctrl+c` **cannot interrupt a
  program that does not speak kitty**: the terminal encodes it as an escape code
  instead of a raw `0x03`, so no SIGINT is raised. `ctrl+d` likewise. The flags
  survive an app relaunch too, because the daemon replays the scrollback that
  set them. If a program leaves them set there is no in-band recovery; pop them
  from the program side against that terminal's tty:
  `printf '\033[>0u' > /dev/ttysNNN`.
- **⌃C, ⌃F and ⌃R stop working through `key` once the Window menu is filled
  in.** macOS adds tiling items to it (Fill ⌃F, Center ⌃C, Return to Previous
  Size ⌃R, each with the 🌐 key). They are filled in when a second window is
  shown — the Settings window, ⌘, — or when the Window menu is read through
  Accessibility. From then on, in that app process, a `key <term> ctrl+c`
  runs *Center* and never reaches the PTY, and `ctrl+f` resizes the window to
  the screen. A real keyboard is not affected, and neither are other chords.
  So drive the Settings window (`scripts/qa/settings-window.swift`) after
  `make qa`, or relaunch between them.
- `resize` drags the bottom-right handle in board units and reports where the
  card landed, clamped to the 160×90 minimum:
  `{"from": {...}, "to": {"w": 800, "h": 600}, "delta_px": {...}}`.
  The press on the handle selects the card like any press on it, so a visible
  terminal card also takes the keys; a culled card is resized and the keys stay
  where they were.
- `focus <doc card>` works too (#183), and never clicks inside a document: a
  markdown card is selected and the keys drop to the board (`BODY`,
  `delivery: handling`); an HTML card is selected, **borrowed** by a
  double-click on its shield (`delivery` `window` or `target`;
  `cards[].borrowed` true) and its document focused (`IFRAME`). A card that is
  already borrowed has no shield left, so it is handed the keys with no click
  (`delivery: handling`). Two things to know:
  - a **culled** HTML card is refused with `card_hidden` — its web view is
    hidden and cannot take focus. `zoom` out, or pan by hand; no verb pans;
  - a borrowed card **stays borrowed** after focus moves away, and the next Esc
    that no toast or fly-back claims is spent un-borrowing it (it never reaches
    the terminal). Send `key <term> escape` while `borrowed` reads true to undo
    it, as D18 does.
  `type` and `key` still refuse doc cards (`unsupported_card_kind`).
- A `focus <term>` press never lands on a link (a click would open it) and
  prefers a point two cells clear of the previous press (a second press on the
  same point inside the double-click interval selects a word). When every point
  the driver tries is on a link, the terminal is selected and focused with no
  click at all (`delivery: handling`).

### Pressing a native ⌘ chord — `press`

`press` (#183) posts a constructed keyDown to the application's **event queue**,
so the chord takes the path a typed one does — the app's key monitor, the first
responder, then the menu — and the ⌘Q guard reads it off `NSApp.currentEvent`
like any other. It is what `make qa` uses to drive the guard, and it presses any
⌘ chord: `cmd+q`, `cmd+shift+z`, `alt+cmd+q`, `cmd+1`. `cmd` plus any of
`shift`, `alt`, `ctrl`, then one lowercase letter or digit; no named keys (⌘⌫,
⌘Enter) and no `meta`.

```sh
tarmac dev press cmd+q --hold 300      # a tap: 300 < the 500 ms hold threshold
tarmac dev snapshot --until 'quit_guard.last_press.press_ms ~= <press_ms>' --timeout 1000
```

- The reply says **what it did, not what the key caused**:
  `{"combo": "cmd+q", "press_ms": 268318196, "hold_ms": 300, "activated": false, "busy_ms": null}`.
  Read the effect off the snapshot: wait for `quit_guard.last_press.press_ms`
  to match the reply (`~=` absorbs a ±1 truncation), then read `route`,
  `age_ms`, `phase` and `notice` off the snapshot that wait returns.
- `--hold <ms>` (1–10000, default 100): how long the key **reads as held** — a
  debug-only override the guard's poller ORs into its physical key read, since
  no posted event can make `CGEventSourceKeyState` read a key as down. `--age
  <ms>` (0–60000) stamps the press that far in the past. `--busy <ms>`
  (1–1800) blocks the app's main thread behind the posted key, which is read
  only once the block ends; the reply arrives then, and `age_ms` shows it.
  `--busy` cannot be combined with `--age`.
- **A posted chord fires its menu action.** `press alt+cmd+h` runs Hide Others
  and hides your other apps; `press cmd+h` / `cmd+m` hide or minimise the dev
  window. The one chord refused is a real quit: a chord that a native
  `terminate:` item would take (or a Quit item whose guard target is gone)
  answers `not_retargeted` and posts nothing.
- **These quit the app for real** — keep them to `make qa-quit`: a ⌘Q
  `--hold` of 500 or more; two ⌘Q presses within 1 s; `--age` past the 2000 ms
  freshness bound; `--age` plus `--hold` reaching ~500 ms; and a `--hold` of
  500 or more that outlasts a `--busy` block. *Warn Before Quitting* is not
  read: with the toggle off a ⌘Q press quits at once, so check
  `quit_guard.enabled` first.
- **Never `press cmd+w` while a borrowed HTML card's document has the keys** —
  the app's key ladder steps aside for a borrowed document, so ⌘W reaches the
  menu's Close Window item and hides the window.
- The chord's characters are supplied, so the input source and IME play no
  part, and a shifted digit carries the digit, not its layout's symbol.

### Waiting for something to become true

Effects are asynchronous, so assert with `--until` rather than sleeping:

```sh
tarmac dev zoom 0.5
tarmac dev snapshot --until 'viewport.zoom == 0.5'
```

Grammar is `<path> <op> <value>` with `==`, `!=`, `~=` (numeric, |Δ| ≤ 1) and
`contains`. `cards[<id>]` indexes by card id and the id runs to the **last** `]`,
so doc paths with dots and slashes work. A string value takes its own double quotes inside the
expression — `--until 'theme.name == "file:Dracula"'` — and a bare word is a
`bad_expr` (`not a value`). An unresolvable path is `false` (so
polling continues); a malformed expression is an immediate `bad_expr`. Default
timeout 5000 ms; `--timeout 0` means evaluate once.

### What it cannot do

- **Not a release feature.** Two build gates: `#[cfg(debug_assertions)]` on the
  CLI verb, `#if DEBUG` on the app's endpoint.
- `key` cannot send a ⌘ chord; `press` can, but its reply does not say what the
  key did, and ⌘C / ⌘V have no snapshot field yet (the clipboard, the paste), so
  nothing can assert on them.
- `type` and `key` refuse doc cards; only `focus` accepts them.
- `focus <term>` is a real mouse press unless its `delivery` reads `handling`,
  so a program with mouse reporting on (Claude Code, vim) also receives a
  button-press report.
- No verb pans, switches boards, or creates a card.

## The scenario suite — `make qa`

```sh
make qa           # needs `make run` up in another shell
```

`scripts/qa/smoke.mjs` drives a live window entirely through `tarmac dev`.
Deliberately **not** in `make test` or CI — every scenario needs a window. It
exits non-zero with a clear message if no app is listening, and prints the board,
terminal and `visibility` it chose in its header.

It needs **a live terminal card on the active board** — no verb creates one — and
picks the first card with `term.alive`. A fresh board always boots one.

The run presses, keys and clicks natively, so it needs an **unlocked session**
and **your hands off other apps** while it runs. S21 — that a verb activates a
non-frontmost app — is exercised only when another app is in front when D12
runs (`open -a Finder` first); otherwise it is reported as skipped, never as
passed.

D4 and D5 — the #162 pair — **fail unless their resize press went through the
window**. Before each resize the suite zooms to 0.4, which puts the boot
terminal's bottom-right handle inside a default-size window at the default
viewport; if the board was panned or the window shrunk they fail with `the
resize press was delivered by "target"` — bring the terminal back inside the
window and re-run. D18 zooms to 0.3 so its borrowing double-click can take the
same path; that is printed (`focus d18.html → window`), not required.

```sh
make qa-quit CASE=hold      # S15: a 2 s hold hides the window, then quits on release
make qa-quit CASE=double    # S16: two taps within 1 s quit
make qa-quit CASE=stale     # S17: a press stamped 2.5 s old quits at once
```

`scripts/qa/quit.mjs` holds the three scenarios that **end the app**. One
`CASE` per run, and `make run` again between cases: the app exits and `make
run` returns, the daemon survives, and the next app reconnects to it.
`CASE=stale`'s route is only visible in the `make run` output
(`tarmac: quit-key route=terminate …`); record it by hand.

## When it does not answer

Work down this list before suspecting the driver:

1. **Is the app up?** `lsof -t "$PWD/.dev/tarmac-dev.sock"` prints the pid that
   owns the driver socket; nothing printed means no app is listening.
2. **Did you pin the socket?** Without `TARMAC_DEV_SOCKET` the CLI resolves the
   channel default, not this worktree's `.dev/`.
3. **Is it a debug build?** A release app binds no driver, and a release CLI
   refuses the verb.
4. **Did the driver fail to bind?** Read the `make run` output for
   `tarmac: dev driver listening on <path>`. Instead you may find `a dev driver
   is already listening on …` (another app owns that socket — it is never
   stolen) or `dev driver disabled: …` (a path too long for a socket, or a
   failed bind). A killed app leaves the socket file behind; the next `make
   run` replaces it, since it only unlinks a socket nothing answers on.
   `dev driver accept failed: …` means the listener died: the app has removed
   its socket file, so every later verb fails at once — restart `make run`.
5. **`app_not_ready`?** The board is out of the window for a moment during a
   board switch, or the driver has not attached yet. Retry.
6. **`app_unresponsive`?** Requests are served strictly one at a time; a verb
   did not answer within its own budget plus 2 s. Look for a modal state — a
   tracked menu, a stuck `--busy`.
7. **`not_key`?** The screen is locked, or activation was refused. Unlock,
   click the dev window, re-run.
8. **Is the window hidden?** Verbs still work, but the settle falls back to a
   100 ms cap because a hidden or minimised window services no display frames.
   The snapshot's `visibility` reads `"hidden"` for exactly those two states
   and `"visible"` for a window merely sitting behind another app's — which
   does *not* stall frames. So the field is the tell; read it before blaming
   the driver.

## Adding a scenario

Each `[D]` scenario in `smoke.mjs` should start `zoom 1`, then `focus board`,
then `focus <term>` — zoom persists to `state.json` between runs, and every
scenario should start from the same selection and focus. Give each its own
sentinel string: `scrollback_tail` spans 40 lines, so an earlier scenario's echo
would satisfy a repeated `contains` and turn a later check green for free.
Send `focus`/`resize` through `pointer()` so the run prints their delivery; call
`showGrip()` before a `resize`, and wrap it in `windowPress()` when the scenario
is about the press itself.

**Then knock it out.** Change one thing that should break it, confirm it fails,
revert. A `[D]` scenario that has never been observed failing is not yet known to
test anything — this is how `screen_rect` was caught reporting the projection
instead of the measurement, which made its scenario compare a formula with a copy
of itself.
