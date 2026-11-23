import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

import "./test-env.mjs";

import { rowOf, runScript, scratchIn } from "./test-support.mjs";

import { judgePr } from "./pr.mjs";

const SCRIPT = join(import.meta.dirname, "pr.mjs");
const PR = { number: "7", title: "fix(board): close a doc card", body: "Closes #34", head: "fix/34-doc-card-close" };
const scratch = scratchIn("pr-test-");
const summaries = (report) => report.split("\n").filter((line) => line.startsWith("✗ "));

test("a pull request with a subject title, an issue line and a type/N-slug branch passes", () => {
  assert.equal(judgePr(PR), "");
});

for (const title of ["feat: editable docs", "feat!: drop a key", "chore(check): a title with (#12) inside it", "release: 0.24.0 — inbox preview pane, term new"]) {
  test(`the title "${title}" is a subject`, () => {
    assert.equal(judgePr({ ...PR, title }), "");
  });
}

for (const title of ["Fix the thing", "fix(board) x", "ci: probe", 'Revert "fix: y"', "Merge branch 'main' into x", "fixup! fix: y", ""]) {
  test(`the title "${title}" is not a subject, by the rule of the commit-msg hook`, () => {
    const report = judgePr({ ...PR, title });

    assert.deepEqual(summaries(report), ["✗ pr: the title is not `type(scope): summary`"]);
    assert.equal(rowOf(report, "fix"), "gh pr edit 7 --title 'type(scope): summary'");
  });
}

test("a title that ends in (#N) is refused: the squash merge appends GitHub's own", () => {
  const report = judgePr({ ...PR, title: "fix(board): close a doc card (#12)" });

  assert.deepEqual(summaries(report), ["✗ pr: the title ends in a (#N), and the squash merge appends another"]);
  assert.equal(rowOf(report, "fix"), "gh pr edit 7 --title 'fix(board): close a doc card'");
});

test("the fixed title is one shell word, whatever the title holds", () => {
  const report = judgePr({ ...PR, title: "fix: a \"b\" c's $(touch x) `id` (#12)" });

  assert.equal(rowOf(report, "fix"), "gh pr edit 7 --title 'fix: a \"b\" c'\\''s $(touch x) `id`'");
});

for (const body of [
  "Closes #34",
  "closes #34.",
  "Fixes #432.",
  "Refs #497, #498, #499",
  "The record of a run.\n\n- Filed: #497.\n\nRefs #486",
  ...["Close", "Closed", "Fix", "Fixed", "Resolve", "Resolves", "Resolved"].map((word) => `${word} #34`),
  "Closes: #34",
  "Refs: #34",
  "Text\r\n\r\nCloses #34\r\n",
  "<!-- a note -->\nCloses #34",
]) {
  test(`the body ${JSON.stringify(body)} names its issue`, () => {
    assert.equal(judgePr({ ...PR, body }), "");
  });
}

for (const body of [
  "",
  "Closes #",
  "Closes the issue",
  "See #34",
  "Closes owner/repo#34",
  "Closes https://github.com/pingeplin/tarmac/issues/34",
  "Closes#34",
  "Fixing #34",
  "prefix #34",
  "<!-- Closes #34 -->",
  "Text\n<!-- Closes #34",
  readFileSync(join(import.meta.dirname, "../../.github/pull_request_template.md"), "utf8"),
]) {
  test(`the body ${JSON.stringify(body)} names no issue`, () => {
    const report = judgePr({ ...PR, body });

    assert.deepEqual(summaries(report), ["✗ pr: the body has no `Closes #N` or `Refs #N`"]);
    assert.ok(rowOf(report, "fix").includes("Closes #34"), "the fix names the issue of the branch");
  });
}

for (const head of ["chore/496-pr-title", "refactor/428-inline-markdown-refactor", "fix/7-x"]) {
  test(`the branch "${head}" is type/N-slug`, () => {
    assert.equal(judgePr({ ...PR, head }), "");
  });
}

for (const head of ["chore/mutants-file-scope", "main", "feature/12-x", "fix/12", "fix/12-", "fix/12-Doc-card", "fix/12-doc_card", "fix/x-12-doc", "release-0.24.0", "revert-12-fix/34-doc-card-close"]) {
  test(`the branch "${head}" is not type/N-slug`, () => {
    const report = judgePr({ ...PR, head });

    assert.deepEqual(summaries(report), ["✗ pr: the branch is not `type/N-slug`"]);
    assert.equal(report.split("\n")[1], `  at   ${head}`);
  });
}

for (const [head, title, body] of [
  ["release-0.24.0", "release: 0.24.0 — inbox preview pane, term new", "- feat(inbox): the preview pane (#435)\n- fix(app): a fence (#430)"],
  ["release-1.14.0-beta", "release: 1.14.0-beta", "release: 1.14.0-beta"],
]) {
  test(`the release pull request of release.sh (${head}) needs no issue line and no type/N-slug branch`, () => {
    assert.equal(judgePr({ number: "437", title, body, head }), "");
  });
}

test("a release branch does not excuse a pull request whose title is not a release", () => {
  const report = judgePr({ number: "7", title: "feat: x", body: "", head: "release-0.24.0" });

  assert.deepEqual(summaries(report), ["✗ pr: the body has no `Closes #N` or `Refs #N`", "✗ pr: the branch is not `type/N-slug`"]);
});

test("a release branch with a release title that is not a subject is refused for its title only", () => {
  const report = judgePr({ number: "7", title: "release:0.24.0", body: "", head: "release-0.24.0" });

  assert.deepEqual(summaries(report), ["✗ pr: the title is not `type(scope): summary`"]);
});

test("a release title does not excuse a branch that is not a release branch", () => {
  const report = judgePr({ number: "7", title: "release: 0.24.0", body: "", head: "chore/12-bump" });

  assert.deepEqual(summaries(report), ["✗ pr: the body has no `Closes #N` or `Refs #N`"]);
});

test("every finding is reported, each with the next command", () => {
  const report = judgePr({ number: "7", title: "Fix it", body: "", head: "my-branch" });

  assert.equal(summaries(report).length, 3);
  assert.equal(report.split("\n").filter((line) => line === "  then gh pr checks 7 --watch").length, 3);
});

const eventFile = (pull_request) => {
  const path = join(scratch(), "event.json");
  writeFileSync(path, JSON.stringify({ action: "edited", pull_request }));
  return path;
};
const eventOf = ({ number, title, body, head }) => ({ number: Number(number), title, body, head: { ref: head } });
const run = (path) => {
  const { GITHUB_EVENT_PATH, ...env } = process.env;
  return runScript(SCRIPT, [], { env: path === undefined ? env : { ...env, GITHUB_EVENT_PATH: path } });
};

test("the script reads the pull request from the event file: 0 when it passes, 1 with the report", () => {
  const good = run(eventFile(eventOf(PR)));
  const bad = run(eventFile(eventOf({ ...PR, title: "Fix it" })));

  assert.deepEqual([good.code, good.err], [0, ""]);
  assert.equal(bad.code, 1);
  assert.equal(bad.err.split("\n")[0], "✗ pr: the title is not `type(scope): summary`");
  assert.equal(rowOf(bad.err, "then"), "gh pr checks 7 --watch");
});

test("a null body is an empty body: a finding, not a check that could not run", () => {
  const run1 = run(eventFile({ ...eventOf(PR), body: null }));

  assert.equal(run1.code, 1);
  assert.equal(run1.err.split("\n")[0], "✗ pr: the body has no `Closes #N` or `Refs #N`");
});

test("a body of 200 KiB, more than an environment variable holds, is read whole", () => {
  const body = `${"文".repeat(70 * 1024)}\r\n\r\nCloses #34\r\n`;

  assert.ok(Buffer.byteLength(body) > 200 * 1024);
  assert.deepEqual(run(eventFile(eventOf({ ...PR, body }))).code, 0);
});

test("with no event file named the check cannot run (2)", () => {
  const result = run(undefined);

  assert.equal(result.code, 2);
  assert.ok(result.err.includes("GITHUB_EVENT_PATH"));
});

for (const [name, write] of [
  ["a missing file", (path) => path],
  ["a file that is not JSON", (path) => (writeFileSync(path, "{"), path)],
  ["an event with no pull request", (path) => (writeFileSync(path, JSON.stringify({ action: "push" })), path)],
]) {
  test(`${name} as the event: the check cannot run (2), and names the file`, () => {
    const path = write(join(scratch(), "event.json"));
    const result = run(path);

    assert.equal(result.code, 2);
    assert.ok(result.err.includes(path));
  });
}
