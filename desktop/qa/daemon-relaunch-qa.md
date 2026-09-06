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

Given `make run` connected, when the app window is closed and `make run` is
issued again, the app must reach connected without `make kill-daemon` in
between. Note that run 1's daemon is orphaned but *alive* across a window close,
so the expected path is "run 2 simply reconnects to it" — a changed pid here is
itself a finding.

- [ ] Round 1: `make run`, wait for connected, close the window, `make run`
      again. Record: reached connected (y/n), time to connected, the
      `lsof -t` pid before and after.

      Observation:

- [ ] Round 2: repeat.

      Observation:

- [ ] Round 3: repeat.

      Observation:

- [ ] Round 4 — **the SIGHUP path**: `make run`, wait for connected, then close
      the *dev terminal itself* (not just the window), so the shell's session
      gets SIGHUP. Open a new terminal, `make run` again. Record whether the
      daemon survived the terminal's teardown (`lsof -t .dev/tarmacd.sock`
      immediately after closing it) and whether the app reached connected.

      Observation:

- [ ] **Pass iff** every round reaches connected with no `make kill-daemon`, and
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

- [ ] **Against `main`** (`git stash` the change, or a second worktree at
      `9175b49`): run the three commands above. Record the observed give-up time
      and the final status string.

      Observed give-up time:

      Final status string:

- [ ] **Against this branch**: run the same three commands. Record time to
      reconnect, the final status, and the `lsof -t .dev/tarmacd.sock` pid before
      the kill and after the recovery (they must differ — that is the respawn).

      Time to reconnect:

      Pid before / after:

- [ ] **Pass iff** `main` reaches "could not reconnect to tarmacd" and stays
      there, and this branch returns to connected on its own with a new pid.

      Observation:

---

## S11 — dev logging survives the move off the inherited pipe

D1 redirects the daemon's stdout/stderr into `.dev/tarmacd.log` instead of the
`make run` terminal. The output must still be reachable — `tail -f
.dev/tarmacd.log` replaces watching the terminal.

- [ ] `make run`. Confirm `.dev/tarmacd.log` exists, and that
      `tail -f .dev/tarmacd.log` shows the `tarmacd (dev) listening on …` line
      and grows as the app is used (open a terminal card, `tarmac open` a doc).

      Observation:

- [ ] `make kill-daemon`, then `RUST_LOG=debug make run`. Confirm `DEBUG` lines
      appear in `.dev/tarmacd.log` (`spawn_daemon` overrides only `PATH`, so
      `RUST_LOG` is inherited by the child).

      Observation:

- [ ] Confirm the truncate behaviour end to end: note the file's size, then
      `make kill-daemon` and `make run` again — the file must restart from the
      new daemon's first line, not append below the old session.

      Observation:

- [ ] **Pass iff** the log exists, carries `info` output by default and `debug`
      output under `RUST_LOG=debug`, and starts fresh at each daemon launch.

---

## S12 — a detached daemon still drives PTYs

`setsid()` changes the daemon's session, and a session leader with no
controlling terminal can in principle acquire one by opening a tty. The hazard
was probed directly on macOS and does not exist (the spec's Trade-offs section
records the `setsid()` → `openpty()` → `open("/dev/tty")` probe returning ENXIO
both before and after). **This check has no automated counterpart on purpose** —
`make test`'s PTY suites spawn their daemon from the harness, which is not a
session leader, so they never exercise the changed condition, and the integration
scenario that would have covered it could not be made to go red under any
implementation.

- [ ] `make run` with the detached daemon. Open a terminal card (⌘T), run
      something interactive and something noisy (`vim`, then `ls -R /usr` or
      `yes | head -100000`). Confirm output flows and the card stays responsive.

      Observation:

- [ ] Close the card. Confirm it exits cleanly and the shell process is gone
      (`ps -p <pid>` on the pid the card reported, or check no orphan shell
      remains).

      Observation:

- [ ] Confirm the daemon is still connected afterwards — the status chrome still
      reads connected, and `lsof -t .dev/tarmacd.sock` reports the same pid as
      before the card was opened. A card teardown SIGHUPs the card's process
      group; the daemon must not be in it.

      Observation:

- [ ] Repeat with two cards open at once, closing them in the reverse order they
      were opened.

      Observation:

- [ ] **Pass iff** output flows in every card, every card exits cleanly, and the
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
