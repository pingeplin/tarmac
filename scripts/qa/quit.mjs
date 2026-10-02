#!/usr/bin/env node
// The ⌘Q guard's QUITTING scenarios (spec 2609.0018, issue #183): S15 (a hold
// hides, then quits on release), S16 (two taps within 1 s quit) and S17 (a
// stale press quits at once). Each ends the app, so each is one `CASE` per
// fresh `make run`. The cases that leave the app running are in `smoke.mjs`.
//
// Run:  make qa-quit CASE=hold|double|stale    (default hold)

import {
  eq,
  json,
  dev,
  snapshot,
  sleep,
  waitFor,
  runner,
  preflight,
  pressQuit,
  pressQuitAgain,
  pressBody,
  matchPress,
  waitGone,
} from "./lib.mjs";

const run = runner("make qa-quit");
const CASE = process.env.CASE ?? "hold";

const cases = {
  async hold(term) {
    console.log("\nS15 — a hold hides the window, then quits on release (CASE=hold)");
    await run.checkAsync("press cmd+q --hold 2000", async () => {
      // 2000 rather than Q1's ~1 s: `visibility` lags the hide, and at a 1 s
      // hold the app exits about 500 ms after it.
      const r = await pressQuit("--hold", "2000");
      const body = pressBody(r);
      eq(matchPress(body.press_ms).quit_guard.last_press.route, "guard", "last_press.route");
      const confirming = waitFor(term, 'quit_guard.phase == "confirming"', "--timeout", "1000");
      eq(confirming.quit_guard.notice.visible, true, "notice.visible while confirming");
      waitFor(term, 'visibility == "hidden"', "--timeout", "1000");
      await sleep(Math.max(0, r.exitedAt + 1500 - Date.now()));
      eq(dev("snapshot").code, 0, "snapshot at +1500 ms: the key still reads held, the app has not quit");
      const gone = await waitGone(r.exitedAt + 3500 - Date.now());
      console.log(`       gone ${gone - r.exitedAt} ms after the reply`);
    });
  },

  async double(term) {
    console.log("\nS16 — two taps within 1 s quit on release (CASE=double)");
    await run.checkAsync("press cmd+q, then press cmd+q --hold 400", async () => {
      const first = pressBody(await pressQuit());
      matchPress(first.press_ms);
      // The first tap's release must already have been polled, so the second
      // press takes Idle's `recent` branch and not Showing's re-press branch.
      waitFor(term, 'quit_guard.phase == "idle"', "--timeout", "1000");
      const r2 = await pressQuitAgain("--hold", "400");
      const second = pressBody(r2);
      const gap = second.press_ms - first.press_ms;
      if (!(gap < 999)) throw new Error(`inconclusive: press_ms₂ − press_ms₁ = ${gap} ms, not under 999; re-run`);
      const snap = matchPress(second.press_ms);
      eq(snap.quit_guard.last_press.route, "guard", "second press route");
      eq(snap.quit_guard.phase, "confirming", "phase after the second tap");
      const gone = await waitGone(r2.exitedAt + 2000 - Date.now());
      console.log(`       gone ${gone - r2.exitedAt} ms after the second reply`);
    });
  },

  async stale() {
    console.log("\nS17 — a stale press quits at once (CASE=stale)");
    await run.checkAsync("press cmd+q --age 2500 --hold 1", async () => {
      const r = await pressQuit("--age", "2500", "--hold", "1");
      // The reply races the terminate: exit 0, or exit 1 with the connection
      // lost, are both correct.
      if (r.code === 0) {
        eq(json(r).hold_ms, 1, "reply hold_ms");
      } else if (!r.err.includes("app connection lost")) {
        throw new Error(`press exited ${r.code}: ${r.err.trim()}`);
      }
      const gone = await waitGone(r.exitedAt + 1000 - Date.now());
      console.log(`       gone ${gone - r.exitedAt} ms after the CLI exited`);
      console.log(
        "       record from the `make run` output: the last quit-key line should read route=terminate, age_ms >= 2500",
      );
    });
  },
};

const scenario = cases[CASE];
if (!scenario) run.die(`unknown CASE=${CASE}; expected hold, double or stale`);
const { term } = preflight(run);
if (snapshot().quit_guard?.enabled !== true) {
  run.die("Warn Before Quitting is off; a tap would quit at once and the case would pass for the wrong reason");
}
await scenario(term);
run.finish();
