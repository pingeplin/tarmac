# Hold ⌘Q to quit — manual QA (spec 2609.0016, #171)

Q1–Q16 and S37 of `.blueprint/specs/2609.0016_hold_to_quit.md`. They discharge
the thin-wiring exception (`quit_intercept.rs`, the AppKit half of
`quit_notice.rs`, the `lib.rs` menu/window/run wiring, `app_prefs.rs`'s file IO,
`bridge.rs::app_prefs_path`, `devDriver.ts`, and the `App.tsx` switcher and
paste changes) and the pure-presentation exception (the notice's look).

The automated suites cover every decision without a window: `quit_guard.rs`
(routing, the state table, the labels), `app_prefs.rs`, `window_lifecycle.rs`,
`quit_notice.rs` (frame and screen choice), `kit/termKeyRoute.test.ts`,
`kit/boardSwitcher.test.ts` and `kit/devSnapshot.test.ts`. None of them presses a
key: **synthetic input never reaches AppKit** — `tarmac dev key` dispatches DOM
events, and neither computer-use nor `cliclick` reaches this window — so every
row below needs a human at the keyboard.

Run against this worktree's `make run` and its `.dev/` socket only.

**CAUTION: do NOT `pkill tarmacd`.** That kills the user's installed Tarmac and
every terminal its daemon owns. `make run` pins `TARMAC_SOCKET`,
`TARMAC_STATE` and `TARMAC_DEV_SOCKET` under `$(ROOT)/.dev/`, so the dev app and
an installed app coexist. `make kill-daemon` is the correct tool. If an
installed Tarmac is running there will be two windows, both named `tarmac-app`
with bundle id `com.tarmac.desktop`; the dev window's title carries
` · 171-confirm-quit-live-terminal`.

**What to watch.** The `make run` terminal logs one line per call to the Quit
item (debug builds only):

```
tarmac: quit-key route=<guard|terminate> type=<NSEventType raw> repeat=<bool> age_ms=<n> press_ms=<n>
```

`type=10` is a keyDown, `type=1` a mouse-down. Record any two lines with the
same `press_ms` and `repeat=false`: that is the double delivery S20 guards
against, for which no path was found. `-` means the field does not apply.

**Build under test:** `make run` from this worktree at 2026-09-18 08:23,
tree = the #171 implementation (`make test` green, `cargo build` warning-free).

---

## Agent-runnable

- **S36 / D11 (`make qa`)** — with the app up, `make qa` must pass, including
  `D11 — the ⌘Q guard says whether the Quit item is really retargeted`.
  - **PASS** (2026-09-18). `19/19 checks passed`, D11 included. A bare
    `tarmac dev snapshot` reports `quit_guard: {"enabled": true,
    "retargeted": true}` — the retarget survives into the running app, and the
    dev command answers on the main thread.
- **S37 (knockout)** — comment out the `quit_intercept::install(...)` line in
  `lib.rs` (revert the line afterwards, not the file), let `tauri dev` relaunch,
  and re-run D11: it must fail with `quit_guard.retargeted` false.
  - **PASS** (2026-09-18). With the line commented out and the app relaunched,
    `snapshot --until "quit_guard.retargeted == true" --timeout 2000` exited 1
    with `{"error":"timeout"}`, and the plain snapshot read
    `{"enabled": true, "retargeted": false}`. Restoring the line put it back to
    exit 0. So D11 is not vacuous.

## Needs a human at the keyboard

- **Q1** — the grid: focus in (a) a terminal on a plain shell, (b) a terminal
  running Claude Code, (c) an HTML card, (d) a markdown card, (e) the board ×
  input sources ABC, Zhuyin, Japanese Romaji, Japanese Kana. In each cell: a tap
  shows the notice and the app stays (it fades ~1 s after release, and typing
  still reaches the card); a ~1 s hold hides the window with the notice up and
  quits only on release, with no ⌘Q reaching the app behind; no `q` is typed;
  two taps within 1 s quit.
  - **PASS with one defect, now fixed** (2026-09-18, hand-run): tap and hold
    both behave as specified. The notice's **text sat too high inside the
    slab** — an `NSTextField` draws its single line at the top of its frame,
    and the label had been given the slab's full height. Fixed by sizing the
    label to its text and centring that box (`label_y`, S39), and by zeroing the
    `NSBox`'s content-view margins: the box insets its content view by 5 pt plus
    the border, so a label centred on the slab's own height was drawn 6 pt high
    and 6 pt right. Measured from the QA screenshot (text centre 4–5 px above
    the slab centre) and reproduced headlessly in
    `scratchpad/boxprobe.swift` (text centre 41.0 vs slab centre 35.0; 35.0
    after the fix). **Re-checked by hand: centred.** The rest of the grid is
    still pending — this row was run in one cell, a plain-shell terminal under
    ABC.
- **Q2** — window minimized: a tap shows the notice on the main screen, app
  stays.
  - **PASS** (2026-09-18, hand-run).
- **Q3** — uncheck *Warn Before Quitting (⌘Q)*: `.dev/app-prefs.json` reads
  `{"warn_before_quit":false}`, `tarmac dev snapshot` shows
  `quit_guard.enabled` false, and a tap quits at once. After a relaunch the item
  is still unchecked and the snapshot still false. Re-check it: the file reads
  `true`.
  - **PASS** (2026-09-18, hand-run).
- **Q4** — a menu click on Quit, and Dock → Quit, each quit immediately
  (`route=terminate`, `type=1` for the click).
  - **PASS** (2026-09-18, hand-run).
- **Q5** — the red button hides the window and the app keeps running
  (`tarmac dev snapshot` still answers; a terminal running
  `while :; do date; sleep 1; done` keeps advancing). ⌘Tab back, a Dock click
  and Spotlight each restore it with terminals live, also while an earlier tap's
  notice is still on screen. While hidden, a tap shows the notice on the main
  screen and a hold quits. File → Close Window hides as well.
  - **PASS** (2026-09-18, hand-run).
- **Q6** — plain shell: ⌘C with a selection copies, ⌘V pastes. Claude Code: its
  fullscreen `cmd+c` selection copy still works, ⌘V pastes, ⌘H hides the app and
  ⌘M minimizes (both newly reachable).
  - **PASS** (2026-09-18, hand-run).
- **Q7** — VoiceOver announces "Hold ⌘Q to Quit", also with the window hidden.
  - **PASS** (2026-09-18, hand-run).
- **Q8** — on a `make bundle` build, a hold quits with no permission prompt
  (`CGEventSourceKeyState` has no documented TCC requirement, and `make run`
  attributes TCC to the launching terminal).
  - **Built, not yet launched** (2026-09-18). `make bundle` exits 0 and
    assembles `dist/Tarmac.app`. `strings` on the release binary finds no
    `dev_quit_guard` (the dev command is compiled out, as the three `cfg` gates
    intend) and does find the notice's text, so the guard ships.
  - **PASS** (2026-09-18, hand-run). Launched from Finder — a terminal launch
    would attribute TCC to the terminal and prove nothing — against the release
    channel. Bundle, installed app and running daemon were all 0.12.3, so no
    version-mismatch restart was risked. A tap showed the notice, a hold quit on
    release, and **no permission dialog appeared**: `CGEventSourceKeyState`
    needs no Input Monitoring grant for this use, which the design could only
    infer.
- **Q9** — Quit remapped to ⌥⌘Q in System Settings → Keyboard → App Shortcuts:
  ⌥⌘Q is guarded, plain ⌘Q does nothing, the notice reads "Hold ⌥⌘Q to Quit",
  and both hold with the switcher open and with Claude Code focused.
  - **PASS** (2026-09-18, hand-run). The shortcut was applied to the dev app's
    own defaults domain (`defaults write tarmac-app NSUserKeyEquivalents
    -dict-add "Quit Tarmac" "@~q"`, the installed app's domain untouched) and
    removed afterwards; that domain held no `NSUserKeyEquivalents` before, so
    the undo was exact. ⌥⌘Q guarded and the notice read "Hold ⌥⌘Q to Quit",
    plain ⌘Q did nothing, and both held with the switcher open and with Claude
    Code focused. This is the row that earns the retarget over matching a
    literal key: the guard follows whatever chord AppKit matched.
- **Q10** — keyboard menu navigation (⌃F2 → Quit → Return) and a VoiceOver press
  on Quit each quit immediately, including within 1 s of a guarded tap. Record
  each line's `route`.
  - **PASS** (2026-09-18, hand-run).
- **Q11** — one tap and one hold each under AZERTY, Dvorak, "Dvorak – QWERTY ⌘",
  Cangjie, Korean 2-Set, and one of Hebrew/Greek/Russian; Caps Lock on; ⌘Q
  during a Zhuyin or Japanese composition; Zhuyin with the switcher open.
  - **PASS** (2026-09-18, hand-run).
- **Q12 (freshness)** — record `age_ms` for 5 taps on an idle page. Then, in Web
  Inspector, run
  `setTimeout(() => { const t = performance.now(); while (performance.now() - t < 1000); }, 3000)`
  and tap ⌘Q during the loop, 3 times. Pass: every busy age ≤ 2000
  (`FRESHNESS_BOUND_MS`) and each busy tap still shows the notice.
  - **Idle half measured** (2026-09-18, from the first hand-run session): six
    real ⌘Q presses logged `route=guard type=10 repeat=false` with
    `age_ms` = 18, 18, 20, 22, 28, 72 — two orders of magnitude under the
    2000 ms bound. The busy-page half is still pending.
  - **Busy half PASS** (2026-09-18, hand-run): with the page frozen by the
    Inspector snippet, each tap still showed the notice.
  - Ages across the 14 presses this log captured (some rows were run in the
    operator's own `make run` session, whose log is elsewhere): 4, 8, 10, 13,
    14, 15, 18, 19, 21, 26, 27, 62, 98 and **268 ms** — the highest is an
    eighth of the 2000 ms bound.
  - Two side facts from those lines: **no two presses shared a `press_ms`**, so
    the double delivery S20 guards against did not occur; and **no
    `repeat=true` line appeared** during a ~1 s hold, which is consistent with
    Key Repeat being off on this Mac. Worth re-checking on a machine with Key
    Repeat on.
- **Q13 (switcher)** — with a terminal focused (plain shell, then Claude Code),
  open ⌘K: ⌘V pastes nothing into the terminal; letters filter; ⌘E / ⌘⌫ / ⌘1–9 /
  ⌘N / Esc behave as before; a ⌘Q tap shows the notice; ⌘H hides the app; ⌘A, ⌘Z
  and ⌘X send nothing to the PTY (`scrollback_tail` unchanged) — record what
  else they do.
  - **PASS** (2026-09-18, hand-run).
- **Q14** — ⌘W typed inside an HTML card's iframe (`App.tsx` never sees it):
  expected to hide the window, app still running.
  - **PASS** (2026-09-18, hand-run).
- **Q15** — run S37's knockout, then restore the line.
  - **Done above** (agent-runnable), no keyboard needed.
- **Q16 (notice re-show)** — under ABC with a plain-shell terminal focused, tap
  ⌘Q, then tap again ~1.1–1.2 s after the first press, while the notice still
  lingers or fades (a second press within 1 s quits; if it does, relaunch and
  retry). The notice returns to full opacity, stays up until ~1 s after the
  second release, then fades — it never vanishes early. Record the time from the
  second release to its disappearance (expected ~1.2 s).
  - **PASS** (2026-09-18, hand-run).
