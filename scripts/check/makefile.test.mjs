import "./test-env.mjs";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { test } from "node:test";

const MAKEFILE = join(import.meta.dirname, "../../Makefile");

/** What make would run for `goals`. `-n` prints the recipe and runs none of it. */
const planned = (...goals) => spawnSync("make", ["-n", "-f", MAKEFILE, ...goals], { encoding: "utf8" });

test("a make with no goal is not the setup that configures git and installs the hooks (#515)", () => {
  const setup = planned("setup");
  const bare = planned();

  assert.match(setup.stdout, /git .*config blame\.ignoreRevsFile/);
  assert.match(setup.stdout, /lefthook install/);
  assert.equal(bare.status, 0);
  assert.doesNotMatch(bare.stdout, /\b(git|lefthook|cargo|swift|node)\b/);
});

test("a make with no goal names the goals", () => {
  const bare = planned();

  for (const goal of ["setup", "test", "fmt", "lint", "run"]) assert.match(bare.stdout, new RegExp(`\\b${goal}\\b`));
});
