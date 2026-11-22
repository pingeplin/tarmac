#!/usr/bin/env node
// The formatter check: one definition for `make fmt`, `make fmt-check` and CI.
//
//   node scripts/check/fmt.mjs --check [<language>]   exit 0 clean, 1 unformatted, 2 could not run
//   node scripts/check/fmt.mjs --write [<language>]   exit 0 done, 2 could not run
//
// Scope is the files git tracks, each one handed to the formatter by itself on
// stdin. So an untracked or ignored file is never reported or rewritten, and a
// tracked file is always checked, whatever a `mod` line or a build target says.
// A check must not exit 1 for a reason that `--write` cannot fix: that case is
// "could not run".

import { execFile, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { dirname, join } from "node:path";

import { failure } from "./report.mjs";

const RULE = "fmt";
const CHECK = "make fmt-check";

// Each language: the files it owns, and the command that reads one file on
// stdin and writes the formatted text to stdout. The command runs in the
// file's directory, which is where the formatter looks for its configuration.
const LANGUAGES = {
  rust: {
    tool: "rustfmt",
    glob: "*.rs",
    // A bare rustfmt takes edition 2015; the workspace is edition 2024 (core/Cargo.toml).
    command: ["rustfmt", "--edition", "2024"],
    install: "rustup component add rustfmt",
  },
};

export const notFormatted = (paths) =>
  failure({
    rule: RULE,
    summary: `${paths.length} ${paths.length === 1 ? "file is" : "files are"} not formatted`,
    at: paths,
    fix: "make fmt",
    then: CHECK,
  });

const cannotRun = (summary, why, fix) => failure({ rule: RULE, summary, why, fix, then: CHECK });

/** The formatted text of one file, or the reason the formatter gave none. */
function formatted([command, ...args], cwd, text) {
  return new Promise((done) => {
    const child = execFile(command, args, { cwd, encoding: "utf8", maxBuffer: 64 << 20 }, (error, stdout, stderr) => {
      if (!error) done({ text: stdout });
      else if (error.code === "ENOENT") done({ missing: true });
      else done({ refused: stderr.split("\n").find((line) => /^error/i.test(line)) ?? `exit ${error.code ?? error.signal}` });
    });
    // A formatter that is missing or stops early closes its stdin; the callback above reports that.
    child.stdin.on("error", () => {});
    child.stdin.end(text);
  });
}

async function each(items, limit, work) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await work(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

/** Runs one language; returns the report it owes, if any, and the files it found unformatted. */
async function run(language, root, write) {
  const paths = execFileSync("git", ["ls-files", "-z", "--", language.glob], { cwd: root, encoding: "utf8" }).split("\0").filter(Boolean);
  const results = await each(paths, availableParallelism(), async (path) => {
    const file = join(root, path);
    const before = readFileSync(file, "utf8");
    return { path, file, before, ...(await formatted(language.command, dirname(file), before)) };
  });
  if (results.some((r) => r.missing)) {
    return { blocked: cannotRun(`cannot run ${language.tool}`, [`${language.command[0]} is not on the PATH`], language.install) };
  }
  const refused = results.filter((r) => r.refused);
  if (refused.length > 0) {
    const why = refused.map((r) => `${r.path}: ${r.refused}`);
    return { blocked: cannotRun(`cannot run ${language.tool}`, why, "correct each file above so that it parses") };
  }
  const changed = results.filter((r) => r.text !== r.before);
  if (write) changed.forEach((r) => writeFileSync(r.file, r.text));
  return { unformatted: write ? [] : changed.map((r) => r.path) };
}

function gitRoot() {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

async function main([mode, only]) {
  const names = Object.keys(LANGUAGES);
  const usage = (summary) => cannotRun(summary, [`it knows: ${names.join(", ")}`], `make fmt-check ONLY=${names[0]}`);
  if (mode !== "--check" && mode !== "--write") return { code: 2, text: usage("the mode must be --check or --write") };
  if (only && !names.includes(only)) return { code: 2, text: usage(`${only} is not a language this check knows`) };
  const root = gitRoot();
  if (!root) return { code: 2, text: cannotRun("not in a git repository", [], "run it from inside the repository") };

  const done = [];
  for (const name of only ? [only] : names) done.push(await run(LANGUAGES[name], root, mode === "--write"));
  const blocked = done.filter((d) => d.blocked).map((d) => d.blocked);
  const unformatted = done.flatMap((d) => d.unformatted ?? []);
  const text = blocked.join("") + (unformatted.length > 0 ? notFormatted(unformatted) : "");
  return { code: exitCode(blocked, unformatted), text };
}

function exitCode(blocked, unformatted) {
  if (blocked.length > 0) return 2;
  return unformatted.length > 0 ? 1 : 0;
}

if (import.meta.filename === process.argv[1]) {
  const { code, text } = await main(process.argv.slice(2));
  process.stderr.write(text);
  process.exitCode = code;
}
