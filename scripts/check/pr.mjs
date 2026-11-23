#!/usr/bin/env node
// The title, body and branch of a pull request, for CI (.github/workflows/pr.yml).
//
//   GITHUB_EVENT_PATH=<pull_request event JSON> node scripts/check/pr.mjs   exit 0, 1 with a report, 2 could not run
//
// The event file, not the environment: a body can outgrow an environment
// variable, and the text never passes through the workflow's shell.
//
// The squash merge makes the title the subject on main (for a pull request of
// one commit, GitHub proposes that commit's subject instead), so the title is
// held to the subject rule of the commit-msg hook, the one function both call.

import { readFileSync } from "node:fs";

import { TYPES, isSubject } from "./commit-msg.mjs";
import { blockedFor, failure, runCheck } from "./report.mjs";

const CHECK = { rule: "pr", then: "gh pr checks --watch" };

const SUFFIX = /\s*\(#\d+\)$/;
// GitHub's closing keywords, and Refs. An issue of another repository
// (owner/repo#N) or named by its URL does not count.
const ISSUE_LINE = /\b(close[sd]?|fix(e[sd])?|resolve[sd]?|refs):? #\d+/i;
// GitHub shows none of it, and the template's own note sits in one.
const COMMENT = /<!--[\s\S]*?(-->|$)/g;
const BRANCH = new RegExp(`^(${TYPES.join("|")})/\\d+-[a-z0-9]+(-[a-z0-9]+)*$`);
// The branch scripts/release.sh opens its pull request from.
const RELEASE_BRANCH = /^release-\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$/;

/** The release pull request of scripts/release.sh: it names no issue and has no type/N-slug branch. */
const isReleasePr = ({ title, head }) => RELEASE_BRANCH.test(head) && /^release[(!:]/.test(title);

/** One shell word, so that a fix row pasted into a shell runs nothing the title holds. */
const quoted = (text) => `'${text.replaceAll("'", "'\\''")}'`;

/** The report for a pull request that is refused, or "" for one that passes. */
export function judgePr({ number, title, body, head }) {
  const refuse = (summary, at, why, fix) => failure({ rule: CHECK.rule, summary, at, why, fix, then: `gh pr checks ${number} --watch` });
  const issue = head.match(/^[a-z]+\/(\d+)-/)?.[1] ?? "N";
  const release = isReleasePr({ title, head });
  const found = [];
  if (!isSubject(title)) {
    const why = ["the squash merge can make the title the subject on main, and the commit-msg hook holds a subject to this form", `types in use: ${TYPES.join(", ")}`];
    found.push(refuse("the title is not `type(scope): summary`", [title || "(no title)"], why, `gh pr edit ${number} --title ${quoted("type(scope): summary")}`));
  } else if (SUFFIX.test(title)) {
    const why = ["docs/workflow.md: the squash merge keeps the (#N) suffix GitHub appends; a title with its own ends with two on main"];
    found.push(refuse("the title ends in a (#N), and the squash merge appends another", [title], why, `gh pr edit ${number} --title ${quoted(title.replace(SUFFIX, ""))}`));
  }
  if (!release && !ISSUE_LINE.test(body.replace(COMMENT, ""))) {
    const why = ["docs/workflow.md: the body includes `Closes #N`, so the merge closes the issue; `Refs #N` names an issue that one pull request does not finish"];
    const fix = `add "Closes #${issue}" or "Refs #${issue}" on a line of the body: gh pr edit ${number} --body-file <the body with that line>`;
    found.push(refuse("the body has no `Closes #N` or `Refs #N`", [], why, fix));
  }
  if (!release && !BRANCH.test(head)) {
    const why = ["docs/workflow.md: one branch `type/N-slug` per issue — a type, the issue number, a short lower-case kebab slug", `types in use: ${TYPES.join(", ")}`];
    const fix = `git branch -m type/${issue}-slug && git push -u origin type/${issue}-slug, then open the pull request from it (gh pr create) and close this one`;
    found.push(refuse("the branch is not `type/N-slug`", [head], why, fix));
  }
  return found.join("");
}

const blocked = blockedFor(CHECK.rule, CHECK.then);

/** The fields of the pull request in a pull_request event file, or a reason it has none. */
function pullRequestIn(path) {
  let event;
  try {
    event = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    return { reason: String(error.message) };
  }
  const pr = event?.pull_request;
  if (typeof pr?.title !== "string" || typeof pr?.head?.ref !== "string") return { reason: "the event has no pull_request with a title and a head ref" };
  return { fields: { number: String(pr.number), title: pr.title, body: pr.body ?? "", head: pr.head.ref } };
}

await runCheck(import.meta, CHECK, () => {
  const path = process.env.GITHUB_EVENT_PATH;
  const fix = "run it on a pull_request event, as .github/workflows/pr.yml does";
  if (!path) return blocked("no event file: GITHUB_EVENT_PATH is not set", [], fix);
  const { fields, reason } = pullRequestIn(path);
  if (!fields) return blocked(`the event file ${path} cannot be read`, [reason], fix);
  const text = judgePr(fields);
  return { code: text ? 1 : 0, text };
});
