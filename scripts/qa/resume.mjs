#!/usr/bin/env node
// Resume after a restart (spec 2611.0011 S37; spec 2611.0015 D15). Stand-in
// agents record a command and the dev daemon is killed, which ends every dev
// terminal, so this is a runner of its own and not part of `smoke.mjs`.
//
//   CASE=reopen (default)   no relaunch: dead cards reopen and offer the
//                           command; Return, Esc, the panel's clicks, the
//                           header chip and the `click` refusals (S26, S28–S30,
//                           S40, and 2611.0011 S37).
//   CASE=restore-setup      two more terminals, the records, a quit through the
//                           ⌘Q guard and the daemon kill; then `make run` and
//                           one of the cases below (S25–S27, S32).
//   CASE=resume-all | resume-all-held | resume-all-click | per-card |
//        per-card-click | veil | skip-all | skip-all-click | quit
//   CASE=before-output      needs `make run SHELL_GATE=1`: Return and a
//                           `resume` click on a reopened card while the gate
//                           holds its shell before the first output (S28).
//
// The daemon is found only by `lsof -t` on lib.mjs's absolute DAEMON_SOCK, as
// `make kill-daemon` does, and only those pids are killed. A held key is
// `press --repeat`: autorepeat keyDowns posted in the app, not by the keyboard
// (#380). A step that reads the clipboard saves it first and puts it back.
//
// Run:  make qa-resume [CASE=...]    (against a live `make run`; DEV_DIR= as for it)

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  CLI,
  DAEMON_SOCK,
  STATE,
  dev,
  eq,
  json,
  open,
  pointer,
  preflight,
  pressQuit,
  pressQuitAgain,
  runner,
  sleep,
  snapshot,
  termCard,
  typeAll,
  waitFor,
  waitGone,
} from "./lib.mjs";

const run = runner("make qa-resume");
const CASE = process.env.CASE || "reopen";

/** Its output, `RESUMED`, is not in its own text: a line that is exactly
 *  `RESUMED` proves the command ran, which the echoed command line cannot. */
const CMD = "printf 'RES%s\\n' UMED";
const TITLE = "resume last agent session?";
const QUEUED_TITLE = "resumes when the shell is ready";
/** `make run SHELL_GATE=1` holds each new shell while this file exists. */
const GATE = process.env.TARMAC_QA_SHELL_GATE;
const COPIED = "resume command copied";

const state = () => JSON.parse(readFileSync(STATE, "utf8"));
const records = (boardId) => state().boards.find((b) => b.board_id === boardId)?.term_records ?? {};
const term = (snap, id) => termCard(snap, id)?.term;
const eqJson = (actual, expected, what) => eq(JSON.stringify(actual), JSON.stringify(expected), what);
const resumedLines = (tail) => (tail ?? "").split("\n").filter((l) => l.trimEnd() === "RESUMED").length;
const resumed = (snap, id) => resumedLines(term(snap, id)?.scrollback_tail);
const terminals = (snap) => snap.cards.filter((c) => c.kind === "term").map((c) => c.id);
/** `scrollback_tail` ends at the cursor's row, so on a young terminal its line
 *  count is how far the cursor has gone down. */
const rows = (tail) => tail.split("\n").length;

async function until(what, boundMs, done) {
  const deadline = Date.now() + boundMs;
  for (;;) {
    const value = done();
    if (value) return value;
    if (Date.now() >= deadline) throw new Error(`${what} never held within ${boundMs} ms`);
    await sleep(200);
  }
}

/** A snapshot once `holds` does. `--until` cannot wait for a key to go: a
 *  path that does not resolve is false in both polarities. */
const settled = (what, boundMs, holds) => until(what, boundMs, () => {
  const s = snapshot();
  return holds(s) ? s : null;
});
const chipsGone = (ids) =>
  settled(`the resume_chip of ${ids.join(", ")} gone`, 2000, (s) => ids.every((id) => term(s, id)?.resume_chip === undefined));

/** Each terminal's scrollback, once it has not changed for a second. */
async function steadyTails() {
  let last;
  let since = 0;
  const tails = await until("the scrollback holds still for 1000 ms", 10000, () => {
    const s = snapshot();
    const now = JSON.stringify(Object.fromEntries(terminals(s).map((id) => [id, term(s, id).scrollback_tail])));
    if (now !== last) [last, since] = [now, Date.now()];
    return Date.now() - since >= 1000 ? now : null;
  });
  return JSON.parse(tails);
}

/** The dev daemon's pids, from the socket alone. */
function daemonPids() {
  try {
    return execFileSync("lsof", ["-t", DAEMON_SOCK], { encoding: "utf8" }).split("\n").filter(Boolean).map(Number);
  } catch {
    return [];
  }
}

function killDaemon() {
  const pids = daemonPids();
  if (pids.length === 0) throw new Error(`no daemon holds ${DAEMON_SOCK}`);
  console.log(`       killing tarmacd pid(s) ${pids.join(" ")} on ${DAEMON_SOCK}`);
  for (const pid of pids) process.kill(pid, "SIGKILL");
}

/** A `click`, with its parsed body: stdout on success, stderr on a refusal. */
function click(target, control) {
  const r = dev("click", target, control);
  return { code: r.code, body: json(r) };
}

const agents = [];

/** A stand-in agent in `id`: it records the command and sleeps, so the
 *  daemon's poll keeps the record. Returns its pid, which is also its group. */
function startAgent(id) {
  pointer("focus", id);
  typeAll(id, `( '${CLI}' resume set "${CMD}"; sleep 600 ) & echo QA""PID=$!\n`);
  const snap = waitFor(id, `cards[${id}].term.scrollback_tail contains "QAPID="`, "--timeout", "5000");
  const tail = term(snap, id).scrollback_tail;
  const pid = Number([...tail.matchAll(/QAPID=(\d+)/g)].at(-1)?.[1]) || null;
  if (!pid) throw new Error(`the stand-in agent's pid in ${id} was not printed; end its \`sleep 600\` by hand (jobs -l)`);
  agents.push(pid);
  console.log(`       stand-in agent ${pid} in ${id}`);
  return pid;
}

function endAgents() {
  for (const pid of agents.splice(0)) {
    try {
      process.kill(-pid, "SIGTERM");
      console.log(`       ended the stand-in agent's process group ${pid}`);
    } catch {
      console.log(`       the stand-in agent's process group ${pid} is already gone`);
    }
  }
}

function folder() {
  return realpathSync(mkdtempSync(join(tmpdir(), "tarmac-qa-resume-")));
}

/** `press cmd+t` and the id of the terminal it made. */
async function newTerminal() {
  const before = new Set(terminals(snapshot()));
  eq(dev("press", "cmd+t").code, 0, "press cmd+t");
  const snap = await until("a new terminal", 5000, () => {
    const s = snapshot();
    return terminals(s).some((id) => !before.has(id) && term(s, id)?.alive) ? s : null;
  });
  return terminals(snap).find((id) => !before.has(id));
}

/** The clipboard is the user's: read it only between a save and a restore. */
function withClipboard(body) {
  const saved = execFileSync("pbpaste", { encoding: "utf8" });
  try {
    return body();
  } finally {
    execFileSync("pbcopy", { input: saved });
  }
}

// ------------------------------------------------------------ shared steps

/** S26: a click on a card that is not prime runs its command and selects it;
 *  a click on `skip` on another leaves the selection and drops the record. */
async function panelClicks(boardId, resumeID, skipID) {
  await run.checkAsync(`click ${resumeID} resume: it runs there, selects the card and leaves the viewport (S26, S40)`, async () => {
    const before = snapshot();
    if (before.active_element.card === resumeID) throw new Error(`${resumeID} is prime already; the step needs a card that is not`);
    const { code, body } = click(resumeID, "resume");
    eq(code, 0, "click exit");
    eq(body.delivery, "window", "delivery (the panel's hit test lets the press reach the button)");
    eq(body.control, "resume", "reply control");
    eq(body.card, resumeID, "reply card");
    eq(typeof body.activated, "boolean", "reply activated is a boolean");
    eq(body.focused_card, resumeID, "the card is selected (O10)");
    eq(body.active_element.card, resumeID, "the card has the keys");
    const snap = waitFor(resumeID, `cards[${resumeID}].term.scrollback_tail contains "RESUMED"`, "--timeout", "5000");
    eq(resumed(snap, resumeID), 1, "lines that are exactly RESUMED");
    eqJson(snap.viewport, before.viewport, "viewport");
  });

  await run.checkAsync(`click ${skipID} skip: the selection stays, the panel, the chip and the record go (S26)`, async () => {
    const { code, body } = click(skipID, "skip");
    eq(code, 0, "click exit");
    eq(body.focused_card, resumeID, "the selection is the resume click's card (O10)");
    eq(term(snapshot(), skipID).resume, undefined, "the panel is gone");
    await chipsGone([skipID]);
    await until(`no resume for ${skipID} in state.json`, 2000, () => records(boardId)[skipID]?.resume === undefined);
  });
}

// ------------------------------------------------------ dead card cases

/** The preflight terminal and `count - 1` more each record the command in a
 *  folder of its own; then the daemon is killed, so each card is dead with a
 *  reopen offer. `reopenOne` reopens one by Return on its dead card and gives
 *  the id of the card that takes its place, which `fresh` keeps. */
async function deadCards(count) {
  const { term: a, boardId } = preflight(run);
  const ids = [a];
  const folders = new Map();

  await run.checkAsync(`${count} terminals record the command, and state.json has each before the kill`, async () => {
    for (let i = 1; i < count; i++) ids.push(await newTerminal());
    for (const id of ids) {
      folders.set(id, folder());
      pointer("focus", id);
      typeAll(id, `cd '${folders.get(id)}' && sleep 1\n`);
      startAgent(id);
    }
    await until(`the ${count} records in state.json`, 10000, () =>
      ids.every((id) => records(boardId)[id]?.resume?.cmd === CMD),
    );
  });

  await run.checkAsync("the daemon is killed by pid and each card is dead with a reopen offer", async () => {
    killDaemon();
    for (const id of ids) {
      const snap = waitFor(id, `cards[${id}].term.reopen == true`, "--timeout", "20000");
      eq(term(snap, id).alive, false, `${id} is dead`);
    }
  });

  const fresh = new Map();
  async function reopenOne(id) {
    pointer("focus", id);
    eq(dev("key", id, "enter").code, 0, `key ${id} enter`);
    const known = new Set([...fresh.values()]);
    const { snap, added } = await until(`a reopened card in ${id}'s place`, 5000, () => {
      const s = snapshot();
      const found = s.cards.find((c) => c.term?.resume?.cmd === CMD && !known.has(c.id) && !ids.includes(c.id));
      return s.cards.every((c) => c.id !== id) && found ? { snap: s, added: found.id } : null;
    });
    fresh.set(id, added);
    eq(snap.focused_card, added, "the reopened card is selected");
    return added;
  }
  return { boardId, ids, folders, fresh, reopenOne };
}

// --------------------------------------------------------------- reopen

async function reopen() {
  const { boardId, ids, folders, fresh, reopenOne } = await deadCards(4);
  const [a] = ids;

  let a2;
  await run.checkAsync("Return on A's dead card reopens it with the panel and the chip (S30)", async () => {
    a2 = await reopenOne(a);
    const t = term(snapshot(), a2);
    eq(t.resume.queued, false, "resume.queued");
    eq(t.resume.title, TITLE, "resume.title");
    eq(t.resume_chip, CMD, "resume_chip");
  });

  await run.checkAsync("Return on A″'s armed panel runs the command once; the chip goes (S30, 2611.0011 S37)", async () => {
    waitFor(a2, `cards[${a2}].term.resume.armed == true`, "--timeout", "10000");
    eqJson(term(snapshot(), a2).resume.buttons, ["⏎ resume", "esc skip"], "prime buttons");
    eq(dev("key", a2, "enter").code, 0, "key enter");
    const snap = waitFor(a2, `cards[${a2}].term.scrollback_tail contains "RESUMED"`, "--timeout", "5000");
    eq(resumed(snap, a2), 1, "lines that are exactly RESUMED");
    eq(term(snap, a2).resume, undefined, "the panel is gone");
    await chipsGone([a2]);
  });

  await run.checkAsync("A″ is in its folder, and state.json has no entry under A's dead id", async () => {
    // A short mark of the folder, not the path itself: a temp path is wider
    // than a default card, and a wrapped line would not match.
    const mark = createHash("sha1").update(`${folders.get(a)}\n`).digest("hex").slice(0, 8);
    typeAll(a2, `printf 'CW%s:%s\\n' D "$(pwd -P | shasum | cut -c1-8)"\n`);
    waitFor(a2, `cards[${a2}].term.scrollback_tail contains "CWD:${mark}"`, "--timeout", "5000");
    await until("the saved records", 5000, () => {
      const r = records(boardId);
      return r[a] === undefined && r[a2] !== undefined && r[a2].resume === undefined;
    });
  });

  const [, b, c, d] = ids;
  for (const id of [b, c, d]) {
    await run.checkAsync(`Return on ${id}'s dead card reopens it`, async () => {
      await reopenOne(id);
    });
  }

  await run.checkAsync("Esc on D″'s armed panel drops the offer and the record (S28)", async () => {
    const d2 = fresh.get(d);
    waitFor(d2, `cards[${d2}].term.resume.armed == true`, "--timeout", "10000");
    // The kill's `tarmacd connection lost` toast takes the first Esc (EscLadder).
    await settled("no toast", 10000, (s) => s.toasts.length === 0);
    eq(dev("key", d2, "escape").code, 0, "key escape");
    await settled(`${d2}'s panel gone`, 2000, (s) => term(s, d2)?.resume === undefined);
    await until(`no resume for ${d2} in state.json`, 2000, () => records(boardId)[d2]?.resume === undefined);
  });

  await panelClicks(boardId, fresh.get(b), fresh.get(c));

  await run.checkAsync("A″'s header chip shows a live record, copies it and moves nothing (S29)", async () => {
    startAgent(a2);
    await settled(`${a2}'s resume_chip`, 2000, (s) => term(s, a2)?.resume_chip === CMD);
    pointer("focus", fresh.get(d));
    const before = snapshot();
    withClipboard(() => {
      const { code, body } = click(a2, "resume_chip");
      eq(code, 0, "click exit");
      eq(body.delivery, "window", "delivery (the header's hit test lets the press reach the chip)");
      eq(execFileSync("pbpaste", { encoding: "utf8" }), CMD, "the clipboard");
      eq(body.focused_card, before.focused_card, "focused_card");
      eq(body.active_element.card, before.active_element.card, "active_element.card");
    });
    await settled("the copy toast", 7000, (s) => s.toasts.includes(COPIED));
  });

  await run.checkAsync("`tarmac resume clear` in A″ takes the chip away (S29)", async () => {
    pointer("focus", a2);
    typeAll(a2, `'${CLI}' resume clear\n`);
    await chipsGone([a2]);
  });

  await run.checkAsync("click refuses a bad name, an absent control, no restore card and a doc (S40)", async () => {
    const offers = () => snapshot().cards.map((c) => [c.id, c.term?.resume, c.term?.resume_chip]);
    const before = offers();
    let r = click(a2, "nonsense");
    eq(r.code, 1, "nonsense exit");
    eq(r.body.error, "bad_request", "nonsense error");
    eqJson(offers(), before, "nothing changed");
    r = click(a2, "resume");
    eq(r.code, 1, "absent exit");
    eq(r.body.error, "no_such_control", "absent error");
    eq(Array.isArray(r.body.present), true, "present lists what the card has");
    r = click("restore_card", "resume_all");
    eq(r.code, 1, "restore_card exit");
    eq(r.body.error, "no_such_control", "restore_card error");
    eq(r.body.card, null, "restore_card's card");
    const doc = join(folder(), "qa-resume.md");
    writeFileSync(doc, "# qa\n");
    open(doc);
    waitFor(null, `cards[${doc}].kind == "doc"`, "--timeout", "5000");
    r = click(doc, "resume");
    eq(r.code, 1, "doc exit");
    eq(r.body.error, "unsupported_card_kind", "doc error");
  });
}

// -------------------------------------------------------- before output

/** The gate holds `id`'s shell: its foreground process becomes the gate
 *  script (`sh`, or its `sleep`; just after the spawn it is still the forked
 *  `tarmacd`), it has printed nothing, and the offer is not armed. A shell
 *  that is merely slow to start is not enough: the step must not depend on
 *  the race. */
async function silent(id) {
  let t;
  try {
    t = await until(`${id} held by the gate`, 3000, () => {
      const now = term(snapshot(), id);
      if (now.scrollback_tail.trim() !== "") throw new Error(`proc ${now.proc}, and it printed`);
      return ["sh", "sleep"].includes(now.proc) ? now : null;
    });
  } catch (e) {
    throw new Error(`${id} is not held by the gate (${e.message}); run \`make run SHELL_GATE=1\` (same DEV_DIR) first`);
  }
  eq(t.resume.armed, false, `${id} resume.armed`);
  return t;
}

async function beforeOutput() {
  if (!GATE) run.die("TARMAC_QA_SHELL_GATE is not set; run this through `make qa-resume`");
  const { boardId, ids, fresh, reopenOne } = await deadCards(3);
  const [x, y, z] = ids;
  writeFileSync(GATE, "");
  try {
    await run.checkAsync(`Return on ${x}'s reopened card before its first output: the panel and the record go (S28)`, async () => {
      const x2 = await reopenOne(x);
      await silent(x2);
      eq(dev("key", x2, "enter").code, 0, "key enter");
      await settled(`${x2}'s panel gone`, 2000, (s) => term(s, x2)?.resume === undefined);
      await until(`no resume for ${x2} in state.json`, 2000, () => records(boardId)[x2]?.resume === undefined);
      eq(term(snapshot(), x2).scrollback_tail.trim(), "", `${x2} still has no output`);
    });

    await run.checkAsync(`click resume on ${y}'s reopened card before its first output: the run is queued (S28)`, async () => {
      const y2 = await reopenOne(y);
      await silent(y2);
      const { code, body } = click(y2, "resume");
      eq(code, 0, "click exit");
      eq(body.focused_card, y2, "the card is selected (O10)");
      const t = term(snapshot(), y2);
      eq(t.resume.queued, true, "resume.queued");
      eq(t.resume.title, QUEUED_TITLE, "resume.title");
      eqJson(t.resume.buttons, ["skip"], "buttons");
      eq(t.scrollback_tail.trim(), "", `${y2} still has no output`);
    });

    await run.checkAsync(`${z} is reopened under the gate and gets no key: the reference for the empty line`, async () => {
      await silent(await reopenOne(z));
    });
  } finally {
    rmSync(GATE, { force: true });
  }

  await run.checkAsync("the gate opens: the queued card runs once, the other shell gets an empty line (S28)", async () => {
    const [x2, y2, z2] = [fresh.get(x), fresh.get(y), fresh.get(z)];
    const snap = waitFor(y2, `cards[${y2}].term.scrollback_tail contains "RESUMED"`, "--timeout", "10000");
    eq(resumed(snap, y2), 1, `RESUMED lines in ${y2}`);
    await chipsGone([x2, y2]);
    await until(`no resume for ${y2} in state.json`, 2000, () => records(boardId)[y2]?.resume === undefined);
    const tails = await steadyTails();
    eq(resumed(snapshot(), x2), 0, `RESUMED lines in ${x2}`);
    // The same shell start-up in both, so only the empty line's second prompt
    // puts X″'s cursor further down, however many rows the prompt has.
    if (rows(tails[x2]) <= rows(tails[z2])) {
      throw new Error(`${x2}'s cursor is not below ${z2}'s (no empty line):\n${tails[x2]}\n--- ${z2}:\n${tails[z2]}`);
    }
  });
}

// ------------------------------------------------------- restore card cases

async function restoreSetup() {
  const { term: a, boardId } = preflight(run);
  if (terminals(snapshot()).length !== 1) {
    run.die("restore-setup needs a board with exactly one terminal card; use a fresh DEV_DIR");
  }
  await run.checkAsync("A and B record the command, C only a folder; state.json has both", async () => {
    const b = await newTerminal();
    const c = await newTerminal();
    const f = folder();
    for (const id of [a, b]) {
      pointer("focus", id);
      typeAll(id, `cd '${f}' && sleep 1\n`);
      startAgent(id);
    }
    pointer("focus", c);
    typeAll(c, `cd '${folder()}' && sleep 1\n`);
    await until("both records in state.json", 10000, () =>
      [a, b].every((id) => records(boardId)[id]?.resume?.cmd === CMD) && records(boardId)[c]?.last_cwd,
    );
  });
  await run.checkAsync("the app quits by a double ⌘Q tap, then the daemon is killed by pid", async () => {
    await quitByDoubleTap();
    killDaemon();
  });
  endAgents();
  console.log("\nnext: `make run` (same DEV_DIR), then `make qa-resume CASE=<a restore card case>`");
}

async function quitByDoubleTap() {
  await pressQuit();
  waitFor(null, 'quit_guard.phase == "idle"', "--timeout", "1000");
  const r = await pressQuitAgain("--hold", "400");
  await waitGone(r.exitedAt + 2000 - Date.now());
}

const CHOICES = ["⏎ resume all", "decide per card", "esc skip all"];

/** The card as `restore-setup` left it: two cards that offer the command, one
 *  that does not. */
function restoreCardUp() {
  const { boardId } = preflight(run, { keepRestoreCard: true });
  const snap = snapshot();
  if (!snap.restore_card) run.die("no restore card; run `make qa-resume CASE=restore-setup`, then `make run`, first");
  const offers = snap.cards.filter((c) => c.term?.resume?.cmd === CMD).map((c) => c.id);
  const plain = terminals(snap).filter((id) => !offers.includes(id));
  run.check("the restore card reads its lines and its choices (S25)", () => {
    eqJson(snap.restore_card.lines, ["✓ 3 terminals back in their folders", "2 with an agent session to resume"], "lines");
    eqJson(snap.restore_card.choices, CHOICES, "choices");
    eq(offers.length, 2, "cards that offer the command");
  });
  return { boardId, offers, plain };
}

/** `held` (S25's held Return, #380): the repeats after the card closes are
 *  taken and dropped, so the card with the keys moves down no more rows than
 *  the other card that ran the same command in the same folder, and the card
 *  with no offer gets no byte. */
async function resumeAll(choose, { held = false } = {}) {
  const { boardId, offers, plain } = restoreCardUp();
  await run.checkAsync("resume all: each offer runs once, at its own output; the third card gets nothing (S25)", async () => {
    const before = held && (await steadyTails());
    choose();
    waitFor(null, "restore_card == null", "--timeout", "2000");
    for (const id of offers) {
      const snap = waitFor(id, `cards[${id}].term.scrollback_tail contains "RESUMED"`, "--timeout", "10000");
      eq(resumed(snap, id), 1, `RESUMED lines in ${id}`);
    }
    const snap = snapshot();
    for (const id of plain) eq(resumed(snap, id), 0, `RESUMED lines in ${id}`);
    await until("no resume in state.json", 2000, () => offers.every((id) => records(boardId)[id]?.resume === undefined));
    await chipsGone(offers);
    if (!held) return;
    const after = await steadyTails();
    for (const id of offers) eq(resumedLines(after[id]), 1, `RESUMED lines in ${id}`);
    const moved = (id) => rows(after[id]) - rows(before[id]);
    eq(moved(offers[0]), moved(offers[1]), `rows ${offers[0]} moved, against ${offers[1]}`);
    for (const id of plain) eq(after[id], before[id], `${id}'s scrollback`);
  });
}

async function perCard(choose) {
  const { boardId, offers } = restoreCardUp();
  await run.checkAsync("decide per card: the card closes, no terminal gets a byte, both panels show (S26)", async () => {
    const tails = await steadyTails();
    choose();
    waitFor(null, "restore_card == null", "--timeout", "2000");
    // Nothing to wait for: the check is that no byte arrives.
    await sleep(500);
    const snap = snapshot();
    for (const [id, tail] of Object.entries(tails)) eq(term(snap, id).scrollback_tail, tail, `${id}'s scrollback`);
    for (const id of offers) {
      eq(term(snap, id).resume.queued, false, `${id} queued`);
      eq(term(snap, id).resume.title, TITLE, `${id} title`);
      eq(term(snap, id).resume_chip, CMD, `${id} resume_chip`);
    }
    const prime = snap.active_element.card;
    const other = offers.find((id) => id !== prime);
    if (offers.includes(prime)) {
      const armed = waitFor(prime, `cards[${prime}].term.resume.armed == true`, "--timeout", "10000");
      eqJson(term(armed, prime).resume.buttons, ["⏎ resume", "esc skip"], "prime buttons");
    }
    eqJson(term(snapshot(), other).resume.buttons, ["resume", "skip"], "other buttons");
  });
  if (CASE === "per-card") {
    const prime = snapshot().active_element.card;
    const notPrime = offers.find((id) => id !== prime);
    const rest = offers.find((id) => id !== notPrime);
    await panelClicks(boardId, notPrime, rest);
  }
}

async function skipAll(choose) {
  const { boardId, offers } = restoreCardUp();
  await run.checkAsync("skip all: nothing runs, the records and the chips go (S27)", async () => {
    choose();
    waitFor(null, "restore_card == null", "--timeout", "2000");
    await until("no resume in state.json", 2000, () => offers.every((id) => records(boardId)[id]?.resume === undefined));
    await chipsGone(offers);
    await sleep(2000);
    const snap = snapshot();
    for (const id of offers) eq(resumed(snap, id), 0, `RESUMED lines in ${id}`);
  });
}

async function quitWithChoicesUp() {
  const { boardId, offers } = restoreCardUp();
  await run.checkAsync("⌘Q with the choices up quits; nothing ran, the records stay (S32)", async () => {
    const snap = snapshot();
    for (const id of offers) eq(resumed(snap, id), 0, `RESUMED lines in ${id}`);
    await quitByDoubleTap();
    eq(offers.every((id) => records(boardId)[id]?.resume?.cmd === CMD), true, "both commands in state.json");
  });
}

const cases = {
  reopen,
  "restore-setup": restoreSetup,
  "resume-all": () => resumeAll(() => eq(dev("press", "enter").code, 0, "press enter")),
  "resume-all-held": () =>
    resumeAll(() => {
      const r = dev("press", "enter", "--hold", "1000", "--repeat", "20");
      eq(r.code, 0, "press enter --repeat 20");
      eq(json(r).repeats, 20, "repeats posted");
    }, { held: true }),
  "before-output": beforeOutput,
  "resume-all-click": () => resumeAll(() => eq(click("restore_card", "resume_all").code, 0, "click resume_all")),
  "per-card": () => perCard(() => eq(dev("press", "tab").code, 0, "press tab")),
  "per-card-click": () => perCard(() => eq(click("restore_card", "decide_per_card").code, 0, "click decide_per_card")),
  veil: () => perCard(() => eq(click("restore_card", "veil").code, 0, "click veil")),
  "skip-all": () => skipAll(() => eq(dev("press", "escape").code, 0, "press escape")),
  "skip-all-click": () => skipAll(() => eq(click("restore_card", "skip_all").code, 0, "click skip_all")),
  quit: quitWithChoicesUp,
};
const CASES = Object.keys(cases);
if (!CASES.includes(CASE)) run.die(`unknown CASE=${CASE}; expected one of ${CASES.join(", ")}`);

try {
  await cases[CASE]();
} finally {
  endAgents();
}
run.finish();
