import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

import "./test-env.mjs";

import { rowOf, scratchIn } from "./test-support.mjs";

import { TYPES, judge } from "./commit-msg.mjs";

const scratch = scratchIn("msg-test-");
const ME = "me@example.invalid";
const signed = (subject, email = ME) => `${subject}\n\nA body.\n\nSigned-off-by: Me <${email}>\n`;
const firstLine = (report) => report.split("\n")[0];

for (const subject of [
  "fix(board): close a doc card",
  "feat: editable docs",
  "release: 0.24.0",
  "feat!: drop a key",
  "fix(board)!: drop a key",
  "fixup! fix: y",
  "squash! fix: y",
  'Revert "fix: y"',
  ...TYPES.map((type) => `${type}: x`),
]) {
  test(`Commit message hook checks subject and sign-off: "${subject}" with a sign-off passes`, () => {
    assert.equal(judge(signed(subject), [ME]), "");
  });
}

for (const subject of ["fix the thing", "Fix(board): x", "fix(board) x", "fix: ", "fix(board):x", "ci: probe", "fix(): x", "fix(a b): x", "Revert x", "Merged it", "fixup!fix: y", ""]) {
  test(`Commit message hook checks subject and sign-off: "${subject}" is not a subject`, () => {
    const report = judge(signed(subject), [ME]);

    assert.equal(firstLine(report), "✗ commit-msg: the subject is not `type(scope): summary`");
    assert.ok(report.includes(`  why  types in use: ${TYPES.join(", ")}`));
    assert.ok(report.endsWith("  then git commit\n"));
  });
}

test("Commit message hook checks subject and sign-off: a merge needs no sign-off; every other message does, whatever its subject", () => {
  assert.equal(judge("Merge branch 'main' into x\n", [ME], true), "");
  assert.equal(firstLine(judge("Merge branch 'main' into x\n", [ME])), "✗ commit-msg: the message has no Signed-off-by line");
  assert.equal(firstLine(judge("fix: y\n\nA body.\n", [ME])), "✗ commit-msg: the message has no Signed-off-by line");
  assert.equal(firstLine(judge('Revert "fix: y"\n', [ME])), "✗ commit-msg: the message has no Signed-off-by line");
});

test("the sign-off must be the author's or the committer's, as CI requires", () => {
  const other = signed("fix: y", "someone@example.invalid");

  assert.equal(firstLine(judge(other, [ME])), "✗ commit-msg: the Signed-off-by line is not the author's or the committer's");
  assert.equal(judge(other, [ME, "someone@example.invalid"]), "");
  assert.equal(judge(`${signed("fix: y", "x@example.invalid")}Signed-off-by: Me <${ME}>\n`, [ME]), "");
});

test("the sign-off is read as CI reads it: any letter case of the key and of the email", () => {
  assert.equal(judge(`fix: y\n\nSigned-Off-By: Me <ME@Example.invalid>\n`, [ME]), "");
});

test("a sign-off counts only as a line of its own, from the first column", () => {
  assert.notEqual(judge(`fix: y\n\nsee Signed-off-by: Me <${ME}>\n`, [ME]), "");
  assert.notEqual(judge(`fix: y\n\n  Signed-off-by: Me <${ME}>\n`, [ME]), "");
});

test("Commit message hook skips comment lines: comment lines are not the message", () => {
  assert.equal(judge(`# Please enter the commit message\n\n${signed("fix: y")}`, [ME]), "");
  assert.equal(firstLine(judge("# only\n# comments\n", [ME])), "✗ commit-msg: the subject is not `type(scope): summary`");
  assert.equal(firstLine(judge(`fix: y\n\n# Signed-off-by: Me <${ME}>\n`, [ME])), "✗ commit-msg: the message has no Signed-off-by line");
});

test("the script reads the message file and the identity git would commit with", () => {
  const dir = scratch();
  execFileSync("git", ["init", "-q"], { cwd: dir });
  const env = { ...process.env, GIT_AUTHOR_NAME: "Me", GIT_AUTHOR_EMAIL: ME, GIT_COMMITTER_NAME: "Me", GIT_COMMITTER_EMAIL: ME };
  const run = (message) => {
    writeFileSync(join(dir, "MSG"), message);
    return spawnSync(process.execPath, [join(import.meta.dirname, "commit-msg.mjs"), join(dir, "MSG")], { cwd: dir, encoding: "utf8", env });
  };

  const good = run(signed("fix: y"));
  const bad = run("fix the thing\n");
  const unsigned = run("Merge branch 'main' into x\n");
  writeFileSync(join(dir, ".git/MERGE_HEAD"), "0000000000000000000000000000000000000000\n");
  const merge = run("Merge branch 'main' into x\n");

  assert.deepEqual([good.status, good.stderr], [0, ""]);
  assert.equal(bad.status, 1);
  assert.equal(bad.stderr.split("\n")[1], "  at   fix the thing");
  assert.equal(unsigned.status, 1);
  assert.deepEqual([merge.status, merge.stderr], [0, ""]);
});

test("Docs name the six hooks and no verify: the types in CLAUDE.md are the types the script accepts", () => {
  const doc = readFileSync(join(import.meta.dirname, "../../CLAUDE.md"), "utf8");
  const line = doc.split("\n").find((text) => text.includes("Commits: Conventional Commits"));
  const named = [...line.matchAll(/`([a-z]+):?`/g)].map(([, type]) => type).filter((type) => type !== "type");

  assert.deepEqual([...new Set(named)].sort(), [...TYPES].sort());
});

test("on main only a merge is made; a branch, a detached HEAD and a first commit take any", () => {
  const dir = scratch();
  const env = { ...process.env, GIT_AUTHOR_NAME: "Me", GIT_AUTHOR_EMAIL: ME, GIT_COMMITTER_NAME: "Me", GIT_COMMITTER_EMAIL: ME };
  const sh = (...args) => execFileSync("git", ["-c", "core.hooksPath=/dev/null", ...args], { cwd: dir, env, stdio: "pipe" });
  const run = (message) => {
    writeFileSync(join(dir, "MSG"), message);
    return spawnSync(process.execPath, [join(import.meta.dirname, "commit-msg.mjs"), join(dir, "MSG")], { cwd: dir, encoding: "utf8", env });
  };
  const commit = (file, text, subject) => {
    writeFileSync(join(dir, file), text);
    sh("add", file);
    sh("commit", "-q", "-m", subject);
  };
  sh("init", "-q", "-b", "main");

  const first = run(signed("fix: y"));
  commit("a", "base\n", "chore: base");
  const onMain = run(signed("fix: y"));
  const release = run(signed("release: 0.24.0 — inbox preview pane"));
  sh("switch", "-q", "-c", "fix/1-y");
  const onBranch = run(signed("fix: y"));
  commit("a", "branch\n", "fix: branch");
  sh("switch", "-q", "main");
  commit("a", "main\n", "fix: main");
  assert.throws(() => sh("merge", "fix/1-y"));
  const merge = run("Merge branch 'fix/1-y'\n");
  sh("merge", "--abort");
  assert.throws(() => sh("rebase", "fix/1-y"));
  const rebasing = run(signed("fix: main"));

  assert.deepEqual([first.status, first.stderr], [0, ""]);
  assert.equal(onMain.status, 1);
  assert.equal(onMain.stderr.split("\n")[0], "✗ commit-msg: a commit on main");
  assert.equal(rowOf(onMain.stderr, "fix"), "git switch -c type/N-slug (the staged changes go with you; no commit was made)");
  assert.equal(rowOf(onMain.stderr, "then"), "git commit");
  assert.equal(release.status, 1);
  assert.deepEqual([onBranch.status, onBranch.stderr], [0, ""]);
  assert.deepEqual([merge.status, merge.stderr], [0, ""]);
  assert.deepEqual([rebasing.status, rebasing.stderr], [0, ""]);
});

test("the subject rule of a commit on main runs before the main rule, and the sign-off after it", () => {
  assert.equal(firstLine(judge(signed("fix the thing"), [ME], false, "refs/heads/main")), "✗ commit-msg: the subject is not `type(scope): summary`");
  assert.equal(firstLine(judge("fix: y\n", [ME], false, "refs/heads/main")), "✗ commit-msg: a commit on main");
  assert.equal(firstLine(judge(signed("release: 1.0.0"), [ME], false, "refs/heads/main")), "✗ commit-msg: a commit on main");
  assert.equal(firstLine(judge("fix: y\n", [ME], false, "refs/heads/fix/1-y")), "✗ commit-msg: the message has no Signed-off-by line");
  assert.equal(judge(signed("fix: y"), [ME], false, "refs/heads/fix/1-y"), "");
});

test("as the installed hook: a tag named main does not hide the branch; a cherry-pick or a revert that git finishes on main passes", () => {
  const dir = scratch();
  const env = { ...process.env, GIT_AUTHOR_NAME: "Me", GIT_AUTHOR_EMAIL: ME, GIT_COMMITTER_NAME: "Me", GIT_COMMITTER_EMAIL: ME, GIT_EDITOR: "true", GIT_CONFIG_GLOBAL: "/dev/null" };
  const sh = (...args) => spawnSync("git", args, { cwd: dir, env, encoding: "utf8" });
  const commit = (text, subject) => {
    writeFileSync(join(dir, "a"), text);
    sh("add", "a");
    return sh("commit", "-q", "-s", "-m", subject);
  };
  sh("init", "-q", "-b", "main");
  writeFileSync(join(dir, ".git/hooks/commit-msg"), `#!/bin/sh\nexec "${process.execPath}" "${join(import.meta.dirname, "commit-msg.mjs")}" "$1"\n`, { mode: 0o755 });
  commit("base\n", "chore: base");
  sh("tag", "main", "HEAD");
  const behindTag = commit("tagged\n", "fix: y");
  sh("tag", "-d", "main");
  sh("switch", "-q", "-c", "fix/1-y");
  commit("branch\n", "fix: branch");
  sh("switch", "-q", "main");
  writeFileSync(join(dir, "a"), "main\n");
  sh("commit", "-q", "--no-verify", "-s", "-am", "fix: main");

  const pickConflict = sh("cherry-pick", "-s", "fix/1-y");
  writeFileSync(join(dir, "a"), "picked\n");
  sh("add", "a");
  const picked = sh("cherry-pick", "--continue");
  const revertConflict = sh("revert", "-s", "HEAD~1");
  writeFileSync(join(dir, "a"), "reverted\n");
  sh("add", "a");
  const reverted = sh("revert", "--continue");

  assert.equal(behindTag.status, 1);
  assert.ok(behindTag.stderr.includes("✗ commit-msg: a commit on main"));
  assert.notEqual(pickConflict.status, 0, "the cherry-pick stops on a conflict");
  assert.deepEqual([picked.status, picked.stderr], [0, ""]);
  assert.notEqual(revertConflict.status, 0, "the revert stops on a conflict");
  assert.deepEqual([reverted.status, reverted.stderr], [0, ""]);
});
