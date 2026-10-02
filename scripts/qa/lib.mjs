// Shared by `smoke.mjs` (make qa) and `quit.mjs` (make qa-quit): the CLI
// wrapper, the check runner, the wait helpers, and the ⌘Q press discipline of
// spec 2609.0018 (*Before every ⌘Q press*, *Matching a press*).

import { execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dirname, "../..");
export const CLI = resolve(ROOT, "core/target/debug/tarmac");
export const STATE = process.env.TARMAC_STATE ?? resolve(ROOT, ".dev/state.json");
export const SOCK = process.env.TARMAC_DEV_SOCKET ?? resolve(ROOT, ".dev/tarmac-dev.sock");
/** The daemon's socket, so a scenario can `tarmac open` a fixture into the
 *  same app `make run` started. Unpinned, the debug CLI resolves the dev
 *  channel's default socket, not `make run`'s. */
export const DAEMON_SOCK = process.env.TARMAC_SOCKET ?? resolve(ROOT, ".dev/tarmacd.sock");

const env = () => ({ ...process.env, TARMAC_DEV_SOCKET: SOCK, TARMAC_SOCKET: DAEMON_SOCK });

/** Run a verb. Returns { code, out, err } — never throws on a non-zero exit, so a
 *  scenario can assert on failure as readily as on success. */
export function dev(...args) {
  try {
    const out = execFileSync(CLI, ["dev", ...args], {
      encoding: "utf8",
      env: env(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, out, err: "" };
  } catch (e) {
    return { code: e.status ?? 1, out: e.stdout ?? "", err: e.stderr ?? "" };
  }
}

/** `dev`, but asynchronous and timed: `spawnedAt` and `exitedAt` are wall
 *  clock, so a scenario can bound how long the verb itself took. */
export function devTimed(...args) {
  return new Promise((done) => {
    const spawnedAt = Date.now();
    const child = spawn(CLI, ["dev", ...args], { env: env(), stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => done({ code: code ?? 1, out, err, spawnedAt, exitedAt: Date.now() }));
  });
}

/** `tarmac open <path>` against the daemon `make run` spawned. `TARMAC_TERM_ID`
 *  is removed so the doc lands on the active board rather than being attributed
 *  to the terminal this script happens to run in. */
export function open(path) {
  const e = env();
  delete e.TARMAC_TERM_ID;
  execFileSync(CLI, ["open", path], { env: e, stdio: ["ignore", "pipe", "pipe"] });
}

export const json = (r) => JSON.parse(r.out || r.err);
export const snapshot = (...args) => json(dev("snapshot", ...args));
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const termCard = (snap, term) => snap.cards.find((c) => c.id === term);

export function eq(actual, expected, what) {
  if (actual !== expected) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

export const near = (a, b, tol, what) => {
  if (Math.abs(a - b) > tol) throw new Error(`${what}: ${a} is not within ${tol} of ${b}`);
};

export function between(v, lo, hi, what) {
  if (!(v >= lo && v <= hi)) throw new Error(`${what}: ${v} is not within [${lo}, ${hi}]`);
}

/** Wait for an expression, and on timeout raise the terminal's tail with it — the
 *  difference between a diagnosable failure and a mysterious one. */
export function waitFor(term, expr, ...args) {
  const r = dev("snapshot", "--until", expr, ...args);
  if (r.code === 0) return JSON.parse(r.out);
  let tail = null;
  try {
    tail = termCard(JSON.parse(r.err).snapshot, term)?.term?.scrollback_tail;
  } catch {
    // A timeout body always carries the final snapshot; anything else means the
    // driver failed for a different reason, and `expr` is the useful half.
  }
  throw new Error(`\`${expr}\` never held.\n       tail: ${JSON.stringify(tail)}`);
}

/** `focus board` then `focus <term>` — the clean reset. Per #162, `focus()` on an
 *  already-focused textarea does not restore the caret, so the blur is required.
 *  The leading `zoom 1` is not decoration: zoom persists, so a re-run after D2
 *  would start at 0.5 and shift every grip delta and cell point below. */
export function reset(term) {
  // `zoom` settles before it replies and reports the observed zoom, so asserting
  // the reply is both stronger and a subprocess cheaper than re-reading it.
  eq(json(dev("zoom", "1")).zoom, 1, "zoom after reset");
  dev("focus", "board");
  dev("focus", term);
}

/** Type, and assert the driver dropped nothing — the #162 fact D4 and D5 turn on. */
export function typeAll(term, text) {
  const body = json(dev("type", term, text));
  if (body.dropped.length > 0) {
    throw new Error(`type ${JSON.stringify(text)} dropped ${JSON.stringify(body.dropped)}`);
  }
  return body;
}

// ------------------------------------------------------------------ the runner

export function runner(prog) {
  const failures = [];
  let checks = 0;
  const pass = (name) => console.log(`  ok   ${name}`);
  const fail = (name, e) => {
    failures.push(`${name}: ${e.message}`);
    console.log(`  FAIL ${name}\n       ${e.message}`);
  };
  return {
    check(name, fn) {
      checks++;
      try {
        fn();
        pass(name);
      } catch (e) {
        fail(name, e);
      }
    },
    async checkAsync(name, fn) {
      checks++;
      try {
        await fn();
        pass(name);
      } catch (e) {
        fail(name, e);
      }
    },
    /** A scenario the run could not exercise. Printed, never counted as a pass. */
    skip(name, reason) {
      console.log(`  skip ${name}\n       ${reason}`);
    },
    die(message) {
      console.error(`${prog}: ${message}`);
      process.exit(1);
    },
    finish() {
      console.log(`\n${checks - failures.length}/${checks} checks passed`);
      if (failures.length > 0) {
        console.error(`\n${prog}: ${failures.length} check(s) failed`);
        process.exit(1);
      }
    },
  };
}

/** The suite's entry conditions: a debug CLI, a listening driver, a live
 *  terminal on the active board. Returns that terminal's id and the board. */
export function preflight(run) {
  if (!existsSync(CLI)) {
    run.die(`no debug CLI at ${CLI} — run \`make core\` first`);
  }
  if (!existsSync(SOCK)) {
    run.die(`no dev driver socket at ${SOCK} — start the app with \`make run\` first`);
  }
  const probe = dev("snapshot");
  if (probe.code !== 0) {
    // A leftover socket file from a killed app lands here rather than in the
    // branch above, so this message names the remedy too.
    run.die(
      `the dev driver did not answer — start the app with \`make run\` first ` +
        `(a stale socket file is left behind when the app is killed). ` +
        `Reply: ${probe.err.trim() || probe.out.trim()}`,
    );
  }
  const snap = JSON.parse(probe.out);
  const term = snap.cards.find((c) => c.kind === "term" && c.term?.alive);
  if (!term) {
    run.die("no live terminal card on the active board — open one and re-run");
  }
  console.log(`board ${snap.board_id} · terminal ${term.id} · visibility ${snap.visibility}`);
  if (snap.visibility !== "visible") {
    console.log("note: the window is not visible; see Q5 before blaming a failure on the driver");
  }
  return { term: term.id, boardId: snap.board_id };
}

// ------------------------------------------------------------- ⌘Q discipline

let lastQuitReplyAt = 0;

/** *Before every ⌘Q press* (2609.0018): the toggle is on and the item
 *  retargeted (with it off a tap quits at once), the guard is idle and its
 *  notice gone (a press within 1 s of the last is a second tap, which quits),
 *  and at least 1000 ms have passed since the previous ⌘Q reply — the backstop
 *  for when no notice was shown at all. Then the press. */
export async function pressQuit(...flags) {
  const guard = snapshot().quit_guard;
  if (guard?.enabled !== true || guard?.retargeted !== true) {
    throw new Error(
      `not pressing ⌘Q: quit_guard is ${JSON.stringify(guard)}; ` +
        `the toggle must be on and the item retargeted, or a tap would quit the app`,
    );
  }
  waitFor(null, 'quit_guard.phase == "idle"', "--timeout", "3000");
  waitFor(null, "quit_guard.notice.visible == false", "--timeout", "3000");
  const since = Date.now() - lastQuitReplyAt;
  if (since < 1000) await sleep(1000 - since);
  return pressQuitAgain(...flags);
}

/** The deliberate second press of a re-show or double-tap scenario: no checks. */
export async function pressQuitAgain(...flags) {
  const r = await devTimed("press", "cmd+q", ...flags);
  lastQuitReplyAt = r.exitedAt;
  return r;
}

/** The reply of a successful press, or a scenario failure that names the
 *  refused posture when activation was denied (Gate item 2's fallback). */
export function pressBody(r) {
  if (r.code === 0) return json(r);
  let body;
  try {
    body = JSON.parse(r.err);
  } catch {
    throw new Error(`press failed: ${r.err.trim()}`);
  }
  if (body.error === "not_key") {
    throw new Error(
      "activation was refused from this posture (a locked screen?); " +
        "click the dev window so it is key, then re-run (spec 2609.0018, Gate item 2)",
    );
  }
  throw new Error(`press failed: ${r.err.trim()}`);
}

/** *Matching a press*: the snapshot in which the handler has recorded this
 *  press. `~=` allows ±1 for the float truncation in `press_ms`. */
export function matchPress(pressMs, timeoutMs = 1000) {
  return waitFor(null, `quit_guard.last_press.press_ms ~= ${pressMs}`, "--timeout", String(timeoutMs));
}

/** Poll `snapshot` until the app is gone (`no tarmac app driver`), or `bound`
 *  ms have passed. `--until` cannot express this: the app is not there to
 *  evaluate it. */
export async function waitGone(boundMs) {
  const deadline = Date.now() + boundMs;
  for (;;) {
    const r = dev("snapshot");
    if (r.code === 1 && r.err.includes("no tarmac app driver")) return Date.now();
    if (Date.now() >= deadline) {
      throw new Error(`the app still answers ${boundMs} ms on (exit ${r.code}: ${r.err.trim().slice(0, 80)})`);
    }
    await sleep(100);
  }
}
