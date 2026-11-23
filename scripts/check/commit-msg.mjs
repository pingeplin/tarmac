#!/usr/bin/env node
// The form of a commit message, and the branch it may go on, for the commit-msg hook.
//
//   node scripts/check/commit-msg.mjs <message file>   exit 0, or 1 with a report
//
// CI checks the sign-off again over the whole branch (scripts/dco-check.mjs);
// this is the same rule at the moment the message is written.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { startedAs } from "./git.mjs";
import { failure } from "./report.mjs";
import { signedBy, signers } from "./signoff.mjs";

export const TYPES = ["feat", "fix", "refactor", "perf", "test", "docs", "chore", "release"];
const SUBJECT = new RegExp(`^(${TYPES.join("|")})(\\([^()\\s]+\\))?!?: \\S`);
/** The subject rule: `type(scope): summary`. The pull request check holds a title to it too (pr.mjs). */
export const isSubject = (subject) => SUBJECT.test(subject);
// git writes these three itself; a later rebase removes the last two.
const isGenerated = (subject) => subject.startsWith("Merge ") || subject.startsWith('Revert "') || /^(fixup|squash)! /.test(subject);

const refuse = (summary, at, why, fix) => failure({ rule: "commit-msg", summary, at, why, fix, then: "git commit" });

/**
 * The report for a message that is refused, or "" for one that passes. `emails`
 * are the author's and the committer's. `merging` is true while git makes a
 * merge commit: CI asks no sign-off of one, and it goes by the commit's
 * parents, not by its subject. `branch` is the full ref of the branch that
 * will hold the commit, or null where the commit is not new work on it: a
 * detached HEAD (a rebase), the first commit, and a merge, cherry-pick or
 * revert that git is finishing.
 */
export function judge(message, emails, merging = false, branch = null) {
  const lines = message.split("\n").filter((line) => !line.startsWith("#"));
  const subject = lines.find((line) => line.trim() !== "") ?? "";
  if (!isGenerated(subject) && !isSubject(subject)) {
    const why = [`types in use: ${TYPES.join(", ")}`];
    return refuse("the subject is not `type(scope): summary`", [subject || "(no subject)"], why, "write the subject as, for example, `fix(board): close a doc card on ⌘W`");
  }
  if (merging) return "";
  if (branch === "refs/heads/main") {
    const why = ["docs/workflow.md: never work directly on main; one branch type/N-slug per issue"];
    return refuse("a commit on main", [subject], why, "git switch -c type/N-slug (the staged changes go with you; no commit was made)");
  }
  const signed = signers(lines.join("\n"));
  if (signedBy(signed, emails)) return "";
  const why = ["CONTRIBUTING.md asks for a DCO sign-off, and CI refuses a commit without one that matches its author"];
  return refuse(
    signed.length > 0 ? "the Signed-off-by line is not the author's or the committer's" : "the message has no Signed-off-by line",
    [subject],
    why,
    "commit again with -s: git commit -s -F .git/COMMIT_EDITMSG",
  );
}

const emailOf = (ident) => execFileSync("git", ["var", ident], { encoding: "utf8" }).match(/<([^<>]*)>/)?.[1];

// The full ref: `--short` prints `heads/main` when a tag is also named main.
const branchOfHead = () => {
  const quiet = { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] };
  try {
    execFileSync("git", ["rev-parse", "--verify", "--quiet", "HEAD"], quiet);
    return execFileSync("git", ["symbolic-ref", "--quiet", "HEAD"], quiet).trim();
  } catch {
    return null;
  }
};

/** The operations git is finishing: their commits are made by git, not new work on the branch. */
const finishing = (gitDir) => ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"].filter((name) => existsSync(join(gitDir, name)));

if (startedAs(import.meta)) {
  const gitDir = execFileSync("git", ["rev-parse", "--absolute-git-dir"], { encoding: "utf8" }).trim();
  const emails = [emailOf("GIT_AUTHOR_IDENT"), emailOf("GIT_COMMITTER_IDENT")];
  const pending = finishing(gitDir);
  const text = judge(readFileSync(process.argv[2], "utf8"), emails, pending.includes("MERGE_HEAD"), pending.length > 0 ? null : branchOfHead());
  process.stderr.write(text);
  process.exitCode = text ? 1 : 0;
}
