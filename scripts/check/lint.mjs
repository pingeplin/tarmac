#!/usr/bin/env node
// The lint check: one definition for `make lint` and CI.
//
//   node scripts/check/lint.mjs [<language>]    exit 0 clean, 1 findings, 2 could not run
//
// The lint table (core/Cargo.toml) is at `warn`, so that `cargo test` still
// runs a `todo!()` stub. This script is the one place where a warning fails.
// It prints clippy's own text unchanged, then one block that names each place.

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";
import { LANGUAGES, sources, toolVersion, tracked, unusable } from "./languages.mjs";
import { cannotRunFor, failure } from "./report.mjs";

const RULE = "lint";
const THEN = "make lint";
const CLEAN = { code: 0, text: "" };

const report = cannotRunFor(RULE, THEN);
const cannotRun = (...parts) => ({ code: 2, text: report(...parts) });

const findings = (count, tool) => `${count} ${count === 1 ? "finding" : "findings"} from ${tool}`;

// ------------------------------------------------------------------ Rust

/** The compiler messages of a `--message-format=json` run. */
const messages = (stdout) =>
  stdout
    .split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line))
    .filter(({ reason }) => reason === "compiler-message")
    .map(({ message }) => message);

/** `path:line:column` of the message's primary span, with the path relative to the repo. */
function place(message, workspace, root) {
  let span = message.spans.find((s) => s.is_primary);
  // Inside a macro the span is in the macro's own source; the call site is ours.
  while (span?.expansion) span = span.expansion.span;
  return span && `${relative(root, resolve(workspace, span.file_name))}:${span.line_start}:${span.column_start}`;
}

// A lint has a name; a compile error has an `E####` code or none. A message
// with no place is a count line ("3 warnings emitted").
const lintName = (message) => (/^[a-z]/.test(message.code?.code ?? "") ? message.code.code : null);
const isCompileError = (message) => message.level === "error" && !lintName(message);

function lintRust(root) {
  if (tracked(root, LANGUAGES.rust.glob).length === 0) return CLEAN;
  const workspace = join(root, "core");
  const run = spawnSync("cargo", ["clippy", "--workspace", "--all-targets", "--message-format=json"], {
    cwd: workspace,
    encoding: "utf8",
    maxBuffer: 256 << 20,
  });
  if (run.error?.code === "ENOENT") return cannotRun("cannot run clippy", ["cargo is not on the PATH"], "install Rust from https://rustup.rs");

  // Each target that compiles a file reports it again, sometimes under another
  // spelling of its path, so a message is one place and one name.
  const byPlace = new Map();
  for (const message of messages(run.stdout)) {
    const at = place(message, workspace, root);
    if (at) byPlace.set(`${at} ${lintName(message) ?? message.message}`, { message, at });
  }
  const placed = [...byPlace.values()];
  const rendered = placed.map(({ message }) => message.rendered).join("");
  const errors = placed.filter(({ message }) => isCompileError(message));
  if (errors.length > 0) {
    const why = errors.map(({ message, at }) => `${at} error${message.code ? `[${message.code.code}]` : ""}: ${message.message}`);
    const blocked = cannotRun("cannot run clippy", why, "make the workspace compile: cd core && cargo check --all-targets");
    return { ...blocked, text: rendered + blocked.text };
  }
  if (placed.length === 0 && run.status !== 0) {
    const why = run.stderr.split("\n").filter((line) => line.startsWith("error"));
    const noClippy = /clippy/.test(why.join("\n"));
    return cannotRun("cannot run clippy", why.slice(0, 3), noClippy ? "rustup component add clippy" : "correct the error above");
  }
  if (placed.length === 0) return CLEAN;
  const summary = findings(placed.length, "clippy");
  const fix = "correct each one above; `cargo clippy --fix` applies the ones clippy marks as fixable";
  const at = placed.map(({ message, at }) => `${at} ${lintName(message) ?? "warning"}`);
  return { code: 1, text: rendered + failure({ rule: RULE, summary, at, fix, then: THEN }) };
}

// ----------------------------------------------------------------- Swift

const SWIFT_FIX =
  "correct each one above; `make fmt` clears a layout finding; to keep one, put the reason in a comment and `// swift-format-ignore: <Rule>` on the next line";

const CONFIG = ".swift-format";

/**
 * The rules the configuration knows by name and the ones it turns on, or the
 * parts of a "cannot run" report. Only the root file is read, while the tool
 * obeys the nearest one above each file, tracked or not; so a second one in a
 * directory above any linted file is refused.
 */
function configuredRules(root, language, files) {
  const blocked = (why, fix) => ({ blocked: { summary: `cannot run ${language.tool}`, why: [why], fix } });
  const above = new Set(files.flatMap(({ path }) => ancestors(path)));
  const nested = [...above].sort().find((dir) => existsSync(join(root, dir, CONFIG)));
  if (nested) {
    return blocked(`${nested}/${CONFIG}: only the configuration at the repository root is read`, `remove it, and put its settings in ${CONFIG} at the repository root`);
  }
  if (!existsSync(join(root, CONFIG))) return { known: new Set(), on: [] };
  const correct = `correct ${CONFIG} at the repository root`;
  let rules;
  try {
    rules = JSON.parse(readFileSync(join(root, CONFIG), "utf8"))?.rules ?? {};
  } catch {
    return blocked(`${CONFIG} is not valid JSON`, correct);
  }
  if (typeof rules !== "object" || Array.isArray(rules)) return blocked(`${CONFIG}: rules is not a table of rule names`, correct);
  return { known: new Set(Object.keys(rules)), on: Object.keys(rules).filter((name) => rules[name]) };
}

/** The directories above a repo-relative path, the root not among them: `a/b/c.swift` gives `a/b` and `a`. */
function ancestors(path) {
  const parts = path.split("/").slice(0, -1);
  return parts.map((_, i) => parts.slice(0, i + 1).join("/"));
}

/** A rule that is on in the configuration and unknown to the running tool would be off without a word. */
function missingRules(language, on, version) {
  const dumped = spawnSync("swift", ["format", "dump-configuration"], { encoding: "utf8" });
  const has = new Set(Object.keys(JSON.parse(dumped.stdout).rules));
  const missing = on.filter((name) => !has.has(name));
  if (missing.length === 0) return null;
  return {
    summary: `cannot run ${language.tool}`,
    why: missing.map((name) => `${name} is not a rule of ${language.tool} ${version}`),
    fix: "use a toolchain whose swift-format has the rule, or turn it off in .swift-format",
  };
}

const DIRECTIVE = /\/\/\s*swift-format-ignore(-file)?\b(?::\s*(.*?))?\s*$/;
// A `///` line belongs to a declaration's documentation, so it is not a reason.
const isReason = (line) => /^\/\/(?!\/)\s*\S/.test(line) && !DIRECTIVE.test(line);

/**
 * swift-format's ignore comment has no reason and never goes stale, and three
 * of its forms do something other than they say, so each use is held to one
 * shape: a named rule, on its own line, under a comment that says why.
 */
function directiveFindings({ path, text }, known) {
  const lines = text.split("\n");
  return lines.flatMap((line, i) => {
    const found = line.match(DIRECTIVE);
    if (!found) return [];
    const names = (found[2] ?? "").split(",").map((name) => name.trim()).filter(Boolean);
    const what =
      (line.slice(0, found.index).trim() !== "" && "ignore-has-no-effect") ||
      (found[1] && "ignore-file") ||
      (names.length === 0 && "ignore-without-rule") ||
      (names.some((name) => !known.has(name)) && "ignore-unknown-rule") ||
      (!isReason((lines[i - 1] ?? "").trim()) && "ignore-without-reason");
    return what ? [`${path}:${i + 1}:${found.index + 1} ${what}`] : [];
  });
}

function lintSwift(root) {
  const language = LANGUAGES.swift;
  const files = sources(language, root);
  if (files.length === 0) return CLEAN;
  const version = toolVersion(language);
  const { known, on, blocked: badConfig } = configuredRules(root, language, files);
  const reason = unusable(language, version) ?? badConfig ?? missingRules(language, on, version.found);
  if (reason) return cannotRun(reason.summary, reason.why, reason.fix);

  const run = spawnSync("swift", ["format", "lint", "--parallel", ...files.map(({ path }) => path)], { cwd: root, encoding: "utf8", maxBuffer: 64 << 20 });
  const said = [...run.stderr.matchAll(/^(.+?):(\d+):(\d+): (warning|error): (?:\[(\w+)\] )?(.*)$/gm)].map(
    ([, file, line, column, level, rule, message]) => ({ at: `${relative(root, resolve(root, file))}:${line}:${column}`, level, rule, message }),
  );
  const errors = said.filter(({ level }) => level === "error");
  if (errors.length > 0) {
    const why = errors.map(({ at, message }) => `${at} error: ${message}`);
    const blocked = cannotRun(`cannot run ${language.tool}`, why, `see the whole error with: ${language.explain(errors[0].at.split(":")[0])}`);
    return { ...blocked, text: run.stderr + blocked.text };
  }
  const at = [...said.map(({ at, rule }) => `${at} ${rule ?? "warning"}`), ...files.flatMap((source) => directiveFindings(source, known))];
  // The tool can stop with a message that names no place (a configuration it cannot read).
  if (said.length === 0 && run.status !== 0) {
    const why = run.stderr.split("\n").filter((line) => /\berror\b/.test(line));
    return cannotRun(`cannot run ${language.tool}`, why.slice(0, 3), "correct the error above");
  }
  if (at.length === 0) return CLEAN;
  return { code: 1, text: run.stderr + failure({ rule: RULE, summary: findings(at.length, language.tool), at, fix: SWIFT_FIX, then: THEN }) };
}

// ---------------------------------------------------------------- swiftc

const KNOWN = "scripts/check/swiftc-known-warnings.json";
const SWIFTC_THEN = "make lint ONLY=swiftc";
const swiftcBlocked = (...parts) => ({ code: 2, text: cannotRunFor(RULE, SWIFTC_THEN)(...parts) });

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

function lintSwiftc(root) {
  const packageDir = join(root, "app");
  if (!existsSync(join(packageDir, "Package.swift"))) return CLEAN;
  const { list, bad } = knownWarnings(root);
  if (bad) return swiftcBlocked("cannot run swiftc", [bad], `correct ${KNOWN}`);

  // An incremental build prints a warning only for a file it compiles again,
  // so every run builds from nothing, in a directory of its own.
  const buildDir = mkdtempSync(join(tmpdir(), "tarmac-swiftc-"));
  let run;
  try {
    run = spawnSync("swift", ["build", "--build-tests", "--build-path", buildDir], { cwd: packageDir, encoding: "utf8", maxBuffer: 256 << 20 });
  } finally {
    rmSync(buildDir, { recursive: true, force: true });
  }
  if (run.error?.code === "ENOENT") return swiftcBlocked("cannot run swiftc", ["swift is not on the PATH"], LANGUAGES.swift.install);

  const output = plain(run.stdout + run.stderr);
  const said = new Map();
  for (const [text, path, line, column, level, message] of output.matchAll(/^(\/.+?):(\d+):(\d+): (warning|error): (.*)$/gm)) {
    const file = relative(root, path);
    said.set(`${file}:${line}:${column} ${message}`, { text, at: `${file}:${line}:${column}`, file, level, message });
  }
  const errors = [...said.values()].filter(({ level }) => level === "error");
  if (errors.length > 0 || run.status !== 0) {
    const why = errors.length > 0 ? errors.map(({ at, message }) => `${at} error: ${message}`) : output.split("\n").filter((line) => /^error\b/.test(line)).slice(0, 3);
    return swiftcBlocked("cannot run swiftc", why, "make the package build: cd app && swift build");
  }
  const { fresh, gone } = unmatched([...said.values()], list);
  const at = [...fresh.map((warning) => `${warning.at} swiftc-warning`), ...gone.map((position) => `${KNOWN}:${position} known-warning-is-gone`)];
  if (at.length === 0) return CLEAN;
  const fix = `correct each warning above; remove a known warning from ${KNOWN} when its code is fixed`;
  const shown = fresh.map(({ text }) => `${text}\n`).join("");
  return { code: 1, text: shown + failure({ rule: RULE, summary: findings(at.length, "swiftc"), at, fix, then: SWIFTC_THEN }) };
}

// ------------------------------------------------------------------ both

const LINTS = { rust: lintRust, swift: lintSwift, swiftc: lintSwiftc };

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
