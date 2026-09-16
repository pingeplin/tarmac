# In-app QA driver — manual QA (spec 2609.0015, #166)

Q1…Q6 of [`2609.0015_in_app_qa_driver.md`](../../.blueprint/specs/2609.0015_in_app_qa_driver.md)
(Q6 was added to the spec during stage 2).
These are `[Q]` scenarios because each is a property of a **build**, a **window**
or a **deliberate break**, not of the code: `make test` runs debug, so nothing
automated can observe a release binary; `make qa` cannot test its own entry
condition; whether WebKit services `requestAnimationFrame` behind another window
is an observation, not an assertion; and a knockout is a thing you do to a
working tree, not a test you can commit.

Q1, Q4 and Q5 were run for stage 1 (`snapshot`, `zoom`, `focus`). Q2, Q3 and the
stage-2 half of Q5 were run for stage 2 (`resize`, `type`, `key`) and are recorded
below their stage-1 sections. Counts differ by stage: stage 1's suite was 11
checks, stage 2's is 18.

**CAUTION: do NOT `pkill tarmacd` or `pkill tarmac-app`.** That kills the user's
installed Tarmac and every terminal its daemon owns. `make run` pins
`TARMAC_SOCKET`, `TARMAC_STATE` and `TARMAC_DEV_SOCKET` under this worktree's
`.dev/`, so the dev app and an installed app coexist. `make kill-daemon` is the
correct tool — it resolves the pid by `lsof` on *this worktree's* socket.

---

## Q1 — the driver is absent from a release build

Three gates, one predicate each. All three must hold.

| # | Gate | How to observe |
|---|---|---|
| 1 | `#[cfg(debug_assertions)]` on the CLI verb | `cd core && cargo build --release && ./target/release/tarmac dev snapshot` |
| 1b | the verb is not *advertised* in release | `./target/release/tarmac --help \| grep -c dev` |
| 2 | `#[cfg(debug_assertions)]` on the endpoint | `make bundle`, launch `dist/Tarmac.app`, then `ls`/`lsof` its channel dir for `tarmac-dev.sock` |
| 3 | `import.meta.env.DEV` on the frontend half | `cd desktop && npm run build && grep -rl "dev-request\|installDevDriver" dist/` |

### Result — all three gates: PASS (2026-09-16, `make bundle` of `516dcaa`)

- **Gate 1.** `core/target/release/tarmac dev snapshot` printed
  `tarmac: driver unavailable in release builds` and exited **1** — not the
  exit-2 unknown-command path, which is what it would do without the explicit
  `#[cfg(not(debug_assertions))]` arm in `main.rs`.
- **Gate 3.** `npm run build` produced 6 asset files; `grep -rl` for
  `dev-request`, `installDevDriver` and `dev_ready` across `dist/` matched
  **nothing**. Vite eliminates the dynamic import behind `import.meta.env.DEV`
  entirely, so the driver is not merely inert in a production bundle — it is not
  in it.

### Result — gate 2, and gates 1/3 re-checked on the shipped artifact

`make bundle` produced `dist/Tarmac.app`. Checked its **actual shipped
binaries**, which is stronger than the `ls`/`lsof` the spec suggested: an absent
socket has several possible causes, absent *code* has one.

```
$ dist/Tarmac.app/Contents/MacOS/tarmac dev snapshot
tarmac: driver unavailable in release builds        # exit 1
```

**Gate 1b** — a release `--help` mentions `tarmac dev` and `TARMAC_DEV_SOCKET`
**0** times; the same debug binary mentions them 11 times. `README.md` and
`SKILL.md` leave the family out because they are user-facing, and `--help` is at
least as user-facing as either — but the verb stays *recognised*, so a user who
types it gets `driver unavailable in release builds` and exit 1 rather than an
`unknown command` exit 2. Recognised, not advertised.

Strings in `dist/Tarmac.app/Contents/MacOS/tarmac-app` (the release app, with the
production frontend bundle embedded):

| needle | count |
|---|---|
| `dev-request` | 0 |
| `tarmac-dev.sock` | 0 |
| `installDevDriver` | 0 |
| `dev_ready` | 0 |
| `app_unresponsive` | 0 |
| `not_focused` | 0 |
| `daemon-status` *(control — must be present)* | 1 |

So the endpoint, its socket path literal, its error codes and the whole frontend
half are absent from the release build, not merely unreachable in it. The control
row is what makes the zeros mean something.

**Launching the bundle was deliberately skipped.** A release app resolves the
*release* channel socket — the one the user's installed Tarmac is already on — so
launching it would have put a second window on their live daemon. The static
evidence above answers the same question without touching it.

---

## Q4 — `make qa` with no app listening

**Result: PASS (2026-09-16, `8e90b62`).** With no `make run` app, `make qa`
printed

```
make qa: no dev driver socket at …/.dev/tarmac-dev.sock — start the app with `make run` first
```

and exited non-zero, running **no** scenario. Neither a green suite nor a
scenario-shaped failure — both would be a lie about what was checked. `scripts/`
is TDD exception 3 and the `[D]` suite cannot test its own entry condition, so
this hand-run is the only check on it.

---

## Q5 — does `requestAnimationFrame` stall behind another window?

The settle is "two animation frames **or** 100 ms, whichever comes first"
(Decision 15). The cap exists for a **named but unverified** risk: WebKit is
documented to throttle rAF for an occluded window, and a driver invoked from a
shell is *expected* to run with Tarmac behind the terminal. Nothing in this repo
has observed it in the real Tauri WKWebView, and Tarmac's invariant is that a
reported fact is an observed one — so the cap is labelled a bound, not a fix, and
this scenario is what settles it in either direction.

Run `make qa` three times against one `make run` app: window frontmost, window
fully covered by another window, and window minimised. For each, record the
`visibility` the run header prints, whether every scenario passed, and whether the
settle ended on the second frame or on the cap.

- If rAF keeps running while occluded, the cap is harmless dead weight and can be
  dropped in a follow-up.
- If it stalls, the cap is load-bearing and this is the evidence.

Until this runs, **no doc in this repo may state the rAF-suspension claim as
fact.**

### Result: PASS — and the cap is load-bearing (2026-09-16, `8e90b62` + the seam commit)

Run against a debug `make run` of this worktree, dev app pid 83882, addressed by
pid (two `tarmac-app` processes were on the machine — the installed 0.12.3 and
this one).

**1. Hidden, cap at its shipped 100 ms.** `make qa` → **11/11 passed**, header
`visibility visible`. Median `tarmac dev focus <term>` wall time, 5 runs each:

| window state | median | spread |
|---|---|---|
| frontmost | 130 ms | 118-157 |
| hidden (`System Events`, `visible = false`) | 225 ms | 208-235 |

**2. The knockout — one knob, one factor.** `SETTLE_CAP_MS` 100 → 1500, nothing
else, Vite HMR only (no relaunch):

| window state | median | spread |
|---|---|---|
| frontmost | 134 ms | 116-138 — unchanged |
| hidden | 1743 ms | 1633-1751 — **the full cap** |

Reverted; `make qa` 11/11 again.

**Conclusion: `requestAnimationFrame` does not fire at all for a hidden window.**
Frontmost, the settle ends on the second frame and the cap is never reached —
raising it changes nothing. Hidden, the settle runs to whatever the cap is, which
means without one it would wait until the backend's 2 s bound and every verb
would come back `app_unresponsive`. Decision 15's cap is **not** a hedge against a
documented-but-unobserved behaviour; it is the thing that makes the driver usable
in its most normal posture — called from a shell with Tarmac behind the terminal.

**Correction this run forced on the spec — and which the stage-2 re-run below
reverses.** `visibility` reported `"visible"` the whole time the app was hidden,
so Decision 16 was rewritten to say `document.visibilityState` does not flip for
a hidden macOS *application*. **That reading did not reproduce.** See the
stage-2 section below: the flip is observable in both directions, repeatedly.
This paragraph is kept as the record of what was recorded when, not as a
statement of fact.

**Not run in stage 1:** minimised (⌘M) as distinct from hidden. Run in stage 2.

### Stage-2 re-run: the cap holds, the visibility reading does not (2026-09-16, `da07c62`)

Same instrument, dev app pid 92364, addressed by pid. `tarmac dev snapshot`
reads state and never settles, so its wall time is the process-start floor and
the difference is the settle itself. Medians of 12 paired runs:

| window state | `visibility` | `snapshot` | `focus board` | settle | ended on |
|---|---|---|---|---|---|
| frontmost (key) | `visible` | 5.8 ms | 27.1 ms | **21.3 ms** | two frames |
| another app key, Tarmac on screen | `visible` | 4.7 ms | 28.4 ms | **23.7 ms** | two frames |
| app hidden (`visible = false`) | `hidden` | 6.0 ms | 107.4 ms | **101.4 ms** | the 100 ms cap |
| window minimised (`AXMinimized`) | `hidden` | 5.4 ms | 110.5 ms | **105.1 ms** | the 100 ms cap |

**Decision 15's cap is load-bearing — confirmed, and now with the minimised case
too.** Both states that stall rAF pin the settle at the cap; both states that
service it end on the second frame. Merely being behind another app's window is
*not* one of the stalling states, which is worth knowing: the driver's most
common posture costs nothing.

**`visibility` DOES flip, contradicting stage 1.** Three independent
observations, all the opposite of the stage-1 record:

1. `make qa` with the app hidden printed header `visibility hidden` — literally
   stage 1's experiment, opposite result.
2. Two hide/unhide cycles: `visible` → `hidden` within 0.5 s of hiding, still
   `hidden` at +4 s, back to `visible` on unhide. Both cycles identical.
3. Twelve consecutive snapshots over 12 s while hidden: `hidden` every time,
   with `System Events` confirming `visible = false` at the end.

The stage-1 reading was not reproducible and the spec's Decision 16 and Interface
Contract are corrected back. `visibility` is a usable tell for exactly the two
states where the cap fires.

**Pre-check 3 — does `execCommand("insertText")` work in a non-key window?**
This is the third stage-2 entry pre-check, which the Playwright harness could not
answer because it needs the real WKWebView. Answered here: `make qa` run with the
app **hidden** passed **18/18**, D4 and D5 included, both reporting
`dropped: []`. The editing path is unaffected by key-window status.

---

## D1's knockout — the scenario now observes something

Recorded because D1 was **vacuous in the first implementation** and the referee
caught it: `screen_rect` was being filled with `boardRectToScreenRect(frame, …)`
and the card's real measurement was used only as a presence flag. D1 was
therefore comparing the projection against `smoke.mjs`'s inline copy of the same
formula — it could not have failed for any card, anywhere. `screen_rect` now
reports the measurement.

**Knockout, one knob** (`devDriver.ts`, `+5` on the measured `x`, Vite HMR only):

| | frontmost |
|---|---|
| perturbed | **9/11** — `x: off by 5.00px` at zoom 1 *and* at zoom 1.7 |
| reverted | 11/11 |

Before the fix this same perturbation changed nothing, because the measurement
never reached the snapshot. D1 is now the end-to-end check it was written to be:
the painted position and the board transform agree within ±1 px at both zooms.

---

## Incidental finding — the unit tests could not have caught the reactor bug

Worth recording because it bounds what the `[S]` tier is worth here. The first
`make run` of the endpoint aborted at startup:

```
thread 'main' panicked at src/dev_driver.rs:168:
there is no reactor running, must be called from the context of a Tokio 1.x runtime
```

`tokio::net::UnixListener::from_std` was being called from Tauri's `setup`, which
runs *outside* the async runtime. Every backend unit test passed, because
`#[tokio::test]` always provides a reactor — the one context the production call
site does not have. The fix splits the claim (std, in `setup`) from the reactor
registration (`into_async`, inside the spawned task).

The `[S]` tier cannot see this class of bug at all. `make qa` found it on its
first live run, which is the argument for the `[D]` tier existing.

---

## Q2 — the #162 knockout (one knob, one factor)

`desktop/src/kit/resizeSelection.ts`'s `flushesOnResize` changed to `return true;`
— **nothing else** — and applied by Vite HMR with no relaunch, so the app, the
daemon, the terminal and its shell are all the same ones the passing run used.

### Result: PASS, both halves (2026-09-16, `da07c62`, dev app pid 92364)

Re-run at `da07c62` after the referee pass, because production code in the `type`
path had changed since the first run. Identical result both times.

| run | D4 | D5 | everything else | total |
|---|---|---|---|---|
| unmodified | ok | ok | ok | **18/18** |
| knockout (`return true`) | **FAIL** | **FAIL** | ok | 16/18 |
| reverted | ok | ok | ok | **18/18** |

Both failures read `second type dropped [{"index":0,"char":"b"}]` — which is
#162's mechanism exactly: the resize press flushed the focused terminal's
selection, WebKit then fired no `beforeinput`, and `execCommand` returned
`false`. The driver reported it rather than passing quietly, which is the whole
point of S71's summariser.

**One knob, one factor.** Sixteen other checks stayed green under the knockout,
so the two failures are attributable to the predicate and not to a disturbed app.
D5 failing alongside D4 is expected and is noted in the spec: the knockout removes
both branches of the predicate, and D4 is the required observation.

**What this rules out.** If `type` were delivering text through its bracket
keydown rather than through `execCommand`, the knockout could not have changed
anything and D4 would have passed — S19's inert bracket (Decision 1) is what makes
these scenarios able to fail at all. They can.

---

## Q3 — the mouse-report side effect, observed

`focus <term>` goes through xterm's real `mousedown`/`mouseup` handlers, so a
program with mouse reporting enabled receives a button report. Documented rather
than worked around; this records what it actually looks like.

### Result: confirmed (2026-09-16, `da07c62`, dev app pid 92364)

Driven entirely through `tarmac dev`, no keyboard:

```
tarmac dev focus board && tarmac dev focus <term>
tarmac dev type <term> "printf '\033[?1000h'; cat -v\n"
tarmac dev focus board && tarmac dev focus <term>
```

`cat -v` then showed, in the snapshot's `scrollback_tail`:

```
❯ printf '\033[?1000h'; cat -v
^[[M ?(^[[M#?(
```

Two reports, not one: `^[[M ?(` is the button **press** and `^[[M#?(` the
**release** — `focus` plans `mousedown` + `mouseup` (S35), and xterm encodes
both. A program that acts on a click (Claude Code, vim) sees a complete click at
the centre of the terminal element. `tarmac --help` and the dev-channel skill
both say so.

Restored with `tarmac dev key <term> ctrl+c` and `printf '\033[?1000l'; clear`.

---

## S17's "unpatched rect" has no test, at any tier — measured, not assumed

Recorded because the referee flagged it as covered-but-vacuous and the obvious fix
did not work.

`key <card> contextmenu` must compute its point from the **unpatched**
`screenElement` rect —
`Element.prototype.getBoundingClientRect.call(screen)` in `devDriver.ts` — because
`TerminalCard` patches `getBoundingClientRect` on that very element. S17 claims
"a patched-rect implementation fails it". It does not:

- The **kit** test cannot see it. `devCellPoint` takes the rect by argument, so
  the test can only re-derive the same formula from a second literal; it never
  observes which rect the *caller* passes.
- No **`[D]`** scenario catches it either. D5 pins zoom 1, where
  `deriveRasterScale(1) === 1` makes the patch a no-op by construction.

### The knockout, and why a new scenario was written and then deleted

`devDriver.ts` switched to the patched `screen.getBoundingClientRect()` —
nothing else, Vite HMR only — and a new D5b was written to catch it: at zoom 1.7,
print a target on its own line, hold the terminal with a foreground `sleep` (so
the last written row is the target and not the user's shell prompt),
`key contextmenu`, and assert the selected word.

| target | zoom | patched rect selects |
|---|---|---|
| 12-char token | 1.7 | the token — **passes under the knockout** |
| `AAA BBB … HHH` (31 chars) | 1.7, 2.5 | `HHH`, the correct last word |
| `QQQ` (3 chars, row's left edge — the most displaced case) | 1.05, 1.1, 1.4, 1.7, 2.1, 2.9 | `QQQ` every time |

**Every variant passed under the knockout.** The reason is in S17's own algebra:
the leading `mousemove` (S16) re-anchors the patched rect on the very point being
dispatched, and that cancels most of the error back out — enough that the
resolved cell stays inside the target at every reachable zoom.

**D5b was deleted rather than kept.** A check that passes identically with and
without the behaviour under test is exactly the vacuity the Definition of Done
forbids; keeping it would have been worse than not having it, because it would
have looked like coverage. The `Element.prototype` call now stands on the algebra
and on a comment that says it is the only guard, and S17's claim is corrected in
the spec.

---

## Pre-check 4, second pass — the pointer-capture premise was wrong in both directions

The spec's scope list mandates a `try`/`catch` around `CardShell`'s
`setPointerCapture` (`:124`) and `releasePointerCapture` (`:138`), reasoning that
"an untrusted synthetic `PointerEvent` has no active pointer, so
`setPointerCapture` throws `NotFoundError` and the resize never starts".

The first pass measured "no throw" but read `hasPointerCapture` **after**
`pointerup`, which had already released it — so it could not tell "capture never
happened" from "capture happened and was released". Second pass reads it inside
the handler and varies the pointer id:

| `pointerId` | `setPointerCapture` | `hasPointerCapture` inside the handler | `gotpointercapture` | `releasePointerCapture` |
|---|---|---|---|---|
| **1** (the mouse's reserved id) | no throw | **false** | never fires | **no throw** |
| 2 | **`NotFoundError`** | — | — | `NotFoundError` |
| 99 | **`NotFoundError`** | — | — | `NotFoundError` |

So the throw depends on the **pointer id**, not on whether the event is trusted.
Two consequences:

1. **No guard is needed.** `CardShell.tsx` is untouched, and D3/D4/D5/D10(b) pass
   — a throw at `:124` would abort before `resizeStart.current` was set and D3
   would fail outright. `releasePointerCapture(1)` does not throw either, so the
   pointerup path completes and the card's lifted state clears.
2. **`pointerId: 1` in `devResizeGrip` is load-bearing for safety, not fidelity.**
   Any other id throws at `:124` and the resize silently never starts while the
   driver still reports success. S44 asserts the id for that reason.

Capture itself never happens for id 1 — which is harmless: all three events land
on the grip, where `CardShell` wires its own move/up listeners, so capture only
ever matters for a real pointer that leaves the element.

---

## Q6 — `type` under kitty flag 8, in the real WKWebView

The flag-8 branch (S77) was the one production path whose only evidence was the
Playwright harness — the instrument this spec's own *Alternatives Considered*
distrusts, for exactly the reason it gives there. This closes that gap against the
real app. It is a **[Q] hand-run and not a `make qa` scenario**, for a reason
measured below: it cannot safely clean up after itself.

### Result: PASS (2026-09-16, `c7efcd0`, dev app pid 92364)

`cat -v` renders escape codes as text, so the PTY's own bytes are readable through
`scrollback_tail`:

```sh
tarmac dev focus board && tarmac dev focus <term>
tarmac dev type <term> "clear; printf '\033[>8u'; cat -v\n"
tarmac dev type <term> "ab!"
```

Reply: `{"chars":3,"inserted":0,"dropped":[],"mode":"key"}` — **no `insertText` at
all**, which is S77's point: under flag 8 xterm owns every key, and an
`execCommand` on top would deliver each character a second time.

The PTY received:

```
^[[97u^[[98u^[[49;2u
```

`a` → `ESC[97u`, `b` → `ESC[98u`, and `!` → **`ESC[49;2u`** — the *unshifted*
Digit1 with the shift modifier, which is what a real `Shift+1` press produces.
That is the physical-key table confirmed end to end in the real WKWebView, not
just against Playwright: a plan carrying the character's own code point would
have sent `ESC[33;2u`, a key nobody pressed.

### Why this is not a `make qa` scenario

Written as D11 first, it wedged the terminal and failed five later scenarios. Two
measured reasons, both worth knowing independently of this test:

1. **Under kitty flag 8, `tarmac dev key <term> ctrl+c` cannot interrupt a
   non-kitty program.** xterm encodes it as `ESC[99;5u` rather than emitting raw
   `0x03`, so the line discipline never raises SIGINT and `cat -v` just prints the
   escape. `ctrl+d` is the same. A program that pushed flag 8 and does not
   understand kitty input therefore cannot be stopped through the driver at all.
2. **Kitty flags survive an app reload.** Forcing a Vite page reload recreates the
   `Terminal`, but the daemon replays the stored scrollback into it — including
   the original `ESC[>8u` — so the flags are re-applied and the terminal is still
   in key mode.

Together those leave no in-band recovery: nothing can be typed as raw bytes, so
nothing can pop the flags. The terminal was restored out of band, by killing the
stuck `cat` by pid (verified as a child of *this worktree's* `tarmacd`, never by
name) and writing the pop sequence straight to the PTY's tty, which reaches xterm
from the program side:

```sh
printf '\033[>0u' > /dev/ttys000
```

A scenario whose failure mode requires that is not one `make qa` should run
unattended. The limitation is documented in `tarmac --help` and the dev-channel
skill instead.
