import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";

import { unmatched } from "./lint.mjs";

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
    if (text === null) continue;
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  execFileSync("git", ["init", "-q"], { cwd: dir });
  execFileSync("git", ["add", "-A"], { cwd: dir });
  return dir;
}

function lint(dir, env = process.env, only = "rust") {
  const run = spawnSync(process.execPath, [SCRIPT, ...(only ? [only] : [])], { cwd: dir, encoding: "utf8", env });
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

  assert.equal(run.code, 1);
  assert.deepEqual(report(run).slice(0, 3), [
    "✗ lint: 2 findings from clippy",
    "  at   core/src/lib.rs:3:5 clippy::todo",
    "       core/src/shared.rs:2:5 clippy::todo",
  ]);
});

test("two lints at one place are two findings", () => {
  const manifest = `${MANIFEST}cast_possible_truncation = "warn"\ncast_sign_loss = "warn"\n`;
  const source = "fn main() {\n    let wide: i64 = std::env::args().count() as i64;\n    let _narrow = wide as u8;\n}\n";

  const run = lint(repo({ "core/Cargo.toml": manifest, "core/src/main.rs": source }));

  assert.deepEqual(report(run).slice(0, 3), [
    "✗ lint: 2 findings from clippy",
    "  at   core/src/main.rs:3:19 clippy::cast_possible_truncation",
    "       core/src/main.rs:3:19 clippy::cast_sign_loss",
  ]);
});

test("a finding inside a macro is placed where the macro is called", () => {
  const manifest = `${MANIFEST}dbg_macro = "warn"\n`;

  const run = lint(repo({ "core/Cargo.toml": manifest, "core/src/main.rs": "fn main() {\n    dbg!(todo!())\n}\n" }));

  assert.ok(report(run).slice(1, -3).every((line) => /^ {2}(at| {2}) {3}core\/src\/main\.rs:2:/.test(line)), report(run).join("\n"));
});

test("S4: a workspace that does not compile is a check that cannot run, with each error named", () => {
  const source = "fn main() {\n    let _n: u8 = missing;\n    let _m: u8 = absent;\n    todo!()\n}\n";

  const run = lint(repo({ "core/src/main.rs": source }));

  assert.equal(run.code, 2);
  assert.ok(run.err.includes("error[E0425]: cannot find value `missing` in this scope"), "the compiler's own text is shown");
  assert.deepEqual(report(run), [
    "✗ lint: cannot run clippy",
    "  why  core/src/main.rs:2:18 error[E0425]: cannot find value `missing` in this scope",
    "       core/src/main.rs:3:18 error[E0425]: cannot find value `absent` in this scope",
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
  assert.deepEqual(report(run), [
    "✗ lint: cannot run clippy",
    "  why  cargo is not on the PATH",
    "  fix  install Rust from https://rustup.rs",
    "  then make lint",
    "",
  ]);
});

test("S20: a cargo with no clippy cannot run the check, and the fix installs clippy", () => {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));
  writeFileSync(join(bin, "cargo"), "#!/bin/sh\necho 'error: no such command: `clippy`' >&2\necho 'help: a line that is not an error' >&2\nexit 101\n", { mode: 0o755 });

  const run = lint(repo({ "core/src/main.rs": "fn main() {}\n" }), { ...process.env, PATH: bin });

  assert.equal(run.code, 2);
  assert.deepEqual(report(run), [
    "✗ lint: cannot run clippy",
    "  why  error: no such command: `clippy`",
    "  fix  rustup component add clippy",
    "  then make lint",
    "",
  ]);
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
  assert.equal(report(run).at(-3), "  fix  correct the error above");
});

test("S21: outside a git repository the check cannot run", () => {
  const run = lint(scratch());

  assert.equal(run.code, 2);
  assert.equal(report(run)[0], "✗ lint: not in a git repository");
});

test("the script still runs when it is started through a symlinked path", () => {
  const link = join(scratch(), "check");
  symlinkSync(import.meta.dirname, link);
  const dir = repo({ "core/src/main.rs": "fn main() {\n    todo!()\n}\n" });

  const run = spawnSync(process.execPath, [join(link, "lint.mjs")], { cwd: dir, encoding: "utf8" });

  assert.equal(run.status, 1);
});

// ---------------------------------------------------------------- Swift

const SWIFT_RULES = '{"version": 1, "indentation": {"spaces": 4}, "rules": {"NeverForceUnwrap": true}}\n';
const UNWRAP = "func f(_ x: Int?) -> Int {\n    let y = x!\n    return y\n}\n";
const FIX = "  fix  correct each one above; `make fmt` clears a layout finding; to keep one, put the reason in a comment and `// swift-format-ignore: <Rule>` on the next line";

/** A git repository with a Swift configuration, every listed file tracked. */
function swiftRepo(files) {
  return repo({ ".swift-format": SWIFT_RULES, "core/Cargo.toml": null, ...files });
}

const lintSwift = (dir, env) => lint(dir, env, "swift");

test("Swift S1: tracked files with no finding pass and say nothing", () => {
  const run = lintSwift(swiftRepo({ "app/A.swift": "let x = 1\n" }));

  assert.deepEqual({ code: run.code, err: run.err, out: run.out }, { ...CLEAN, out: "" });
});

test("Swift S2: a finding is shown as the tool wrote it, then named with the next command", () => {
  const run = lintSwift(swiftRepo({ "app/A.swift": UNWRAP }));

  assert.equal(run.code, 1);
  assert.ok(run.err.some((line) => line.endsWith("warning: [NeverForceUnwrap] do not force unwrap 'x'")), run.err.join("\n"));
  assert.deepEqual(report(run), ["✗ lint: 1 finding from swift-format", "  at   app/A.swift:2:13 NeverForceUnwrap", FIX, "  then make lint", ""]);
});

test("Swift S3: a directive with a reason on the line before it keeps the finding", () => {
  const kept = "func f(_ x: Int?) -> Int {\n    // The caller checked it.\n    // swift-format-ignore: NeverForceUnwrap\n    let y = x!\n    return y\n}\n";

  assert.deepEqual(lintSwift(swiftRepo({ "app/A.swift": kept })).code, 0);
});

const directive = (lines) => `func f(_ x: Int?) -> Int {\n${lines}\n    let y = x!\n    return y\n}\n`;
for (const [name, source, at] of [
  ["ignore-without-rule", directive("    // Why.\n    // swift-format-ignore"), "3:5"],
  ["ignore-file", "// Why.\n// swift-format-ignore-file\nlet x = 1\n", "2:1"],
  ["ignore-file", "// Why.\n// swift-format-ignore-file: NeverForceUnwrap\nlet x = 1\n", "2:1"],
  ["ignore-unknown-rule", "func f() {\n    // Why.\n    // swift-format-ignore: NoSuchRule\n    let y = 1\n    _ = y\n}\n", "3:5"],
  ["ignore-unknown-rule", directive("    // Why.\n    // swift-format-ignore: NeverForceUnwrap, NoSuchRule"), "3:5"],
  ["ignore-without-reason", directive("    // swift-format-ignore: NeverForceUnwrap"), "2:5"],
  ["ignore-without-reason", directive("    //\n    // swift-format-ignore: NeverForceUnwrap"), "3:5"],
]) {
  test(`Swift S4: ${name} at ${at} is the one finding`, () => {
    const run = lintSwift(swiftRepo({ "app/A.swift": source }));

    assert.equal(run.code, 1);
    assert.deepEqual(report(run).slice(0, 2), ["✗ lint: 1 finding from swift-format", `  at   app/A.swift:${at} ${name}`]);
  });
}

test("Swift S4: a directive whose previous line is another directive has no reason", () => {
  const two = "func f(_ x: Int?) -> Int {\n    // Why.\n    // swift-format-ignore: NeverForceUnwrap\n    // swift-format-ignore: NeverForceUnwrap\n    let y = x!\n    return y\n}\n";

  const run = lintSwift(swiftRepo({ "app/A.swift": two }));

  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: 1 finding from swift-format", "  at   app/A.swift:4:5 ignore-without-reason"]);
});

test("Swift S5: an untracked file and a #! script are not linted", () => {
  const dir = swiftRepo({ "tools/run.swift": `#!/usr/bin/env swift\n// swift-format-ignore\n${UNWRAP}` });
  writeFileSync(join(dir, "Stray.swift"), `// swift-format-ignore\n${UNWRAP}`);

  assert.equal(lintSwift(dir).code, 0);
});

test("Swift S6: with no language named, each language writes its own block, clippy's first", () => {
  const dir = swiftRepo({ "core/Cargo.toml": MANIFEST, "core/src/main.rs": "fn main() {\n    todo!()\n}\n", "app/A.swift": UNWRAP });

  const run = lint(dir, process.env, null);

  assert.equal(run.code, 1);
  assert.deepEqual(run.err.filter((line) => line.startsWith("✗ ")), ["✗ lint: 1 finding from clippy", "✗ lint: 1 finding from swift-format"]);
});

test("Swift S7: a layout finding is a finding, named as the tool names it", () => {
  const run = lintSwift(swiftRepo({ "app/A.swift": "let  x = 1\n" }));

  assert.equal(run.code, 1);
  assert.deepEqual(report(run).slice(0, 3), ["✗ lint: 1 finding from swift-format", "  at   app/A.swift:1:4 Spacing", FIX]);
});

/** A PATH with git and a `swift` that answers `--version` as told and is the real one otherwise. */
function swiftReporting(answer) {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));
  const real = execFileSync("which", ["swift"], { encoding: "utf8" }).trim();
  writeFileSync(join(bin, "swift"), `#!/bin/sh\n[ "$2" = "--version" ] && { ${answer}; exit; }\nexec ${real} "$@"\n`, { mode: 0o755 });
  return { ...process.env, PATH: bin };
}

test("Swift S8: another minor version of swift-format cannot run the check", () => {
  const run = lintSwift(swiftRepo({ "app/A.swift": UNWRAP }), swiftReporting("echo 5.9.2"));

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  swift-format 5.9.2 is on the PATH; this tree is formatted with 6.3 or 6.4"]);
});

test("Swift S8: with no swift on the PATH the check cannot run", () => {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));

  const run = lintSwift(swiftRepo({ "app/A.swift": UNWRAP }), { ...process.env, PATH: bin });

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  swift is not on the PATH"]);
});

test("Swift S9: a rule the running swift-format does not have cannot be silently off", () => {
  const config = '{"version": 1, "rules": {"NeverForceUnwrap": true, "ARuleOfTheFuture": true}}\n';

  const run = lintSwift(swiftRepo({ ".swift-format": config, "app/A.swift": "let x = 1\n" }));

  assert.equal(run.code, 2);
  assert.equal(report(run)[0], "✗ lint: cannot run swift-format");
  assert.match(report(run)[1], /^ {2}why {2}ARuleOfTheFuture is not a rule of swift-format \d+\.\d+/);
});

test("S9: a name that is not a language is refused with the names that are", () => {
  const run = lint(swiftRepo({ "app/A.swift": "let x = 1\n" }), process.env, "cobol");

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cobol is not a language this check knows", "  why  it knows: rust, swift, swiftc"]);
});

test("Swift S17: a file that does not parse cannot be linted, and is named", () => {
  const run = lintSwift(swiftRepo({ "app/A.swift": "let x = (\n" }));

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  app/A.swift:1:10 error: expected value and ')' to end tuple"]);
});

test("Swift S18: a Rust finding and a swift-format that cannot run: both blocks, and the exit code says cannot run", () => {
  const dir = swiftRepo({ "core/Cargo.toml": MANIFEST, "core/src/main.rs": "fn main() {\n    todo!()\n}\n", "app/A.swift": UNWRAP });
  const old = swiftReporting("echo 5.9.2");

  const run = lint(dir, { ...old, PATH: `${old.PATH}:${process.env.PATH}` }, null);

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.filter((line) => line.startsWith("✗ ")), ["✗ lint: 1 finding from clippy", "✗ lint: cannot run swift-format"]);
});

test("Swift S19: naming one language runs only that one", () => {
  const dir = swiftRepo({ "core/Cargo.toml": MANIFEST, "core/src/main.rs": "fn main() {\n    todo!()\n}\n", "app/A.swift": UNWRAP });

  assert.deepEqual(lintSwift(dir).err.filter((line) => line.startsWith("✗ ")), ["✗ lint: 1 finding from swift-format"]);
  assert.deepEqual(lint(dir).err.filter((line) => line.startsWith("✗ ")), ["✗ lint: 1 finding from clippy"]);
});

test("Swift S20: a directive as a trailing comment has no effect, and is named so", () => {
  const trailing = "func f(_ x: Int?) -> Int {\n    let y = x!  // swift-format-ignore: NeverForceUnwrap\n    return y\n}\n";

  const run = lintSwift(swiftRepo({ "app/A.swift": trailing }));

  assert.deepEqual(report(run).slice(0, 3), [
    "✗ lint: 2 findings from swift-format",
    "  at   app/A.swift:2:13 NeverForceUnwrap",
    "       app/A.swift:2:17 ignore-has-no-effect",
  ]);
});

test("Swift: a directive may name two rules", () => {
  const config = '{"version": 1, "indentation": {"spaces": 4}, "rules": {"NeverForceUnwrap": true, "NeverUseForceTry": true}}\n';
  const kept = "func f(_ x: Int?) -> Int {\n    // The caller checked it.\n    // swift-format-ignore: NeverForceUnwrap, NeverUseForceTry\n    let y = x!\n    return y\n}\n";

  assert.equal(lintSwift(swiftRepo({ ".swift-format": config, "app/A.swift": kept })).code, 0);
});

test("Swift: a doc comment line is not a reason", () => {
  const source = "func f(_ x: Int?) -> Int {\n    /// Not a reason.\n    // swift-format-ignore: NeverForceUnwrap\n    let y = x!\n    return y\n}\n";

  const run = lintSwift(swiftRepo({ "app/A.swift": source }));

  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: 1 finding from swift-format", "  at   app/A.swift:3:5 ignore-without-reason"]);
});

test("with no language named, a repository with no Rust file lints only its Swift", () => {
  const run = lint(swiftRepo({ "app/A.swift": UNWRAP }), process.env, null);

  assert.equal(run.code, 1);
  assert.deepEqual(run.err.filter((line) => line.startsWith("✗ ")), ["✗ lint: 1 finding from swift-format"]);
});

test("Swift: a configuration that is not JSON cannot run the check", () => {
  const run = lintSwift(swiftRepo({ ".swift-format": "{ not json\n", "app/A.swift": "let x = 1\n" }));

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  .swift-format is not valid JSON"]);
});

test("Swift: a second configuration below the root cannot run the check, because it could turn rules off", () => {
  const run = lintSwift(swiftRepo({ "app/.swift-format": '{"version": 1, "rules": {"NeverForceUnwrap": false}}\n', "app/A.swift": UNWRAP }));

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  app/.swift-format: only the configuration at the repository root is read"]);
});

test("Swift: an untracked configuration above a tracked Swift file is refused too: the tool would obey it", () => {
  const dir = swiftRepo({ "app/A.swift": UNWRAP });
  writeFileSync(join(dir, "app/.swift-format"), '{"version": 1, "rules": {"NeverForceUnwrap": false}}\n');

  const run = lintSwift(dir);

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 3), [
    "✗ lint: cannot run swift-format",
    "  why  app/.swift-format: only the configuration at the repository root is read",
    "  fix  remove it, and put its settings in .swift-format at the repository root",
  ]);
});

test("Swift: a configuration whose rules are not a table cannot run the check", () => {
  const run = lintSwift(swiftRepo({ ".swift-format": '{"version": 1, "rules": ["NeverForceUnwrap"]}\n', "app/A.swift": "let x = 1\n" }));

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  .swift-format: rules is not a table of rule names"]);
});

test("Swift: when the tool fails without a finding, the check has not run", () => {
  const bin = scratch();
  const real = execFileSync("which", ["swift"], { encoding: "utf8" }).trim();
  const script = `#!/bin/sh\n[ "$2" = "lint" ] && { echo '<unknown>: error: Unable to read configuration' >&2; exit 1; }\nexec ${real} "$@"\n`;
  writeFileSync(join(bin, "swift"), script, { mode: 0o755 });

  const run = lintSwift(swiftRepo({ "app/A.swift": "let x = 1\n" }), { ...process.env, PATH: `${bin}:${process.env.PATH}` });

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swift-format", "  why  <unknown>: error: Unable to read configuration"]);
});

// ---------------------------------------------------------------- swiftc

const W = (file, line, message) => ({ at: `${file}:${line}:9`, file, message });
const K = (file, message) => ({ file, message, issue: "#1", reason: "r" });

test("swiftc S3/S4: a known warning matches on file and message, whatever its line", () => {
  const known = [K("app/Sources/P/a.swift", "variable 'x' was never used")];

  assert.deepEqual(unmatched([W("app/Sources/P/a.swift", 2, "variable 'x' was never used")], known), { fresh: [], gone: [] });
  assert.deepEqual(unmatched([W("app/Sources/P/a.swift", 40, "variable 'x' was never used")], known), { fresh: [], gone: [] });
});

test("swiftc: a warning with another message, or in another file, is new, and the entry is gone", () => {
  const known = [K("app/Sources/P/a.swift", "variable 'x' was never used")];
  const other = W("app/Sources/P/a.swift", 2, "variable 'y' was never used");
  const elsewhere = W("app/Sources/P/b.swift", 2, "variable 'x' was never used");

  assert.deepEqual(unmatched([other], known), { fresh: [other], gone: [1] });
  assert.deepEqual(unmatched([elsewhere], known), { fresh: [elsewhere], gone: [1] });
});

test("swiftc S5/S17: an entry that no warning matched is named by its position in the list", () => {
  const known = [K("app/Sources/P/a.swift", "m"), K("app/Sources/P/gone.swift", "m")];

  assert.deepEqual(unmatched([W("app/Sources/P/a.swift", 2, "m")], known), { fresh: [], gone: [2] });
});

test("swiftc: one entry matches one warning, so a second identical warning is new", () => {
  const twice = [W("app/Sources/P/a.swift", 2, "m"), W("app/Sources/P/a.swift", 9, "m")];

  assert.deepEqual(unmatched(twice, [K("app/Sources/P/a.swift", "m")]), { fresh: [twice[1]], gone: [] });
  assert.deepEqual(unmatched(twice, [K("app/Sources/P/a.swift", "m"), K("app/Sources/P/a.swift", "m")]), { fresh: [], gone: [] });
});

const PACKAGE = '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "P", targets: [.target(name: "P")])\n';
const UNUSED = "func f() {\n    let x = 1\n}\n";
const LIST = "scripts/check/swiftc-known-warnings.json";

/** A git repository with a one-target package under `app/` and a known-warnings list. */
const packageRepo = (source, known = "[]\n") => repo({ "core/Cargo.toml": null, "app/Package.swift": PACKAGE, "app/Sources/P/a.swift": source, [LIST]: known });

const lintSwiftc = (dir, env) => lint(dir, env, "swiftc");

test("swiftc S1/S18: a package with no warning passes, says nothing, and leaves no build directory", () => {
  const tmp = scratch();
  const dir = packageRepo("func f() {}\n");
  const before = execFileSync("git", ["status", "--porcelain", "--ignored"], { cwd: dir, encoding: "utf8" });

  const run = lintSwiftc(dir, { ...process.env, TMPDIR: tmp });

  assert.deepEqual({ code: run.code, err: run.err, out: run.out }, { ...CLEAN, out: "" });
  assert.deepEqual(readdirSync(tmp).filter((name) => name.startsWith("tarmac-swiftc-") && !name.endsWith(".lock")), []);
  assert.equal(execFileSync("git", ["status", "--porcelain", "--ignored"], { cwd: dir, encoding: "utf8" }), before);
});

test("swiftc S2/S6: a warning is a finding, on the first run and on the next one", () => {
  const dir = packageRepo(UNUSED);

  const runs = [lintSwiftc(dir), lintSwiftc(dir)];

  for (const run of runs) {
    assert.equal(run.code, 1);
    assert.ok(run.err.some((line) => line.includes("warning: initialization of immutable value 'x' was never used")), run.err.join("\n"));
    assert.deepEqual(report(run), [
      "✗ lint: 1 finding from swiftc",
      "  at   app/Sources/P/a.swift:2:9 swiftc-warning",
      `  fix  correct each warning above; remove a known warning from ${LIST} when its code is fixed`,
      "  then make lint ONLY=swiftc",
      "",
    ]);
  }
});

test("swiftc S3: the same warning with an entry in the list passes", () => {
  const message = "initialization of immutable value 'x' was never used; consider replacing with assignment to '_' or removing it";
  const known = JSON.stringify([{ file: "app/Sources/P/a.swift", message, issue: "#1", reason: "a fixture" }]);

  assert.equal(lintSwiftc(packageRepo(UNUSED, known)).code, 0);
});

test("swiftc S5: a list entry with no warning is a finding at its place in the list", () => {
  const known = JSON.stringify([{ file: "app/Sources/P/a.swift", message: "m", issue: "#1", reason: "a fixture" }]);

  const run = lintSwiftc(packageRepo("func f() {}\n", known));

  assert.equal(run.code, 1);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: 1 finding from swiftc", `  at   ${LIST}:1 known-warning-is-gone`]);
});

test("swiftc S7: a package that does not compile cannot be linted", () => {
  const tmp = scratch();

  const run = lintSwiftc(packageRepo("func f() {\n    let n: Int = missing\n    _ = n\n}\n"), { ...process.env, TMPDIR: tmp });

  assert.equal(run.code, 2);
  assert.deepEqual(report(run), [
    "✗ lint: cannot run swiftc",
    "  why  app/Sources/P/a.swift:2:18 error: cannot find 'missing' in scope",
    "  fix  make the package build: cd app && swift build",
    "  then make lint ONLY=swiftc",
    "",
  ]);
  assert.deepEqual(readdirSync(tmp).filter((name) => name.startsWith("tarmac-swiftc-") && !name.endsWith(".lock")), []);
});

for (const [name, text] of [
  ["not JSON", "[ not json"],
  ["not a list", "{}"],
  ["an entry with no reason", '[{"file": "a", "message": "m", "issue": "#1"}]'],
  ["an entry with an empty reason", '[{"file": "a", "message": "m", "issue": "#1", "reason": ""}]'],
]) {
  test(`swiftc S16: a list that is ${name} cannot run the check`, () => {
    const run = lintSwiftc(packageRepo("func f() {}\n", text));

    assert.equal(run.code, 2);
    assert.equal(report(run)[0], "✗ lint: cannot run swiftc");
    assert.ok(report(run)[1].startsWith(`  why  ${LIST}`), report(run)[1]);
  });
}

test("swiftc S16: a missing list cannot run the check", () => {
  const dir = repo({ "core/Cargo.toml": null, "app/Package.swift": PACKAGE, "app/Sources/P/a.swift": "func f() {}\n" });

  assert.deepEqual(report(lintSwiftc(dir)).slice(0, 2), ["✗ lint: cannot run swiftc", `  why  ${LIST} is missing`]);
});

test("swiftc S15: with no swift on the PATH the check cannot run", () => {
  const bin = scratch();
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));

  const run = lintSwiftc(packageRepo(UNUSED), { ...process.env, PATH: bin });

  assert.equal(run.code, 2);
  assert.deepEqual(report(run).slice(0, 2), ["✗ lint: cannot run swiftc", "  why  swift is not on the PATH"]);
});
