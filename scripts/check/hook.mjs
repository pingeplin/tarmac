#!/usr/bin/env node
// The adapter between Claude Code's hooks and the checks. It holds no rule of
// its own (the Bash rule is kill-guard.mjs): it finds the repository an event is about, runs that repository's
// own check scripts, and maps their exit codes to what a hook may say.
//
//   node scripts/check/hook.mjs edit|stop|bash   < the hook's JSON
//
// Claude Code starts the adapter of the session's root. When the event is
// about another repository (a worktree, most often), this one hands the event
// to that repository's own adapter, so a branch is judged by its own rules. A
// repository with no adapter is from before the hooks, or is not this project:
// it is not judged at all.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";
import { killsTarmacByName } from "./kill-guard.mjs";
import { languageOf } from "./languages.mjs";
import { failure } from "./report.mjs";

const git = (cwd, ...args) => spawnSync("git", args, { cwd, encoding: "utf8" });

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
function edit(input, root) {
  const file = input.tool_input.file_path;
  if (!languageOf(file) || !statSync(file, { throwIfNoEntry: false })?.isFile()) return pass;
  if (git(root, "check-ignore", "-q", "--", file).status === 0) return pass;
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
function stop(input, root) {
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

/** docs-check predates the shared reporter and its exit codes: a failure of it is a finding. */
function docs(root) {
  const done = check(root, "scripts/docs-check.mjs");
  return done && { ...done, code: done.code === 0 ? 0 : 1 };
}

// ------------------------------------------------------------------ bash

/** Before a Bash call. A kill by name can end the installed app and every terminal it owns. */
function bash(input) {
  const command = input.tool_input?.command;
  if (typeof command !== "string" || !killsTarmacByName(command)) return pass;
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
const CHECKS = { edit, stop };
const SELF = realpathSync(import.meta.filename);

/** The directory an event is about: the edited file's, or the one the turn ended in. */
function placeOf(event, input) {
  if (event === "stop") return input.cwd ?? process.cwd();
  const file = input.tool_input?.file_path;
  return typeof file === "string" ? dirname(file) : null;
}

function main(event, raw) {
  let input;
  try {
    input = JSON.parse(raw) ?? {};
  } catch {
    return pass;
  }
  if (event === "bash") return bash(input);
  const place = CHECKS[event] && placeOf(event, input);
  const root = place && repoRoot(place);
  const adapter = root && join(root, "scripts/check/hook.mjs");
  if (!adapter || !existsSync(adapter)) return pass;
  if (realpathSync(adapter) === SELF) return CHECKS[event](input, root);
  const run = spawnSync(process.execPath, [adapter, event], { input: raw, encoding: "utf8" });
  return { code: run.status ?? 0, text: run.stderr };
}

if (startedAs(import.meta)) {
  const { code, text } = main(process.argv[2], readFileSync(0, "utf8"));
  process.stderr.write(text);
  process.exitCode = code;
}
