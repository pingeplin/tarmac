# Say so when a version-mismatch restart cold-spawns terminals — manual QA (spec 2609.0017, #172)

S14, S15, S16 and S17 of `.blueprint/specs/2609.0017_upgrade_restart_notice.md`.
They discharge the thin-wiring exception: the three `desktop/src-tauri/src/bridge.rs`
call sites (the record write in the mismatch branch, the `note_proceeding` call
before `dispatch(app, first_msg)`, and the `annotate_restore` call in `dispatch`)
plus the `desktop/src/App.tsx` and `desktop/src/ipc/protocol.ts` changes. The
automated suites cover the decisions without a window: `restartNotice`
(`desktop/src/kit/restartNotice.test.ts`, S1 and S3–S9) and `annotate_restore` /
`note_proceeding` (`bridge.rs` `mod tests`, S2 and S10–S13e). None of them runs the
app's connect loop, so these four scenarios are the only evidence that the wiring
carries the fact from the mismatch branch to a toast:

- **S14** — the record, its `to`, the annotation, and the toast.
- **S15** — the shared latch.
- **S16** — no record, no notice.
- **S17** — the existing reconnect toast is unchanged.

Run against the worktree's `make run` and its `.dev/` socket only.

**CAUTION: do NOT `pkill tarmacd`.** That kills the user's installed Tarmac and
every terminal its daemon owns. It is also unnecessary: `make run` pins
`TARMAC_SOCKET=$(ROOT)/.dev/tarmacd.sock` and `TARMAC_STATE=$(ROOT)/.dev/state.json`
(`Makefile`), so the dev app and an installed app use different sockets and
different state and coexist fine. `make kill-daemon` is the correct tool — it
resolves the pid with `lsof -t` on *this worktree's* dev socket and cannot touch
the installed daemon. Never touch the installed app.

**If an installed Tarmac is running there will be two windows on screen**, both
named `tarmac-app` and sharing bundle id `com.tarmac.desktop`. Address the dev
window by pid, and confirm which is which before any keystroke.

**These need a human operator.** `tarmac dev` has no verb for ⌘Q, ⌘N, or board
switching, its snapshot does not report toasts, and synthetic input does not
reach the window. A toast lives for 7 s (`TOAST_TTL_MS`,
`desktop/src/kit/toasts.ts`), and more than 3 at once evicts the oldest. Watch
right after launch, or take a region screencapture, so that a toast you missed
is not recorded as "no toast".

Run **S14 → S15 → version revert → S16 → S17**, in that order.

**Build:** branch `fix/172-silent-cold-spawn-upgrade`, based on `main` @ 94ce43c.

### How this run was driven (2026-09-17, agent operator, no human at the window)

Driven from the CLI only, against this worktree's `.dev/` sockets. Deviations from
the human recipe:

1. **Arranging the boards (instead of ⌘N / ⌘T).** With no dev app and no dev
   daemon running, `.dev/state.json` was seeded: `active` = `board-0` (A) with
   two term tiles with frames and placeholder `term_id`s, plus `board-1` (B)
   with one term tile whose `term_id` is a placeholder. A setup `make run`
   (0.12.3) cold-spawned A's two shells and persisted their real ids
   (`7bac6f2e…`, `f38dca2a…`, matching the live cards in `tarmac dev snapshot`).
   B's `term_id` was never live in any daemon. That does not matter for S14, S16
   or S17, but it would for S15.
2. **Quit (⌘Q) → SIGTERM to the dev app pid.** The pid was the process holding
   `.dev/tarmac-dev.sock`, and its executable and cwd were this worktree's.
   SIGTERM skips any `beforeunload` flush, so `.dev/state.json` was checked
   before every quit. The whole `make run` tree exited with the app each time,
   and the daemon survived.
3. **Watching for toasts → captures of the dev window only.** The window was
   found by the app's pid and captured with `screencapture -l <id>` about every
   1.1 s from the moment it appeared: 25 frames per launch and 20 for S17. Frame 01 of each
   launch is the webview before it loads. A 7 s toast spans at least 5 frames,
   so from the first rendered frame on, a missing toast means no toast. The frames and logs are
   in `.dev/qa-172/` (gitignored).
4. **Versions** were confirmed with `tarmac --version` (cli, daemon and pid,
   connected app) against `.dev/tarmacd.sock`.
5. **Version bump.** Both `Cargo.toml` files were edited by line. The lockfiles
   were updated with `cargo update --workspace --offline` (version lines only)
   before `make run`, so nothing under `desktop/src-tauri` was written while
   `tauri dev` was live. For the revert, `git checkout --` restored the four files,
   which were clean before QA.
6. **Evidence of fresh shells.** Before S14, `tarmac dev type` ran
   `echo QA172-OLD-SHELL pid=$$ tty=$(tty)` in both old shells (pids 89577 and
   89578). Before S14, `tarmac dev zoom 0.5` was also run.

---

## S14 — an upgrade restart toasts the version change

- [ ] `make run`. On board A, keep its terminal. Press ⌘N to create board B and
      let its shell spawn. Switch back to A and add a second terminal (⌘T).
- [ ] Confirm `.dev/state.json` shows `active` = A, A with exactly 2 and B with
      exactly 1 `kind:"term"` tiles carrying a non-null `term_id`.
- [ ] Note `lsof -t .dev/tarmacd.sock`.
- [ ] Quit (⌘Q; the daemon survives).
- [ ] With no `make run` live, bump `version` in `core/Cargo.toml`
      (`[workspace.package]`) and `desktop/src-tauri/Cargo.toml` (e.g. 0.12.4),
      then `make run`.

**Expected:**

- Exactly one toast titled `tarmacd restarted: …`, with title
  `tarmacd restarted: 0.12.3 → 0.12.4` and body
  `2 terminals on this board were restarted`.
- Both A cards hold fresh shells.
- The socket's pid differs from the one noted.
- A "tarmacd connection lost" toast (body "version mismatch / restarting") may
  also appear if JS mounted in time; that is expected.
- **Known pre-existing race (spec, Trade-offs):** if A's fresh cards turn dead
  right after spawning and only one `tarmacd restarted` toast shows, record it
  and file it separately. It is not a failure of this spec.

**Observed:** PASS (the wiring works), with one visual finding.

- Before relaunch: the 0.12.3 daemon was pid 89346 (`tarmac --version`: daemon
  0.12.3, app 0.12.3). The state had A = `7bac6f2e…`, `f38dca2a…`. After SIGTERM
  to app 88716, daemon 89346 and both shells (89577, 89578) were still running.
- After the bump, `make run`: `.dev/tarmacd.sock` was held by 89346 until
  20:32:13.5, by nothing at 20:32:15.2, and by **96633** at 20:32:16.1. 89346,
  89577 and 89578 are gone. `tarmac --version`: cli 0.12.4, daemon 0.12.4
  (pid 96633), app 0.12.4.
- The snapshot showed A with two term cards, `d20d6374…` and `e5576bcb…` (new ids),
  both `alive: true`, `proc: zsh`. Their `scrollback_tail` is only a fresh prompt, with no
  `QA172-OLD-SHELL`. They were still alive about 25 s later, so the pre-existing
  dead-card race was **not** hit. `.dev/state.json` A now holds those two ids.
- Toasts: `s14-01` (20:32:15.0) is the webview before it loads. In `s14-02` to `s14-07`
  (20:32:16.1 to 20:32:21.8) there is **exactly one** toast: `¶ tarmacd restarted:
  0.12.3 → 0.12.4`. From `s14-08` to `s14-25` (to 20:32:41.8) there is no toast. No
  "tarmacd connection lost" toast appears in any frame: the mismatch happened
  before JS mounted, which the spec allows.
- **Finding: the body is cut off on screen.** The rendered body reads
  `2 terminals on this board were restarted as f…`. `.tm-toast-body`
  (`desktop/src/theme/chrome.css`) is `max-width: 280px; white-space: nowrap;
  text-overflow: ellipsis`, so the words "fresh shells" never show. The
  count matches the expected body, but the full string is only proven by the S1
  unit test, not on screen.
- **Follow-up:** this truncation finding led to shortening the body to
  `2 terminals on this board were restarted`. S14 was re-checked (below): the
  body now shows in full.

### S14 re-check: shortened body (2026-09-17, 21:02–21:05)

Same method as the first run (see *How this run was driven*).

**Result:** PASS. The body shows in full.

- **Setup (0.12.3).** A was re-seeded, because S17's dead cards had left A with a
  single `term_id: null` tile. App 34297 and daemon 34591 cold-spawned
  `f9860e88…` and `c5ce833a…` (both live; the state holds both ids). App 34297 was
  stopped with SIGTERM, which ended the `make run` tree. Daemon 34591 and its shells (34659, 34660) survived.
- **Bump and relaunch.** App 37597 replaced the old daemon with **37855**. `tarmac --version`
  showed cli, daemon and app all at 0.12.4. 34591, 34659 and 34660 are gone. The new live
  cards are `fba8ff90…` and `1789cfea…` (zsh, fresh prompt), and the state holds both ids.
- **Toast.** `recheck-s14-01` (21:03:47.6) is the webview before it loads.
  `recheck-s14-02` to `07` (21:03:48.7 to 21:03:54.3) show **exactly one** toast:
  `¶ tarmacd restarted: 0.12.3 → 0.12.4` / `2 terminals on this board were
  restarted`. At 4× zoom (`recheck/recheck-s14-03-toast-zoom4x.png`) the body
  ends with the full word "restarted" and no ellipsis, with padding left over inside the
  toast. `recheck-s14-08` to `25` (to 21:04:14.5) show no toast. No "tarmacd connection
  lost" toast appeared.
- **Revert and teardown.** App 37597 was stopped with SIGTERM, and then the four Cargo files were reverted
  (no `make run` was live, and their shasums match the pre-check ones). `make kill-daemon` killed 37855.
  Both dev sockets are free, and no process from this worktree is left running.

---

## S15 — later first visits do not toast again

- [ ] In the same app session as S14, switch to board B (its first visit this
      session, with a persisted `term_id` that is not live).
- [ ] Then press ⌘N and visit the new board.

**Expected:**

- B's card holds a fresh shell and no second toast appears.
- The new ⌘N board shows no toast.

**Observed:** not agent-drivable: `tarmac dev` has no board-switch or ⌘N verb, and synthetic
input does not reach the window. **Checked by hand (EP Lin, 2026-09-17), PASS**: switching to B
and a new ⌘N board showed no second toast.

---

## Version revert (between S15 and S16)

- [ ] Switch back to board A and confirm `.dev/state.json` shows `active` = A
      (`make kill-daemon` sends SIGKILL, so a save still inside the 150 ms
      persist debounce is lost), then quit.
- [ ] With no `make run` live, revert both `Cargo.toml` files and both lockfiles
      (`core/Cargo.lock`, `desktop/src-tauri/Cargo.lock`).
- [ ] `make kill-daemon` (the surviving daemon is 0.12.4).

Do not revert while `make run` is live: an edit under `desktop/src-tauri`
relaunches the app against the 0.12.4 daemon and triggers a second, unrelated
mismatch restart.

**Observed:** done (S15 skipped). The board was never switched, and `.dev/state.json` showed
`active` = `board-0` with A = `d20d6374…`, `e5576bcb…`. App 96117 was stopped with SIGTERM, which ended the
`make run` tree, and daemon 96633 survived. With nothing live, the four files were
reverted, and their shasums match the pre-QA ones. `tarmac --version` then showed daemon
0.12.4 (pid 96633) with no app connected. `make kill-daemon` killed 96633, and the
socket had no holder afterwards.

---

## S16 — negative control: a plain cold start does not toast

- [ ] With app and daemon both 0.12.3 and board A active with its two persisted
      terminals, quit if running, `make kill-daemon`, `make run`.

**Expected:**

- The terminals cold-spawn.
- No toast titled `tarmacd restarted: …` appears.

**Observed:** PASS. The daemon had been stopped with `make kill-daemon` during the revert. `make run` started app
3615 and freshly spawned daemon 4045. `tarmac --version`: cli, daemon and app all
0.12.3. The snapshot showed A with `ec784939…` and `9bb90863…` (new ids, so both were cold-spawned), both
`alive: true`, `proc: zsh`, and still alive about 28 s later. `s16-01` (20:35:00.9) is
the webview before it loads. `s16-02` to `s16-25` (20:35:02.0 to 20:35:28.1) show **no toast of
any kind**.

---

## S17 — regression: the reconnect toast is unchanged

- [ ] With the S16 app running, `make kill-daemon`.

**Expected:**

- The existing "daemon restarted — terminals lost" toast appears exactly once.
- The existing "tarmacd connection lost" toast also appears, as before this
  change.
- No toast titled `tarmacd restarted: …` appears.

**Observed:** PASS. Capture of app 3615's window started at 20:35:56.0, and
`make kill-daemon` killed 4045 at 20:35:58.25. `s17-01` to `s17-03` (before the kill)
show no toast. In `s17-04` (20:35:59.3) there are two toasts: `¶ tarmacd connection lost`
(body `daemon connection closed`, frames 04 to 09) and `¶ daemon restarted — terminals
lost` (body `open new terminals with ⌘T`, frames 04 to 10, **once**). `s17-11` to `s17-20`
(to about 20:36:17) show no toast. There is no `tarmacd restarted: …` toast in any frame. The snapshot showed both
cards `alive: false`. The app respawned daemon 6580 (`tarmac --version`: daemon
0.12.3, pid 6580). Teardown: app 3615 was stopped with SIGTERM, which ended the `make run` tree, and `make
kill-daemon` killed 6580. Neither dev socket has a holder, and no process from this worktree is left.
