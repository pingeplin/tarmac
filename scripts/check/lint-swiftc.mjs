// The Swift compiler's warnings. Warnings as errors are not in
// app/Package.swift: the compiler is not pinned, and a warning that a
// toolchain update adds must fail this lint, not `make run`, `make bundle` or
// the test job. So this lint builds the package and compares every warning
// with a list of known ones.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

import { LANGUAGES } from "./languages.mjs";
import { CLEAN, RULE, blockedFor, findings } from "./lint-common.mjs";
import { failure } from "./report.mjs";

const KNOWN = "scripts/check/swiftc-known-warnings.json";
const THEN = "make lint ONLY=swiftc";
const PACKAGE = "app";
const cannotRun = blockedFor(THEN);

/** The known-warnings list, or the reason it cannot be used. */
function knownWarnings(root) {
  const bad = (why) => ({ bad: `${KNOWN} ${why}` });
  if (!existsSync(join(root, KNOWN))) return bad("is missing");
  let list;
  try {
    list = JSON.parse(readFileSync(join(root, KNOWN), "utf8"));
  } catch {
    return bad("is not valid JSON");
  }
  if (!Array.isArray(list)) return bad("is not a list");
  const fields = ["file", "message", "issue", "reason"];
  const at = list.findIndex((entry) => fields.some((field) => typeof entry?.[field] !== "string" || entry[field] === ""));
  return at === -1 ? { list } : bad(`entry ${at + 1} needs ${fields.join(", ")}, each a text that is not empty`);
}

/**
 * The warnings with no entry in the list, and the positions (from 1) of the
 * entries that no warning matched. An entry matches on file and message and
 * not on the line, so an edit above a warning does not make it new; and it is
 * used up by one warning, so a second identical warning is new.
 */
export function unmatched(warnings, known) {
  const left = known.map((entry, i) => ({ ...entry, position: i + 1 }));
  const fresh = warnings.filter((warning) => {
    const at = left.findIndex((entry) => entry.file === warning.file && entry.message === warning.message);
    if (at === -1) return true;
    left.splice(at, 1);
    return false;
  });
  return { fresh, gone: left.map(({ position }) => position) };
}

/**
 * The compiler colours its lines and links a warning's group even when its
 * output is not a terminal. The group (` [#NoUsage]`) is dropped too: not every
 * compiler version prints one, and the list must match on all of them.
 */
const plain = (text) =>
  text
    .replace(/\x1b\]8;;[^\x1b]*\x1b\\/g, "")
    .replace(/\x1b\[[0-9;]*m/g, "")
    .replace(/ \[#\w+\]$/gm, "");

/**
 * The warnings and errors of a build, each place and message once: the
 * compiler prints one again for each target that compiles the file. A warning
 * with no place (SwiftPM's own, the linker's) belongs to the package.
 */
export function diagnostics(output, root) {
  const said = new Map();
  for (const [text, path, line, column, level, message] of output.matchAll(/^(\/.+?):(\d+):(\d+): (warning|error): (.*)$/gm)) {
    const file = relative(root, path);
    said.set(`${file}:${line}:${column} ${message}`, { text, at: `${file}:${line}:${column}`, file, level, message });
  }
  for (const [text, message] of output.matchAll(/^warning: (.*)$/gm)) {
    said.set(`${PACKAGE} ${message}`, { text, at: PACKAGE, file: PACKAGE, level: "warning", message });
  }
  return [...said.values()];
}

/**
 * A build of the package from nothing: an incremental build prints a warning
 * only for a file it compiles again. The directory is this run's own, SwiftPM's
 * lock files and temporary folders go inside it, and all of it is removed.
 */
function build(root) {
  const scratch = mkdtempSync(join(tmpdir(), "tarmac-swiftc-"));
  try {
    mkdirSync(join(scratch, "tmp"));
    return spawnSync("swift", ["build", "--build-tests", "--build-path", join(scratch, "build")], {
      cwd: join(root, PACKAGE),
      encoding: "utf8",
      maxBuffer: 256 << 20,
      env: { ...process.env, TMPDIR: join(scratch, "tmp") },
    });
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

export function lintSwiftc(root) {
  if (!existsSync(join(root, PACKAGE, "Package.swift"))) return CLEAN;
  const { list, bad } = knownWarnings(root);
  if (bad) return cannotRun("cannot run swiftc", [bad], `correct ${KNOWN}`);

  const run = build(root);
  if (run.error?.code === "ENOENT") return cannotRun("cannot run swiftc", ["swift is not on the PATH"], LANGUAGES.swift.install);
  const output = plain(run.stdout + run.stderr);
  const said = diagnostics(output, root);
  const errors = said.filter(({ level }) => level === "error");
  if (errors.length > 0 || run.status !== 0) {
    const placed = errors.map(({ at, message }) => `${at} error: ${message}`);
    const unplaced = output.split("\n").filter((line) => /^error\b/.test(line));
    return cannotRun("cannot run swiftc", placed.length > 0 ? placed : unplaced.slice(0, 3), `make the package build: cd ${PACKAGE} && swift build`);
  }

  const { fresh, gone } = unmatched(said, list);
  const at = [...fresh.map((warning) => `${warning.at} swiftc-warning`), ...gone.map((position) => `${KNOWN}:${position} known-warning-is-gone`)];
  if (at.length === 0) return CLEAN;
  const fix = `correct each warning above; remove a known warning from ${KNOWN} when its code is fixed`;
  const shown = fresh.map(({ text }) => `${text}\n`).join("");
  return { code: 1, text: shown + failure({ rule: RULE, summary: findings(at.length, "swiftc"), at, fix, then: THEN }) };
}
