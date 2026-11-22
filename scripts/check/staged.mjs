#!/usr/bin/env node
// What the pre-commit hook runs: the checks that can judge the staged files,
// and the rules about the whole tree.
//
//   node scripts/check/staged.mjs   exit 0 clean, 1 findings, 2 a check could not run
//
// It reads each staged file as it is in the working tree, not as it is staged.

import { spawnSync } from "node:child_process";
import { join } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";

function main() {
  const root = repoRoot();
  if (!root) return { code: 2, text: "✗ staged: not in a git repository\n" };
  const staged = spawnSync("git", ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"], { cwd: root, encoding: "utf8" }).stdout.split("\0").filter(Boolean);
  const node = (script, ...args) => spawnSync(process.execPath, [join(root, script), ...args], { cwd: root, encoding: "utf8" });
  const runs = [
    ...(staged.length > 0 ? [node("scripts/check/fmt.mjs", "--check", "--paths", ...staged), node("scripts/check/lint.mjs", "--paths", ...staged)] : []),
    // clippy judges the whole workspace, so it runs when any Rust file is staged.
    ...(staged.some((path) => path.endsWith(".rs")) ? [node("scripts/check/lint.mjs", "rust")] : []),
    node("scripts/check/arch.mjs"),
    node("scripts/docs-check.mjs"),
  ];
  return { code: Math.max(...runs.map((run) => run.status ?? 2)), text: runs.map((run) => run.stderr).join("") };
}

if (startedAs(import.meta)) {
  const { code, text } = main();
  process.stderr.write(text);
  process.exitCode = code;
}
