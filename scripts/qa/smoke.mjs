#!/usr/bin/env node
// The QA driver's own scenario suite (spec 2609.0015, issue #166).
//
// These are the `[D]` scenarios: end-to-end checks against a LIVE `make run`
// app, driven entirely through `tarmac dev`. They are not part of `make test`
// and not on CI, because they need a window.
//
// D1, D2, D8, D9(a), D9(b) and D10(a) need only `snapshot`, `zoom` and `focus`.
// D3-D7, D9(c) and D10(b) drive `resize`, `type` and `key` as well.
//
// Every scenario that types mints its OWN sentinel from a per-run nonce, and the
// run asserts they are all distinct: `scrollback_tail` spans 40 lines, so an
// earlier scenario's echo would satisfy a repeated `contains` and turn a later
// scenario green without doing anything.
//
// Run:  make qa          (pins TARMAC_DEV_SOCKET to this worktree's .dev/)

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "../..");
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

// ------------------------------------------------------------------- sentinels
// One nonce per run, one sentinel per scenario. Short, alphanumeric and
// lowercase: it is echoed by a shell, so anything a shell would expand or a
// narrow card would wrap across lines breaks `contains` for reasons unrelated to
// the bug under test.
const NONCE = Math.random().toString(36).slice(2, 8);
const minted = new Set();
function sentinel(tag) {
  const s = `qa${NONCE}${tag}`;
  if (minted.has(s)) throw new Error(`sentinel ${s} was minted twice`);
  minted.add(s);
  return s;
}

/** `focus board` then `focus <term>` — the clean reset. Per #162, `focus()` on an
 *  already-focused textarea does not restore the caret, so the blur is required.
 *  The leading `zoom 1` is not decoration: zoom persists, so a re-run after D2
 *  would start at 0.5 and shift every grip delta and cell point below. */
function reset(term) {
  dev("zoom", "1");
  snapshot("--until", "viewport.zoom == 1");
  dev("focus", "board");
  dev("focus", term);
}

/** Wait for an expression, and on timeout raise the terminal's tail with it — the
 *  difference between a diagnosable failure and a mysterious one. */
function waitFor(term, expr, ...args) {
  const r = dev("snapshot", "--until", expr, ...args);
  if (r.code === 0) return JSON.parse(r.out);
  const tail = (() => {
    try {
      return JSON.parse(r.err).snapshot?.cards?.find((c) => c.id === term)?.term?.scrollback_tail;
    } catch {
      return null;
    }
  })();
  throw new Error(`\`${expr}\` never held.\n       tail: ${JSON.stringify(tail)}`);
}

const termCard = (snap, term) => snap.cards.find((c) => c.id === term);
const near = (a, b, tol, what) => {
  if (Math.abs(a - b) > tol) throw new Error(`${what}: ${a} is not within ${tol} of ${b}`);
};

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
    // A leftover socket file from a killed app lands here rather than in the
    // branch above, so this message names the remedy too.
    die(
      `the dev driver did not answer — start the app with \`make run\` first ` +
        `(a stale socket file is left behind when the app is killed). ` +
        `Reply: ${probe.err.trim() || probe.out.trim()}`,
    );
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
  return { term: term.id, boardId: snap.board_id };
}

/** The active board's persisted zoom. The shape is the one `persist.rs` writes —
 *  `{ boards: [{ board_id, board: { zoom, cx, cy } }] }` — and nothing else can
 *  reach this file, so a missing `boards` array is a schema change and throws
 *  rather than degrading into a silent "never recorded zoom 0.5".
 *  A board with no viewport yet is a normal `null`. */
function activeBoardZoom(state, boardId) {
  if (!Array.isArray(state.boards)) {
    throw new Error(`${STATE}: expected a \`boards\` array; has the persisted shape changed?`);
  }
  const zoom = state.boards.find((b) => b.board_id === boardId)?.board?.zoom;
  return typeof zoom === "number" ? zoom : null;
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
  const { term, boardId } = preflight();
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
      // The ACTIVE board's zoom specifically. A grep over the whole file would
      // match another board's viewport, and `includes("0.5")` would match 0.55.
      const state = JSON.parse(readFileSync(STATE, "utf8"));
      const z = activeBoardZoom(state, boardId);
      if (z === 0.5) persisted = z;
    }
    check("state.json advanced and holds the active board's zoom at 0.5", () => {
      if (persisted === null) {
        throw new Error(
          `${STATE} never recorded zoom 0.5 for board ${boardId} (mtime ${mark}); ` +
            `last read: ${JSON.stringify(activeBoardZoom(JSON.parse(readFileSync(STATE, "utf8")), boardId))}`,
        );
      }
    });
    check("mtime advanced", () => {
      if (statSync(STATE).mtimeMs <= before) throw new Error("state.json mtime did not advance");
    });
    dev("zoom", "1");
  })();

  console.log("\nD3 — a resize reaches the PTY's winsize");
  check("the grip drag lands the card, and stty sees the new grid", () => {
    reset(term);
    // Pin the start size too, so the grip delta below is exact.
    dev("resize", term, "600x400");
    waitFor(term, `cards[${term}].board_rect.w ~= 600`);
    const cols0 = termCard(snapshot(), term).term.cols;

    const body = json(dev("resize", term, "800x600"));
    // The card's stored frame can be a float from an earlier gesture, so
    // `w0 + (800 − w0)` need not be bit-identical to 800 — `===` would flake.
    near(body.to.w, 800, 1e-6, "reply to.w");
    near(body.to.h, 600, 1e-6, "reply to.h");

    waitFor(term, `cards[${term}].board_rect.w ~= 800`);
    // Separate waits on purpose: the frame settles before xterm refits and the
    // daemon's Resize lands.
    const snap = waitFor(term, `cards[${term}].term.cols != ${cols0}`);
    const { rows, cols } = termCard(snap, term).term;

    dev("type", term, "stty size\n");
    // The OS fact: the PTY's winsize changed, and the shell can read it back.
    waitFor(term, `cards[${term}].term.scrollback_tail contains "${rows} ${cols}"`);
  });

  console.log("\nD4 — #162 regression, caret variant");
  check("a resize press between two types drops nothing", () => {
    const s4 = sentinel("d4");
    reset(term);
    // This is issue #162's own repro: NO focus round-trip anywhere between.
    const first = json(dev("type", term, `${s4}a`));
    dev("resize", term, "700x500");
    const second = json(dev("type", term, "b\n"));
    if (first.dropped.length > 0) throw new Error(`first type dropped ${JSON.stringify(first.dropped)}`);
    if (second.dropped.length > 0) throw new Error(`second type dropped ${JSON.stringify(second.dropped)}`);
    waitFor(term, `cards[${term}].term.scrollback_tail contains "${s4}ab"`);
  });

  console.log("\nD5 — #162 regression, Range variant");
  check("a right-click selection survives the resize press", () => {
    const seed = sentinel("d5a");
    const s5 = sentinel("d5b");
    reset(term);
    dev("type", term, `echo ${seed}\n`);
    waitFor(term, `cards[${term}].term.scrollback_tail contains "${seed}"`);

    const keyed = dev("key", term, "contextmenu");
    eq(keyed.code, 0, "key contextmenu exit code");
    const selType = snapshot().active_element.selection_type;
    // A right-click on blank space degrades to a Caret and would silently re-run
    // D4 under a different name. The Range comes from xterm's own
    // rightClickSelectsWord default (isMac); if xterm ever changes it, this line
    // fails loudly rather than quietly.
    eq(selType, "Range", "active_element.selection_type after contextmenu");

    // Stronger than the spec's bare `contains "ab"`, per the suite's own sentinel
    // hygiene: D4's echo is still inside the 40-line tail and would satisfy it.
    const first = json(dev("type", term, `${s5}a`));
    dev("resize", term, "720x520");
    const second = json(dev("type", term, "b\n"));
    if (first.dropped.length > 0) throw new Error(`first type dropped ${JSON.stringify(first.dropped)}`);
    if (second.dropped.length > 0) throw new Error(`second type dropped ${JSON.stringify(second.dropped)}`);
    waitFor(term, `cards[${term}].term.scrollback_tail contains "${s5}ab"`);
  });

  console.log("\nD6 — bytes reach the PTY, exactly once");
  check("the echo carries the sentinel and not its doubled form", () => {
    const s6 = sentinel("d6");
    reset(term);
    dev("type", term, `printf ${s6}\n`);
    waitFor(term, `cards[${term}].term.scrollback_tail contains "${s6}"`);
    // The end-to-end guard on S19's inert bracket: if the keydown ALSO delivered
    // the character, every character would echo twice and every #162 scenario
    // would be vacuous.
    const doubled = [...s6].map((c) => c + c).join("");
    const tail = termCard(snapshot(), term).term.scrollback_tail;
    if (tail.includes(doubled)) {
      throw new Error(`the tail holds the doubled form ${doubled} — the bracket is delivering too`);
    }
  });

  console.log("\nD7 — the foreground process changes, both directions");
  check("type starts sleep and ctrl+c ends it", () => {
    reset(term);
    dev("type", term, "sleep 100\n");
    // The daemon polls TermProc at 750ms, so the wait is required.
    waitFor(term, `cards[${term}].term.proc == "sleep"`);
    const body = json(dev("key", term, "ctrl+c"));
    eq(body.combo, "ctrl+c", "reply combo");
    // No keypress — the app produces none for a combo xterm owns (S10, measured).
    eq(JSON.stringify(body.events), '["keydown","keyup"]', "reply events");
    waitFor(term, `cards[${term}].term.proc != "sleep"`, "--timeout", "3000");
  });

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

  check("(c) type without focus is refused BEFORE anything is dispatched", () => {
    const s9 = sentinel("d9c");
    // Deliberately unfocused — that is the condition under test, so this is the
    // one scenario that does not reset focus.
    dev("focus", "board");
    const r = dev("type", term, s9);
    eq(r.code, 1, "exit code");
    eq(JSON.parse(r.err).error, "not_focused", "error code");
    // The operational form of "the tail never gains that sentinel": proof the
    // precondition ran before any event was dispatched rather than after.
    const t = dev("snapshot", "--until", `cards[${term}].term.scrollback_tail contains "${s9}"`, "--timeout", "500");
    eq(t.code, 1, "the sentinel must never appear");
    eq(JSON.parse(t.err).error, "timeout", "error code");
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
  check("(b) resize below the minimum clamps to 160x90 and says so", () => {
    reset(term);
    const body = json(dev("resize", term, "10x10"));
    eq(body.to.w, 160, "reply to.w");
    eq(body.to.h, 90, "reply to.h");
    const snap = waitFor(term, `cards[${term}].board_rect.w ~= 160`);
    near(termCard(snap, term).board_rect.h, 90, 1, "snapshot board_rect.h");
    // Restore: a card left at 160x90 is ~15 columns wide and would wrap every
    // later sentinel across lines, breaking `contains` for reasons that have
    // nothing to do with the bug under test.
    dev("resize", term, "600x400");
    waitFor(term, `cards[${term}].board_rect.w ~= 600`);
  });

  console.log(`\n${checks - failures.length}/${checks} checks passed`);
  if (failures.length > 0) {
    console.error(`\nmake qa: ${failures.length} check(s) failed`);
    process.exit(1);
  }
}

await run();
