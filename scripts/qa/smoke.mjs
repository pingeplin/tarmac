#!/usr/bin/env node
// The QA driver's own scenario suite (spec 2609.0015, issue #166).
//
// These are the `[D]` scenarios: end-to-end checks against a LIVE `make run`
// app, driven entirely through `tarmac dev`. They are not part of `make test`
// and not on CI, because they need a window.
//
// D1, D2, D8, D9(a), D9(b), D10(a) and D11 need only `snapshot`, `zoom` and
// `focus`. D3-D7, D9(c) and D10(b) drive `resize`, `type` and `key` as well.
//
// D11 (spec 2609.0016, issue #171) is the only automated check on the ⌘Q guard's
// native retarget: replacing the app menu silently drops it, and no unit test can
// read a live NSMenu.
//
// D12–D19 (spec 2609.0018, issue #183) press a native ⌘ chord with `tarmac dev
// press` and read what the guard did off the snapshot: a tap from a plain
// shell (D12, with S21's activation check), through kitty flags 5 (D13), from
// the board (D14), the re-show (D15), a page shortcut ⌘T/⌘W (D16), from a
// markdown card (D17) and an HTML card (D18), and into a frozen page (D19).
// The cases that END the app are `make qa-quit` (`quit.mjs`).
//
// Every scenario that types mints its OWN sentinel from a per-run nonce, and the
// run asserts they are all distinct: `scrollback_tail` spans 40 lines, so an
// earlier scenario's echo would satisfy a repeated `contains` and turn a later
// scenario green without doing anything.
//
// Run:  make qa          (pins TARMAC_DEV_SOCKET and TARMAC_SOCKET to this worktree's .dev/)

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import {
  ROOT,
  STATE,
  SOCK,
  dev,
  json,
  snapshot,
  sleep,
  termCard,
  eq,
  near,
  between,
  waitFor,
  reset,
  typeAll,
  runner,
  preflight,
  open,
  pressQuit,
  pressQuitAgain,
  pressBody,
  matchPress,
} from "./lib.mjs";

const run = runner("make qa");
const { check, checkAsync, skip } = run;

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

// ------------------------------------------------------------- pids (S21)

/** `lsappinfo front` prints an ASN, not a pid; `info -only pid` prints
 *  `"pid"=637`. */
function frontmostPid() {
  const asn = execFileSync("lsappinfo", ["front"], { encoding: "utf8" }).trim();
  const line = execFileSync("lsappinfo", ["info", "-only", "pid", asn], { encoding: "utf8" });
  const m = /=\s*(\d+)/.exec(line);
  return m ? Number(m[1]) : null;
}

/** The dev app's pid, the way `make kill-daemon` finds its daemon. */
function devAppPid() {
  try {
    const out = execFileSync("lsof", ["-t", SOCK], { encoding: "utf8" });
    const pid = out.trim().split("\n").map(Number).find((n) => n > 0);
    return pid ?? null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- fixtures
// Written only when missing or when the bytes differ: rewriting an open
// fixture bumps its mtime, and the daemon's file_event then refetches a
// markdown card and reloads an HTML card's iframe, racing the focus and the
// press. Both are written before the first `tarmac open`, because the first
// open makes the daemon watch the directory and a later create would raise a
// debounced event after its own open.

const FIXTURES = resolve(ROOT, ".dev/qa-fixtures");
const D17_MD = "# D17\n\nA markdown fixture for the ⌘Q guard.\n\n[a link](https://example.com/)\n";
const D18_HTML =
  "<!doctype html><html><body><p>D18: an HTML fixture for the ⌘Q guard.</p>" +
  "<button>a button</button> <a href=\"https://example.com/\">a link</a></body></html>\n";

function writeFixtures() {
  mkdirSync(FIXTURES, { recursive: true });
  const paths = {};
  for (const [name, bytes] of [["d17.md", D17_MD], ["d18.html", D18_HTML]]) {
    const path = resolve(FIXTURES, name);
    if (!existsSync(path) || readFileSync(path, "utf8") !== bytes) writeFileSync(path, bytes);
    // The daemon canonicalises the path, and that is the card's id.
    paths[name] = realpathSync(path);
  }
  return paths;
}

/** Open a fixture and wait until the app has registered its card's node —
 *  `tarmac open` exits on the daemon's ack, before the card exists. */
function openFixture(path) {
  open(path);
  waitFor(null, `cards[${path}].screen_rect != null`, "--timeout", "3000");
  return path;
}

/** Un-borrow an HTML card: Esc while `borrowed` reads true, up to three times
 *  (a visible toast or a pending fly-back takes an Esc first). Escape is sent
 *  only while borrowed — otherwise the ladder's `fresh` branch takes it, or it
 *  reaches zsh. */
function unborrow(term, id) {
  for (let i = 0; i < 3; i++) {
    if (termCard(snapshot(), id)?.borrowed !== true) return;
    dev("key", term, "escape");
    try {
      waitFor(term, `cards[${id}].borrowed == false`, "--timeout", "1000");
      return;
    } catch {
      // Something else claimed that Esc; go round again.
    }
  }
  if (termCard(snapshot(), id)?.borrowed === true) throw new Error(`${id} is still borrowed after three Esc`);
}

/** The route and the notice of a ⌘Q press that must have been guarded. */
function assertGuarded(pressMs, timeoutMs = 1000) {
  const snap = matchPress(pressMs, timeoutMs);
  eq(snap.quit_guard.last_press.route, "guard", "last_press.route");
  eq(snap.quit_guard.notice.visible, true, "notice.visible");
  return snap;
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

async function main() {
  const { term, boardId } = preflight(run);
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
    const started = waitFor(term, `cards[${term}].board_rect.w ~= 600`);
    const cols0 = termCard(started, term).term.cols;

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
    typeAll(term, `${s4}a`);
    dev("resize", term, "700x500");
    typeAll(term, "b\n");
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
    typeAll(term, `${s5}a`);
    dev("resize", term, "720x520");
    typeAll(term, "b\n");
    waitFor(term, `cards[${term}].term.scrollback_tail contains "${s5}ab"`);
  });

  console.log("\nD6 — bytes reach the PTY, exactly once");
  check("the echo carries the sentinel and not its doubled form", () => {
    const s6 = sentinel("d6");
    reset(term);
    dev("type", term, `printf ${s6}\n`);
    const echoed = waitFor(term, `cards[${term}].term.scrollback_tail contains "${s6}"`);
    // The end-to-end guard on S19's inert bracket: if the keydown ALSO delivered
    // the character, every character would echo twice and every #162 scenario
    // would be vacuous.
    // Read off the snapshot the wait already returned, not a fresh one: nothing
    // ran in between. And under real doubling the wait itself is what fails —
    // the echo would read `pprriinnttff`, so the undoubled sentinel never
    // appears — which makes this check the second line of defence, not the first.
    const doubled = [...s6].map((c) => c + c).join("");
    const tail = termCard(echoed, term).term.scrollback_tail;
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

  console.log("\nD11 — the ⌘Q guard says whether the Quit item is really retargeted");
  check("quit_guard reports a retargeted Quit item and a boolean toggle", () => {
    const r = dev("snapshot", "--until", "quit_guard.retargeted == true", "--timeout", "2000");
    eq(r.code, 0, "exit code");
    const { quit_guard } = json(r);
    // The toggle's VALUE is the user's, so only its type can be asserted — but a
    // backend that answered nothing would report it as null rather than a bool.
    if (typeof quit_guard?.enabled !== "boolean") {
      throw new Error(`quit_guard.enabled is ${JSON.stringify(quit_guard?.enabled)}, not a boolean`);
    }
  });

  await quitGuardScenarios(term);
  run.finish();
}

// ------------------------------------------------- the ⌘Q guard (2609.0018)
// D12–D19 press a native ⌘Q with `tarmac dev press` and read what the guard did
// off the snapshot. Every ⌘Q press goes through `pressQuit` (the *Before every
// ⌘Q press* checks) and `matchPress`; the deliberate second presses in D15 are
// the only exception. The cases that END the app live in `quit.mjs`.

async function quitGuardScenarios(term) {
  let s21 = null;

  console.log("\nD12 — ⌘Q tap from a plain-shell terminal (S10), and the verb activates the app (S21)");
  await checkAsync("a tap routes guard, shows the notice, and leaves the prompt clean", async () => {
    reset(term);
    const tail0 = termCard(snapshot(), term).term.scrollback_tail;
    const frontBefore = frontmostPid();
    const devPid = devAppPid();
    // 300 ms: still a tap (HOLD_MS is 500), and long enough that the matching
    // snapshot lands inside `showing`.
    const body = pressBody(await pressQuit("--hold", "300"));
    eq(body.hold_ms, 300, "reply hold_ms");
    const snap = matchPress(body.press_ms);
    const { last_press, phase, notice } = snap.quit_guard;
    eq(last_press.route, "guard", "last_press.route");
    between(last_press.age_ms, 0, 2000, "last_press.age_ms");
    eq(phase, "showing", "phase");
    eq(notice.visible, true, "notice.visible");
    // Read only after the matching wait: `showing` lasts about 300 ms and the
    // lsappinfo call must not delay that snapshot.
    s21 = { frontBefore, devPid, activated: body.activated, frontAfter: frontmostPid() };
    waitFor(term, 'quit_guard.phase == "idle"', "--timeout", "3000");
    waitFor(term, "quit_guard.notice.visible == false", "--timeout", "3000");
    eq(termCard(snapshot(), term).term.scrollback_tail, tail0, "scrollback_tail (a stray q would echo)");
  });
  if (s21 === null) {
    skip("S21 — the verb activates a non-frontmost app", "D12 did not reach its press");
  } else if (s21.devPid === null) {
    skip("S21 — the verb activates a non-frontmost app", `could not resolve the dev app's pid from ${SOCK}`);
  } else if (s21.frontBefore === s21.devPid) {
    skip("S21 — the verb activates a non-frontmost app", "not exercised: the dev app was already frontmost");
  } else {
    check("S21 — the verb activates a non-frontmost app", () => {
      eq(s21.activated, true, "reply activated");
      eq(s21.frontAfter, s21.devPid, `frontmost pid after the press (was ${s21.frontBefore})`);
    });
  }

  console.log("\nD13 — ⌘Q tap through a kitty-flags-5 terminal (S11)");
  await checkAsync("with flags 5 pushed, the key still reaches the guard", async () => {
    reset(term);
    const pushed = sentinel("d13a");
    const popped = sentinel("d13b");
    try {
      // Only the command's output carries `-42`; the typed line's echo cannot
      // satisfy the wait. Flags 5 is what Claude Code pushes (#171).
      typeAll(term, `printf '\\033[>5u' && echo ${pushed}-$((6*7))\n`);
      waitFor(term, `cards[${term}].term.scrollback_tail contains "${pushed}-42"`);
      assertGuarded(pressBody(await pressQuit()).press_ms);
    } finally {
      // Under the knockout, xterm's `ESC[113;9u` sits at the prompt; Enter is
      // still a legacy CR under flags 5 and flushes it as its own failing
      // command. Pushed flags would otherwise leak into every later run,
      // because the daemon replays the scrollback.
      dev("type", term, "\n");
      dev("type", term, `printf '\\033[<u' && echo ${popped}-$((6*7))\n`);
      waitFor(term, `cards[${term}].term.scrollback_tail contains "${popped}-42"`);
    }
  });

  console.log("\nD14 — ⌘Q tap from the board (S12)");
  await checkAsync("with nothing focused, the key routes guard", async () => {
    reset(term);
    dev("focus", "board");
    assertGuarded(pressBody(await pressQuit()).press_ms);
  });

  console.log("\nD15 — a second tap while the first notice fades re-shows it (S13, Q16)");
  await checkAsync("the notice returns to full opacity and lingers its own second", async () => {
    reset(term);
    const first = pressBody(await pressQuit());
    matchPress(first.press_ms);
    const fading = waitFor(term, "quit_guard.notice.alpha != 1", "--timeout", "3000");
    eq(fading.quit_guard.notice.visible, true, "the first notice is fading, not gone");
    const r2 = await pressQuitAgain();
    const second = pressBody(r2);
    const gap = second.press_ms - first.press_ms;
    // Above 1000 or it is a second tap (and quits); below 1300 or the first
    // notice may already be gone, which would make the knockout vacuous.
    if (!(gap > 1000 && gap < 1300)) {
      throw new Error(`inconclusive: press_ms₂ − press_ms₁ = ${gap} ms, outside (1000, 1300); re-run`);
    }
    const snap = matchPress(second.press_ms);
    eq(snap.quit_guard.last_press.route, "guard", "second press route");
    waitFor(term, "quit_guard.notice.alpha == 1", "--timeout", "300");
    waitFor(term, "quit_guard.notice.visible == false", "--timeout", "3000");
    const lingered = Date.now() - r2.exitedAt;
    if (lingered < 900) throw new Error(`the second notice was gone ${lingered} ms after its reply; expected ≥ 900`);
    eq(dev("snapshot").code, 0, "the app still answers");
  });

  console.log("\nD16 — a page shortcut: ⌘T opens a terminal and ⌘W closes it (S14)");
  await checkAsync("the verb is not ⌘Q-specific", async () => {
    reset(term);
    const before = snapshot();
    const ids = new Set(before.cards.map((c) => c.id));
    const lastPress = JSON.stringify(before.quit_guard.last_press);

    const opened = dev("press", "cmd+t");
    eq(opened.code, 0, "press cmd+t exit code");
    eq(json(opened).combo, "cmd+t", "reply combo");
    let created = null;
    for (const deadline = Date.now() + 3000; created === null && Date.now() < deadline; ) {
      created = snapshot().cards.find((c) => c.kind === "term" && !ids.has(c.id))?.id ?? null;
      if (created === null) await sleep(100);
    }
    if (created === null) throw new Error("no new terminal card appeared within 3000 ms of ⌘T");
    // The card enters `cards` before its xterm mounts; a `proc` means the
    // daemon has spawned its shell, so ⌘W's close has a PTY to close.
    waitFor(term, `cards[${created}].term.proc != null`, "--timeout", "3000");
    eq(json(dev("focus", created)).focused_card, created, "focus the new terminal");
    // ⌘W inside an HTML card's frame would hide the window (Q14).
    eq(snapshot().active_element.tag, "TEXTAREA", "active_element.tag before ⌘W");

    const closed = dev("press", "cmd+w");
    eq(closed.code, 0, "press cmd+w exit code");
    eq(json(closed).combo, "cmd+w", "reply combo");
    let after = null;
    for (const deadline = Date.now() + 3000; after === null && Date.now() < deadline; ) {
      const snap = snapshot();
      if (!snap.cards.some((c) => c.id === created)) after = snap;
      else await sleep(100);
    }
    if (after === null) throw new Error(`${created} was still on the board 3000 ms after ⌘W`);
    for (const id of ids) {
      if (!after.cards.some((c) => c.id === id)) throw new Error(`⌘W removed ${id} as well`);
    }
    eq(termCard(after, term).term.alive, true, "the original terminal is still alive");
    eq(JSON.stringify(after.quit_guard.last_press), lastPress, "last_press is untouched by ⌘T/⌘W");
  });

  console.log("\nD17 — ⌘Q tap with a markdown card focused (S18, Q1's markdown cell)");
  const fixtures = writeFixtures();
  await checkAsync("focus drops to BODY, and the key routes guard", async () => {
    const id = openFixture(fixtures["d17.md"]);
    reset(term);
    eq(json(dev("zoom", "0.5")).zoom, 0.5, "zoom 0.5");
    // If focus were already on BODY, the page-body knockout would pass vacuously.
    eq(snapshot().active_element.tag, "TEXTAREA", "active_element.tag before focus");
    const focused = json(dev("focus", id));
    eq(focused.focused_card, id, "reply focused_card");
    eq(focused.active_element.tag, "BODY", "reply active_element.tag");
    assertGuarded(pressBody(await pressQuit()).press_ms);
  });

  console.log("\nD18 — ⌘Q tap with an HTML card focused (S19, Q1's HTML cell)");
  await checkAsync("focus lands in the IFRAME, the card is borrowed, and the key routes guard", async () => {
    const id = openFixture(fixtures["d18.html"]);
    reset(term);
    eq(json(dev("zoom", "0.5")).zoom, 0.5, "zoom 0.5");
    eq(snapshot().active_element.tag, "TEXTAREA", "active_element.tag before focus");
    // Un-borrowed first, so every run really exercises the dblclick.
    unborrow(term, id);
    try {
      const r = dev("focus", id);
      if (r.code !== 0 && json(r).error === "card_hidden") {
        const snap = snapshot();
        throw new Error(
          `card_hidden: ${id} sits at ${JSON.stringify(termCard(snap, id)?.board_rect)} with the viewport at ` +
            `${JSON.stringify(snap.viewport)}; pan the board toward the prime terminal and re-run`,
        );
      }
      eq(r.code, 0, `focus ${id} exit code (${r.err.trim()})`);
      const focused = json(r);
      eq(focused.focused_card, id, "reply focused_card");
      eq(focused.active_element.tag, "IFRAME", "reply active_element.tag");
      eq(termCard(snapshot(), id).borrowed, true, "cards[].borrowed after focus");
      assertGuarded(pressBody(await pressQuit()).press_ms);
    } finally {
      // Never press ⌘W while the IFRAME has focus: it hides the window (Q14).
      dev("focus", term);
      unborrow(term, id);
    }
  });

  console.log("\nD19 — a ⌘Q into a frozen page (S24, Q12's busy half)");
  await checkAsync("the press waits out the freeze, and age_ms reflects it", async () => {
    reset(term);
    const r = await pressQuit("--busy", "1000");
    const body = pressBody(r);
    eq(body.busy_ms, 1000, "reply busy_ms");
    const took = r.exitedAt - r.spawnedAt;
    if (took < 950) throw new Error(`press exited ${took} ms after spawn; a frozen page cannot answer before the freeze ends`);
    const snap = assertGuarded(body.press_ms, 3000);
    between(snap.quit_guard.last_press.age_ms, 900, 2000, "last_press.age_ms");
  });
}

await main();
