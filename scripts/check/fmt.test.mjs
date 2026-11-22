import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";

import { notFormatted } from "./fmt.mjs";

const SCRIPT = join(import.meta.dirname, "fmt.mjs");
const FORMATTED = "fn main() {}\n";
const UGLY = "pub fn y(){let a=1;let _=a;}\n";
const repos = [];
after(() => repos.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

function scratch() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "fmt-test-")));
  repos.push(dir);
  return dir;
}

/** A git repository in which every listed file is tracked. */
function repo(files = {}) {
  const dir = scratch();
  for (const [path, text] of Object.entries({ "core/src/main.rs": FORMATTED, ...files })) write(dir, path, text);
  git(dir, "init", "-q");
  git(dir, "add", "-A");
  return dir;
}

/** An environment whose PATH holds git and nothing else. */
function pathWithOnlyGit() {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));
  return { ...process.env, PATH: bin };
}

function write(dir, path, text) {
  mkdirSync(dirname(join(dir, path)), { recursive: true });
  writeFileSync(join(dir, path), text);
}

const git = (dir, ...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });

function fmt(dir, args, env = process.env) {
  const run = spawnSync(process.execPath, [SCRIPT, ...args], { cwd: dir, encoding: "utf8", env });
  return { code: run.status, err: run.stderr.split("\n") };
}

test("S1: a formatted tree passes and says nothing", () => {
  const run = fmt(repo(), ["--check", "rust"]);

  assert.deepEqual(run, { code: 0, err: [""] });
});

test("S2: one file the formatter would rewrite is named, with the command that fixes it", () => {
  const run = fmt(repo({ "core/src/ugly.rs": UGLY }), ["--check", "rust"]);

  assert.equal(run.code, 1);
  assert.deepEqual(run.err, [
    "✗ fmt: 1 file is not formatted",
    "  at   core/src/ugly.rs",
    "  fix  make fmt",
    "  then make fmt-check",
    "",
  ]);
});

test("S3: after a write, the check passes", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY });

  const before = fmt(dir, ["--check", "rust"]).code;

  fmt(dir, ["--write", "rust"]);

  assert.deepEqual([before, fmt(dir, ["--check", "rust"]).code], [1, 0]);
});

test("S21: a write succeeds silently and leaves other files alone", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY, "core/src/main.rs": "mod stray;\nfn main() {}\n", "notes.swift": "let  x=1\n" });
  write(dir, "core/src/stray.rs", UGLY);

  const mtime = () => statSync(join(dir, "core/src/main.rs")).mtimeMs;
  const before = mtime();

  const run = fmt(dir, ["--write", "rust"]);

  assert.deepEqual(run, { code: 0, err: [""] });
  assert.equal(mtime(), before, "a file that is already formatted is not written again");
  assert.notEqual(readFileSync(join(dir, "core/src/ugly.rs"), "utf8"), UGLY);
  assert.equal(readFileSync(join(dir, "core/src/stray.rs"), "utf8"), UGLY);
  assert.equal(readFileSync(join(dir, "notes.swift"), "utf8"), "let  x=1\n");
});

test("S10: an untracked file is not checked or rewritten, even when a tracked mod names it", () => {
  const dir = repo({ "core/src/main.rs": "mod stray;\nfn main() {}\n" });
  write(dir, "core/src/stray.rs", UGLY);
  write(dir, "core/src/loose.rs", UGLY);

  const check = fmt(dir, ["--check", "rust"]);
  fmt(dir, ["--write", "rust"]);

  assert.deepEqual(check, { code: 0, err: [""] });
  assert.deepEqual(["stray", "loose"].map((name) => readFileSync(join(dir, `core/src/${name}.rs`), "utf8")), [UGLY, UGLY]);
});

test("S19: a check changes no byte, no mtime and no git status line", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY });
  const snapshot = () => ({
    status: git(dir, "status", "--porcelain"),
    files: ["core/src/ugly.rs", "core/src/main.rs"].map((p) => [readFileSync(join(dir, p), "utf8"), statSync(join(dir, p)).mtimeMs]),
  });
  const before = snapshot();

  fmt(dir, ["--check", "rust"]);

  assert.deepEqual(snapshot(), before);
});

test("a tracked file is checked even when no mod line and no workspace reaches it", () => {
  const run = fmt(repo({ "tools/orphan.rs": UGLY }), ["--check", "rust"]);

  assert.equal(run.code, 1);
  assert.equal(run.err[1], "  at   tools/orphan.rs");
});

test("a file is named once, however many modules name it", () => {
  const shared = { "core/src/shared.rs": UGLY, "core/src/main.rs": "mod shared;\nfn main() {}\n", "core/tests/a.rs": '#[path = "../src/shared.rs"]\nmod shared;\n' };

  const run = fmt(repo(shared), ["--check", "rust"]);

  assert.deepEqual(run.err.slice(0, 2), ["✗ fmt: 1 file is not formatted", "  at   core/src/shared.rs"]);
});

test("the formatter reads the configuration nearest to the file", () => {
  const wide = "fn main() {\n    let v = [aaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccc, dddddddddddddddddddd, eeeeeeeeeeeeee];\n}\n";
  const config = 'max_width = 120\nuse_small_heuristics = "Max"\n';

  const configured = fmt(repo({ "core/rustfmt.toml": config, "core/src/main.rs": wide }), ["--check", "rust"]);
  const defaults = fmt(repo({ "core/src/main.rs": wide }), ["--check", "rust"]);

  assert.deepEqual([configured.code, defaults.code], [0, 1]);
});

test("Rust is read as edition 2024, the workspace's edition", () => {
  const asyncBlock = "fn main() {\n    let x = async { 1 };\n    drop(x);\n}\n";

  assert.deepEqual(fmt(repo({ "core/src/main.rs": asyncBlock }), ["--check", "rust"]), { code: 0, err: [""] });
});

test("outside a git repository the check cannot run", () => {
  const run = fmt(scratch(), ["--check", "rust"]);

  assert.equal(run.code, 2);
  assert.equal(run.err[0], "✗ fmt: not in a git repository");
});

test("S22: a repository with no file of the language passes and says nothing", () => {
  const dir = scratch();
  write(dir, "README.md", "x\n");
  git(dir, "init", "-q");
  git(dir, "add", "-A");

  assert.deepEqual(fmt(dir, ["--check", "rust"]), { code: 0, err: [""] });
});

test("S14: with no formatter on the PATH the check cannot run, and says so", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY });
  const bare = pathWithOnlyGit();

  const check = fmt(dir, ["--check", "rust"], bare);
  const written = fmt(dir, ["--write", "rust"], bare);

  assert.equal(check.code, 2);
  assert.equal(check.err[0], "✗ fmt: cannot run rustfmt");
  assert.deepEqual(check.err.map((line) => line.slice(0, 7)), ["✗ fmt: ", "  why  ", "  fix  ", "  then ", ""]);
  assert.equal(check.err[3], "  then make fmt-check");
  assert.equal(written.code, 2);
  assert.equal(readFileSync(join(dir, "core/src/ugly.rs"), "utf8"), UGLY);
});

test("S20: a file that does not parse is a check that cannot run, not an unformatted file", () => {
  const dir = repo({ "core/src/bad.rs": "fn x( {\n", "core/src/ugly.rs": UGLY });

  const check = fmt(dir, ["--check", "rust"]);
  const written = fmt(dir, ["--write", "rust"]);

  assert.equal(check.code, 2);
  assert.equal(check.err[0], "✗ fmt: cannot run rustfmt");
  assert.equal(check.err[1], "  why  core/src/bad.rs: error: this file contains an unclosed delimiter");
  assert.ok(!check.err.some((line) => line.startsWith("  at ")));
  assert.equal(written.code, 2);
  assert.equal(readFileSync(join(dir, "core/src/ugly.rs"), "utf8"), UGLY);
});

test("S15: a name that is not a language is refused with the names that are", () => {
  const run = fmt(repo(), ["--check", "cobol"]);

  assert.equal(run.code, 2);
  assert.equal(run.err[0], "✗ fmt: cobol is not a language this check knows");
  assert.ok(run.err.includes("  why  it knows: rust"));
  assert.ok(run.err.some((line) => line.startsWith("  fix  ")) && run.err.some((line) => line.startsWith("  then ")));
});

test("S12: three unformatted files are counted and listed in byte order", () => {
  const text = notFormatted(["core/b.rs", "core/a.rs", "app/Z.swift"]);

  assert.deepEqual(text.split("\n").slice(0, 4), [
    "✗ fmt: 3 files are not formatted",
    "  at   app/Z.swift",
    "       core/a.rs",
    "       core/b.rs",
  ]);
});
