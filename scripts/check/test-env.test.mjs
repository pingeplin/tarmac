import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

import { REPOSITORY_VARIABLES } from "./test-env.mjs";

const HERE = import.meta.dirname;
const dirs = [];
after(() => dirs.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

/** A repository that stands in for the one a hook runs in, and what a stray git command would change in it. */
function bystander() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "test-env-")));
  dirs.push(dir);
  const git = (...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "kept.txt"), "kept\n");
  git("add", "-A");
  git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "kept");
  const state = () => ({ refs: git("for-each-ref"), head: git("symbolic-ref", "HEAD"), status: git("status", "--porcelain"), config: readFileSync(join(dir, ".git/config"), "utf8") });
  // What git gives a pre-push hook in a linked worktree (#502).
  return { dir, state, hookEnv: { ...process.env, GIT_DIR: join(dir, ".git"), GIT_INDEX_FILE: join(dir, ".git/index"), GIT_PREFIX: "" } };
}

test("#502: a test file run under a hook's environment leaves the hook's repository as it was", () => {
  const { state, hookEnv } = bystander();
  const before = state();

  // With NODE_TEST_CONTEXT a nested `node --test` reports to its parent and runs nothing of its own.
  const { NODE_TEST_CONTEXT, ...env } = hookEnv;
  const run = spawnSync(process.execPath, ["--test", join(HERE, "arch.test.mjs")], { encoding: "utf8", env });

  assert.deepEqual(state(), before);
  assert.match(run.stdout, /^# pass [1-9]\d*$/m);
  assert.match(run.stdout, /^# fail 0$/m);
});

test("#502: every test file takes the repository variables out of its environment before it starts git", () => {
  const tests = execFileSync("git", ["ls-files", "--", "scripts/check/*.test.mjs"], { cwd: join(HERE, "../.."), encoding: "utf8" }).split("\n").filter(Boolean);

  const without = tests.filter((path) => !/^import (\{ REPOSITORY_VARIABLES \} from )?"\.\/test-env\.mjs";$/m.test(readFileSync(join(HERE, "../..", path), "utf8")));

  assert.deepEqual(without, []);
});

test("#502: make gives its recipes none of the repository variables", () => {
  const { dir, hookEnv } = bystander();
  writeFileSync(join(dir, "probe.mk"), "probe:\n\t@env\n");

  const run = spawnSync("make", ["-f", join(HERE, "../../Makefile"), "-f", join(dir, "probe.mk"), "probe"], { encoding: "utf8", env: { ...hookEnv, ...Object.fromEntries(REPOSITORY_VARIABLES.map((name) => [name, dir])) } });

  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(REPOSITORY_VARIABLES.filter((name) => new RegExp(`^${name}=`, "m").test(run.stdout)), []);
});
