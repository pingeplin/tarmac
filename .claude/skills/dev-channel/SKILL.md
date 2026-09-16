---
name: dev-channel
description: Bring up, drive, inspect and tear down Tarmac's dev channel — `make run`, the per-worktree sockets it pins, the `tarmac dev` QA driver, `make qa`, and the rules that keep a dev build from touching the user's installed app. Use when the user says "run the app", "start a dev build", "drive the app", "take a snapshot", "check the UI", "run the QA scenarios", "why is my dev app not answering", or when hand-testing anything that needs a live window.
---

# Tarmac's dev channel

A dev build and an installed Tarmac **coexist on purpose**. Everything below
exists so a dev build can be driven and inspected without ever reaching the app
the user actually works in.

## The one rule that matters

**Never `pkill tarmacd`, `pkill tarmac-app`, or `killall` anything by name.**
Both builds share the process name `tarmac-app` and the bundle id
`com.tarmac.desktop`, so a name-based kill takes down the user's real app and
every terminal its daemon owns.

- Stop the dev **daemon**: `make kill-daemon` — it resolves the pid with `lsof`
  on *this worktree's* socket and cannot touch anything else.
- Stop the dev **app**: kill the pid from `ps -eo pid,command | grep
  "[t]arget/debug/tarmac-app"`, or stop the task running `make run`.
- Addressing a window with a GUI tool: **always by pid**, never by name.

## Bringing it up

```sh
make run          # Tauri dev app + Vite HMR; needs `make sidecars` first in a fresh worktree
```

`make run` pins three paths under `$(ROOT)/.dev/`, which is what makes a dev
build harmless:

| env | what it isolates |
| --- | --- |
| `TARMAC_SOCKET` | the daemon socket — a dev app never joins the installed daemon |
| `TARMAC_STATE` | `state.json` — boards and layout, never the user's |
| `TARMAC_DEV_SOCKET` | the QA driver's socket (issue #166) |

Two more things `make run` does: it prefixes `PATH` with
`core/target/debug`, so `tarmac open` inside the app's own terminals resolves the
freshly built CLI; and it suffixes the window title with the worktree name, which
is the only way to tell two dev windows apart.

**A fresh worktree needs `make sidecars` and `cd desktop && npm ci` before
anything builds.** `make run` depends on `sidecars`; `make app` and `make test`
do not, and fail with a missing-resource-path error until you run it.

**Editing `desktop/src-tauri` while `make run` is live relaunches the app.** The
daemon survives and the new window reconnects. Expect it mid-hand-test; `desktop/src`
is HMR only and does not relaunch.

## Driving it — `tarmac dev`

Debug builds only. A release binary exits 1 with `driver unavailable in release
builds` and does not document the family at all.

```sh
tarmac dev snapshot [--until <expr>] [--timeout <ms>]
tarmac dev zoom <z>
tarmac dev resize <card> <w>x<h>
tarmac dev focus <card>|board
tarmac dev type <card> "<text>"
tarmac dev key <card> "<combo>"
```

Use the debug CLI with the socket pinned, or nothing will answer:

```sh
export TARMAC_DEV_SOCKET="$PWD/.dev/tarmac-dev.sock"
core/target/debug/tarmac dev snapshot | jq .
```

- `<card>` is a terminal's **term id** or a doc's **absolute path** — the bare
  wire ids, not the app-internal `term:`/`doc:` form.
- `snapshot` prints the active board's live state: viewport, every card's
  `board_rect` and measured `screen_rect`, `focused_card`, `active_element`, and
  per-terminal `cols`/`rows`/`proc`/`selection`/`scrollback_tail`.
- Every other verb prints a small JSON object describing **what it observed**,
  not what you asked for — `zoom 99` answers `{"zoom": 3}` because the board
  clamps.
- A failure prints JSON on **stderr** and exits 1: `no_such_card`,
  `not_focused`, `unsupported_card_kind`, `unsupported_combo`, `bad_combo`,
  `empty_buffer`, `unsupported_verb`, `bad_expr`, `timeout`, `app_not_ready`,
  `app_unresponsive`. CLI-side failures (no app, a too-long socket path) stay
  one-line plain text.

### Typing and keying

`type` and `key` require the card to **already** hold keyboard focus — they
answer `not_focused` rather than establishing it, so a passing verb proves focus
was right. `focus board` then `focus <term>` is the clean reset: per #162,
`focus()` on an already-focused textarea does not restore the caret.

```sh
tarmac dev focus board && tarmac dev focus t-1
tarmac dev type t-1 'printf hello\n'
tarmac dev key t-1 ctrl+c
```

- `type` sends printables through the editing path a real keystroke takes, and
  control characters as key events: LF/CR → Enter, TAB → Tab, ESC/DEL → Escape
  and Backspace, and `\x01`–`\x1a` → their ctrl chords, so `\x03` is ctrl+c.
  (`\x00` and `\x1c`–`\x1f` have no spelling in the combo grammar and take the
  editing path.) Its reply counts what landed:
  `{"chars": 6, "inserted": 6, "dropped": [], "mode": "insert"}`. A non-empty
  `dropped` is the #162 failure mode.
- `key` takes a closed set: `enter`, `tab`, `escape`, `backspace`, the four
  arrows, a lowercase letter or digit **as the base of a ctrl/alt chord**, or
  `contextmenu`. Lowercase only. A bare printable is refused with
  `unsupported_combo` — use `type`. So are ⌘ chords: they need WebKit's native
  Edit menu, which a dispatched event never reaches.
- Two combos move things: `alt+tab` cycles the prime terminal and **takes focus
  away**, so every later verb in the scenario fails `not_focused`; `contextmenu`
  right-clicks the last written cell and leaves xterm's helper textarea parked
  under the cursor (which is what makes the selection real).
- **Kitty flag 8 is a trap.** A program that pushes it (`ESC[>8u`) puts `type` on
  the key path — the reply reads `"mode": "key"` — and while it is set, `key
  ctrl+c` **cannot interrupt a program that does not speak kitty**: xterm encodes
  it as an escape code instead of a raw `0x03`, so no SIGINT is raised. `ctrl+d`
  likewise. The flags survive an app reload too, because the daemon replays the
  scrollback that set them. If a program leaves them set there is no in-band
  recovery; pop them from the program side against that terminal's tty:
  `printf '\033[>0u' > /dev/ttysNNN`.
- `resize` drags the bottom-right grip in board units and reports where the card
  landed, clamped to the 160×90 minimum:
  `{"from": {...}, "to": {"w": 800, "h": 600}, "delta_px": {...}}`.

### Waiting for something to become true

Effects are asynchronous, so assert with `--until` rather than sleeping:

```sh
tarmac dev zoom 0.5
tarmac dev snapshot --until 'viewport.zoom == 0.5'
```

Grammar is `<path> <op> <value>` with `==`, `!=`, `~=` (numeric, |Δ| ≤ 1) and
`contains`. `cards[<id>]` indexes by card id and the id runs to the **last** `]`,
so doc paths with dots and slashes work. An unresolvable path is `false` (so
polling continues); a malformed expression is an immediate `bad_expr`. Default
timeout 5000 ms; `--timeout 0` means evaluate once.

### What it cannot do

- **Not a release feature.** Three build gates, one predicate each.
- ⌘C / ⌘V cannot be driven — they need WebKit's native Edit-menu action, which
  an untrusted dispatched event never triggers.
- `focus` on a doc card is refused: no focus target an untrusted `mousedown`
  reaches.
- `focus`/`key` go through the real mouse path, so a program with mouse reporting
  on (Claude Code, vim) also receives a button-press report.

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

Results and the hand-run scenarios live in
[`desktop/qa/qa-driver-qa.md`](../../desktop/qa/qa-driver-qa.md).

## When it does not answer

Work down this list before suspecting the driver:

1. **Is the app up?** `ps -eo pid,command | grep "[t]arget/debug/tarmac-app"`.
2. **Did you pin the socket?** Without `TARMAC_DEV_SOCKET` the CLI resolves the
   channel default, not this worktree's `.dev/`.
3. **Is the socket stale?** A killed app leaves the file behind. The next
   `make run` replaces it (it only unlinks a socket nothing answers on); a *live*
   sibling worktree's socket is never touched.
4. **Did the app panic at startup?** Read the `make run` output — a backend
   panic aborts before the endpoint binds.
5. **Is the window hidden?** Verbs still work, but the settle falls back to a
   100 ms cap because a hidden macOS app services no animation frames. Note the
   snapshot's `visibility` stays `"visible"` for a *hidden app* — it only catches
   a minimised or genuinely hidden page — so use the latency, not that field.

## Adding a scenario

Each `[D]` scenario in `smoke.mjs` should start `zoom 1`, then `focus board`,
then `focus <term>` — zoom persists to `state.json` between runs, and per #162 a
blur is the only clean focus reset. Give each its own sentinel string:
`scrollback_tail` spans 40 lines, so an earlier scenario's echo would satisfy a
repeated `contains` and turn a later check green for free.

**Then knock it out.** Change one thing that should break it, confirm it fails,
revert. A `[D]` scenario that has never been observed failing is not yet known to
test anything — this is how `screen_rect` was caught reporting the projection
instead of the measurement, which made its scenario compare a formula with a copy
of itself.
