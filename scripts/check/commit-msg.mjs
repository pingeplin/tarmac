#!/usr/bin/env node
// The form of a commit message, for the commit-msg hook.
//
//   node scripts/check/commit-msg.mjs <message file>   exit 0, or 1 with a report
//
// CI checks the sign-off again over the whole branch (scripts/dco-check.mjs);
// this is the same rule at the moment the message is written.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

import { startedAs } from "./git.mjs";
import { failure } from "./report.mjs";

export const TYPES = ["feat", "fix", "refactor", "perf", "test", "docs", "chore", "release"];
const SUBJECT = new RegExp(`^(${TYPES.join("|")})(\\([^()\\s]+\\))?!?: \\S`);
// git writes these three itself; a later rebase removes the last two.
const isMerge = (subject) => subject.startsWith("Merge ");
const isGenerated = (subject) => isMerge(subject) || subject.startsWith('Revert "') || /^(fixup|squash)! /.test(subject);

const refuse = (summary, at, why, fix) => failure({ rule: "commit-msg", summary, at, why, fix, then: "git commit" });

/** The report for a message that is refused, or "" for one that passes. `emails` are the author's and the committer's. */
export function judge(message, emails) {
  const lines = message.split("\n").filter((line) => !line.startsWith("#"));
  const subject = lines.find((line) => line.trim() !== "") ?? "";
  if (!isGenerated(subject) && !SUBJECT.test(subject)) {
    const why = [`types in use: ${TYPES.join(", ")}`];
    return refuse("the subject is not `type(scope): summary`", [subject || "(no subject)"], why, "write the subject as, for example, `fix(board): close a doc card on ⌘W`");
  }
  if (isMerge(subject)) return "";
  const signed = lines.map((line) => line.match(/^Signed-off-by: .*<([^<>]+)>\s*$/)?.[1]).filter(Boolean);
  if (signed.some((email) => emails.includes(email))) return "";
  const why = ["CONTRIBUTING.md asks for a DCO sign-off, and CI refuses a commit without one that matches its author"];
  return refuse(
    signed.length > 0 ? "the Signed-off-by line is not the author's or the committer's" : "the message has no Signed-off-by line",
    [subject],
    why,
    "git commit --amend -s   (or commit with -s)",
  );
}

const emailOf = (ident) => execFileSync("git", ["var", ident], { encoding: "utf8" }).match(/<([^<>]*)>/)?.[1];

if (startedAs(import.meta)) {
  const text = judge(readFileSync(process.argv[2], "utf8"), [emailOf("GIT_AUTHOR_IDENT"), emailOf("GIT_COMMITTER_IDENT")]);
  process.stderr.write(text);
  process.exitCode = text ? 1 : 0;
}
