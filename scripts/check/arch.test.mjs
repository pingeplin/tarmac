import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";

import "./test-env.mjs";

const SCRIPT = join(import.meta.dirname, "arch.mjs");
const LIST = "scripts/check/arch-exceptions.json";
const CARGO = "core/Cargo.toml";
const PINNED = '[workspace.dependencies]\nserde = { version = "=1.0.228", features = ["derive"] }\nrmp-serde = "=1.3.1"\nserde_bytes = "=0.11.19"\n';
const KIT = "app/Sources/TarmacKit";
const dirs = [];
after(() => dirs.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

function scratch() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "arch-test-")));
  dirs.push(dir);
  return dir;
}

function write(dir, files) {
  for (const [path, text] of Object.entries(files)) {
    if (text === null) continue;
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
}

/** A git repository that breaks no rule, plus the listed files, all tracked. */
function repo(files = {}) {
  const dir = scratch();
  write(dir, { [CARGO]: PINNED, [LIST]: "[]\n", ...files });
  execFileSync("git", ["init", "-q"], { cwd: dir });
  execFileSync("git", ["add", "-A"], { cwd: dir });
  return dir;
}

function arch(dir) {
  const run = spawnSync(process.execPath, [SCRIPT], { cwd: dir, encoding: "utf8" });
  return { code: run.status, out: run.stdout, err: run.stderr.split("\n") };
}

/** The `at` rows of a run, as `path:line`. */
const places = (run) => run.err.filter((line) => /^ {2}(at| {2}) {3}/.test(line)).map((line) => line.slice(7));
const summaries = (run) => run.err.filter((line) => line.startsWith("✗ ")).map((line) => line.slice("✗ arch: ".length));

const KIT_IMPORTS = "TarmacKit must not import AppKit, WebKit or a sibling target";
const TERM_IMPORTS = "TarmacTerm must not import TarmacKit or TarmacApp";
const BUNDLE = "Bundle.module is used outside BundledResource";
const SIGNAL = "a signal is sent outside TermHandle::kill";
const SWIFT_SIGNAL = "kill(2) is called in Swift outside the app's wiring and the tests' fence";
const CLIPBOARD = "a test uses the system clipboard";
const PROFILE = "a profile sets debug-assertions";
const SERDE = "the serde stack is not pinned with =";
const KIT_TESTS = "a TarmacKit module has no paired test file, or an exception is no longer needed";

test("S1: a repository that breaks no rule passes and says nothing", () => {
  const run = arch(repo({ [`${KIT}/A.swift`]: "import Foundation\n", "app/Tests/TarmacKitTests/ATests.swift": "import XCTest\n" }));

  assert.deepEqual(run, { code: 0, out: "", err: [""] });
});

test("S2/S14: every form of a forbidden import in TarmacKit is reported at its line", () => {
  const source = [
    "import AppKit",
    "@testable import WebKit",
    "import struct AppKit.NSColor",
    "import Cocoa",
    "import SwiftUI",
    "import TarmacTerm",
    "#if canImport(AppKit)",
    "    import AppKit",
    "#elseif canImport(WebKit)",
    "#endif",
    "public import AppKit",
    "@_spi(X) import AppKit",
    "import AppKit.NSColor",
    "import TarmacApp",
  ].join("\n");

  const run = arch(repo({ [`${KIT}/A.swift`]: source, "app/Tests/TarmacKitTests/ATests.swift": "" }));

  assert.equal(run.code, 1);
  assert.deepEqual(summaries(run), [KIT_IMPORTS]);
  assert.deepEqual(places(run), [1, 11, 12, 13, 14, 2, 3, 4, 5, 6, 7, 8, 9].map((line) => `${KIT}/A.swift:${line}`));
});

for (const form of [
  ...["public", "package", "internal", "fileprivate", "private"].map((access) => `${access} import AppKit`),
  ...["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"].map((kind) => `import ${kind} AppKit.Thing`),
  "@preconcurrency @testable import AppKit",
  "import\tAppKit",
]) {
  test(`S14: "${form.replace("\t", "<tab>")}" in TarmacKit is a forbidden import`, () => {
    const run = arch(repo({ [`${KIT}/A.swift`]: `${form}\n`, "app/Tests/TarmacKitTests/ATests.swift": "" }));

    assert.deepEqual(places(run), [`${KIT}/A.swift:1`]);
  });
}

test("S2: only Swift files are read for imports", () => {
  const run = arch(repo({ [`${KIT}/notes.md`]: "import AppKit\n", "app/Sources/TarmacTerm/notes.txt": "import TarmacKit\n" }));

  assert.equal(run.code, 0);
});

test("S2/S14: the near misses of a forbidden import are not reported", () => {
  const kit = ["import Foundation", "import AppKitLike", "// import AppKit", "let x = 1 // import AppKit", "let importAppKit = 1"].join("\n");

  const run = arch(repo({ [`${KIT}/A.swift`]: kit, "app/Tests/TarmacKitTests/ATests.swift": "", "app/Sources/TarmacApp/B.swift": "import AppKit\nimport TarmacKit\n" }));

  assert.equal(run.code, 0);
});

test("S3/S14: TarmacTerm may import AppKit, and not a sibling", () => {
  const source = ["import AppKit", "import TarmacKit", "#if canImport(TarmacKit)", "#endif", "import TarmacApp"].join("\n");

  const run = arch(repo({ "app/Sources/TarmacTerm/T.swift": source }));

  assert.deepEqual(summaries(run), [TERM_IMPORTS]);
  assert.deepEqual(places(run), [2, 3, 5].map((line) => `app/Sources/TarmacTerm/T.swift:${line}`));
});

test("S4/S15: Bundle.module in code is reported everywhere but in BundledResource", () => {
  const run = arch(
    repo({
      "app/Sources/TarmacApp/BundledResource.swift": "let a = Bundle.module\n",
      "app/Sources/TarmacApp/Other.swift": "/// Bundle.module traps there.\nlet b = Bundle.module.url\nlet c = Bundle.moduleURL\nlet d = 1 // Bundle.module\n",
      "scripts/qa/x.swift": "let e = Bundle.module\n",
      "app/Sources/TarmacKit/BundledResource.swift": "let f = Bundle.module\n",
      "app/Tests/TarmacKitTests/BundledResourceTests.swift": "",
    }),
  );

  assert.deepEqual(summaries(run), [BUNDLE]);
  assert.deepEqual(places(run), ["app/Sources/TarmacApp/Other.swift:2", "app/Sources/TarmacKit/BundledResource.swift:1", "scripts/qa/x.swift:1"]);
});

test("S5/S15: a signal is sent in term.rs only, among the files under a crate's src", () => {
  const send = "fn f() {\n    unsafe { libc::kill(1, 0) };\n}\n";
  const run = arch(
    repo({
      "core/crates/tarmacd/src/term.rs": send,
      "core/crates/tarmacd/src/conn.rs": `${send}// libc::kill(1, 0)\nfn g() { libc::kill_all(); libc::killpg(1, 0); }\n`,
      "core/crates/tarmacd/src/state/deep.rs": send,
      "core/crates/tarmacd/tests/common/daemon.rs": send,
      "core/crates/tarmac-cli/src/main.rs": send,
      "core/crates/tarmac-cli/src/term.rs": send,
    }),
  );

  assert.deepEqual(summaries(run), [SIGNAL]);
  assert.deepEqual(places(run), [
    "core/crates/tarmac-cli/src/main.rs:2",
    "core/crates/tarmac-cli/src/term.rs:2",
    "core/crates/tarmacd/src/conn.rs:2",
    "core/crates/tarmacd/src/conn.rs:5",
    "core/crates/tarmacd/src/state/deep.rs:2",
  ]);
});

test("2611.0033 S6: kill(2) in Swift is called in the app's wiring and the tests' fence only", () => {
  const send = "func f() {\n    kill(pid, SIGTERM)\n}\n";
  const forms = ["Darwin.kill(1, 0)", "killpg(1, 0)", "_ = kill (1, 0)", "Foundation.kill(1, 0)", "`kill`(1, 0)", "// kill(1, 0)", "skill(1)", "let kill = 1", "kill_all()"].join("\n");
  const run = arch(
    repo({
      "app/Sources/TarmacApp/AppController+Connection.swift": send,
      "app/Tests/TarmacKitTests/OwnChild.swift": send,
      "app/Sources/TarmacKit/DaemonClient.swift": send,
      "app/Sources/TarmacKit/Forms.swift": forms,
      "app/Sources/TarmacApp/Other.swift": send,
      "app/Sources/tarmac-smoke/main.swift": send,
      "app/Tests/TarmacKitTests/DaemonClientTests.swift": send,
      "app/Tests/TarmacTermTests/XTests.swift": send,
      "scripts/qa/x.swift": send,
      "app/Tests/TarmacKitTests/FormsTests.swift": "",
    }),
  );

  assert.deepEqual(summaries(run), [SWIFT_SIGNAL]);
  assert.deepEqual(places(run), [
    "app/Sources/TarmacApp/Other.swift:2",
    "app/Sources/TarmacKit/DaemonClient.swift:2",
    "app/Sources/TarmacKit/Forms.swift:1",
    "app/Sources/TarmacKit/Forms.swift:2",
    "app/Sources/TarmacKit/Forms.swift:3",
    "app/Sources/TarmacKit/Forms.swift:4",
    "app/Sources/TarmacKit/Forms.swift:5",
    "app/Sources/tarmac-smoke/main.swift:2",
    "app/Tests/TarmacKitTests/DaemonClientTests.swift:2",
    "app/Tests/TarmacTermTests/XTests.swift:2",
  ]);
});

test("#490: the system clipboard is named in no test", () => {
  const use = "func f() {\n    NSPasteboard.general.clearContents()\n    // NSPasteboard.general\n    let p = NSPasteboard .general\n    let own = NSPasteboard.withUniqueName()\n    let other = NSPasteboard.generalPurpose\n}\n";
  const run = arch(
    repo({
      "app/Tests/TarmacTermTests/TerminalViewTests.swift": use,
      "app/Tests/TarmacKitTests/ATests.swift": use,
      "app/Sources/TarmacKit/A.swift": "",
      "app/Sources/TarmacTerm/TerminalView.swift": use,
      "scripts/qa/x.swift": use,
    }),
  );

  assert.deepEqual(summaries(run), [CLIPBOARD]);
  assert.deepEqual(places(run), ["app/Tests/TarmacKitTests/ATests.swift:2", "app/Tests/TarmacKitTests/ATests.swift:4", "app/Tests/TarmacTermTests/TerminalViewTests.swift:2", "app/Tests/TarmacTermTests/TerminalViewTests.swift:4"]);
});

test("S6/S16: debug-assertions in any profile table is reported at its line, and nowhere else", () => {
  const workspace = [PINNED, "[profile.release]", "lto = true", "debug-assertions = true", "[profile.dev]", "# debug-assertions = false", "opt-level = 1", "[profile.dev.package.foo]", "debug-assertions = false"].join("\n");
  const crate = "[package]\nname = \"x\"\ndebug-assertions = false\n[profile.dev]\ndebug-assertions = false\n";

  const config = "[profile.dev]\ndebug-assertions = false\n";
  const run = arch(repo({ [CARGO]: workspace, "core/crates/x/Cargo.toml": crate, "core/.cargo/config.toml": config, ".cargo/config.toml": config }));

  assert.deepEqual(summaries(run), [PROFILE]);
  assert.deepEqual(places(run), [".cargo/config.toml:2", "core/.cargo/config.toml:2", "core/Cargo.toml:13", "core/Cargo.toml:8", "core/crates/x/Cargo.toml:5"]);
});

test("S16: a table header with a comment after it is still a header", () => {
  const run = arch(repo({ [CARGO]: `${PINNED}[profile.dev] # for local builds\ndebug-assertions = false\n` }));

  assert.deepEqual(places(run), ["core/Cargo.toml:6"]);
});

test("S16: an array-of-tables header ends a profile table, and a header may have spaces inside", () => {
  const ended = `${PINNED}[profile.dev]\nopt-level = 1\n[[bin]]\ndebug-assertions = false\n`;
  const spaced = `${PINNED}[ profile.dev ]\ndebug-assertions = false\n`;

  assert.equal(arch(repo({ [CARGO]: ended })).code, 0);
  assert.deepEqual(places(arch(repo({ [CARGO]: spaced }))), ["core/Cargo.toml:6"]);
});

test("S6: a profile with no debug-assertions key passes", () => {
  assert.equal(arch(repo({ [CARGO]: `${PINNED}[profile.release]\nlto = true\n` })).code, 0);
});

test("S7/S17: each of the three serde crates must be there, with a version that starts with =", () => {
  const loose = '[workspace.package]\nversion = "1"\n\n[workspace.dependencies]\nserde = "1.0"\nrmp-serde = { version = "1.3.1" }\nserde_json = "1"\n\n[other]\nserde_bytes = "=0.11.19"\n';

  const run = arch(repo({ [CARGO]: loose }));

  assert.deepEqual(summaries(run), [SERDE]);
  assert.deepEqual(places(run), ["core/Cargo.toml:4", "core/Cargo.toml:5", "core/Cargo.toml:6"]);
});

test("S7/S17: a path dependency has no version to pin, and a missing table is reported at line 1", () => {
  const byPath = '[workspace.dependencies]\nserde = { path = "../serde" }\nrmp-serde = "=1.3.1"\nserde_bytes = "=0.11.19"\n';

  assert.deepEqual(places(arch(repo({ [CARGO]: byPath }))), ["core/Cargo.toml:2"]);
  assert.deepEqual(places(arch(repo({ [CARGO]: "[workspace]\n" }))), ["core/Cargo.toml:1"]);
});

test("S17: a key that only ends in version is not the version", () => {
  const sly = '[workspace.dependencies]\nserde = { default-version = "=1", version = "1.0" }\nrmp-serde = "=1.3.1"\nserde_bytes = "=0.11.19"\n';

  assert.deepEqual(places(arch(repo({ [CARGO]: sly }))), ["core/Cargo.toml:2"]);
});

test("S8/S19: a kit module needs its test file or an entry; a slice needs neither", () => {
  const run = arch(
    repo({
      [`${KIT}/Tested.swift`]: "",
      "app/Tests/TarmacKitTests/TestedTests.swift": "",
      [`${KIT}/Bare.swift`]: "",
      [`${KIT}/Listed.swift`]: "",
      [`${KIT}/OffscreenHintLayout+PillStack.swift`]: "",
      [`${KIT}/Nested/Deep.swift`]: "",
      [LIST]: JSON.stringify([{ module: "Listed", issue: "#1", reason: "r" }]),
    }),
  );

  assert.deepEqual(summaries(run), [KIT_TESTS]);
  assert.deepEqual(places(run), [`${KIT}/Bare.swift:1`, `${KIT}/Nested/Deep.swift:1`], "a module in a subfolder is a module too");
});

test("S8/S19: an entry that is no longer needed is reported at the line of its module", () => {
  const list = '[\n  {\n    "module": "Tested",\n    "issue": "#1",\n    "reason": "r"\n  },\n  {\n    "module": "Gone",\n    "issue": "#1",\n    "reason": "r"\n  }\n]\n';

  const run = arch(repo({ [`${KIT}/Tested.swift`]: "", "app/Tests/TarmacKitTests/TestedTests.swift": "", [LIST]: list }));

  assert.deepEqual(summaries(run), [KIT_TESTS]);
  assert.deepEqual(places(run), [`${LIST}:3`, `${LIST}:8`]);
});

test("S9: two broken rules give two blocks, in the order of the rules, each with its reason and next step", () => {
  const run = arch(repo({ [CARGO]: `${PINNED}[profile.dev]\ndebug-assertions = false\n`, [`${KIT}/A.swift`]: "import AppKit\n", "app/Tests/TarmacKitTests/ATests.swift": "" }));

  assert.equal(run.code, 1);
  assert.equal(run.out, "");
  assert.deepEqual(run.err, [
    `✗ arch: ${KIT_IMPORTS}`,
    `  at   ${KIT}/A.swift:1`,
    "  why  TarmacKit holds the pure decisions and is the only layer with unit tests",
    "  fix  move the code that needs the module into TarmacApp, and pass the value in",
    "  then make arch-check",
    `✗ arch: ${PROFILE}`,
    "  at   core/Cargo.toml:6",
    "  why  the daemon and the CLI pick their channel from debug_assertions; a profile that changes it moves a debug build onto the installed app's socket and state",
    "  fix  remove the debug-assertions key",
    "  then make arch-check",
    "",
  ]);
});

test("S18: several places of one rule are one block, in byte order", () => {
  const pad = (n) => "\n".repeat(n - 1);
  const run = arch(
    repo({
      [`${KIT}/Zeta.swift`]: `${pad(9)}import AppKit\n`,
      [`${KIT}/Alpha.swift`]: `${pad(10)}import AppKit\n`,
      "app/Tests/TarmacKitTests/ZetaTests.swift": "",
      "app/Tests/TarmacKitTests/AlphaTests.swift": "",
    }),
  );

  assert.deepEqual(summaries(run), [KIT_IMPORTS]);
  assert.deepEqual(places(run), [`${KIT}/Alpha.swift:10`, `${KIT}/Zeta.swift:9`]);
});

for (const [name, files, why] of [
  ["missing", { [LIST]: null }, `${LIST} is missing`],
  ["not JSON", { [LIST]: "[ nope" }, `${LIST} is not valid JSON`],
  ["not a list", { [LIST]: "{}" }, `${LIST} is not a list`],
  ["an entry with no reason", { [LIST]: '[{"module": "A", "issue": "#1"}]' }, `${LIST} entry 1 needs module, issue, reason, each a text that is not empty`],
  ["an entry with no module", { [LIST]: '[{"issue": "#1", "reason": "r"}]' }, `${LIST} entry 1 needs module, issue, reason, each a text that is not empty`],
  ["an entry with an empty issue", { [LIST]: '[{"module": "A", "issue": "", "reason": "r"}]' }, `${LIST} entry 1 needs module, issue, reason, each a text that is not empty`],
  ["two entries for one module", { [LIST]: '[{"module": "A", "issue": "#1", "reason": "r"}, {"module": "A", "issue": "#1", "reason": "r"}]' }, `${LIST} names A twice`],
]) {
  test(`S10/S19: an exceptions list that is ${name} cannot run the check`, () => {
    const run = arch(repo({ ...files, [`${KIT}/A.swift`]: "import AppKit\n" }));

    assert.equal(run.code, 2);
    assert.equal(run.out, "");
    assert.deepEqual(run.err.slice(0, 2), ["✗ arch: cannot run the architecture check", `  why  ${why}`]);
    assert.deepEqual(summaries(run), ["cannot run the architecture check"], "no rule runs");
  });
}

test("S10: with no core/Cargo.toml, and outside a git repository, the check cannot run", () => {
  const noCargo = arch(repo({ [CARGO]: null }));
  const outside = arch(scratch());

  assert.deepEqual([noCargo.code, noCargo.err[1]], [2, `  why  ${CARGO} is missing`]);
  assert.deepEqual([outside.code, outside.err[0]], [2, "✗ arch: not in a git repository"]);
});

test("S10/S20: an untracked file is not read; a tracked file is read as it is in the working tree; a deleted one is skipped", () => {
  const dir = repo({ [`${KIT}/Tracked.swift`]: "import Foundation\n", "app/Tests/TarmacKitTests/TrackedTests.swift": "", [`${KIT}/Deleted.swift`]: "import AppKit\n" });
  write(dir, { [`${KIT}/Untracked.swift`]: "import AppKit\n", [`${KIT}/Tracked.swift`]: "import AppKit\n" });
  rmSync(join(dir, `${KIT}/Deleted.swift`));

  const run = arch(dir);

  assert.equal(run.code, 1);
  assert.deepEqual(places(run), [`${KIT}/Tracked.swift:1`]);
});

test("S19: a stale entry is placed at its module's line, whatever characters the name has and however the entry is laid out", () => {
  const list = '[\n  { "issue": "#1",\n    "module":\n      "A(",\n    "reason": "r" }\n]\n';

  const run = arch(repo({ [LIST]: list }));

  assert.equal(run.code, 1);
  assert.deepEqual(places(run), [`${LIST}:4`]);
});

test("a file that cannot be read cannot run the check: it is not a broken rule", () => {
  const dir = repo({ [`${KIT}/A.swift`]: "import Foundation\n", "app/Tests/TarmacKitTests/ATests.swift": "" });
  chmodSync(join(dir, `${KIT}/A.swift`), 0o000);

  const run = arch(dir);
  chmodSync(join(dir, `${KIT}/A.swift`), 0o644);

  assert.equal(run.code, 2);
  assert.equal(run.err[0], "✗ arch: cannot run the architecture check");
});
