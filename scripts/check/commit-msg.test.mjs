import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

import "./test-env.mjs";

import { TYPES, judge } from "./commit-msg.mjs";

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
  test(`S12: "${subject}" with a sign-off passes`, () => {
    assert.equal(judge(signed(subject), [ME]), "");
  });
}

for (const subject of ["fix the thing", "Fix(board): x", "fix(board) x", "fix: ", "fix(board):x", "ci: probe", "fix(): x", "fix(a b): x", "Revert x", "Merged it", "fixup!fix: y", ""]) {
  test(`S12: "${subject}" is not a subject`, () => {
    const report = judge(signed(subject), [ME]);

    assert.equal(firstLine(report), "✗ commit-msg: the subject is not `type(scope): summary`");
    assert.ok(report.includes(`  why  types in use: ${TYPES.join(", ")}`));
    assert.ok(report.endsWith("  then git commit\n"));
  });
}

test("S12: a merge needs no sign-off; every other message does, whatever its subject", () => {
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

test("S27: comment lines are not the message", () => {
  assert.equal(judge(`# Please enter the commit message\n\n${signed("fix: y")}`, [ME]), "");
  assert.equal(firstLine(judge("# only\n# comments\n", [ME])), "✗ commit-msg: the subject is not `type(scope): summary`");
  assert.equal(firstLine(judge(`fix: y\n\n# Signed-off-by: Me <${ME}>\n`, [ME])), "✗ commit-msg: the message has no Signed-off-by line");
});

test("the script reads the message file and the identity git would commit with", () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "msg-test-")));
  after(() => rmSync(dir, { recursive: true, force: true }));
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

test("S20: the types in CLAUDE.md are the types the script accepts", () => {
  const doc = readFileSync(join(import.meta.dirname, "../../CLAUDE.md"), "utf8");
  const line = doc.split("\n").find((text) => text.includes("Commits: Conventional Commits"));
  const named = [...line.matchAll(/`([a-z]+):?`/g)].map(([, type]) => type).filter((type) => type !== "type");

  assert.deepEqual([...new Set(named)].sort(), [...TYPES].sort());
});
