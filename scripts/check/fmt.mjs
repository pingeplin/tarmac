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

import { execFile } from "node:child_process";
import { writeFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { dirname } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";
import { LANGUAGES, notOnPath, sources, unusable } from "./languages.mjs";
import { cannotRunFor, failure } from "./report.mjs";

const RULE = "fmt";
const CHECK = "make fmt-check";

export const notFormatted = (paths) =>
  failure({
    rule: RULE,
    summary: `${paths.length} ${paths.length === 1 ? "file is" : "files are"} not formatted`,
    at: paths,
    fix: "make fmt",
    then: CHECK,
  });

const cannotRun = cannotRunFor(RULE, CHECK);

/** The formatted text of one file, or the reason the formatter gave none. */
function formatted([command, ...args], cwd, text) {
  return new Promise((done) => {
    const child = execFile(command, args, { cwd, encoding: "utf8", maxBuffer: 64 << 20 }, (error, stdout, stderr) => {
      if (!error) done({ formatted: stdout });
      else if (error.code === "ENOENT") done({ missing: true });
      else done({ refused: firstError(stderr) ?? `exit ${error.code ?? error.signal}` });
    });
    // A formatter that is missing or stops early closes its stdin; the callback above reports that.
    child.stdin.on("error", () => {});
    child.stdin.end(text);
  });
}

/** rustfmt starts the line with `error:`; swift-format puts `<file>:<line>:<column>: ` before it. */
const firstError = (stderr) => stderr.split("\n").map((line) => line.match(/\berror: .*$/)?.[0]).find(Boolean);

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
  const files = sources(language, root);
  if (files.length === 0) return {};
  const blocked = (parts) => ({ blocked: cannotRun(parts.summary, parts.why, parts.fix) });
  const reason = unusable(language);
  if (reason) return blocked(reason);
  const results = await each(files, availableParallelism(), async (source) => ({
    ...source,
    ...(await formatted(language.command, dirname(source.file), source.text)),
  }));
  if (results.some((r) => r.missing)) return blocked(notOnPath(language));
  const refused = results.filter((r) => r.refused);
  if (refused.length > 0) {
    const why = refused.map((r) => `${r.path}: ${r.refused}`);
    return { blocked: cannotRun(`cannot run ${language.tool}`, why, `see the whole error with: ${language.explain(refused[0].path)}`) };
  }
  const changed = results.filter((r) => r.formatted !== r.text);
  if (write) changed.forEach((r) => writeFileSync(r.file, r.formatted));
  return { unformatted: write ? [] : changed.map((r) => r.path) };
}

async function main([mode, only]) {
  const names = Object.keys(LANGUAGES);
  const usage = (summary) => cannotRun(summary, [`it knows: ${names.join(", ")}`], `make fmt-check ONLY=${names[0]}`);
  if (mode !== "--check" && mode !== "--write") return { code: 2, text: usage("the mode must be --check or --write") };
  if (only && !names.includes(only)) return { code: 2, text: usage(`${only} is not a language this check knows`) };
  const root = repoRoot();
  if (!root) return { code: 2, text: cannotRun("not in a git repository", [], "run it from inside the repository") };

  const done = await Promise.all((only ? [only] : names).map((name) => run(LANGUAGES[name], root, mode === "--write")));
  const blocked = done.filter((d) => d.blocked).map((d) => d.blocked);
  const unformatted = done.flatMap((d) => d.unformatted ?? []);
  const text = blocked.join("") + (unformatted.length > 0 ? notFormatted(unformatted) : "");
  return { code: exitCode(blocked, unformatted), text };
}

function exitCode(blocked, unformatted) {
  if (blocked.length > 0) return 2;
  return unformatted.length > 0 ? 1 : 0;
}

if (startedAs(import.meta)) {
  const { code, text } = await main(process.argv.slice(2));
  process.stderr.write(text);
  process.exitCode = code;
}
