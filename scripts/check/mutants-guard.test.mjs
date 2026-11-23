import assert from "node:assert/strict";
import { test } from "node:test";

import "./test-env.mjs";

import { bareMutants } from "./mutants-guard.mjs";
import { refuses } from "./shell-commands.mjs";

const runsMutantsBare = (line) => refuses(bareMutants, line);

// The rule's contract is this list and its cases in hook.test.mjs; the head of
// mutants-guard.mjs lists what it does not read.

const BARE = [
  "cargo mutants",
  "cargo mutants --in-diff x.diff",
  "cargo mutants -f core/crates/tarmacd/src/main.rs",
  "cargo mutants --package tarmacd --jobs 4",
  "cargo mutants -- --list",
  "cargo-mutants",
  "cargo-mutants mutants",
  "cargo-mutants mutants --in-place",
  "~/.cargo/bin/cargo-mutants mutants",
  "cargo +stable mutants",
  "cargo +1.90.0 mutants --package tarmacd",
  "cargo --locked mutants",
  "cargo --color always mutants",
  "cargo --config build.jobs=2 mutants",
  "cargo -C core mutants",
  "cargo -Z unstable-options mutants",
  "/usr/local/bin/cargo mutants",
  "CARGO MUTANTS",
  "rustup run stable cargo mutants",
  "rustup run 1.90.0 cargo +x mutants",
  "rustup run --install stable cargo-mutants",
  "rustup run stable cargo-mutants mutants -f x.rs",
];

test("each way to run cargo-mutants is refused", () => {
  assert.deepEqual(BARE.filter((line) => !runsMutantsBare(line)), []);
});

test("cargo-mutants behind a wrapper, a shell, a pipeline, a chain or a subshell is refused", () => {
  const lines = [
    "sudo cargo mutants",
    "env HOME=/tmp cargo mutants",
    "env -i cargo mutants",
    "nohup cargo mutants &",
    "time cargo mutants",
    "timeout 600 cargo mutants",
    "nice -n 5 cargo-mutants",
    "exec cargo mutants",
    "sh -c 'cargo mutants'",
    'bash -lc "cd core && cargo mutants"',
    "zsh -c 'rustup run stable cargo mutants'",
    "cargo mutants | tee mutants.log",
    "cargo mutants 2>&1 | tail",
    "cd core && cargo mutants",
    "cargo build || cargo mutants",
    "ls; cargo mutants",
    "(cd core && cargo mutants)",
    "{ cargo mutants; }",
    "echo $(cargo mutants)",
    'echo "now `cargo mutants`"',
    "eval cargo mutants",
    "eval 'cargo mutants'",
    "if true; then cargo mutants; fi",
    "cat <<EOF\nx\nEOF\ncargo mutants",
    "make mutants && cargo mutants",
  ];

  assert.deepEqual(lines.filter((line) => !runsMutantsBare(line)), []);
});

test("a run that only lists or answers --help or --version passes", () => {
  const lines = [
    "cargo mutants --list",
    "cargo mutants --list --json",
    "cargo mutants --in-diff x.diff --list",
    "cargo mutants --list-files",
    "cargo mutants --help",
    "cargo mutants -h",
    "cargo mutants --version",
    "cargo mutants -V",
    "cargo-mutants --version",
    "cargo-mutants mutants --help",
    "cargo +stable mutants --list",
    "rustup run stable cargo mutants --list",
    "cargo mutants --list | head",
    "sudo cargo mutants --list",
    "sh -c 'cargo mutants --list'",
    "cd core && cargo mutants --list --in-diff d.diff",
  ];

  assert.deepEqual(lines.filter(runsMutantsBare), []);
});

test("the script, its make goal, the install and other cargo commands pass", () => {
  const lines = [
    "make mutants",
    "make mutants FILE=core/crates/tarmacd/src/main.rs",
    "make mutants ALL=1 SHARD=0/4",
    "make mutants BASE=origin/main JOBS=2",
    "node scripts/check/mutants.mjs --base origin/main",
    "node scripts/check/mutants.mjs --file core/crates/tarmac-cli/src/main.rs",
    "cargo install cargo-mutants --version 27.1.0 --locked",
    "cargo install --locked cargo-mutants",
    "cargo test",
    "cargo build --release",
    "cargo help mutants",
    "cargo --version",
    "rustup run stable cargo test",
    "rustup show",
  ];

  assert.deepEqual(lines.filter(runsMutantsBare), []);
});

// The body of a commit message or of a pull request, as an agent sends it.
const BODY = "Do not run `cargo mutants` bare;\ncargo mutants\n$(cargo mutants) and (cargo-mutants) \\\nrustup run stable cargo mutants";

test("text that only mentions cargo-mutants is not a run of it", () => {
  const lines = [
    `git commit -s -m "$(cat <<'EOF'\n${BODY}\nEOF\n)"`,
    `gh pr create --title x --body "$(cat <<'EOF'\n${BODY}\nEOF\n)"`,
    `cat > notes.md <<'EOF'\n${BODY}\nEOF`,
    'git commit -m "docs: never run cargo mutants bare"',
    'grep -rn "cargo mutants" CLAUDE.md',
    "rg 'cargo mutants|cargo-mutants' scripts/",
    "grep -n cargo-mutants Makefile",
    "echo cargo mutants",
    'echo "run cargo mutants --in-diff"',
    "ls ~/.cargo/bin/cargo-mutants",
    "which cargo-mutants",
    "command -v cargo-mutants",
    "ls # cargo mutants",
    "git log --grep='cargo mutants'",
    "node -e 'console.log(\"cargo mutants\")'",
  ];

  assert.deepEqual(lines.filter(runsMutantsBare), []);
});

test("text too deep to read is refused only when it holds cargo mutants and no --list", () => {
  const deep = (tail) => `${"eval ".repeat(25)}${tail}`;

  assert.deepEqual(["cargo mutants", "cargo-mutants", "CARGO MUTANTS -f x.rs"].filter((tail) => !runsMutantsBare(deep(tail))), []);
  assert.deepEqual(["cargo mutants --list", "ls", "cargo test", "make mutants"].filter((tail) => runsMutantsBare(deep(tail))), []);
  assert.equal(runsMutantsBare(`${"$(".repeat(6000)}cargo mutants`), true);
  assert.equal(runsMutantsBare(`${"$(".repeat(6000)}ls`), false);
});
