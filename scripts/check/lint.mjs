#!/usr/bin/env node
// The lint check: one definition for `make lint` and CI.
//
//   node scripts/check/lint.mjs [<lint>]    exit 0 clean, 1 findings, 2 could not run
//
// Each lint prints its tool's own text unchanged, then one block that names
// each place. With no name, every lint runs and writes its own block.

import { repoRoot, startedAs } from "./git.mjs";
import { blockedFor } from "./lint-common.mjs";
import { lintRust } from "./lint-rust.mjs";
import { lintSwift } from "./lint-swift.mjs";
import { lintSwiftc } from "./lint-swiftc.mjs";

const LINTS = { rust: lintRust, swift: lintSwift, swiftc: lintSwiftc };
const cannotRun = blockedFor("make lint");

function main([only]) {
  const names = Object.keys(LINTS);
  if (only && !names.includes(only)) {
    return cannotRun(`${only} is not a language this check knows`, [`it knows: ${names.join(", ")}`], `make lint ONLY=${names[0]}`);
  }
  const root = repoRoot();
  if (!root) return cannotRun("not in a git repository", [], "run it from inside the repository");
  const done = (only ? [only] : names).map((name) => LINTS[name](root));
  return { code: Math.max(...done.map(({ code }) => code)), text: done.map(({ text }) => text).join("") };
}

if (startedAs(import.meta)) {
  const { code, text } = main(process.argv.slice(2));
  process.stderr.write(text);
  process.exitCode = code;
}
