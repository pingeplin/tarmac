#!/usr/bin/env node
// Resume after a restart (spec 2611.0011, S37): a stand-in agent records a
// command, the dev daemon is killed, the dead card reopens in its folder and
// its chip runs the command. It kills the dev daemon, which ends every dev
// terminal, so it is a runner of its own and not part of `smoke.mjs`.
//
// The daemon is found only by `lsof -t` on lib.mjs's absolute DAEMON_SOCK, as
// `make kill-daemon` does, and only those pids are killed. The driver's `key`
// always sends `isARepeat: false`, so the held-Return steps of S32 stay
// manual: here Return is pressed once for each.
//
// Run:  make qa-resume    (against a live `make run`; DEV_DIR= as for it)

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { CLI, DAEMON_SOCK, STATE, dev, eq, json, pointer, preflight, runner, sleep, typeAll, waitFor } from "./lib.mjs";

const run = runner("make qa-resume");
/** Its output, `RESUMED`, is not in its own text: a line that is exactly
 *  `RESUMED` proves the command ran, which the echoed command line cannot. */
const CMD = "printf 'RES%s\\n' UMED";

const state = () => JSON.parse(readFileSync(STATE, "utf8"));
const records = (boardId) => state().boards.find((b) => b.board_id === boardId)?.term_records ?? {};

async function until(what, boundMs, done) {
  const deadline = Date.now() + boundMs;
  for (;;) {
    const value = done();
    if (value) return value;
    if (Date.now() >= deadline) throw new Error(`${what} never held within ${boundMs} ms`);
    await sleep(200);
  }
}

/** The dev daemon's pids, from the socket alone. */
function daemonPids() {
  try {
    return execFileSync("lsof", ["-t", DAEMON_SOCK], { encoding: "utf8" }).split("\n").filter(Boolean).map(Number);
  } catch {
    return [];
  }
}

const { term, boardId } = preflight(run);
const folder = realpathSync(mkdtempSync(join(tmpdir(), "tarmac-qa-resume-")));
let agentPgid = null;
let reopened = null;

await run.checkAsync("a stand-in agent records the command, and state.json has it before the kill", async () => {
  pointer("focus", term);
  typeAll(term, `cd '${folder}' && sleep 1\n`);
  typeAll(term, `( '${CLI}' resume set "${CMD}"; sleep 600 ) & echo QAPID=$!\n`);
  const tail = waitFor(term, `cards[${term}].term.scrollback_tail contains "QAPID="`, "--timeout", "5000");
  agentPgid = Number(/QAPID=(\d+)/.exec(tail.cards.find((c) => c.id === term).term.scrollback_tail)?.[1]) || null;
  const entry = await until("the record in state.json", 10000, () => {
    const r = records(boardId)[term];
    return r?.resume?.cmd === CMD && r?.last_cwd === folder ? r : null;
  });
  console.log(`       ${JSON.stringify(entry)}`);
});

await run.checkAsync("the daemon is killed by pid and the card is dead with a reopen offer", async () => {
  const pids = daemonPids();
  if (pids.length === 0) throw new Error(`no daemon holds ${DAEMON_SOCK}`);
  console.log(`       killing tarmacd pid(s) ${pids.join(" ")} on ${DAEMON_SOCK}`);
  for (const pid of pids) process.kill(pid, "SIGKILL");
  const snap = waitFor(term, `cards[${term}].term.reopen == true`, "--timeout", "20000");
  eq(snap.cards.find((c) => c.id === term).term.alive, false, "the old card is dead");
});

await run.checkAsync("Return on the dead card reopens it in its folder with the resume chip", async () => {
  pointer("focus", term);
  eq(dev("key", term, "enter").code, 0, "key enter");
  const snap = await until("a reopened card in the dead card's place", 5000, () => {
    const s = json(dev("snapshot"));
    return s.cards.every((c) => c.id !== term) && s.cards.some((c) => c.term?.resume?.cmd === CMD) ? s : null;
  });
  reopened = snap.cards.find((c) => c.term?.resume?.cmd === CMD).id;
  eq(snap.focused_card, reopened, "the reopened card is selected");
  waitFor(reopened, `cards[${reopened}].term.resume.armed == true`, "--timeout", "10000");
});

await run.checkAsync("Return on the armed chip runs the command once", async () => {
  if (!reopened) throw new Error("no reopened card");
  eq(dev("key", reopened, "enter").code, 0, "key enter");
  const snap = waitFor(reopened, `cards[${reopened}].term.scrollback_tail contains "RESUMED"`, "--timeout", "5000");
  const card = snap.cards.find((c) => c.id === reopened);
  const lines = card.term.scrollback_tail.split("\n").map((l) => l.trimEnd());
  eq(lines.filter((l) => l === "RESUMED").length, 1, "lines that are exactly RESUMED");
  eq(card.term.resume, undefined, "the chip is gone");
  typeAll(reopened, "pwd\n");
  waitFor(reopened, `cards[${reopened}].term.scrollback_tail contains "${folder}"`, "--timeout", "5000");
});

await run.checkAsync("state.json: no entry under the dead id, and the new entry has no resume", async () => {
  if (!reopened) throw new Error("no reopened card");
  await until("the saved records", 5000, () => {
    const r = records(boardId);
    return r[term] === undefined && r[reopened] !== undefined && r[reopened].resume === undefined;
  });
});

if (agentPgid) {
  try {
    process.kill(-agentPgid, "SIGTERM");
    console.log(`\nended the stand-in agent's process group ${agentPgid}`);
  } catch {
    console.log(`\nthe stand-in agent's process group ${agentPgid} is already gone`);
  }
}
run.finish();
