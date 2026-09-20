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
` · <worktree name>` — ` · 171-confirm-quit-live-terminal` for the #171 runs,
` · 179-quit-poll-run-loop-timer` for #179's.

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

**After these rows were run**, a `/simplify` pass landed a behaviour-preserving
refactor of the same wiring (the notice text is computed at the call site, the
retarget check reads selectors instead of comparing targets, `HiddenByClose`
owns its own atomic, the debug log line is built from fewer arguments). The log
line's format is unchanged, `make test` and `make qa` are green on the refactor,
and S37's knockout was re-run against it. **Not yet re-checked by hand:** one tap
and one hold on the refactored build would re-earn the keyboard rows above.

**#179 moved the release poll to a main-run-loop timer**
(`refactor/179-quit-poll-run-loop-timer` @ `779f9b1`, 2026-09-18). The detached
polling thread is now a repeating `NSTimer` in `NSRunLoopCommonModes`, which
`StopPolling` invalidates synchronously. That changes how release is detected,
so every row that depends on a real hold or release is owed again. What was
re-earned without a keyboard:

- `make test` green, `make qa` 19/19 with D11, and S37's knockout re-run (both
  below).
- **The timer under tao, in isolation.** A standalone tao 0.35.3 / objc2 0.6.4
  harness (main checkout `.dev/nstimer-179/`, three runs) posted an in-process
  ⌘J keyDown. AppKit routed it through `-[NSMenu performKeyEquivalent:]` to a
  target/selector action, and that action created the timers.
  - A common-modes timer first fired about 51 ms after the action returned,
    then every 50.0 ms (p95 at most 50.8).
  - It kept firing while a pop-up menu was tracking (14 fires, all in
    `NSEventTrackingRunLoopMode`) and while tracking mode was forced (10
    fires). Default-mode timers fired 0 times in both.
  - `invalidate()` was called three ways: inside the timer's own fire, from
    another menu action, and from another timer, each after a 120 ms stall.
    Every time, 0 fires followed.
  - `[NSRunLoop currentMode]` is nil inside the key-equivalent action.
  - Not covered: the tauri/wry/muda layers, a real keypress, and a menu-bar
    menu opened with the mouse.
- **The timer in the real app.** A temporary probe (reverted; its log is in the
  main checkout at `.dev/nstimer-179/in-app-probe.log`) fed `on_quit_key` from
  `.setup()` and logged every poll.
  - Tap: one fire 88 ms after the start. Key 12 read up, the effects were
    `[LingerThenFadeHud, StopPolling]`, and no fire followed.
  - Hold (the probe forced `held` for the first 12 fires): a fire about every
    50 ms in `kCFRunLoopDefaultMode`, `[HideWindows]` on fire 10 at +509 ms,
    and `[StopPolling, Exit]` on fire 13. The app then exited through
    `app.exit(0)` called from the timer callback.

**Hand-run on this build (2026-09-19).** Q1, Q11, Q12 and Q16 are the rows
#179 names.
- **Build.** Both `make run` sessions ran `391b6ef`. The later `dd1bd38` only
  turns `Confirming` into a unit variant; it is behaviour-identical, and the
  suite is green on it.
- **Evidence.** The `quit-key` lines are in the main checkout's
  `.dev/nstimer-179/make-run-handqa.log`. "Line n" below means the n-th
  `quit-key` line in that file.
- **Two rows without log lines.** The operator ran every row on the dev app.
  The log backs Q1, Q12's idle half and Q16. For Q11 and Q12's busy half the
  record is the operator's confirmation (see those rows).

The Q1 cell (plain shell × ABC) also pays the `/simplify` debt above.

---

## Agent-runnable

- **S36 / D11 (`make qa`)** — with the app up, `make qa` must pass, including
  `D11 — the ⌘Q guard says whether the Quit item is really retargeted`.
  - **PASS** (2026-09-18). `19/19 checks passed`, D11 included. A bare
    `tarmac dev snapshot` reports `quit_guard: {"enabled": true,
    "retargeted": true}` — the retarget survives into the running app, and the
    dev command answers on the main thread.
  - **PASS on #179** (2026-09-18, `37b4c3b`, then again on `779f9b1`).
    `19/19 checks passed`, D11 included, and the snapshot read
    `{"enabled": true, "retargeted": true}`. The `779f9b1` run's output is in
    the main checkout at `.dev/nstimer-179/qa-779f9b1.log`.
- **S37 (knockout)** — comment out the `quit_intercept::install(...)` line in
  `lib.rs` (revert the line afterwards, not the file), let `tauri dev` relaunch,
  and re-run D11: it must fail with `quit_guard.retargeted` false.
  - **PASS** (2026-09-18). With the line commented out and the app relaunched,
    `snapshot --until "quit_guard.retargeted == true" --timeout 2000` exited 1
    with `{"error":"timeout"}`, and the plain snapshot read
    `{"enabled": true, "retargeted": false}`. Restoring the line put it back to
    exit 0. So D11 is not vacuous.
  - **PASS on #179** (2026-09-18, `37b4c3b`, then again on `779f9b1`).
    Knocked out, the same `--until` exited 1 with `retargeted: false`, and
    `make qa` failed D11 with `exit code: expected 0, got 1`. With the line
    restored it exited 0 and the tree was clean again. The `779f9b1` run's
    output is in the main checkout at `.dev/nstimer-179/s37-knockout-779f9b1.log`.

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
  - **#179: PASS** (2026-09-19, hand-run, plain shell × ABC).
    - Line 1 is a tap (`route=guard`, `age_ms=70`), and the app stayed up.
    - Line 2 is a hold (`age_ms=30`). The app exited after it, ending the first
      session.
    - Lines 18–19 are two taps 163 ms apart. The app exited, ending the second
      session.
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
  - **#179: PASS** (2026-09-19, hand-run on the dev app, operator-confirmed).
    These presses cannot be matched to lines in the captured log: no Q11
    hold appears there, because the second session (lines 3–19) never exited
    before its final double tap. The operator confirmed that the row ran on
    the dev app, not on the installed 0.13.0.
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
  - **#179: idle half PASS; busy half reported, not yet in the log.**
    - Idle: lines 6–10 are five taps 1.7–2.2 s apart, all `route=guard`,
      with `age_ms` 9, 11, 14, 17, 11.
    - Busy: PASS (hand-run on the dev app, operator-confirmed). No press in
      the captured log carries the delay a frozen page adds: the highest age in
      the second session is 59 ms, while #171's busy taps reached 268 ms. So
      this half rests on the operator's confirmation, as Q11 does.
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
  - **#179: PASS** (2026-09-19, hand-run).
    - Lines 13–17 are taps 1.2–1.4 s apart, all `route=guard`.
    - The app stayed up throughout, so none of them landed inside the 1 s
      second-tap window.
    - The operator saw the notice return to full opacity each time.
    - The time from release to disappearance was not recorded.

---

## #183 — the guard driven from `tarmac dev press` (spec 2609.0018)

`press` posts a native ⌘ chord in-process with a debug-only key-held override,
and `quit_guard` now reports `phase`, `notice` and `last_press`. The rows below
are the spec's `[D]` scenarios (`make qa` D12–D19, `make qa-quit`), each with its
knockout run, plus the `[QA]` rows S22 and S33–S35. `desktop/qa/qa-driver-qa.md`
records the driver-side rows (D12–D19 as driver scenarios, S36).

**Build under test:** `feat/183-quit-guard-qa-driver`, 2026-09-20: the first
`make qa` runs and the TS knockouts at `b1cb7c4` plus the then-uncommitted
scripts; S36 at `03f72df`; S35 at `3d424a8`; the Rust knockouts, `make
qa-quit`, S22, S33 and S34 at `2268085` (which carries the one defect the
knockouts found, below). `make test` green throughout. Screen unlocked
(`CGSSessionScreenIsLocked 0`) for every run recorded as a result; the runs
that hit a locked screen are named as such.

### Which Q rows the driver now covers

| Row | Driver | Notes |
|---|---|---|
| Q1 tap, plain shell × ABC | **D12** | `route=guard`, `phase == "showing"`, notice visible, prompt clean |
| Q1 tap, board | **D14** | |
| Q1 tap, markdown card | **D17** | focus via the DOM plan (`active_element.tag == "BODY"`) |
| Q1 tap, HTML card | **D18** | `IFRAME` focused, `borrowed == true`; the fixture knockout shows the ⌘Q passes through the frame |
| Q1 tap, Claude Code (kitty flags 5) | **D13** | a plain shell with flags 5 pushed, #171's headline case; a real Claude Code session stays manual |
| Q1 hold hides then quits on release | **`make qa-quit CASE=hold`** | the override stands in for the physical key read |
| Q1 two taps within 1 s quit | **`CASE=double`** | |
| Q12 freshness, idle half | **D12** (`0 <= age_ms <= 2000`) | idle `age_ms` 2–24 across 50 driver presses this run |
| Q12 freshness, busy half | **D19** (`press --busy 1000`) | `age_ms` 968–973 |
| Q16 re-show | **D15** | second press while the first notice fades; `alpha` back to 1; lingers ≥ 900 ms |
| stale press (S7 of 2609.0016) | **`CASE=stale`** | `--age 2500 --hold 1` |
| ⌘T / ⌘W as page shortcuts | **D16** | proves the verb is not ⌘Q-specific |

**Still manual:** Q1 × Zhuyin / Japanese (the chord's characters are supplied,
so the input source plays no part), Q1's real Claude Code cell, Q2 (minimised;
`press` answers `not_key` there, S34), Q3 (the toggle), Q4 (a menu click), Q5
(the red button), Q6 (⌘C/⌘V have no snapshot field), Q7 (VoiceOver), Q8 (the
release bundle's physical key read — the override bypasses it), Q9 (a remap:
`press alt+cmd+q` can press it, but the row also reads the notice's text), Q10,
Q11, Q13, Q14.

### Results

- **`make qa`** — **PASS, 27/27** (first run; S21 skipped because the dev app
  was already frontmost), then **PASS, 28/28** with Finder raised first
  (`open -a Finder`), which exercised S21: `activated == true` and the frontmost
  pid after the press was the dev app's.
  - Every driver press this session logged `route=guard type=10 repeat=false`
    (60 `quit-key` lines): idle `age_ms` 2–24 (one first-press 93), busy
    968–973 at `--busy 1000`.
- **Knockouts (each reverted by the line, and the run re-passed after):**
  - **S11** (kitty rule in `kit/termKeyRoute.ts` prefixed `false &&`): D13
    **FAIL** — `quit_guard.last_press.press_ms ~= …` never held (xterm swallowed
    the key). The `finally` popped the flags and D14–D19 still passed, 26/27.
  - **S14** (`App.tsx`'s ⌘T branch returns before `spawnNewTerminal()`): D16
    **FAIL** — no new terminal card appeared within 3000 ms of ⌘T.
  - **S18** (`dispatchStep`'s `page-body` case does nothing): D17 **FAIL** —
    `active_element.tag` expected `BODY`, got `TEXTAREA`.
  - **S19, `doc-iframe` case does nothing:** D18 **FAIL** — `active_element.tag`
    expected `IFRAME`, got `TEXTAREA`.
  - **S19, `doc-shield` case does nothing:** D18 **FAIL** —
    `cards[].borrowed` expected `true`, got `false` (`active_element` still read
    `IFRAME`, as V4 predicts: only `borrowed` catches this one).
  - **S19, fixture `keydown` → `preventDefault()` (in `smoke.mjs`, not on
    disk):** D18 **FAIL** — the matching wait timed out: the frame handled the
    ⌘Q and the menu never saw it. So D18's ⌘Q really passes through the frame.
  - **S10** (`Effect::ShowHud` does nothing): D12 **FAIL** — `notice.visible`
    expected `true`, got `false`; so did every other ⌘Q row (D13, D14, D15,
    D17, D18, D19), 20/27. D16 still passed: ⌘T/⌘W never show a notice.
  - **S13** (no `hud_gen` bump in `show_notice`): D15 **FAIL** — after the
    second press, `quit_guard.notice.alpha == 1` never held within 300 ms: the
    first notice's fade kept stepping the re-shown notice down. (The spec
    predicted the later `visible == false` check would catch it; the fade's
    alpha steps are what the scenario met first.)
  - **S21** (the "already key?" test always true, Finder in front): D12's
    tap **passed** (the post went straight to the inactive app's menu and
    still routed `guard`, as spike 2 found) and S21 **FAIL** — `activated`
    expected `true`, got `false`. Two more rows failed under it and are worth
    knowing: D16 (⌘W went to the native Close Window item, and the new
    terminal stayed on the board) and D19 (`age_ms` read 1: the post bypassed
    the frozen page). 25/28.
    - The first attempt at this knockout surfaced a **real defect**: with the
      app inactive, `NSApp.mainWindow` is nil, and `post_key` answered
      `app_not_ready` instead of posting. Fixed in `2268085` (`press` now
      addresses Tauri's `main` window, as `notice_screen` does); the normal
      run re-passed 28/28 before the knockout was re-run.
  - **S24** (the `eval` skipped): D19 **FAIL** — the press exited 51 ms after
    spawn (no freeze to wait out), 26/27.
  - The first S10/S13 attempts ran into a locked screen (every press
    `not_key`, 19/27): inconclusive, not a result. Both were re-run unlocked
    (above).
- **`make qa-quit`** — each **PASS**, one per fresh `make run`:
  - `CASE=hold` (S15): `route=guard`, `confirming` with the notice up,
    `visibility == "hidden"`, still answering at +1500 ms, gone **1993 ms**
    after the reply.
  - `CASE=double` (S16): two presses 182 ms apart, the second routed `guard`
    into `confirming`, gone **477 ms** after the second reply.
  - `CASE=stale` (S17): gone **4 ms** after the CLI exited; the `make run`
    line read `quit-key route=terminate type=10 repeat=false age_ms=2549`.
  - **Knockouts**, each also one fresh `make run`, the app then stopped by pid:
    - S15 (the `|| self.held_override(key_code)` dropped from `on_poll`):
      `CASE=hold` **FAIL** — `phase == "confirming"` never held; the app
      stayed up.
    - S16 (`recent` always false in `on_quit_key`): `CASE=double` **FAIL** —
      phase after the second tap expected `confirming`, got `showing`; the
      app stayed up.
    - S17 (`FRESHNESS_BOUND_MS` = 10 000): `CASE=stale` **FAIL** — the app
      still answered 1000 ms on; its line read `route=guard … age_ms=2545`.
- **S22** — **PASS**. With Finder raised (`open -a Finder`, frontmost
  confirmed by `lsappinfo`), `press cmd+q --hold 300` replied
  `activated: true`, the frontmost app read `tarmac-app` afterwards, the line
  was `route=guard … age_ms=48`, and a temporary libc `backtrace_symbols_fd`
  probe at the top of `on_quit` (reverted) showed **9 WebKit frames**
  (`WebPageProxy::didReceiveEvent → PageClientImpl::doneWithKeyEvent →
  WebViewImpl::doneWithKeyEvent → … → -[NSMenu performKeyEquivalent:]`): the
  page saw the key first. A control press with the window already key gave
  the same 9 frames. (Rust's `std::backtrace` names none of those frames;
  only the libc probe does.)
- **S33** — **PASS**. With `quit_intercept::install(...)` commented out in
  `lib.rs` (reverted), the snapshot read `retargeted: false`; `press cmd+q`
  exited 1 with `not_retargeted` ("would reach a native terminate: item …
  not posted") and **the app stayed up**; `press cmd+t` exited 0 and a new
  terminal card appeared, so only the Quit chord is refused.
- **S34** — **PASS**. `press cmd+m` minimised the window (`visibility`
  `"hidden"`); `press cmd+q` then exited 1 with `not_key` after **1032 ms**
  (`KEY_WAIT_MS` plus hops), the app stayed up, and `last_press` stayed
  `null`, so nothing was posted. `activateIgnoringOtherApps(true)` made the
  app frontmost but did **not** un-minimise the window, as the row expected.
- **S35** — **PASS** (2026-09-20, `make bundle` at `3d424a8`). `strings` on
  `dist/Tarmac.app/Contents/MacOS/tarmac-app` finds `dev_press`,
  `dev_quit_guard` and `not_retargeted` **0** times each (the debug binary has
  each once) and the notice's text once, so the guard ships and the verb does
  not. The bundled CLI's `tarmac dev snapshot` prints
  `tarmac: driver unavailable in release builds` and exits 1.
