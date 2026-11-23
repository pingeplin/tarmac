// The Rust lint: clippy over the workspace with the lint table of
// core/Cargo.toml. The table is at `warn`, so that `cargo test` still runs a
// `todo!()` stub; here a warning is a finding.

import { spawnSync } from "node:child_process";
import { join, relative, resolve } from "node:path";

import { LANGUAGES, tracked } from "./languages.mjs";
import { CLEAN, RULE, findings } from "./lint-common.mjs";
import { blockedFor, failure } from "./report.mjs";

const THEN = "make lint";
const cannotRun = blockedFor(RULE, THEN);

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

export function lintRust(root) {
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
