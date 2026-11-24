import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import "./test-env.mjs";

import { git, scratchIn, write } from "./test-support.mjs";

const RELEASE = join(dirname(fileURLToPath(import.meta.url)), "..", "release.sh");
const scratch = scratchIn("release-test-");

/** A checkout whose `pre-push` hook prints to stdout, a bare remote standing in for GitHub, and a `gh` that answers `pr list` with `pr`. */
function fixture() {
  const root = scratch();
  const remote = join(root, "remote.git");
  const checkout = join(root, "checkout");
  git(root, "init", "-q", "--bare", remote);
  git(root, "init", "-q", checkout);
  git(checkout, "config", "user.email", "me@example.invalid");
  git(checkout, "config", "user.name", "Me");
  write(checkout, {
    "file.txt": "x\n",
    ".git/hooks/pre-push": "#!/bin/sh\necho 'hook: running make test'\n",
    "bin/gh": '#!/bin/sh\n[ "$1 $2" = "pr list" ] && echo 532\n',
  });
  chmodSync(join(checkout, ".git/hooks/pre-push"), 0o755);
  chmodSync(join(checkout, "bin/gh"), 0o755);
  git(checkout, "add", "file.txt");
  git(checkout, "commit", "-q", "-m", "x");
  git(checkout, "switch", "-q", "-c", "release-9.9.9");
  return { checkout, remote };
}

function pushPr(repo) {
  const { checkout, remote } = fixture();
  const env = {
    ...process.env,
    PATH: `${join(checkout, "bin")}:${process.env.PATH}`,
    GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: `url.${remote}.insteadOf`,
    GIT_CONFIG_VALUE_0: `https://github.com/${repo}`,
  };
  const run = spawnSync("bash", ["-c", 'source "$1"; BRANCH=release-9.9.9; push_pr "$2" "$3" title body', "bash", RELEASE, checkout, repo], { encoding: "utf8", env });
  return { code: run.status, out: run.stdout, err: run.stderr };
}

for (const repo of ["pingeplin/tarmac", "pingeplin/homebrew-tarmac"]) {
  test(`push_pr gives only the PR number of ${repo}, though a pre-push hook prints`, () => {
    const run = pushPr(repo);

    assert.equal(run.code, 0, run.err);
    assert.equal(run.out, "532\n");
    assert.ok(run.err.includes("hook: running make test"), "the hook's output stays visible");
  });
}
