import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";

import "./test-env.mjs";

import { git, runScript, scratchIn, tracked } from "./test-support.mjs";

import { notFormatted } from "./fmt.mjs";

const SCRIPT = join(import.meta.dirname, "fmt.mjs");
const FORMATTED = "fn main() {}\n";
const UGLY = "pub fn y(){let a=1;let _=a;}\n";
const UGLY_SWIFT = "let  x=1\n";
const REAL_SWIFT = execFileSync("which", ["swift"], { encoding: "utf8" }).trim();
const CLEAN = { code: 0, err: [""] };
// The fixtures are outside this checkout, so each one carries the pin: a test
// then runs the same rustfmt as a check of the real tree.
const TOOLCHAIN = readFileSync(join(import.meta.dirname, "../../rust-toolchain.toml"), "utf8");
const scratch = scratchIn("fmt-test-");

/** A git repository in which every listed file is tracked, beside one formatted `main.rs`. */
const repo = (files = {}) => tracked(scratch(), { "rust-toolchain.toml": TOOLCHAIN, "core/src/main.rs": FORMATTED, ...files });

/** An environment whose PATH holds git, the given stand-in programs, and nothing else. */
function pathWithOnlyGit(standIns = {}) {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));
  for (const [name, script] of Object.entries(standIns)) {
    writeFileSync(join(bin, name), `#!/bin/sh\n${script}\n`);
    chmodSync(join(bin, name), 0o755);
  }
  return { ...process.env, PATH: bin };
}

function write(dir, path, text) {
  mkdirSync(dirname(join(dir, path)), { recursive: true });
  writeFileSync(join(dir, path), text);
}

function fmt(dir, args, env = process.env) {
  const run = runScript(SCRIPT, args, { cwd: dir, env });
  return { code: run.code, err: run.err.split("\n") };
}

const runCheck = (dir, env) => fmt(dir, ["--check", "rust"], env);
const runWrite = (dir, env) => fmt(dir, ["--write", "rust"], env);

test("Formatted Rust tree passes the check: a formatted tree passes and says nothing", () => {
  const run = runCheck(repo());

  assert.deepEqual(run, CLEAN);
});

test("Unformatted Rust file fails with report: one file the formatter would rewrite is named, with the command that fixes it", () => {
  const run = runCheck(repo({ "core/src/ugly.rs": UGLY }));

  assert.equal(run.code, 1);
  assert.deepEqual(run.err, [
    "✗ fmt: 1 file is not formatted",
    "  at   core/src/ugly.rs",
    "  fix  make fmt",
    "  then make fmt-check",
    "",
  ]);
});

test("Fmt then check passes: after a write, the check passes", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY });

  const before = runCheck(dir).code;

  runWrite(dir);

  assert.deepEqual([before, runCheck(dir).code], [1, 0]);
});

test("Fmt rewrites only tracked files of its language: a write succeeds silently and leaves other files alone", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY, "core/src/main.rs": "mod stray;\nfn main() {}\n", "notes.swift": "let  x=1\n" });
  write(dir, "core/src/stray.rs", UGLY);

  const mtime = () => statSync(join(dir, "core/src/main.rs")).mtimeMs;
  const before = mtime();

  const run = runWrite(dir);

  assert.deepEqual(run, CLEAN);
  assert.equal(mtime(), before, "a file that is already formatted is not written again");
  assert.notEqual(readFileSync(join(dir, "core/src/ugly.rs"), "utf8"), UGLY);
  assert.equal(readFileSync(join(dir, "core/src/stray.rs"), "utf8"), UGLY);
  assert.equal(readFileSync(join(dir, "notes.swift"), "utf8"), "let  x=1\n");
});

test("Untracked unnamed Rust file is skipped: an untracked file is not checked or rewritten, even when a tracked mod names it", () => {
  const dir = repo({ "core/src/main.rs": "mod stray;\nfn main() {}\n" });
  write(dir, "core/src/stray.rs", UGLY);
  write(dir, "core/src/loose.rs", UGLY);

  const check = runCheck(dir);
  runWrite(dir);

  assert.deepEqual(check, CLEAN);
  assert.deepEqual(["stray", "loose"].map((name) => readFileSync(join(dir, `core/src/${name}.rs`), "utf8")), [UGLY, UGLY]);
});

test("Check leaves files and git status untouched: a check changes no byte, no mtime and no git status line", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY });
  const snapshot = () => ({
    status: git(dir, "status", "--porcelain"),
    files: ["core/src/ugly.rs", "core/src/main.rs"].map((p) => [readFileSync(join(dir, p), "utf8"), statSync(join(dir, p)).mtimeMs]),
  });
  const before = snapshot();

  runCheck(dir);

  assert.deepEqual(snapshot(), before);
});

test("a tracked file is checked even when no mod line and no workspace reaches it", () => {
  const run = runCheck(repo({ "tools/orphan.rs": UGLY }));

  assert.equal(run.code, 1);
  assert.equal(run.err[1], "  at   tools/orphan.rs");
});

test("a file is named once, however many modules name it", () => {
  const shared = { "core/src/shared.rs": UGLY, "core/src/main.rs": "mod shared;\nfn main() {}\n", "core/tests/a.rs": '#[path = "../src/shared.rs"]\nmod shared;\n' };

  const run = runCheck(repo(shared));

  assert.deepEqual(run.err.slice(0, 2), ["✗ fmt: 1 file is not formatted", "  at   core/src/shared.rs"]);
});

test("the formatter reads the configuration nearest to the file", () => {
  const wide = "fn main() {\n    let v = [aaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccc, dddddddddddddddddddd, eeeeeeeeeeeeee];\n}\n";
  const config = 'max_width = 120\nuse_small_heuristics = "Max"\n';

  const configured = runCheck(repo({ "core/rustfmt.toml": config, "core/src/main.rs": wide }));
  const defaults = runCheck(repo({ "core/src/main.rs": wide }));

  assert.deepEqual([configured.code, defaults.code], [0, 1]);
});

test("Rust is read as edition 2024, the workspace's edition", () => {
  const asyncBlock = "fn main() {\n    let x = async { 1 };\n    drop(x);\n}\n";

  assert.deepEqual(runCheck(repo({ "core/src/main.rs": asyncBlock })), CLEAN);
});

test("a tracked path that is no longer a file is not a failure", () => {
  const dir = repo({ "core/src/gone.rs": UGLY, "core/src/dir.rs": UGLY });
  rmSync(join(dir, "core/src/gone.rs"));
  rmSync(join(dir, "core/src/dir.rs"));
  mkdirSync(join(dir, "core/src/dir.rs"));

  assert.deepEqual([runCheck(dir), runWrite(dir)], [CLEAN, CLEAN]);
});

test("outside a git repository the check cannot run", () => {
  const run = runCheck(scratch());

  assert.equal(run.code, 2);
  assert.equal(run.err[0], "✗ fmt: not in a git repository");
});

test("Language with no tracked file passes: a repository with no file of the language passes and says nothing", () => {
  assert.deepEqual(runCheck(repo({ "core/src/main.rs": null, "README.md": "x\n" })), CLEAN);
});

test("Missing rustfmt exits 2 with next steps: with no formatter on the PATH the check cannot run, and says so", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY });
  const bare = pathWithOnlyGit();

  const check = runCheck(dir, bare);
  const written = runWrite(dir, bare);

  assert.equal(check.code, 2);
  assert.equal(check.err[0], "✗ fmt: cannot run rustfmt");
  assert.deepEqual(check.err.map((line) => line.slice(0, 7)), ["✗ fmt: ", "  why  ", "  fix  ", "  then ", ""]);
  assert.equal(check.err[3], "  then make fmt-check");
  assert.equal(written.code, 2);
  assert.equal(readFileSync(join(dir, "core/src/ugly.rs"), "utf8"), UGLY);
});

test("Unparseable Rust file exits 2 not 1: a file that does not parse is a check that cannot run, not an unformatted file", () => {
  const dir = repo({ "core/src/bad.rs": "fn x( {\n", "core/src/ugly.rs": UGLY });

  const check = runCheck(dir);
  const written = runWrite(dir);

  assert.equal(check.code, 2);
  assert.equal(check.err[0], "✗ fmt: cannot run rustfmt");
  assert.equal(check.err[1], "  why  core/src/bad.rs: error: this file contains an unclosed delimiter");
  assert.equal(check.err[2], "  fix  see the whole error with: rustfmt --edition 2024 --check core/src/bad.rs");
  assert.ok(!check.err.some((line) => line.startsWith("  at ")));
  assert.equal(written.code, 2);
  assert.equal(readFileSync(join(dir, "core/src/ugly.rs"), "utf8"), UGLY);
});

test("Unknown language name exits 2: a name that is not a language is refused with the names that are", () => {
  const run = fmt(repo(), ["--check", "cobol"]);

  assert.equal(run.code, 2);
  assert.equal(run.err[0], "✗ fmt: cobol is not a language this check knows");
  assert.ok(run.err.includes("  why  it knows: rust, swift"));
  assert.ok(run.err.some((line) => line.startsWith("  fix  ")) && run.err.some((line) => line.startsWith("  then ")));
});

test("Report counts files and sorts paths: three unformatted files are counted and listed in byte order", () => {
  const text = notFormatted(["core/b.rs", "core/a.rs", "app/Z.swift"]);

  assert.deepEqual(text.split("\n").slice(0, 4), [
    "✗ fmt: 3 files are not formatted",
    "  at   app/Z.swift",
    "       core/a.rs",
    "       core/b.rs",
  ]);
});

test("Swift follows the Rust format scenarios: a formatted Swift tree passes; an unformatted file is named; a write fixes it", () => {
  const dir = repo({ "app/Sources/A.swift": UGLY_SWIFT, "app/Sources/B.swift": "let x = 1\n" });

  const before = fmt(dir, ["--check", "swift"]);
  const written = fmt(dir, ["--write", "swift"]);

  assert.equal(before.code, 1);
  assert.deepEqual(before.err.slice(0, 2), ["✗ fmt: 1 file is not formatted", "  at   app/Sources/A.swift"]);
  assert.deepEqual([written, fmt(dir, ["--check", "swift"])], [CLEAN, CLEAN]);
  assert.equal(readFileSync(join(dir, "app/Sources/A.swift"), "utf8"), "let x = 1\n");
});

test("Swift follows the Rust format scenarios: with no swift on the PATH the Swift check cannot run, and says so", () => {
  const run = fmt(repo({ "app/Sources/A.swift": UGLY_SWIFT }), ["--check", "swift"], pathWithOnlyGit());

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.slice(0, 2), ["✗ fmt: cannot run swift-format", "  why  swift is not on the PATH"]);
  assert.ok(!run.err.some((line) => line.startsWith("  at ")));
});

test("Swift check covers package and QA scripts: every tracked Swift file is in scope wherever it is, and an untracked one never is", () => {
  const dir = repo({ "app/Package.swift": UGLY_SWIFT, "scripts/qa/probe.swift": UGLY_SWIFT });
  write(dir, "app/Vendor/Lib.swift", UGLY_SWIFT);

  const run = fmt(dir, ["--check", "swift"]);

  assert.deepEqual(run.err.slice(0, 3), ["✗ fmt: 2 files are not formatted", "  at   app/Package.swift", "       scripts/qa/probe.swift"]);
});

test("the Swift formatter reads the configuration nearest to the file", () => {
  const fourSpaces = "func f() {\n    g()\n}\n";

  const configured = fmt(repo({ ".swift-format": '{"version": 1, "indentation": {"spaces": 4}}\n', "app/A.swift": fourSpaces }), ["--check", "swift"]);
  const defaults = fmt(repo({ "app/A.swift": fourSpaces }), ["--check", "swift"]);

  assert.deepEqual([configured.code, defaults.code], [0, 1]);
});

test("Both languages unformatted give one report: with no language named, the files of both languages are in one list", () => {
  const run = fmt(repo({ "core/src/ugly.rs": UGLY, "app/A.swift": UGLY_SWIFT }), ["--check"]);

  assert.equal(run.code, 1);
  assert.deepEqual(run.err.slice(0, 3), ["✗ fmt: 2 files are not formatted", "  at   app/A.swift", "       core/src/ugly.rs"]);
});

test("when one language cannot run, the other still reports, and the exit code says cannot run", () => {
  const dir = repo({ "core/src/ugly.rs": UGLY, "app/A.swift": "let x = (\n" });

  const run = fmt(dir, ["--check"]);

  assert.equal(run.code, 2);
  assert.ok(run.err.includes("✗ fmt: cannot run swift-format"));
  assert.ok(run.err.includes("  fix  see the whole error with: swift format lint app/A.swift"));
  assert.ok(run.err.includes("✗ fmt: 1 file is not formatted") && run.err.includes("  at   core/src/ugly.rs"));
});

/** A `swift` that reports the given version and is the real one for everything else. */
const swiftReporting = (version) => pathWithOnlyGit({ swift: `[ "$2" = "--version" ] && { ${version}; exit; }\nexec ${REAL_SWIFT} "$@"` });

test("a swift-format of another minor version cannot run a check or a write, and both versions are named", () => {
  const dir = repo({ "app/A.swift": UGLY_SWIFT });
  const old = swiftReporting("echo 5.9.2");

  const runs = [fmt(dir, ["--check", "swift"], old), fmt(dir, ["--write", "swift"], old)];

  for (const run of runs) {
    assert.equal(run.code, 2);
    assert.deepEqual(run.err.slice(0, 2), ["✗ fmt: cannot run swift-format", "  why  swift-format 5.9.2 is on the PATH; this tree is formatted with 6.3 or 6.4"]);
    assert.ok(!run.err.some((line) => line.startsWith("  at ")));
  }
  assert.equal(readFileSync(join(dir, "app/A.swift"), "utf8"), UGLY_SWIFT);
});

for (const [reported, code] of [["echo 6.4", 1], ["echo 6.4.9", 1], ["echo 6.3.0", 1], ["echo 6.40.1", 2], ["echo 6.2.9", 2], ["echo 6.4.4; echo extra", 1], ["echo 5.9.2; echo extra", 2], ["exit 3", 2]]) {
  test(`a swift-format that answers --version with "${reported}" gives exit ${code}`, () => {
    const run = fmt(repo({ "app/A.swift": UGLY_SWIFT }), ["--check", "swift"], swiftReporting(reported));

    assert.equal(run.code, code);
    assert.ok(run.err.every((line) => /^(✗ fmt: |  (at|why|fix|then| {2,4}) |$)/.test(line)), run.err.join("\n"));
  });
}

test("a Swift file that does not parse is named with the formatter's own error", () => {
  const run = fmt(repo({ "app/A.swift": "let x = (\n" }), ["--check", "swift"]);

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.slice(0, 3), [
    "✗ fmt: cannot run swift-format",
    "  why  app/A.swift: error: expected value and ')' to end tuple",
    "  fix  see the whole error with: swift format lint app/A.swift",
  ]);
});

test("a #! that is not the first two bytes does not exempt a Swift file", () => {
  const run = fmt(repo({ "app/A.swift": "// see #!/bin/sh\nlet  x=1\n" }), ["--check", "swift"]);

  assert.equal(run.code, 1);
});

test("Check leaves files and git status untouched: a Swift check changes no byte, no mtime and no git status line", () => {
  const dir = repo({ "app/A.swift": UGLY_SWIFT });
  const snapshot = () => [git(dir, "status", "--porcelain"), readFileSync(join(dir, "app/A.swift"), "utf8"), statSync(join(dir, "app/A.swift")).mtimeMs];
  const before = snapshot();

  fmt(dir, ["--check", "swift"]);

  assert.deepEqual(snapshot(), before);
});

test("a Swift script with a #! line is left alone: swift-format 6.4 corrupts its header", () => {
  const script = "#!/usr/bin/env swift\n// What the script does,\n// on two lines.\nlet  x=1\n";
  const dir = repo({ "tools/run.swift": script });

  const runs = [fmt(dir, ["--check", "swift"]), fmt(dir, ["--write", "swift"])];

  assert.deepEqual(runs, [CLEAN, CLEAN]);
  assert.equal(readFileSync(join(dir, "tools/run.swift"), "utf8"), script);
});

// ------------------------------------------------------------ named files

const named = (dir, mode, paths, cwd = dir) => {
  const run = runScript(SCRIPT, [mode, "--paths", ...paths], { cwd });
  return { code: run.code, err: run.err.split("\n") };
};

test("named files: a new, untracked file is formatted, and no other file is touched", () => {
  const dir = repo({ "core/src/tracked.rs": UGLY });
  write(dir, "core/src/fresh.rs", UGLY);
  write(dir, "app/Fresh.swift", UGLY_SWIFT);

  const run = named(dir, "--write", ["core/src/fresh.rs", "app/Fresh.swift"]);

  assert.deepEqual(run, CLEAN);
  assert.notEqual(readFileSync(join(dir, "core/src/fresh.rs"), "utf8"), UGLY);
  assert.equal(readFileSync(join(dir, "app/Fresh.swift"), "utf8"), "let x = 1\n");
  assert.equal(readFileSync(join(dir, "core/src/tracked.rs"), "utf8"), UGLY);
});

test("named files: a check reports the named files only", () => {
  const dir = repo({ "core/src/a.rs": UGLY, "core/src/b.rs": UGLY });

  const run = named(dir, "--check", ["core/src/b.rs"]);

  assert.equal(run.code, 1);
  assert.deepEqual(run.err.slice(0, 2), ["✗ fmt: 1 file is not formatted", "  at   core/src/b.rs"]);
});

test("named files: the repository is found from the file, not from where the script runs", () => {
  const dir = repo();
  write(dir, "core/src/fresh.rs", UGLY);
  const elsewhere = scratch();

  const run = named(dir, "--write", [join(dir, "core/src/fresh.rs")], elsewhere);

  assert.deepEqual(run, CLEAN);
  assert.notEqual(readFileSync(join(dir, "core/src/fresh.rs"), "utf8"), UGLY);
});

test("named files: an ignored file, a file outside any repository, a missing one and one of no language are left alone", () => {
  const dir = repo({ ".gitignore": "target/\n", "notes.md": "#  x\n" });
  write(dir, "target/gen.rs", UGLY);
  const outside = scratch();
  write(outside, "loose.rs", UGLY);

  const run = named(dir, "--write", ["target/gen.rs", join(outside, "loose.rs"), "core/src/gone.rs", "notes.md"]);

  assert.deepEqual(run, CLEAN);
  assert.equal(readFileSync(join(dir, "target/gen.rs"), "utf8"), UGLY);
  assert.equal(readFileSync(join(outside, "loose.rs"), "utf8"), UGLY);
});

test("named files: a Swift script with a #! line is left alone here too", () => {
  const script = "#!/usr/bin/env swift\nlet  x=1\n";
  const dir = repo();
  write(dir, "tools/run.swift", script);

  assert.deepEqual(named(dir, "--write", ["tools/run.swift"]), CLEAN);
  assert.equal(readFileSync(join(dir, "tools/run.swift"), "utf8"), script);
});

test("named files: a file that does not parse cannot be formatted, and is named", () => {
  const dir = repo();
  write(dir, "core/src/bad.rs", "fn x( {\n");

  const run = named(dir, "--write", ["core/src/bad.rs"]);

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.slice(0, 2), ["✗ fmt: cannot run rustfmt", "  why  core/src/bad.rs: error: this file contains an unclosed delimiter"]);
});

test("a check that throws could not run: exit 2 and the reporter's form, never unformatted", () => {
  const dir = repo({ "core/src/locked.rs": FORMATTED });
  chmodSync(join(dir, "core/src/locked.rs"), 0o000);

  const run = runCheck(dir);
  chmodSync(join(dir, "core/src/locked.rs"), 0o644);

  assert.equal(run.code, 2);
  assert.equal(run.err[0], "✗ fmt: the check itself failed");
  assert.match(run.err[1], /^ {2}why {2}\S/);
  assert.deepEqual(run.err.slice(-3), ["  fix  make fmt-check", "  then make fmt-check", ""]);
});
