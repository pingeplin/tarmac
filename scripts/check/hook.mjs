#!/usr/bin/env node
// The adapter between Claude Code's hooks and the checks. It holds no rule of
// its own: it finds the repository an event is about, runs that repository's
// own check scripts, and maps their exit codes to what a hook may say.
//
//   node scripts/check/hook.mjs edit|stop|bash   < the hook's JSON
//
// The checks run are the ones under the target repository's scripts/check/, so
// a worktree on an older branch is judged by its own rules, and a repository
// with no such scripts is not judged at all.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { startedAs } from "./git.mjs";
import { failure } from "./report.mjs";

const git = (cwd, ...args) => spawnSync("git", args, { cwd, encoding: "utf8" });
const rootOf = (directory) => {
  const top = existsSync(directory) ? git(directory, "rev-parse", "--show-toplevel") : { status: 1 };
  return top.status === 0 ? top.stdout.trim() : null;
};

/** Runs one check script of the repository; null when that repository has no such script. */
function check(root, script, args = []) {
  const path = join(root, script);
  if (!existsSync(path)) return null;
  const run = spawnSync(process.execPath, [path, ...args], { cwd: root, encoding: "utf8" });
  return { code: run.status ?? 2, text: run.stderr };
}

const ran = (checks) => checks.filter(Boolean);
const said = (checks, code) => checks.filter((done) => done.code === code).map(({ text }) => text).join("");

// ------------------------------------------------------------------ edit

/** After an edit: format the file, lint it where one file can be judged, and check the tree's rules. The edit stays. */
function edit(input) {
  const file = input.tool_input?.file_path;
  if (typeof file !== "string" || !/\.(rs|swift)$/.test(file) || !statSync(file, { throwIfNoEntry: false })?.isFile()) return pass;
  const root = rootOf(dirname(file));
  if (!root || git(root, "check-ignore", "-q", "--", file).status === 0) return pass;
  const checks = ran([
    check(root, "scripts/check/fmt.mjs", ["--write", "--paths", file]),
    check(root, "scripts/check/lint.mjs", ["--paths", file]),
    check(root, "scripts/check/arch.mjs"),
  ]);
  const text = checks.filter(({ code }) => code !== 0).map((done) => done.text).join("");
  return text ? { code: 2, text } : pass;
}

// ------------------------------------------------------------------ stop

const NOTE = "(the same findings as at the last stop of this session: reported, not blocking)\n";

/** Tracked files that differ from HEAD, staged or not, and new files git does not ignore; a deleted file is not one. */
function changedFiles(root) {
  const lines = (...args) => git(root, ...args).stdout.split("\0").filter(Boolean);
  const hasHead = git(root, "rev-parse", "--verify", "-q", "HEAD").status === 0;
  const tracked = hasHead ? lines("diff", "--name-only", "-z", "HEAD") : lines("ls-files", "-z");
  const fresh = lines("ls-files", "-z", "--others", "--exclude-standard");
  return [...new Set([...tracked, ...fresh])].filter((path) => statSync(join(root, path), { throwIfNoEntry: false })?.isFile());
}

/** Where the last blocked set of a session is remembered: under the git directory, so it is never tracked. */
function stateFile(root, session) {
  if (typeof session !== "string" || !/^[A-Za-z0-9_-]+$/.test(session)) return null;
  return join(git(root, "rev-parse", "--absolute-git-dir").stdout.trim(), "tarmac-hooks", session);
}

const recall = (file) => {
  try {
    return readFileSync(file, "utf8");
  } catch {
    return null;
  }
};

const attempt = (work) => {
  try {
    work();
  } catch {
    // A state file that cannot be written or removed must not change what the hook answers.
  }
};

/**
 * At the end of a turn. A set of findings blocks once: the agent is sent back
 * to fix what it can, and is not held on what it cannot (another agent's
 * unfinished files in the same tree). A check that could not run is said, and
 * does not block.
 */
function stop(input) {
  const root = rootOf(input.cwd ?? process.cwd());
  if (!root) return pass;
  const files = changedFiles(root);
  const named = files.length > 0 ? ["--paths", ...files] : null;
  const checks = ran([
    named && check(root, "scripts/check/fmt.mjs", ["--check", ...named]),
    named && check(root, "scripts/check/lint.mjs", named),
    check(root, "scripts/check/arch.mjs"),
    docs(root),
  ]);
  const findings = said(checks, 1);
  const cannot = said(checks, 2);
  const state = stateFile(root, input.session_id);
  if (!findings) {
    if (state) attempt(() => rmSync(state, { force: true }));
    return { code: 0, text: cannot };
  }
  const key = createHash("sha256").update(findings).digest("hex");
  if (state && recall(state) === key) return { code: 0, text: NOTE + findings + cannot };
  if (state) {
    attempt(() => {
      mkdirSync(dirname(state), { recursive: true });
      writeFileSync(state, key);
    });
  }
  return { code: 2, text: findings + cannot };
}

/** docs-check predates the shared reporter and writes its own text; a failure of it is a finding. */
function docs(root) {
  const path = join(root, "scripts/docs-check.mjs");
  if (!existsSync(path)) return null;
  const run = spawnSync(process.execPath, [path], { cwd: root, encoding: "utf8" });
  return { code: run.status === 0 ? 0 : 1, text: run.stderr };
}

// ------------------------------------------------------------------ bash

/** True for a simple command that kills by name a process whose name holds "tarmac". */
function killsTarmacByName(simple) {
  const words = simple.trim().split(/\s+/);
  while (words[0] === "sudo" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0] ?? "")) words.shift();
  return ["pkill", "killall"].includes(words[0]) && words.slice(1).some((word) => /tarmac/i.test(word));
}

/** Before a Bash call. A kill by name can end the installed app and every terminal it owns. */
function bash(input) {
  const command = input.tool_input?.command;
  if (typeof command !== "string" || !command.split(/;|&&|\|\||\||\n/).some(killsTarmacByName)) return pass;
  return {
    code: 2,
    text: failure({
      rule: "bash",
      summary: "a Tarmac process is not killed by name",
      why: ["a dev build and the installed app share process names; a kill by name can end the installed app and every terminal it owns"],
      fix: "make kill-daemon   (it finds this worktree's daemon by its socket), or kill one pid you have checked",
      then: "run the command again without pkill or killall",
    }),
  };
}

// ------------------------------------------------------------------ main

const pass = { code: 0, text: "" };
const EVENTS = { edit, stop, bash };

function main(event, raw) {
  const handle = EVENTS[event];
  if (!handle) return { code: 0, text: "" };
  let input;
  try {
    input = JSON.parse(raw);
  } catch {
    return pass;
  }
  return handle(input ?? {});
}

if (startedAs(import.meta)) {
  const { code, text } = main(process.argv[2], readFileSync(0, "utf8"));
  process.stderr.write(text);
  process.exitCode = code;
}
