import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";

const SCRIPT = join(import.meta.dirname, "lint.mjs");
const TOOLCHAIN = readFileSync(join(import.meta.dirname, "../../rust-toolchain.toml"), "utf8");
const MANIFEST = '[package]\nname = "probe"\nversion = "0.1.0"\nedition = "2024"\n\n[lints.clippy]\ntodo = "warn"\n';
const CLEAN = { code: 0, err: [""] };
const dirs = [];
after(() => dirs.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

function scratch() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "lint-test-")));
  dirs.push(dir);
  return dir;
}

/** A git repository with a one-crate workspace under `core/`. */
function repo(files) {
  const dir = scratch();
  const all = { "rust-toolchain.toml": TOOLCHAIN, "core/Cargo.toml": MANIFEST, ...files };
  for (const [path, text] of Object.entries(all)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  execFileSync("git", ["init", "-q"], { cwd: dir });
  return dir;
}

function lint(dir, env = process.env) {
  const run = spawnSync(process.execPath, [SCRIPT], { cwd: dir, encoding: "utf8", env });
  return { code: run.status, out: run.stdout, err: run.stderr.split("\n") };
}

/** The reporter block: the lines from the `✗` line on. */
const report = (run) => run.err.slice(run.err.findIndex((line) => line.startsWith("✗ ")));

test("S1: a workspace with no finding passes and says nothing", () => {
  const run = lint(repo({ "core/src/main.rs": "fn main() {}\n" }));

  assert.deepEqual({ code: run.code, err: run.err, out: run.out }, { ...CLEAN, out: "" });
});

test("S2: a finding is shown as clippy wrote it, then named with the next command", () => {
  const run = lint(repo({ "core/src/main.rs": "fn main() {\n    todo!()\n}\n" }));

  assert.equal(run.code, 1);
  assert.ok(run.err.includes("warning: `todo` should not be present in production code"), run.err.join("\n"));
  assert.deepEqual(report(run), [
    "✗ lint: 1 finding from clippy",
    "  at   core/src/main.rs:2:5 clippy::todo",
    "  fix  correct each one above; `cargo clippy --fix` applies the ones clippy marks as fixable",
    "  then make lint",
    "",
  ]);
});

test("S3: a place that two targets compile is listed once, and places are in byte order", () => {
  const shared = "pub fn late() {\n    todo!()\n}\n";
  const dir = repo({
    "core/src/lib.rs": "pub mod shared;\npub fn first() {\n    todo!()\n}\n",
    "core/src/shared.rs": shared,
    "core/tests/again.rs": '#[path = "../src/shared.rs"]\nmod shared;\n#[test]\nfn t() {\n    let _ = shared::late as fn();\n}\n',
  });

  const run = lint(dir);

  assert.deepEqual(report(run).slice(0, 3), [
    "✗ lint: 2 findings from clippy",
    "  at   core/src/lib.rs:3:5 clippy::todo",
    "       core/src/shared.rs:2:5 clippy::todo",
  ]);
});

test("S4: a workspace that does not compile is a check that cannot run", () => {
  const run = lint(repo({ "core/src/main.rs": "fn main() {\n    let _n: u8 = missing;\n    todo!()\n}\n" }));

  assert.equal(run.code, 2);
  assert.deepEqual(report(run), [
    "✗ lint: cannot run clippy",
    "  why  core/src/main.rs:2:18 error[E0425]: cannot find value `missing` in this scope",
    "  fix  make the workspace compile: cd core && cargo check --all-targets",
    "  then make lint",
    "",
  ]);
});

test("S5: with no cargo on the PATH the check cannot run, and says so", () => {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));

  const run = lint(repo({ "core/src/main.rs": "fn main() {}\n" }), { ...process.env, PATH: bin });

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run clippy", "  why  cargo is not on the PATH"]);
  assert.equal(report(run).at(-2), "  then make lint");
});

test("S9: a compiler warning that is not in the lint table is a finding too", () => {
  const run = lint(repo({ "core/src/main.rs": "fn main() {\n    let unused = 1;\n}\n" }));

  assert.equal(run.code, 1);
  assert.equal(report(run)[1], "  at   core/src/main.rs:2:9 unused_variables");
});

test("S10: an expectation that no finding fulfils is itself a finding", () => {
  const source = '#[expect(clippy::todo, reason = "a stub that is gone")]\nfn main() {}\n';

  const run = lint(repo({ "core/src/main.rs": source }));

  assert.equal(run.code, 1);
  assert.equal(report(run)[1], "  at   core/src/main.rs:1:10 unfulfilled_lint_expectations");
});

test("S18: a lint at deny is a finding, not a check that cannot run", () => {
  const run = lint(repo({ "core/src/main.rs": "#![deny(clippy::todo)]\nfn main() {\n    todo!()\n}\n" }));

  assert.equal(run.code, 1);
  assert.equal(report(run)[1], "  at   core/src/main.rs:3:5 clippy::todo");
});

test("S19: a manifest that cargo cannot read is a check that cannot run", () => {
  const run = lint(repo({ "core/Cargo.toml": "[package\n", "core/src/main.rs": "fn main() {}\n" }));

  assert.equal(run.code, 2);
  assert.equal(report(run)[0], "✗ lint: cannot run clippy");
  assert.ok(report(run)[1].startsWith("  why  error: "), report(run)[1]);
});

test("S21: outside a git repository the check cannot run", () => {
  const run = lint(scratch());

  assert.equal(run.code, 2);
  assert.equal(report(run)[0], "✗ lint: not in a git repository");
});
