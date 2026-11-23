#!/usr/bin/env node
// What the pre-commit hook runs: the checks that can judge the staged files,
// and the rules about the whole tree.
//
//   node scripts/check/staged.mjs   exit 0 clean, 1 findings, 2 a check could not run
//
// It reads each staged file as it is in the working tree, not as it is staged.

import { spawnSync } from "node:child_process";
import { join } from "node:path";

import { repoRoot } from "./git.mjs";
import { languageOf } from "./languages.mjs";
import { blockedFor, runCheck } from "./report.mjs";

const cannotRun = blockedFor("staged", "git commit");

function main() {
  const root = repoRoot();
  if (!root) return cannotRun("not in a git repository", [], "run it from inside the repository");
  const listing = spawnSync("git", ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"], { cwd: root, encoding: "utf8" });
  if (listing.error) throw listing.error;
  if (listing.status !== 0) return cannotRun("cannot read the staged files", saidBy(listing), "git status");
  const staged = listing.stdout.split("\0").filter(Boolean);
  const node = (script, ...args) => spawnSync(process.execPath, [join(root, script), ...args], { cwd: root, encoding: "utf8" });
  const runs = [
    ...(staged.length > 0 ? [node("scripts/check/fmt.mjs", "--check", "--paths", ...staged), node("scripts/check/lint.mjs", "--paths", ...staged)] : []),
    // clippy judges the whole workspace, so it runs when any Rust file is staged.
    ...(staged.some((path) => languageOf(path) === "rust") ? [node("scripts/check/lint.mjs", "rust")] : []),
    node("scripts/check/arch.mjs"),
    node("scripts/docs-check.mjs"),
  ];
  return { code: Math.max(...runs.map((run) => run.status ?? 2)), text: runs.map((run) => run.stderr).join("") };
}

const saidBy = ({ stderr, status }) => {
  const lines = stderr.split("\n").filter(Boolean);
  return lines.length > 0 ? lines : [`git ended with ${status ?? "a signal"} and no message`];
};

// The pre-commit hook runs it, so `git commit` runs it again.
await runCheck(import.meta, { rule: "staged", then: "git commit" }, main);
