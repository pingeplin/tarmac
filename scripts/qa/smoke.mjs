#!/usr/bin/env node
// The QA driver's own scenario suite (spec 2609.0015, issue #166).
//
// These are the `[D]` scenarios: end-to-end checks against a LIVE `make run`
// app, driven entirely through `tarmac dev`. They are not part of `make test`
// and not on CI, because they need a window.
//
// Stage 1 covers D1, D2, D8, D9(a), D9(b) and D10(a) — everything reachable with
// `snapshot`, `zoom` and `focus`. D3-D7, D9(c) and D10(b) arrive with `resize`,
// `type` and `key` in stage 2.
//
// Run:  make qa          (pins TARMAC_DEV_SOCKET to this worktree's .dev/)

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const CLI = resolve(ROOT, "core/target/debug/tarmac");
const STATE = process.env.TARMAC_STATE ?? resolve(ROOT, ".dev/state.json");
const SOCK = process.env.TARMAC_DEV_SOCKET ?? resolve(ROOT, ".dev/tarmac-dev.sock");

const failures = [];
let checks = 0;

/** Run a verb. Returns { code, out, err } — never throws on a non-zero exit, so a
 *  scenario can assert on failure as readily as on success. */
function dev(...args) {
  try {
    const out = execFileSync(CLI, ["dev", ...args], {
      encoding: "utf8",
      env: { ...process.env, TARMAC_DEV_SOCKET: SOCK },
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, out, err: "" };
  } catch (e) {
    return { code: e.status ?? 1, out: e.stdout ?? "", err: e.stderr ?? "" };
  }
}

const json = (r) => JSON.parse(r.out || r.err);
const snapshot = (...args) => json(dev("snapshot", ...args));

function check(name, fn) {
  checks++;
  try {
    fn();
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push(`${name}: ${e.message}`);
    console.log(`  FAIL ${name}\n       ${e.message}`);
  }
}

function eq(actual, expected, what) {
  if (actual !== expected) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- preconditions
// No verb creates a terminal, so the suite needs one that already exists.

function preflight() {
  if (!existsSync(CLI)) {
    die(`no debug CLI at ${CLI} — run \`make core\` first`);
  }
  if (!existsSync(SOCK)) {
    die(`no dev driver socket at ${SOCK} — start the app with \`make run\` first`);
  }
  const probe = dev("snapshot");
  if (probe.code !== 0) {
    die(`the dev driver did not answer: ${probe.err.trim() || probe.out.trim()}`);
  }
  const snap = JSON.parse(probe.out);
  const term = snap.cards.find((c) => c.kind === "term" && c.term?.alive);
  if (!term) {
    die("no live terminal card on the active board — open one and re-run");
  }
  console.log(`board ${snap.board_id} · terminal ${term.id} · visibility ${snap.visibility}`);
  if (snap.visibility !== "visible") {
    console.log("note: the window is not visible; see Q5 before blaming a failure on the driver");
  }
  return term.id;
}

function die(message) {
  console.error(`make qa: ${message}`);
  process.exit(1);
}

// ------------------------------------------------------------------- scenarios

function d1_projection(snap) {
  // Board units -> client px, the same transform kit/devSnapshot uses. The ±1px
  // tolerance is real: docZoom.ts rounds the wrapper translate to a device pixel.
  const { zoom, cx, cy, view_rect: v } = snap.viewport;
  const project = (r) => {
    const px = (wx) => (wx - cx) * zoom + v.x + v.w / 2;
    const py = (wy) => (wy - cy) * zoom + v.y + v.h / 2;
    return { x: px(r.x), y: py(r.y), w: px(r.x + r.w) - px(r.x), h: py(r.y + r.h) - py(r.y) };
  };
  let measured = 0;
  for (const card of snap.cards) {
    if (!card.screen_rect) continue;
    measured++;
    const want = project(card.board_rect);
    for (const k of ["x", "y", "w", "h"]) {
      const d = Math.abs(card.screen_rect[k] - want[k]);
      if (d > 1) {
        throw new Error(`card ${card.id} ${k}: off by ${d.toFixed(2)}px at zoom ${zoom}`);
      }
    }
  }
  if (measured === 0) throw new Error("no card had a measured screen_rect");
}

async function run() {
  const term = preflight();
  console.log("\nD1 — screen_rect matches board_rect projected through viewport");
  check("at zoom 1", () => {
    dev("zoom", "1");
    d1_projection(snapshot("--until", "viewport.zoom == 1"));
  });
  check("at zoom 1.7", () => {
    dev("zoom", "1.7");
    d1_projection(snapshot("--until", "viewport.zoom == 1.7"));
  });

  console.log("\nD2 — a zoom reaches state.json as an OS fact");
  await (async () => {
    const before = existsSync(STATE) ? statSync(STATE).mtimeMs : 0;
    dev("zoom", "1");
    await sleep(400); // clear the 200ms persist debounce from the D1 zooms
    const mark = existsSync(STATE) ? statSync(STATE).mtimeMs : 0;
    const r = dev("zoom", "0.5");
    check("the app reports the new zoom", () => eq(json(r).zoom, 0.5, "reply zoom"));
    check("--until sees it", () => eq(snapshot("--until", "viewport.zoom == 0.5").viewport.zoom, 0.5, "zoom"));
    // Shell-side, on the file: the persist is debounced, so --until cannot see it.
    let persisted = null;
    for (let i = 0; i < 40 && persisted === null; i++) {
      await sleep(50);
      if (!existsSync(STATE) || statSync(STATE).mtimeMs <= mark) continue;
      const state = JSON.parse(readFileSync(STATE, "utf8"));
      const zooms = JSON.stringify(state).match(/"zoom":\s*([0-9.]+)/g) ?? [];
      if (zooms.some((z) => z.includes("0.5"))) persisted = zooms;
    }
    check("state.json advanced and holds zoom 0.5", () => {
      if (persisted === null) throw new Error(`${STATE} never recorded zoom 0.5 (mtime ${mark})`);
    });
    check("mtime advanced", () => {
      if (statSync(STATE).mtimeMs <= before) throw new Error("state.json mtime did not advance");
    });
    dev("zoom", "1");
  })();

  console.log("\nD8 — focus and blur are two separate facts");
  check("focus <term> selects the card AND moves keyboard focus", () => {
    const body = json(dev("focus", term));
    eq(body.focused_card, term, "reply focused_card");
    eq(body.active_element.card, term, "reply active_element.card");
    eq(body.active_element.tag, "TEXTAREA", "reply active_element.tag");
    const snap = snapshot();
    eq(snap.focused_card, term, "snapshot focused_card");
    eq(snap.active_element.card, term, "snapshot active_element.card");
  });
  check("focus board clears BOTH", () => {
    dev("focus", "board");
    const snap = snapshot();
    // A blur that moved only one of these is exactly what this catches.
    eq(snap.active_element.card, null, "active_element.card");
    eq(snap.focused_card, null, "focused_card");
  });

  console.log("\nD9 — the failure paths are reachable");
  check("(a) an unknown card is no_such_card, exit 1", () => {
    const r = dev("focus", "definitely-not-a-card");
    eq(r.code, 1, "exit code");
    eq(JSON.parse(r.err).error, "no_such_card", "error code");
    eq(r.out, "", "stdout must stay clean");
  });
  check("(b) an unsatisfiable --until times out, quickly, with the final snapshot", () => {
    const started = Date.now();
    const r = dev("snapshot", "--until", "viewport.zoom == 99", "--timeout", "300");
    const elapsed = Date.now() - started;
    eq(r.code, 1, "exit code");
    const body = JSON.parse(r.err);
    eq(body.error, "timeout", "error code");
    eq(body.timeout_ms, 300, "reported budget");
    if (!body.snapshot?.viewport) throw new Error("the timeout body carries no final snapshot");
    // 300ms budget + at most one 50ms poll + process start. A 1s poll blows this.
    if (elapsed > 800) throw new Error(`took ${elapsed}ms, expected under 800ms`);
  });

  console.log("\nD10 — a clamped request is reported, not refused");
  check("(a) zoom 99 clamps to 3 and says so", () => {
    const r = dev("zoom", "99");
    eq(r.code, 0, "exit code");
    // The observed zoom, not an echo of the request: a driver that replied
    // {"zoom": 99} would let a scenario believe the board is where it cannot be.
    eq(json(r).zoom, 3, "reply zoom");
    eq(snapshot("--until", "viewport.zoom == 3").viewport.zoom, 3, "snapshot zoom");
    eq(json(dev("zoom", "0.01")).zoom, 0.1, "reply zoom at the low clamp");
    dev("zoom", "1");
  });

  console.log(`\n${checks - failures.length}/${checks} checks passed`);
  if (failures.length > 0) {
    console.error(`\nmake qa: ${failures.length} check(s) failed`);
    process.exit(1);
  }
}

await run();
