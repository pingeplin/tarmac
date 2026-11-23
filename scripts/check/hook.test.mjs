import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, existsSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";

import "./test-env.mjs";

import { git, runScript, scratchIn, tracked, write } from "./test-support.mjs";

const HERE = import.meta.dirname;
const HOOK = join(HERE, "hook.mjs");
// What Claude Code 2.1.330 sent to each hook in a real run, with its paths and ids replaced.
const SENT = JSON.parse(readFileSync(join(HERE, "fixtures/hook-inputs.json"), "utf8"));
const SWIFT_RULES = '{"version": 1, "indentation": {"spaces": 4}, "rules": {"NeverForceUnwrap": true}}\n';
const CARGO = '[workspace.dependencies]\nserde = "=1.0.228"\nrmp-serde = "=1.3.1"\nserde_bytes = "=0.11.19"\n';
const UNWRAP = "func f(_ x: Int?) -> Int {\n    let y = x!\n    return y\n}\n";
const scratch = scratchIn("hook-test-");

/** A git repository with one commit that holds this repository's check scripts and the files a check needs. */
function repo(files = {}) {
  const dir = scratch();
  cpSync(HERE, join(dir, "scripts/check"), { recursive: true, filter: (path) => !path.endsWith(".test.mjs") });
  cpSync(join(HERE, "../../rust-toolchain.toml"), join(dir, "rust-toolchain.toml"));
  tracked(dir, {
    ".swift-format": SWIFT_RULES,
    "core/Cargo.toml": CARGO,
    "scripts/check/arch-exceptions.json": "[]\n",
    // A stand-in for docs-check, which needs this repository's whole doc set: it fails while DOCS_BROKEN exists.
    "scripts/docs-check.mjs": 'import { existsSync } from "node:fs";\nif (existsSync("DOCS_BROKEN")) {\n  console.error("docs-check: 1 problem(s)");\n  process.exit(1);\n}\nconsole.log("docs-check: ok");\n',
    ...files,
  });
  git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "init");
  return dir;
}

const hook = (event, input, env = process.env) => runScript(HOOK, [event], { input: JSON.stringify(input), env });

const QUIET = { code: 0, out: "", err: "" };
const editOf = (file) => ({ ...SENT["PostToolUse.Write"], cwd: dirname(file), tool_input: { ...SENT["PostToolUse.Write"].tool_input, file_path: file } });
const stopIn = (dir, session = "s1", more = {}) => ({ ...SENT.Stop, cwd: dir, session_id: session, ...more });
const bashOf = (command) => ({ ...SENT["PreToolUse.Bash"], tool_input: { ...SENT["PreToolUse.Bash"].tool_input, command } });

// ------------------------------------------------------------------ edit

test("S1: a new Swift file with a layout fault is formatted, and the hook says nothing", () => {
  const dir = repo();
  write(dir, { "app/New.swift": "let  x=1\n" });

  assert.deepEqual(hook("edit", editOf(join(dir, "app/New.swift"))), QUIET);
  assert.equal(readFileSync(join(dir, "app/New.swift"), "utf8"), "let x = 1\n");
});

test("S2: a force unwrap in the edited file is shown to the model, and the file is still formatted", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP.replace("let y = x!", "let  y = x!") });

  const run = hook("edit", editOf(join(dir, "app/New.swift")));

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ lint: 1 finding from swift-format\n {2}at {3}app\/New\.swift:2:13 NeverForceUnwrap$/m);
  assert.equal(readFileSync(join(dir, "app/New.swift"), "utf8"), UNWRAP);
});

test("S3/S29: a file the checks do not own is left alone, with no output", () => {
  // The tree has a finding, so a check that ran for one of these files would be heard.
  const dir = repo({ ".gitignore": "build/\n", "app/Sources/TarmacKit/A.swift": "import AppKit\n", "app/Tests/TarmacKitTests/ATests.swift": "" });
  write(dir, { "build/Gen.swift": "let  x=1\n", "notes.md": "#  x\n" });
  const outside = scratch();
  write(outside, { "Loose.swift": "let  x=1\n" });

  for (const file of [join(dir, "build/Gen.swift"), join(outside, "Loose.swift"), join(dir, "app/Gone.swift"), join(dir, "notes.md")]) {
    assert.deepEqual(hook("edit", editOf(file)), QUIET, file);
  }
  assert.deepEqual(hook("edit", { ...SENT["PostToolUse.Write"], tool_input: {} }), QUIET);
  assert.equal(readFileSync(join(dir, "build/Gen.swift"), "utf8"), "let  x=1\n");
  assert.equal(readFileSync(join(outside, "Loose.swift"), "utf8"), "let  x=1\n");
});

test("S3: an edit of an ignored file runs no check at all, whatever state the tree is in", () => {
  const dir = repo({ ".gitignore": "build/\n", "app/Sources/TarmacKit/A.swift": "import AppKit\n", "app/Tests/TarmacKitTests/ATests.swift": "" });
  write(dir, { "build/Gen.swift": "let x = 1\n" });

  assert.deepEqual(hook("edit", editOf(join(dir, "build/Gen.swift"))), QUIET);
});

test("S4: a TarmacKit file that now imports AppKit is refused by the tree's rules", () => {
  const dir = repo({ "app/Sources/TarmacKit/A.swift": "import Foundation\n", "app/Tests/TarmacKitTests/ATests.swift": "" });
  write(dir, { "app/Sources/TarmacKit/A.swift": "import AppKit\n" });

  const run = hook("edit", editOf(join(dir, "app/Sources/TarmacKit/A.swift")));

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ arch: TarmacKit must not import AppKit, WebKit or a sibling target\n {2}at {3}app\/Sources\/TarmacKit\/A\.swift:1$/m);
});

test("S5: a Rust file that does not parse is said to be so, and is not changed", () => {
  const dir = repo();
  write(dir, { "core/src/bad.rs": "fn x( {\n" });

  const run = hook("edit", editOf(join(dir, "core/src/bad.rs")));

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ fmt: cannot run rustfmt$/m);
  assert.equal(readFileSync(join(dir, "core/src/bad.rs"), "utf8"), "fn x( {\n");
});

test("a worktree from before the hooks is not judged: its check scripts do not take a file list", () => {
  const dir = repo({ "app/Sources/TarmacKit/A.swift": "import AppKit\n", "app/Tests/TarmacKitTests/ATests.swift": "" });
  rmSync(join(dir, "scripts/check/hook.mjs"));
  write(dir, { "app/New.swift": UNWRAP.replace("let y", "let  y") });

  assert.deepEqual(hook("edit", editOf(join(dir, "app/New.swift"))), QUIET);
  assert.deepEqual(hook("stop", stopIn(dir)), QUIET);
  assert.equal(readFileSync(join(dir, "app/New.swift"), "utf8"), UNWRAP.replace("let y", "let  y"));
});

test("an event about another repository is judged by that repository's own adapter", () => {
  const dir = repo();
  write(dir, { "scripts/check/hook.mjs": 'process.stderr.write(`theirs ${process.argv[2]}\\n`);\nprocess.exitCode = 2;\n', "app/New.swift": "let x = 1\n" });

  assert.deepEqual(hook("edit", editOf(join(dir, "app/New.swift"))), { code: 2, out: "", err: "theirs edit\n" });
  assert.deepEqual(hook("stop", stopIn(dir)), { code: 2, out: "", err: "theirs stop\n" });
});

test("a repository with no check scripts is not judged", () => {
  const dir = scratch();
  execFileSync("git", ["init", "-q"], { cwd: dir });
  write(dir, { "a.swift": "let  x=1\n" });

  assert.deepEqual(hook("edit", editOf(join(dir, "a.swift"))), QUIET);
  assert.deepEqual(hook("stop", stopIn(dir)), QUIET);
  assert.equal(readFileSync(join(dir, "a.swift"), "utf8"), "let  x=1\n");
});

// ------------------------------------------------------------------ stop

const NOTE = "(the same findings as at the last stop of this session: reported, not blocking)";

test("S6: a tree with no changed file lets the turn end, and says nothing", () => {
  assert.deepEqual(hook("stop", stopIn(repo())), QUIET);
});

test("S7: a finding blocks once for a session; the same finding again is reported and does not block", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP });

  const first = hook("stop", stopIn(dir));
  const second = hook("stop", stopIn(dir));
  const other = hook("stop", stopIn(dir, "s2"));

  assert.equal(first.code, 2);
  assert.match(first.err, /app\/New\.swift:2:13 NeverForceUnwrap/);
  assert.ok(!first.err.includes(NOTE));
  assert.deepEqual([second.code, second.err], [0, `${NOTE}\n${first.err}`]);
  assert.equal(other.code, 2);
});

test("S8/S21: another set of findings blocks again, and so does the first set when it comes back", () => {
  const dir = repo();
  const a = () => write(dir, { "app/New.swift": UNWRAP });
  const b = () => write(dir, { "app/New.swift": `\n${UNWRAP}` });

  const codes = [a, b, a].map((set) => (set(), hook("stop", stopIn(dir)).code));

  assert.deepEqual(codes, [2, 2, 2]);
});

test("a clean stop forgets the set, so the same findings later block again", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP });
  const blocked = hook("stop", stopIn(dir)).code;
  write(dir, { "app/New.swift": "let x = 1\n" });
  const clean = hook("stop", stopIn(dir));
  write(dir, { "app/New.swift": UNWRAP });

  assert.deepEqual([blocked, clean.code, clean.err, hook("stop", stopIn(dir)).code], [2, 0, "", 2]);
});

test("a failed docs-check is a finding of the stop hook, in its own words", () => {
  const dir = repo({ ".gitignore": "DOCS_BROKEN\n" });
  write(dir, { DOCS_BROKEN: "" });

  const run = hook("stop", stopIn(dir));

  assert.deepEqual([run.code, run.err], [2, "docs-check: 1 problem(s)\n"]);
});

test("a repository with no commit yet has its staged files checked", () => {
  const dir = repo();
  rmSync(join(dir, ".git"), { recursive: true });
  execFileSync("git", ["init", "-q"], { cwd: dir });
  write(dir, { "app/New.swift": UNWRAP });
  execFileSync("git", ["add", "-A"], { cwd: dir });

  const run = hook("stop", stopIn(dir));

  assert.equal(run.code, 2);
  assert.match(run.err, /app\/New\.swift:2:13 NeverForceUnwrap/);
});

test("a file named through a symlink to its directory is the same file", () => {
  const dir = repo();
  const link = join(scratch(), "link");
  symlinkSync(dir, link);
  write(dir, { "app/New.swift": UNWRAP });

  const run = hook("edit", editOf(join(link, "app/New.swift")));

  assert.equal(run.code, 2);
  assert.match(run.err, /^ {2}at {3}app\/New\.swift:2:13 NeverForceUnwrap$/m);
});

test("a file whose name starts with a dash is linted, and hides no other file's finding", () => {
  const dir = repo();
  write(dir, { "-dash.swift": "let x = 1\n", "app/a b.swift": UNWRAP });

  const run = hook("stop", stopIn(dir));

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.match(/^ {2}at .*$/gm), ["  at   app/a b.swift:2:13 NeverForceUnwrap"]);
});

test("S22: stop_hook_active does not let other findings through", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP });

  assert.equal(hook("stop", stopIn(dir, "s1", { stop_hook_active: true })).code, 2);
});

test("S9: a Rust stub is not the stop hook's business", () => {
  const dir = repo();
  write(dir, { "core/src/lib.rs": "pub fn f() -> u8 {\n    todo!()\n}\n" });

  assert.deepEqual(hook("stop", stopIn(dir)), QUIET);
});

/** A PATH on which `swift` answers `--version` with 5.9.2 and is the real one otherwise. */
function oldSwift() {
  const bin = scratch();
  const real = execFileSync("which", ["swift"], { encoding: "utf8" }).trim();
  writeFileSync(join(bin, "swift"), `#!/bin/sh\n[ "$2" = "--version" ] && { echo 5.9.2; exit; }\nexec ${real} "$@"\n`, { mode: 0o755 });
  return { ...process.env, PATH: `${bin}:${process.env.PATH}` };
}

test("S10: a check that cannot run is said, and does not block", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP });

  const run = hook("stop", stopIn(dir), oldSwift());

  assert.equal(run.code, 0);
  assert.match(run.err, /^✗ (fmt|lint): cannot run swift-format$/m);
  assert.ok(!run.err.includes(NOTE));
});

test("S23: findings block and a check that cannot run is said beside them; only the findings are remembered", () => {
  const dir = repo({ "app/Sources/TarmacKit/A.swift": "import Foundation\n", "app/Tests/TarmacKitTests/ATests.swift": "" });
  write(dir, { "app/Sources/TarmacKit/A.swift": "import AppKit\n" });

  const first = hook("stop", stopIn(dir), oldSwift());
  const second = hook("stop", stopIn(dir));

  assert.equal(first.code, 2);
  assert.match(first.err, /^✗ arch: TarmacKit must not import/m);
  assert.match(first.err, /cannot run swift-format/);
  assert.equal(second.code, 0);
  assert.ok(second.err.startsWith(NOTE));
});

test("S24: a deleted file and an ignored new file are not checked; a staged change is", () => {
  const dir = repo({ ".gitignore": "build/\n", "app/Old.swift": "let x = 1\n", "app/Staged.swift": "let x = 1\n" });
  rmSync(join(dir, "app/Old.swift"));
  write(dir, { "build/Gen.swift": UNWRAP, "app/Staged.swift": UNWRAP });
  execFileSync("git", ["add", "app/Staged.swift"], { cwd: dir });

  const run = hook("stop", stopIn(dir));

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.match(/^ {2}at .*$/gm), ["  at   app/Staged.swift:2:13 NeverForceUnwrap"]);
});

test("S25: a session id that is not a plain name writes no file, so nothing is remembered", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP });

  const codes = [hook("stop", stopIn(dir, "../x")).code, hook("stop", stopIn(dir, "../x")).code];

  assert.deepEqual(codes, [2, 2]);
  assert.ok(!existsSync(join(dir, ".git/x")));
  assert.deepEqual(existsSync(join(dir, ".git/tarmac-hooks")) ? readdirSync(join(dir, ".git/tarmac-hooks")) : [], []);
});

test("the remembered set is one small file under the git directory, never in the tree", () => {
  const dir = repo();
  write(dir, { "app/New.swift": UNWRAP });

  hook("stop", stopIn(dir, "abc-123"));

  assert.deepEqual(readdirSync(join(dir, ".git/tarmac-hooks")), ["abc-123"]);
  assert.match(readFileSync(join(dir, ".git/tarmac-hooks/abc-123"), "utf8"), /^[0-9a-f]{64}$/);
  assert.equal(execFileSync("git", ["status", "--porcelain", "--untracked-files=all"], { cwd: dir, encoding: "utf8" }), "?? app/New.swift\n");
});

// ------------------------------------------------------------------ bash

for (const command of [
  "pkill tarmacd",
  "pkill -f tarmac-app",
  "killall TarmacApp",
  "sudo pkill -9 tarmacd",
  "cd x && pkill -f TarmacApp",
  "ls; pkill tarmacd",
  "ps aux | killall -9 TARMACD",
  "FOO=1 pkill -f tarmac",
  "true || pkill tarmacd",
  "/usr/bin/pkill tarmacd",
  "sleep 1 & pkill tarmacd",
  "(pkill tarmacd)",
  "{ pkill tarmacd; }",
  "if true; then pkill tarmacd; fi",
  "while true; do killall tarmacd; done",
  "env pkill tarmacd",
  "sudo env X=1 /usr/bin/killall TarmacApp",
  "pgrep tarmacd | xargs pkill -f tarmac",
  "nohup pkill tarmacd",
  "if pkill tarmacd; then echo x; fi",
  "while killall tarmacd; do :; done",
  "sudo -u root pkill tarmacd",
  "env -i pkill tarmacd",
  "time -p pkill tarmacd",
  "timeout 5 pkill tarmacd",
  "nice pkill tarmacd",
  "echo tarmacd | xargs pkill",
  "echo $(pkill tarmacd)",
  "echo `pkill tarmacd`",
  'echo "now $(pkill tarmacd)"',
  'bash -c "pkill tarmacd"',
  "sh -c 'cd x && killall TarmacApp'",
  "pkill -f 't[a]rmac'",
  'pkill "tarmacd"',
  "pkill tar\\macd",
  'cd "$(git rev-parse --show-toplevel)" && pkill -f TarmacApp',
  'echo "$(date)"; pkill tarmacd',
  'echo "`date`"; killall tarmacd',
  'git commit -m "$(cat msg)" && pkill tarmacd',
  'echo "a $(echo "b $(pkill tarmacd)") c"',
  "(cd x; pkill tarmacd)",
  "sudo sh -c 'pkill tarmacd'",
  "nohup bash -c 'killall TarmacApp' &",
  "kill $(pgrep tarmacd)",
  "kill -9 `pgrep -f tarmac-app`",
  "pgrep -f tarmac-app | xargs kill",
  "cat <<EOF\nx\nEOF\npkill tarmacd",
  "ls # a comment\npkill tarmacd",
  "cat <<-EOF\n\tx\n\tEOF\npkill tarmacd",
  'pkill -f "Tarmac$(echo App)"',
  'grep x <<< "$v"\npkill tarmacd',
  "kill $(sudo pgrep tarmacd)",
  "kill $(sudo -n pgrep tarmacd)",
  "cd x && \\\n  pkill -f tarmac",
  "sudo \\\npkill tarmacd",
  'echo "a \\\nb"; pk\\\nill tarmacd',
  'pkill "tar\\\nmacd"',
  "eval pkill tarmacd",
  "eval 'pkill' tarmacd",
  "PKILL tarmacd",
  "timeout -s KILL 5 pkill tarmacd",
  "timeout --signal KILL 5 pkill tarmacd",
  "timeout --signal=KILL 5s killall Tarmac",
  "sudo -u root -E -- pkill tarmacd",
  "env -u X A=1 pkill tarmacd",
  "nice -n5 pkill tarmacd",
  "xargs -0 -I{} pkill -f tarmac",
  ">/dev/null 2>&1 pkill tarmacd",
  "2> /dev/null pkill tarmacd",
  "< /dev/null pkill tarmacd",
  "ls &>/dev/null; pkill tarmacd",
  "noglob pkill tarmacd",
  "builtin eval 'pkill tarmacd'",
  `${"eval ".repeat(3000)}pkill tarmacd`,
  "2>/dev/null pkill tarmacd",
  "kill $(command pgrep -f tarmac-app)",
  "sudo env A=1 nice -n 10 pkill tarmacd",
  "xargs -n 1 pkill -f tarmac",
  "echo $'a\\'b'; pkill tarmacd",
  "function f { pkill tarmacd; }; f",
  "f() { pkill tarmacd; }; f",
  'cat <<"END X"\nx\nEND X\npkill tarmacd',
  `${"$(".repeat(6000)}pkill tarmacd`,
  "echo a\npkill tarmacd",
]) {
  test(`S11/S26: \`${command.replaceAll("\n", "\\n").slice(0, 80)}\` is refused`, () => {
    const run = hook("bash", bashOf(command));

    assert.equal(run.code, 2);
    assert.match(run.err, /^✗ bash: a Tarmac process is not killed by name$/m);
    assert.match(run.err, /^ {2}fix {2}make kill-daemon/m);
  });
}

for (const command of [
  "make kill-daemon",
  "kill 1234",
  "pkill -f some-other-thing",
  "echo pkill tarmacd is forbidden",
  "git log --grep pkill",
  "grep pkill notes.txt",
  "pkill -f nginx && echo tarmac",
  "pgrep -fl tarmacd",
  "cat tarmac.log | grep killall",
  "make kill-daemon DEV_DIR=.dev2 & wait",
  'git commit -m "docs: never; pkill tarmacd"',
  "grep -E 'x|pkill tarmac' notes",
  'echo "a & killall Tarmac"',
  "echo nginx | xargs pkill",
  "sudo -u tarmac ls",
  "bash -c 'echo pkill tarmacd'",
  "pkill -f nginx; ls tarmac",
  'echo "$(date) pkill tarmacd is forbidden"',
  "gh pr create --body \"$(cat <<'EOF'\nIt refuses `pkill tarmacd` and\npkill -f tarmac-app\nEOF\n)\"",
  "cat > x.md <<'EOF'\nnever `pkill -f tarmac-app`\nEOF",
  "cat <<-EOF\n\tpkill tarmacd\n\tEOF\nls",
  "pkill -f node # not tarmac",
  "ls # ; pkill tarmacd",
  "kill 1234; pgrep nginx",
  "pgrep -fl tarmacd; kill -0 $$ 2>/dev/null",
  "echo a#b; ls",
  "cd tarmac && git ls-files | xargs grep -n pkill",
  "nice grep -rn pkill tarmac/",
  "command -v pkill tarmacd",
  "sudo -u tarmac grep pkill x",
  "timeout 5 make kill-daemon",
  "eval echo pkill tarmacd",
  "find tarmac/scripts -print0 | xargs -0 grep -n pkill",
  "ls tarmac | xargs -I{} grep -l pkill {}",
  "xargs -r grep pkill tarmac/",
  "sudo -n grep -rn pkill tarmac/",
  "command -p -v pkill tarmacd",
  "kill -0 $(pgrep -x tarmacd)",
  "timeout 5 echo pkill tarmacd",
  "ls 2>&1 | grep tarmac",
  `${"eval ".repeat(3000)}ls`,
  "ls > pkill.txt tarmac",
  `${"$(".repeat(6000)}ls`,
  SENT["PreToolUse.Bash"].tool_input.command,
]) {
  test(`S11/S26: \`${command.replaceAll("\n", "\\n").slice(0, 80)}\` passes`, () => {
    assert.deepEqual(hook("bash", bashOf(command)), QUIET);
  });
}

const MUTANTS_REFUSAL = [
  "✗ bash: cargo mutants does not run bare",
  "  why  scripts/check/mutants.mjs gives cargo-mutants an empty HOME and a short fixed list of variables; that keeps a mutated path away from the real home",
  "  fix  make mutants   (FILE=<path> for every mutant of one file, ALL=1 for the whole workspace)",
  "  then run make mutants in place of the command; cargo mutants --list runs nothing and is not refused",
  "",
].join("\n");
const LAUNCH_REFUSAL = [
  "✗ bash: a built app or a release binary does not launch with its channel unpinned",
  "  why  a release build resolves the installed channel: it attaches to the user's daemon and, on a version mismatch, SIGTERMs and replaces it, with every terminal that daemon owns",
  "  fix  make run   (it pins the channel for you), or set TARMAC_SOCKET, TARMAC_STATE and TARMAC_CONFIG_DIR to paths of your own in the same command",
  "  then TARMAC_SOCKET=$PWD/.dev/rel/tarmacd.sock TARMAC_STATE=$PWD/.dev/rel/state.json TARMAC_CONFIG_DIR=$PWD/.dev/rel/config <the command>",
  "",
].join("\n");

for (const [command, err] of [
  ["cargo mutants", MUTANTS_REFUSAL],
  ["cd core && cargo mutants --in-diff d.diff", MUTANTS_REFUSAL],
  ["sudo sh -c 'cargo-mutants mutants'", MUTANTS_REFUSAL],
  ["rustup run stable cargo mutants", MUTANTS_REFUSAL],
  ["open dist/Tarmac.app", LAUNCH_REFUSAL],
  ["make bundle && open dist/Tarmac.app", LAUNCH_REFUSAL],
  ["TARMAC_SOCKET=a TARMAC_STATE=b core/target/release/tarmacd", LAUNCH_REFUSAL],
  ["bash -c 'app/.build/release/TarmacApp' | cat", LAUNCH_REFUSAL],
]) {
  test(`#496: \`${command}\` is refused with its own reason and next step`, () => {
    assert.deepEqual(hook("bash", bashOf(command)), { code: 2, out: "", err });
  });
}

for (const command of [
  "make mutants FILE=core/crates/tarmacd/src/main.rs",
  "cargo mutants --list",
  "cargo install cargo-mutants --version 27.1.0 --locked",
  'grep -rn "cargo mutants" CLAUDE.md',
  "make run",
  "make bundle",
  "codesign --verify --deep --strict dist/Tarmac.app",
  "open /Applications/Tarmac.app",
  "TARMAC_SOCKET=a TARMAC_STATE=b TARMAC_CONFIG_DIR=c open dist/Tarmac.app",
  "core/target/debug/tarmacd",
]) {
  test(`#496: \`${command}\` passes`, () => {
    assert.deepEqual(hook("bash", bashOf(command)), QUIET);
  });
}

test("#496: text too deep to read is refused by each new rule's words, in its own reason", () => {
  const deep = (tail) => `${"eval ".repeat(25)}${tail}`;

  assert.deepEqual(hook("bash", bashOf(deep("cargo mutants"))), { code: 2, out: "", err: MUTANTS_REFUSAL });
  assert.deepEqual(hook("bash", bashOf(deep("open dist/Tarmac.app"))), { code: 2, out: "", err: LAUNCH_REFUSAL });
  assert.deepEqual(hook("bash", bashOf(deep("cargo mutants --list"))), QUIET);
});

test("#496: twenty thousand exports before an unpinned launch are read well inside the hook's ten seconds", () => {
  const started = Date.now();
  const exports = Array.from({ length: 20000 }, (_, i) => `export V${i}=1;`).join(" ");

  const run = hook("bash", bashOf(`${exports} open dist/Tarmac.app`));

  assert.deepEqual(run, { code: 2, out: "", err: LAUNCH_REFUSAL });
  assert.ok(Date.now() - started < 5000);
});

test("#496: a line that two rules refuse is refused once, by the kill rule first", () => {
  const run = hook("bash", bashOf("cargo mutants; open dist/Tarmac.app; pkill tarmacd"));

  assert.equal(run.code, 2);
  assert.deepEqual(run.err.match(/^✗ .*$/gm), ["✗ bash: a Tarmac process is not killed by name"]);
});

test("a megabyte of piped commands is read well inside the hook's ten seconds", () => {
  const started = Date.now();

  const runs = ["a|xargs pkill x;".repeat(65536), "sudo ".repeat(200000), `${"pgrep tarmacd;".repeat(30000)}${"kill 1;".repeat(30000)}`].map((command) => hook("bash", bashOf(command)).code);

  assert.deepEqual(runs, [0, 0, 0]);
  assert.ok(Date.now() - started < 5000);
});

test("an input that is not JSON, and an event the adapter does not know, pass", () => {
  const raw = spawnSync(process.execPath, [HOOK, "stop"], { input: "not json", encoding: "utf8" });

  assert.equal(raw.status, 0);
  assert.deepEqual(hook("launch", {}), QUIET);
});

// ---------------------------------------------------------------- staged

// A one-crate workspace whose lint table refuses a `todo!()`.
const PROBE = `[package]\nname = "probe"\nversion = "0.1.0"\nedition = "2024"\n\n[lints.clippy]\ntodo = "warn"\n\n${CARGO}`;
const stagedIn = (dir, env = process.env) => {
  const run = spawnSync(process.execPath, [join(dir, "scripts/check/staged.mjs")], { cwd: dir, encoding: "utf8", env });
  return { code: run.status, err: run.stderr };
};
const stage = (dir, ...paths) => execFileSync("git", ["add", ...paths], { cwd: dir });

test("S13: nothing staged passes", () => {
  assert.deepEqual(stagedIn(repo()), { code: 0, err: "" });
});

test("S13: a staged file with a finding is named; an unstaged one is not", () => {
  const dir = repo();
  write(dir, { "app/Staged.swift": UNWRAP, "app/Loose.swift": UNWRAP });
  stage(dir, "app/Staged.swift");

  const run = stagedIn(dir);

  assert.equal(run.code, 1);
  assert.deepEqual(run.err.match(/^ {2}at .*$/gm), ["  at   app/Staged.swift:2:13 NeverForceUnwrap"]);
});

// git gives a hook GIT_DIR in a linked worktree; `--show-toplevel` then answers with the current directory (#502).
const asAWorktreeHook = (dir) => ({ ...process.env, GIT_DIR: join(dir, ".git"), GIT_INDEX_FILE: join(dir, ".git/index") });
const KEPT = "func f(_ x: Int?) -> Int {\n    // The caller checked it.\n    // swift-format-ignore: NeverForceUnwrap\n    let y = x!\n    return y\n}\n";

test("#502: under a worktree's hook environment a staged file is judged from the repository root", () => {
  const dir = repo();
  write(dir, { "app/Sources/Kept.swift": KEPT, "app/Sources/Staged.swift": UNWRAP });
  stage(dir, "app/Sources/Kept.swift", "app/Sources/Staged.swift");

  const run = stagedIn(dir, asAWorktreeHook(dir));

  assert.equal(run.code, 1);
  assert.deepEqual(run.err.match(/^ {2}at .*$|^ {7}\S.*$/gm), ["  at   app/Sources/Staged.swift:2:13 NeverForceUnwrap"]);
});

test("#502: the root of a directory is the top of its work tree, whatever GIT_DIR a hook was given", () => {
  const dir = repo({ "app/Sources/A.swift": "" });
  const probe = `import { repoRoot } from ${JSON.stringify(join(dir, "scripts/check/git.mjs"))}; console.log(repoRoot(${JSON.stringify(join(dir, "app/Sources"))}));`;

  const run = spawnSync(process.execPath, ["--input-type=module", "-e", probe], { cwd: dir, encoding: "utf8", env: asAWorktreeHook(dir) });

  assert.equal(run.stdout.trim(), dir);
});

test("S13: a staged Rust file brings clippy in, with the workspace's lint table", () => {
  const dir = repo({ "core/Cargo.toml": PROBE, "core/src/main.rs": "fn main() {}\n" });
  write(dir, { "core/src/main.rs": "fn main() {\n    todo!()\n}\n" });
  stage(dir, "core/src/main.rs");

  const run = stagedIn(dir);

  assert.equal(run.code, 1);
  assert.match(run.err, /^ {2}at {3}core\/src\/main\.rs:2:5 clippy::todo$/m);
});

test("S13: a staged Swift file alone does not start clippy", () => {
  const dir = repo({ "core/Cargo.toml": PROBE, "core/src/main.rs": "fn main() {\n    todo!()\n}\n" });
  write(dir, { "app/A.swift": "let x = 1\n" });
  stage(dir, "app/A.swift");

  assert.deepEqual(stagedIn(dir), { code: 0, err: "" });
});

test("S28: a check that cannot run is exit 2, and a staged deletion alone passes", () => {
  const dir = repo({ "app/Old.swift": "let x = 1\n" });
  execFileSync("git", ["rm", "-q", "app/Old.swift"], { cwd: dir });
  const deleted = stagedIn(dir);
  write(dir, { "app/New.swift": "let x = 1\n" });
  stage(dir, "app/New.swift");

  const blocked = stagedIn(dir, oldSwift());

  assert.deepEqual(deleted, { code: 0, err: "" });
  assert.equal(blocked.code, 2);
  assert.match(blocked.err, /cannot run swift-format/);
});

test("S13: the rules about the whole tree run with a commit too", () => {
  const dir = repo({ ".gitignore": "DOCS_BROKEN\n" });
  write(dir, { DOCS_BROKEN: "" });

  assert.deepEqual(stagedIn(dir), { code: 1, err: "docs-check: 1 problem(s)\n" });
});

// -------------------------------------------------------- the hook files

test("S14: each git hook runs one command, and it is a make target or a script under scripts/check", () => {
  const text = readFileSync(join(HERE, "../../lefthook.yml"), "utf8");
  const hooks = {};
  let current;
  for (const line of text.split("\n")) {
    const top = line.match(/^([a-z-]+):\s*$/)?.[1];
    if (top) hooks[(current = top)] = [];
    const run = line.match(/^\s+run:\s*(.+)$/)?.[1];
    if (run) hooks[current].push(run);
  }

  assert.deepEqual(Object.keys(hooks), ["pre-commit", "commit-msg", "pre-push"]);
  for (const runs of Object.values(hooks)) {
    assert.equal(runs.length, 1);
    assert.match(runs[0], /^(make [a-z-]+|node scripts\/check\/[a-z-]+\.mjs( \{1\})?)$/);
    const script = runs[0].match(/scripts\/check\/[a-z-]+\.mjs/)?.[0];
    if (script) assert.ok(existsSync(join(HERE, "../..", script)), script);
  }
});

test("the agent hooks call the adapter with an event it knows, and name no rule of their own", () => {
  const { hooks } = JSON.parse(readFileSync(join(HERE, "../../.claude/settings.json"), "utf8"));
  const commands = Object.entries(hooks).flatMap(([event, groups]) => groups.flatMap((group) => group.hooks.map((one) => [event, group.matcher ?? null, one.command])));

  assert.deepEqual(commands, [
    ["PostToolUse", "Edit|Write", 'node "$CLAUDE_PROJECT_DIR/scripts/check/hook.mjs" edit'],
    ["Stop", null, 'node "$CLAUDE_PROJECT_DIR/scripts/check/hook.mjs" stop'],
    ["PreToolUse", "Bash", 'node "$CLAUDE_PROJECT_DIR/scripts/check/hook.mjs" bash'],
  ]);
});

test("staged: a check that throws could not run: exit 2 and the reporter's form, never a finding", () => {
  // A git that names a root which is not there: the next git started in it cannot start, and has no output to read.
  const bin = scratch();
  writeFileSync(join(bin, "git"), `#!/bin/sh\necho ${JSON.stringify(join(bin, "gone"))}\n`, { mode: 0o755 });

  const run = spawnSync(process.execPath, [join(HERE, "staged.mjs")], { cwd: bin, encoding: "utf8", env: { ...process.env, PATH: bin } });
  const err = run.stderr.split("\n");

  assert.equal(run.status, 2);
  assert.equal(err[0], "✗ staged: the check itself failed");
  assert.match(err[1], /^ {2}why {2}\S/);
  assert.deepEqual(err.slice(-3), ["  fix  git commit", "  then git commit", ""]);
});

test("staged: outside a git repository the check cannot run, in the reporter's form", () => {
  const run = spawnSync(process.execPath, [join(HERE, "staged.mjs")], { cwd: scratch(), encoding: "utf8" });

  assert.equal(run.status, 2);
  assert.equal(run.stderr, "✗ staged: not in a git repository\n  fix  run it from inside the repository\n  then git commit\n");
});

test("staged: a git that cannot list the staged files is exit 2 with git's message, never a pass", () => {
  const dir = repo();
  write(dir, { "app/Loose.swift": "let  x=1\n" });
  stage(dir, "app/Loose.swift");
  const realGit = spawnSync("sh", ["-c", "command -v git"], { encoding: "utf8" }).stdout.trim();
  const bin = scratch();
  const stub = `#!/bin/sh\nif [ "$1 $2" = "diff --cached" ]; then echo "fatal: index file corrupt" >&2; echo "fatal: second line" >&2; exit 128; fi\nexec ${JSON.stringify(realGit)} "$@"\n`;
  writeFileSync(join(bin, "git"), stub, { mode: 0o755 });

  const run = spawnSync(process.execPath, [join(dir, "scripts/check/staged.mjs")], { cwd: dir, encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });

  assert.notEqual(run.status, 0);
  assert.equal(run.status, 2);
  assert.equal(run.stderr, "✗ staged: cannot read the staged files\n  why  fatal: index file corrupt\n       fatal: second line\n  fix  git status\n  then git commit\n");
});
