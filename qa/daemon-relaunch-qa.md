# The daemon spawn path stops locking itself out — manual QA (spec 2609.0004, #26)

S10, S10b, S11 and S12 of
`.blueprint/specs/2609.0004_dev_daemon_relaunch_recovery.md`. These four are [Q]
scenarios because each one is a property of the *running dev app* — whether the
Tauri backend reaches connected, what it does with a daemon that dies underneath
it, and whether a detached daemon still drives a real PTY. The automated suites
cover the parts that can be observed without a window: session id, the log file,
the `may_spawn` truth table (`desktop/src-tauri/src/bridge.rs` `mod tests`) and
the SIGHUP shutdown (`core/crates/tarmacd/tests/daemon_basics_integration.rs`).
None of them exercises the app's connect loop, so **S10b below is the only
positive demonstration that the lockout is fixed.**

Run against `make run`.

**CAUTION: do NOT `pkill tarmacd`.** That kills the user's installed Tarmac and
every terminal its daemon owns. It is also unnecessary: `make run` pins
`TARMAC_SOCKET=$(ROOT)/.dev/tarmacd.sock` and `TARMAC_STATE=$(ROOT)/.dev/state.json`
(`Makefile`), so the dev app and an installed app use different sockets and
different state and coexist fine. `make kill-daemon` is the correct tool — it
resolves the pid with `lsof -t` on *this worktree's* dev socket and cannot touch
the installed daemon.

**If an installed Tarmac is running there will be two windows on screen**, both
named `tarmac-app` and sharing bundle id `com.tarmac.desktop`. Address the dev
window by pid, and confirm which is which before any keystroke.

## Reading the connection state

Every scenario below is decided by the app's connection status chrome —
"connected" vs. the disconnected reason text `bridge.rs::emit_status` emits
("connect failed: …", "daemon connection closed", "could not reconnect to
tarmacd"). **"could not reconnect to tarmacd" is the terminal state**: the
reconnect budget is spent, `connection_loop` has `break`ed, and nothing short of
quitting the app brings it back (D4, knowingly out of scope). Any scenario that
reaches that string has failed.

Two supporting observations, both cheap:

- `lsof -t .dev/tarmacd.sock` — the pid of the daemon currently holding this
  worktree's socket. A *changed* pid means a respawn happened.
- `ps -o pid,sess,command -p <pid>` — after the fix the daemon's session id is
  its own pid (it is a session leader), not the `make run` shell's.

---

## S10 — close and relaunch reaches connected

> **Method note.** "Close the window" was performed as a `SIGTERM` to the Tauri
> app process, which is what quitting the app does; no mouse was used. Round 4's
> "close the dev terminal" was performed as `kill -HUP` to the app's process
> group — precisely the signal a terminal hangup delivers to its foreground
> group. "Reached connected" was judged from the daemon's own log
> (`app connected (generation N)` incrementing), which is a stronger signal than
> the status chrome.

Given `make run` connected, when the app window is closed and `make run` is
issued again, the app must reach connected without `make kill-daemon` in
between. Note that run 1's daemon is orphaned but *alive* across a window close,
so the expected path is "run 2 simply reconnects to it" — a changed pid here is
itself a finding.

- [x] Round 1: `make run`, wait for connected, close the window, `make run`
      again. Record: reached connected (y/n), time to connected, the
      `lsof -t` pid before and after.

      **Observation (2026-09-06, 23:15 CST).** Fresh start, no prior daemon.
      Connected in **8.6 s**. Daemon pid **14051**, app pid 13702, log shows
      `app connected (generation 1)`. Baseline for the rounds below.

- [x] Round 2: repeat.

      **Observation.** Before: daemon **14051**. App closed → app gone,
      **daemon 14051 survived**. Relaunch with no `make kill-daemon`: connected
      in **9.3 s**, generations 1 → 2, daemon after = **14051, the same one**.
      Exactly the predicted path — run 1's daemon is orphaned but alive and run
      2 reconnects to it rather than spawning.

- [x] Round 3: repeat.

      **Observation.** Before: daemon **14051**. App closed → daemon survived.
      Relaunch: connected in **7.3 s**, daemon after = **14051, unchanged**.
      *Noise disclosure:* the generation counter read 79 → 80 rather than 2 → 3,
      because two stray dev apps of mine (one orphaned into a reconnect loop)
      had been connecting repeatedly between rounds. That inflates the counter
      only; the daemon pid and the reconnect timing are unaffected.

- [x] Round 4 — **the SIGHUP path**: `make run`, wait for connected, then close
      the *dev terminal itself* (not just the window), so the shell's session
      gets SIGHUP. Open a new terminal, `make run` again. Record whether the
      daemon survived the terminal's teardown (`lsof -t .dev/tarmacd.sock`
      immediately after closing it) and whether the app reached connected.

      **Observation — the D1 proof.** Before the signal: app pid 19013, sid
      **18440**, pgid 18440 (the `make run` session); daemon 14051, sid
      **14051**, its own session and its own process group. Sent
      `kill -HUP -18440` — SIGHUP to the app's entire process group, which is
      what a terminal hangup delivers. Result: **app gone; daemon 14051 alive
      and still holding the socket**; socket file present. Relaunch: connected
      in **7.3 s** to the **same daemon 14051**, generations 80 → 81.
      This is D1 end to end in the real app: the terminal's SIGHUP lands on the
      app's session and misses the daemon entirely.

- [x] **Pass iff** every round reaches connected with no `make kill-daemon`, and
      round 4's daemon is still holding the socket after the dev terminal closes
      (that is D1: it is in its own session, so the terminal's SIGHUP misses it).

---

## S10b — the positive repro: a daemon killed underneath the app

*This is the defect demonstration.* It forces both necessary conditions from the
spec: the app itself is the spawner (so it latches), and the daemon it spawned
then stops listening.

```
make kill-daemon      # so the app, not a survivor, becomes the spawner
make run              # wait for connected
make kill-daemon      # from a SECOND shell, leaving the app running
```

**On `main` this must fail**: `connect()` misses the stale socket, the bare
`!*spawned` test is already false, no respawn ever happens, and after ~123 s of
visible retrying the status settles on "could not reconnect to tarmacd" for the
lifetime of the process. **After the change it must self-heal**: a new daemon is
spawned within the reconnect budget and the status returns to connected.

- [x] **Against `main`** (`git stash` the change, or a second worktree at
      `9175b49`): run the three commands above. Record the observed give-up time
      and the final status string.

      **Observed give-up time.** Control run on `~/workspace/tarmac` at
      **9175b49** (the fix absent). The app (pid 98680) spawned daemon 99077 —
      confirmed by ppid — so `spawned` was latched. `make kill-daemon`, then
      **200 s of polling: no respawn ever appeared on the socket.** The app
      stayed alive throughout and the stale socket file remained. The exact
      instant the retry budget was exhausted was **not** timestamped; the
      terminal state was read after the 200 s window.

      **Final status string.** Read off the window with `screencapture` after
      the poll, with this branch's dev app shut down first so only one `board-0`
      window remained and the reading was unambiguous:
      **`could not reconnect to tarmacd`** — the terminal state this sheet
      names. It never recovered.

- [x] **Against this branch**: run the same three commands. Record time to
      reconnect, the final status, and the `lsof -t .dev/tarmacd.sock` pid before
      the kill and after the recovery (they must differ — that is the respawn).

      **Time to reconnect: 1.7 s.** Daemon 87015 killed with `make kill-daemon`
      while the app (86673) kept running; a new daemon appeared on the socket
      1.7 s later.

      **Pid before / after: 87015 → 91896.** Different pids — the app started a
      *new* daemon rather than reattaching, which is the respawn.

- [x] **Pass iff** `main` reaches "could not reconnect to tarmacd" and stays
      there, and this branch returns to connected on its own with a new pid.

      **Observation — pass.** The control at `9175b49` reached
      `could not reconnect to tarmacd` and never left it; this branch recovered
      on its own in 1.7 s with a new daemon pid. The contrast is 1.7 s against
      200 s of nothing, on the same command sequence.

---

## S11 — dev logging survives the move off the inherited pipe

D1 redirects the daemon's stdout/stderr into `.dev/tarmacd.log` instead of the
`make run` terminal. The output must still be reachable — `tail -f
.dev/tarmacd.log` replaces watching the terminal.

- [x] `make run`. Confirm `.dev/tarmacd.log` exists, and that
      `tail -f .dev/tarmacd.log` shows the `tarmacd (dev) listening on …` line
      and grows as the app is used (open a terminal card, `tarmac open` a doc).

      **Observation.** `.dev/tarmacd.log` exists and carries
      `tarmacd (dev) listening on …` as its first line at the default level. It
      grows with use — a `tarmac open` took it from 3 to 4 lines.
      **Finding against this checklist's own wording:** at `info` a
      `tarmac open` writes *nothing* (`doc opened via cli` is a `DEBUG` event);
      what grows the log at `info` is app connects. Anyone using this sheet to
      watch document activity needs `RUST_LOG=debug`.

- [x] `make kill-daemon`, then `RUST_LOG=debug make run`. Confirm `DEBUG` lines
      appear in `.dev/tarmacd.log` (`spawn_daemon` overrides only `PATH`, so
      `RUST_LOG` is inherited by the child).

      **Observation.** `RUST_LOG=debug make run` → `ps eww` shows
      `RUST_LOG=debug` on **both** the app and the daemon it spawned, so the
      variable does flow `make` → npm → cargo → app → `spawn_daemon`. A
      `tarmac open` then produced
      `DEBUG tarmacd::docs: doc opened via cli: /private/tmp/qa26-probe.md`.
      Debug output is reachable.

- [x] Confirm the truncate behaviour end to end: note the file's size, then
      `make kill-daemon` and `make run` again — the file must restart from the
      new daemon's first line, not append below the old session.

      **Observation — truncate confirmed.** Before: **27 339 bytes, 238 lines,
      81 `app connected` entries** (one long-lived daemon). Then
      `make kill-daemon` + relaunch. After: **492 bytes, 3 lines, 1
      `app connected`**, first line the new daemon's `removing stale socket`.
      The file restarts at each daemon launch rather than appending — the
      decided truncate-on-open semantics, working.

- [x] **Pass iff** the log exists, carries `info` output by default and `debug`
      output under `RUST_LOG=debug`, and starts fresh at each daemon launch.

---

## S12 — a detached daemon still drives PTYs

> **Method note — this scenario was substituted, and the substitution is not
> free.** ⌘T could not be delivered to the app (see `new-card-zoom-scale-qa.md`
> for that blocker), so the PTY cycle was driven **over the wire** against the
> live dev daemon instead: a client speaking the length-prefixed MessagePack
> protocol sent `hello` / `spawn_term` / `input` / `term_close` and read the
> `output` and `Exit` frames back. The daemon under test was verified to be a
> real session leader first (`getsid(pid) == pid`), so the condition D1 changes
> *was* exercised. **What this does not cover:** the app's own rendering and
> card teardown path, `vim` or any full-screen TUI, and sustained noisy output.
> The OS-level property S12 exists for — a detached daemon drives PTYs and
> survives a card teardown's process-group SIGHUP — is covered; the UI half is
> not.

`setsid()` changes the daemon's session, and a session leader with no
controlling terminal can in principle acquire one by opening a tty. The hazard
was probed directly on macOS and does not exist (the spec's Trade-offs section
records the `setsid()` → `openpty()` → `open("/dev/tty")` probe returning ENXIO
both before and after). **This check has no automated counterpart on purpose** —
`make test`'s PTY suites spawn their daemon from the harness, which is not a
session leader, so they never exercise the changed condition, and the integration
scenario that would have covered it could not be made to go red under any
implementation.

- [x] `make run` with the detached daemon. Open a terminal card (⌘T), run
      something interactive and something noisy (`vim`, then `ls -R /usr` or
      `yes | head -100000`). Confirm output flows and the card stays responsive.

      **Observation (protocol-level — see the Method note above).** Against
      the live detached daemon **22292** (`getsid(22292) == 22292`, a genuine
      session leader, so the changed condition really was exercised):
      `spawn_term` with `/bin/cat`, then `input` `hello-from-qa` → the same
      bytes came back as `output` (`b'hello-from-qa\r\n'`). The PTY child
      appeared under the daemon as pid **24700**. Output flows.

- [x] Close the card. Confirm it exits cleanly and the shell process is gone
      (`ps -p <pid>` on the pid the card reported, or check no orphan shell
      remains).

      **Observation.** `term_close` → `Exit` received for that `term_id` with
      `code = None`, i.e. terminated by signal — the `kill(-pid, SIGHUP)`
      teardown path. `ps` immediately afterwards showed **no `/bin/cat` child
      remaining** under the daemon. Clean exit, no orphan.

- [x] Confirm the daemon is still connected afterwards — the status chrome still
      reads connected, and `lsof -t .dev/tarmacd.sock` reports the same pid as
      before the card was opened. A card teardown SIGHUPs the card's process
      group; the daemon must not be in it.

      **Observation.** After the teardown a fresh `cli` connection got
      `hello_ok` from **daemon 22292 — the same pid as before the card was
      opened**. The daemon is not in the card's process group and the card's
      SIGHUP did not touch it. (Connection state was read from the daemon side,
      not the status chrome — see the Method note.)

- [x] Repeat with two cards open at once, closing them in the reverse order they
      were opened.

      **Observation.** Two cards (`qaA`, `qaB`) spawned; both produced output.
      Closed in **reverse order** (`qaB` then `qaA`): both `Exit` messages
      arrived, in that order. No orphan `/bin/cat` processes remained, and a
      fresh `cli` hello still reached daemon 22292.

- [x] **Pass iff** output flows in every card, every card exits cleanly, and the
      daemon's pid is unchanged and still connected at the end.

---

## Known limitations to expect while running these

Both are recorded in the spec's Trade-offs and are **not** QA failures:

- **Ctrl-C on `make run` no longer stops the daemon.** It is in its own session,
  so it survives every Ctrl-C, and `should_restart` compares package versions —
  which a same-version rebuild never trips. After changing daemon code, run
  `make kill-daemon` or you will keep reconnecting to stale daemon code.
- **A respawn erases the previous daemon's log.** The log is truncate-on-open. If
  you are chasing a crash-then-relaunch, copy `.dev/tarmacd.log` before
  relaunching.
