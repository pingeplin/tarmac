#!/usr/bin/env node
// The lint check: one definition for `make lint` and CI.
//
//   node scripts/check/lint.mjs [<language>]    exit 0 clean, 1 findings, 2 could not run
//
// The lint table (core/Cargo.toml) is at `warn`, so that `cargo test` still
// runs a `todo!()` stub. This script is the one place where a warning fails.
// It prints clippy's own text unchanged, then one block that names each place.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";
import { LANGUAGES, sources, toolVersion, unusable } from "./languages.mjs";
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
  if (sources(LANGUAGES.rust, root).length === 0) return CLEAN;
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

/** The rules `.swift-format` knows by name and the ones it turns on; empty when there is no such file. */
function configuredRules(root) {
  const file = join(root, ".swift-format");
  const rules = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")).rules ?? {}) : {};
  return { known: new Set(Object.keys(rules)), on: Object.keys(rules).filter((name) => rules[name]) };
}

/** A rule that is on in the configuration and unknown to the running tool would be off without a word. */
function missingRules(language, on) {
  const dumped = spawnSync("swift", ["format", "dump-configuration"], { encoding: "utf8" });
  const has = new Set(Object.keys(JSON.parse(dumped.stdout).rules));
  const missing = on.filter((name) => !has.has(name));
  if (missing.length === 0) return null;
  const version = toolVersion(language).found;
  return {
    summary: `cannot run ${language.tool}`,
    why: missing.map((name) => `${name} is not a rule of ${language.tool} ${version}`),
    fix: "use a toolchain whose swift-format has the rule, or turn it off in .swift-format",
  };
}

const DIRECTIVE = /\/\/\s*swift-format-ignore(-file)?\b(?::\s*(.*?))?\s*$/;
const isReason = (line) => /^\/\/\s*\S/.test(line) && !DIRECTIVE.test(line);

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
  const { known, on } = configuredRules(root);
  const reason = unusable(language) ?? missingRules(language, on);
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
  if (at.length === 0) return CLEAN;
  return { code: 1, text: run.stderr + failure({ rule: RULE, summary: findings(at.length, language.tool), at, fix: SWIFT_FIX, then: THEN }) };
}

// ------------------------------------------------------------------ both

const LINTS = { rust: lintRust, swift: lintSwift };

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
