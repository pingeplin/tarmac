import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { test } from "node:test";

import "./test-env.mjs";

import { atRows, git, rowOf, runScript, scratchIn, write } from "./test-support.mjs";

import { VERSION } from "./mutants.mjs";

const HERE = import.meta.dirname;
const ROOT = join(HERE, "../..");
const SCRIPT = join(HERE, "mutants.mjs");
const SOURCE = "core/crates/x/src/a.rs";
const scratch = scratchIn("mutants-test-");

const AS_SOMEONE = ["-c", "user.name=t", "-c", "user.email=t@example.com"];

/** A repository with one commit on `main` (the base of every run here) and a branch `work` checked out. */
function repo(files = {}) {
  const dir = scratch();
  write(dir, { [SOURCE]: "fn a() -> u8 {\n    1\n}\n", "README.md": "x\n", ...files });
  git(dir, "init", "-q", "-b", "main");
  git(dir, "add", "-A");
  git(dir, ...AS_SOMEONE, "commit", "-q", "-m", "base");
  git(dir, "checkout", "-q", "-b", "work");
  return dir;
}

function commit(dir, files) {
  write(dir, files);
  git(dir, "add", "-A");
  git(dir, ...AS_SOMEONE, "commit", "-q", "-m", "change");
}

/** A repository whose branch changed the one Rust file under `core/`. */
function changed() {
  const dir = repo();
  commit(dir, { [SOURCE]: "fn a() -> u8 {\n    2\n}\n" });
  return dir;
}

// The stand-in for `cargo`: it answers `mutants --version`, writes down what it
// was given, writes the result files it is told to, and exits as it is told to.
const STAND_IN = `#!/usr/bin/env node
const { appendFileSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
// Each test has a link to this one file in a directory of its own, with its plan beside the link.
const here = require("node:path").dirname(process.argv[1]);
const plan = JSON.parse(readFileSync(join(here, "plan.json"), "utf8"));
const args = process.argv.slice(2);
if (args[1] === "--version") {
  if (plan.version === null) {
    console.error("error: no such command: \`mutants\`");
    process.exit(101);
  }
  console.log("cargo-mutants " + plan.version);
  process.exit(0);
}
const diffAt = args.indexOf("--in-diff");
const outAt = args.indexOf("--output");
const call = { args, env: process.env, cwd: process.cwd(), diff: diffAt < 0 ? null : readFileSync(args[diffAt + 1], "utf8") };
call.homeEntries = require("node:fs").readdirSync(process.env.HOME);
call.temporary = diffAt < 0 ? process.env.HOME : args[diffAt + 1];
appendFileSync(join(here, "calls.jsonl"), JSON.stringify(call) + "\\n");
console.log("progress line of the tool");
const out = join(args[outAt + 1], "mutants.out");
mkdirSync(out, { recursive: true });
for (const [name, lines] of Object.entries(plan.files ?? {})) writeFileSync(join(out, name), lines.map((line) => line + "\\n").join(""));
if (plan.signal) process.kill(process.pid, plan.signal);
process.exit(plan.exit ?? 0);
`;

// macOS takes about a second to start an executable file for the first time,
// so the stand-in is one file that every test links to.
let standInFile = null;
function standIn() {
  if (standInFile) return standInFile;
  standInFile = join(scratch("mutants-stand-in-"), "cargo");
  writeFileSync(standInFile, STAND_IN);
  chmodSync(standInFile, 0o755);
  return standInFile;
}

/** A PATH with git and nothing else, so no cargo of this machine is found. */
function onlyGit() {
  const bin = scratch("mutants-bin-");
  symlinkSync(execFileSync("which", ["git"], { encoding: "utf8" }).trim(), join(bin, "git"));
  return bin;
}

/** A directory with the stand-in `cargo`, set to answer as `plan` says. */
function tool(plan = {}) {
  const dir = scratch("mutants-tool-");
  symlinkSync(standIn(), join(dir, "cargo"));
  writeFileSync(join(dir, "plan.json"), JSON.stringify({ version: VERSION, ...plan }));
  return dir;
}

const calls = (toolDir) =>
  existsSync(join(toolDir, "calls.jsonl"))
    ? readFileSync(join(toolDir, "calls.jsonl"), "utf8")
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line))
    : [];

/** Runs the check in `dir` with the stand-in first on the PATH. `base` is `main` unless the arguments name one. */
function mutants(dir, toolDir, args = ["--base", "main"], env = {}) {
  const home = scratch("mutants-home-");
  const path = [toolDir, process.env.PATH].filter(Boolean).join(delimiter);
  return { ...runScript(SCRIPT, args, { cwd: dir, env: { PATH: path, HOME: home, TMPDIR: tmpdir(), ...env } }), home };
}

const MISSED = ["crates/x/src/a.rs:2:5: replace a -> u8 with 0", "crates/x/src/a.rs:2:5: replace a -> u8 with 1"];
const TIMED_OUT = "crates/x/src/a.rs:9:5: replace wait -> bool with true";
const WHY = "each line is a change the tool made to the code; the tests still passed, so no test holds that behaviour";
const FIX = "add a test that fails with that change (see the change: core/mutants.out/diff/), or list the mutant in core/.cargo/mutants.toml with the reason it cannot be seen";
const INSTALL = `cargo install cargo-mutants --version ${VERSION} --locked`;

test("No Rust change exits 0 without the tool / Unchanged branch is no Rust change: with no Rust change against the base the check passes and does not start the tool", () => {
  const cargo = tool();
  const untouched = mutants(repo(), cargo);
  const docsOnly = repo();
  commit(docsOnly, { "README.md": "y\n" });

  assert.deepEqual({ code: untouched.code, out: untouched.out, err: untouched.err }, { code: 0, out: "", err: "mutants: no Rust change against main\n" });
  assert.equal(mutants(docsOnly, cargo).code, 0);
  assert.deepEqual(calls(cargo), []);
});

test("No Rust change exits 0 without the tool: with no Rust change the check passes with no cargo on the PATH at all", () => {
  const dir = repo();
  const run = spawnSync(process.execPath, [SCRIPT, "--base", "main"], { cwd: dir, encoding: "utf8", env: { PATH: onlyGit(), HOME: scratch() } });

  assert.equal(run.status, 0);
  assert.match(run.stderr, /no Rust change/);
});

test("Changes outside core Rust files are no change: a Rust file outside core/, or another kind of file inside it, is no Rust change", () => {
  const cargo = tool();
  const dir = repo({ "scripts/x.rs": "fn a() {}\n", "core/Cargo.toml": "[workspace]\n" });
  commit(dir, { "scripts/x.rs": "fn b() {}\n", "core/Cargo.toml": "[workspace]\nresolver = \"3\"\n" });

  assert.equal(mutants(dir, cargo).code, 0);
  assert.deepEqual(calls(cargo), []);
});

test("Passing run exits 0 and prints the count / Zero mutants tested exits 0: a run in which every mutant was caught passes and says how many", () => {
  const three = mutants(changed(), tool({ exit: 0, files: { "caught.txt": ["a", "b", "c"], "missed.txt": [], "timeout.txt": [], "unviable.txt": ["d"] } }));
  const none = mutants(changed(), tool({ exit: 0 }));

  assert.equal(three.code, 0);
  assert.equal(three.out, "");
  assert.equal(three.err.split("\n").at(-2), "mutants: 3 changes to the code tried, each one seen by a test (1 more did not compile)");
  assert.doesNotMatch(three.err, /✗/);
  assert.equal(none.code, 0);
  assert.equal(none.err.split("\n").at(-2), "mutants: 0 changes to the code tried, each one seen by a test");
});

test("Passing run exits 0 and prints the count: the tool's own progress goes to stderr", () => {
  const run = mutants(changed(), tool({ exit: 0 }));

  assert.match(run.err, /^progress line of the tool$/m);
  assert.equal(run.out, "");
});

test("Missed mutants exit 1 with report / Single missed mutant uses singular summary: a missed mutant fails the check with the report of the contract", () => {
  const two = mutants(changed(), tool({ exit: 2, files: { "missed.txt": MISSED } }));
  const one = mutants(changed(), tool({ exit: 2, files: { "missed.txt": [MISSED[0]] } }));

  assert.equal(two.code, 1);
  assert.match(two.err, /^✗ mutants: 2 changes to the code that no test saw$/m);
  assert.deepEqual(atRows(two.err), MISSED);
  assert.equal(rowOf(two.err, "why"), WHY);
  assert.equal(rowOf(two.err, "fix"), FIX);
  assert.equal(rowOf(two.err, "then"), "make mutants");
  assert.match(one.err, /^✗ mutants: 1 change to the code that no test saw$/m);
});

test("Timed-out mutant is reported as missed: a time-out is listed with its suffix beside the missed mutants, and is no catch", () => {
  const run = mutants(changed(), tool({ exit: 3, files: { "missed.txt": [MISSED[0]], "timeout.txt": [TIMED_OUT] } }));

  assert.equal(run.code, 1);
  assert.match(run.err, /^✗ mutants: 2 changes to the code that no test saw$/m);
  assert.deepEqual(atRows(run.err).slice(0, 2), [MISSED[0], `${TIMED_OUT} (the tests did not end)`]);
  assert.match(run.err, /^ {7}a time-out is not a catch: add a test that fails fast, or exclude the mutant with its reason$/m);
});

test("Timed-out mutant is reported as missed: a time-out alone fails the check", () => {
  const run = mutants(changed(), tool({ exit: 3, files: { "timeout.txt": [TIMED_OUT] } }));

  assert.equal(run.code, 1);
  assert.match(run.err, /^✗ mutants: 1 change to the code that no test saw$/m);
});

test("Missing missed list exits 2 / Missing timeout list exits 2: an exit code that says missed or timed out, with no such mutant in the result files, cannot be read", () => {
  for (const plan of [{ exit: 2 }, { exit: 2, files: { "missed.txt": [] } }, { exit: 3 }, { exit: 3, files: { "timeout.txt": [], "missed.txt": [] } }]) {
    const run = mutants(changed(), tool(plan));

    assert.equal(run.code, 2, JSON.stringify(plan));
    assert.match(run.err, /^✗ mutants: cannot read the result of cargo-mutants$/m);
  }
});

test("Diff paths are relative to core: the diff names paths from core/ and holds committed and uncommitted changes", () => {
  const cargo = tool();
  const dir = changed();
  write(dir, { [SOURCE]: "fn a() -> u8 {\n    2\n}\nfn later() {}\n" });
  mutants(dir, cargo);
  const [{ diff, args, cwd }] = calls(cargo);

  assert.match(diff, /^\+\+\+ b\/crates\/x\/src\/a\.rs$/m);
  assert.doesNotMatch(diff, /core\/crates/);
  assert.match(diff, /^\+ {4}2$/m);
  assert.match(diff, /^\+fn later\(\) \{\}$/m);
  assert.equal(cwd, join(dir, "core"));
  assert.deepEqual(args.slice(0, 3), ["mutants", "--workspace", "--no-shuffle"]);
  assert.equal(args[args.indexOf("--output") + 1], join(dir, "core"));
});

test("Git config does not change the diff: the user's diff settings do not change the prefixes the tool needs", () => {
  for (const setting of ["diff.mnemonicPrefix", "diff.noprefix"]) {
    const cargo = tool();
    const dir = changed();
    git(dir, "config", setting, "true");
    write(dir, { [SOURCE]: "fn a() -> u8 {\n    3\n}\n" });
    mutants(dir, cargo);

    assert.match(calls(cargo)[0].diff, /^--- a\/crates\/x\/src\/a\.rs\n\+\+\+ b\/crates\/x\/src\/a\.rs$/m, setting);
  }
});

test("Untracked Rust file counts as added: a new Rust file that git does not track is in the diff as a whole, and the index stays as it was", () => {
  const cargo = tool();
  const dir = repo({ ".gitignore": "core/ignored/\n" });
  write(dir, { "core/crates/x/src/new.rs": "fn one() {}\nfn two() {}\n" });
  const before = git(dir, "status", "--porcelain");
  const run = mutants(dir, cargo);
  const [{ diff }] = calls(cargo);

  assert.equal(run.code, 0);
  assert.match(diff, /^\+\+\+ b\/crates\/x\/src\/new\.rs$/m);
  assert.match(diff, /^\+fn one\(\) \{\}\n\+fn two\(\) \{\}$/m);
  assert.equal(git(dir, "status", "--porcelain"), before);
});

test("Untracked Rust file counts as added: an ignored new Rust file, or one outside core/, is no Rust change", () => {
  const cargo = tool();
  const dir = repo({ ".gitignore": "core/ignored/\n" });
  write(dir, { "core/ignored/new.rs": "fn one() {}\n", "scripts/new.rs": "fn one() {}\n" });

  assert.match(mutants(dir, cargo).err, /no Rust change/);
  assert.deepEqual(calls(cargo), []);
});

test("All and shard options reach the tool / All ignores the base: --all starts the tool on the whole workspace, with a shard when one is named, and reads no base", () => {
  const cargo = tool();
  const dir = repo();
  mutants(dir, cargo, ["--all"]);
  mutants(dir, cargo, ["--all", "--shard", "3/8"]);
  mutants(dir, cargo, ["--base", "main", "--all"]);
  mutants(dir, cargo, ["--all", "--base", "no-such-ref"]);
  const given = calls(cargo).map(({ args }) => args);

  assert.equal(given.length, 4);
  assert.deepEqual(given.map((args) => args.includes("--in-diff")), [false, false, false, false]);
  assert.deepEqual(given.map((args) => (args.includes("--shard") ? args[args.indexOf("--shard") + 1] : null)), [null, "3/8", null, null]);
});

test("File option runs one file: --file starts the tool on every mutant of one file, named from core/, and reads no base", () => {
  const cargo = tool({ files: { "caught.txt": ["a"] } });
  const dir = repo();
  mutants(dir, cargo, ["--file", SOURCE]);
  mutants(dir, cargo, ["--file", SOURCE, "--base", "no-such-ref"]);
  const fromInside = mutants(join(dir, "core/crates"), cargo, ["--file", "x/src/a.rs"]);
  const given = calls(cargo).map(({ args }) => args);

  assert.equal(fromInside.code, 0, fromInside.err);
  assert.equal(given.length, 3);
  for (const args of given) {
    assert.equal(args[args.indexOf("--file") + 1], "crates/x/src/a.rs");
    assert.equal(args.includes("--in-diff"), false);
    assert.equal(args.includes("--shard"), false);
  }
});

test("File option rejects bad paths: --file with a path that is no Rust file of core/ cannot run, and the tool is not started", () => {
  const cargo = tool();
  const dir = repo({ "app/a.rs": "fn a() {}\n", "core/notes.md": "x\n" });
  for (const [path, why] of [["core/crates/x/src/gone.rs", "no such file"], ["app/a.rs", "not under core/"], ["core/notes.md", "not a Rust file"], ["core/crates/x/src", "not a Rust file"], ["core/crates/x/src/*.rs", "no such file"]]) {
    const run = mutants(dir, cargo, ["--file", path]);

    assert.equal(run.code, 2, path);
    assert.match(run.err, /^✗ mutants: --file /m, path);
    assert.ok(run.err.includes(why), `${path}: ${run.err}`);
  }
  assert.deepEqual(calls(cargo), []);
});

test("File with no mutant exits 2: --file with a file in which the tool finds no mutant cannot run", () => {
  const dir = repo({ "core/crates/x/tests/t.rs": "#[test]\nfn t() {}\n", "core/crates/x/src/a.rs.d/x.rs/keep": "" });
  const none = mutants(dir, tool({ exit: 0 }), ["--file", "core/crates/x/tests/t.rs"]);
  const onlyUnviable = mutants(dir, tool({ exit: 0, files: { "unviable.txt": ["a"] } }), ["--file", SOURCE]);
  const directory = mutants(dir, tool({ exit: 0, files: { "caught.txt": ["a"] } }), ["--file", "core/crates/x/src/a.rs.d/x.rs"]);

  assert.equal(none.code, 2);
  assert.match(none.err, /^✗ mutants: --file crates\/x\/tests\/t\.rs: the tool found no mutant in it$/m);
  assert.equal(onlyUnviable.code, 0, onlyUnviable.err);
  assert.equal(directory.code, 2);
  assert.match(directory.err, /not a Rust file/);
});

test("File option rejects bad combinations: --file does not go with --all or --shard, and --changed with it says true", () => {
  const cargo = tool();
  const dir = repo();
  for (const args of [["--file", SOURCE, "--all"], ["--all", "--file", SOURCE], ["--file"], ["--file", SOURCE, "--shard", "1/2"]]) {
    const run = mutants(dir, cargo, args);

    assert.equal(run.code, 2, args.join(" "));
    assert.match(run.err, /^usage: mutants\.mjs /m, args.join(" "));
  }
  const asked = mutants(dir, cargo, ["--file", SOURCE, "--changed"]);

  assert.deepEqual({ code: asked.code, out: asked.out, err: asked.err }, { code: 0, out: "true\n", err: "" });
  assert.deepEqual(calls(cargo), []);
});

test("Jobs option defaults to two: the tool gets two jobs, or the number that was named", () => {
  const cargo = tool();
  const dir = changed();
  mutants(dir, cargo);
  mutants(dir, cargo, ["--base", "main", "--jobs", "4"]);

  assert.deepEqual(calls(cargo).map(({ args }) => args[args.indexOf("--jobs") + 1]), ["2", "4"]);
});

test("Tool environment is scrubbed except HOME: the tool gets a new empty home and no variable that is not on the list", () => {
  const cargo = tool();
  const leaks = { TARMAC_SOCKET: "/x/s", TARMAC_STATE: "/x/t", TARMAC_TERM_ID: "t1", TARMAC_CONFIG_DIR: "/x/c", TARMAC_DEV_SOCKET: "/x/d", CLAUDE_CONFIG_DIR: "/x/claude", ZDOTDIR: "/x/z", GITHUB_ACTION: "run", RUSTUP_TOOLCHAIN: "nightly", SOME_OTHER_NAME: "1" };
  const run = mutants(changed(), cargo, ["--base", "main"], { ...leaks, GITHUB_ACTIONS: "true", LANG: "en_US.UTF-8", TERM: "xterm", NO_COLOR: "1" });
  const [{ env, homeEntries }] = calls(cargo);

  assert.deepEqual(Object.keys(leaks).filter((name) => name in env), []);
  assert.notEqual(env.HOME, run.home);
  assert.deepEqual(homeEntries, []);
  assert.equal(env.PATH.split(delimiter)[0], cargo);
  assert.deepEqual([env.GITHUB_ACTIONS, env.LANG, env.TERM, env.NO_COLOR], ["true", "en_US.UTF-8", "xterm", "1"]);
  const known = ["HOME", "CARGO_HOME", "RUSTUP_HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME", "SHELL", "CARGO_TERM_COLOR", "NO_COLOR", "CI", "GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_TEMP"];
  // macOS adds this one to every process it starts.
  assert.deepEqual(Object.keys(env).filter((name) => !known.includes(name) && name !== "__CF_USER_TEXT_ENCODING"), []);
});

test("Cargo and rustup homes come from caller HOME: cargo and rustup stay in the real home, or where the caller put them", () => {
  const cargo = tool();
  const plain = mutants(changed(), cargo);
  mutants(changed(), cargo, ["--base", "main"], { CARGO_HOME: "/elsewhere/cargo", RUSTUP_HOME: "/elsewhere/rustup" });
  const [first, second] = calls(cargo).map(({ env }) => [env.CARGO_HOME, env.RUSTUP_HOME]);

  assert.deepEqual(first, [join(plain.home, ".cargo"), join(plain.home, ".rustup")]);
  assert.deepEqual(second, ["/elsewhere/cargo", "/elsewhere/rustup"]);
});

test("Temporary directory is removed after every run: the temporary directory is gone after each outcome", () => {
  for (const plan of [{ exit: 0 }, { exit: 2, files: { "missed.txt": MISSED } }, { exit: 4 }]) {
    const cargo = tool(plan);
    mutants(changed(), cargo);
    const [{ temporary, env }] = calls(cargo);

    assert.equal(existsSync(temporary), false, JSON.stringify(plan));
    assert.equal(existsSync(env.HOME), false, JSON.stringify(plan));
  }
});

test("Missing tool exits 2 with install hint: with no cargo-mutants the check cannot run and gives the install command", () => {
  const cargo = tool({ version: null });
  const run = mutants(changed(), cargo);

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ mutants: cannot run cargo-mutants$/m);
  assert.equal(rowOf(run.err, "fix"), INSTALL);
  assert.equal(rowOf(run.err, "then"), "make mutants");
  assert.deepEqual(calls(cargo), []);
});

test("Missing tool exits 2 with install hint: with no cargo at all the check cannot run", () => {
  const dir = changed();
  const run = spawnSync(process.execPath, [SCRIPT, "--base", "main"], { cwd: dir, encoding: "utf8", env: { PATH: onlyGit(), HOME: scratch() } });

  assert.equal(run.status, 2);
  assert.match(run.stderr, /^✗ mutants: cannot run cargo-mutants$/m);
});

test("Wrong tool version exits 2: a tool of another version is refused before it is started on the tree", () => {
  const cargo = tool({ version: "26.0.0" });
  const run = mutants(changed(), cargo);

  assert.equal(run.code, 2);
  assert.match(run.err, new RegExp(`cargo-mutants 26\\.0\\.0 is installed; this check needs ${VERSION.replaceAll(".", "\\.")}`));
  assert.equal(rowOf(run.err, "fix"), INSTALL);
  assert.deepEqual(calls(cargo), []);
});

test("Tool exit codes four to six exit 2: a run the tool could not make is not a pass and not a finding", () => {
  const said = (exit) => {
    const run = mutants(changed(), tool({ exit, files: { "missed.txt": MISSED } }));
    return [run.code, run.err.split("\n").find((line) => line.startsWith("✗ "))];
  };

  assert.deepEqual(said(4), [2, "✗ mutants: the tests fail with no mutation"]);
  assert.deepEqual(said(5), [2, "✗ mutants: the diff does not fit the tree"]);
  assert.deepEqual(said(6), [2, "✗ mutants: the diff does not fit the tree"]);
  assert.deepEqual(said(70), [2, "✗ mutants: cargo-mutants ended with exit code 70"]);
  assert.deepEqual(said(1), [2, "✗ mutants: cargo-mutants ended with exit code 1"]);
});

test("Bad base or no repository exits 2 / Base with no merge base exits 2: a base that names no commit, or shares no history, cannot be used, and is named", () => {
  const cargo = tool();
  const dir = changed();
  git(dir, "checkout", "-q", "--orphan", "apart");
  git(dir, ...AS_SOMEONE, "commit", "-q", "-m", "apart");
  git(dir, "checkout", "-q", "work");
  const unknown = mutants(dir, cargo, ["--base", "no-such-ref"]);
  const unrelated = mutants(dir, cargo, ["--base", "apart"]);

  assert.equal(unknown.code, 2);
  assert.match(unknown.err, /^✗ mutants: no-such-ref names no commit$/m);
  assert.equal(unrelated.code, 2);
  assert.match(unrelated.err, /^✗ mutants: apart and HEAD share no history$/m);
  assert.deepEqual(calls(cargo), []);
});

test("Bad base or no repository exits 2: outside a git repository the check cannot run", () => {
  const run = mutants(scratch(), tool());

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ mutants: not in a git repository$/m);
});

test("Unknown argument or lone shard exits 2 / Bad jobs or shard values exit 2: arguments the check does not know end it with the usage, before the tool is started", () => {
  const cargo = tool();
  const dir = changed();
  for (const args of [["--frobnicate"], ["--shard", "3/8"], ["--all", "--jobs", "0"], ["--all", "--jobs", "x"], ["--all", "--shard", "3"], ["--all", "--shard", "x/8"], ["--base"], ["--all", "--jobs"]]) {
    const run = mutants(dir, cargo, args);

    assert.equal(run.code, 2, args.join(" "));
    assert.match(run.err, /^usage: mutants\.mjs /m, args.join(" "));
  }
  assert.deepEqual(calls(cargo), []);
});

test("Report option exits 0 and writes summary: --report words a survivor, writes it to the job summary, and still passes; a run that could not be made does not", () => {
  const dir = changed();
  const summary = join(scratch(), "summary.md");
  const survived = mutants(dir, tool({ exit: 2, files: { "missed.txt": MISSED } }), ["--base", "main", "--report"], { GITHUB_STEP_SUMMARY: summary });
  const broken = mutants(dir, tool({ exit: 4 }), ["--base", "main", "--report"], { GITHUB_STEP_SUMMARY: summary });

  assert.equal(survived.code, 0);
  assert.deepEqual(atRows(survived.err), MISSED);
  assert.deepEqual(MISSED.filter((line) => !readFileSync(summary, "utf8").includes(line)), []);
  assert.equal(broken.code, 2);
});

test("Report option exits 0 and writes summary: without --report the job summary is not written", () => {
  const summary = join(scratch(), "summary.md");
  const run = mutants(changed(), tool({ exit: 2, files: { "missed.txt": MISSED } }), ["--base", "main"], { GITHUB_STEP_SUMMARY: summary });

  assert.equal(run.code, 1);
  assert.equal(existsSync(summary), false);
});

test("Config excludes kill and is explained: the config excludes the one function that sends a signal, each exclusion has its reason above it, and git ignores the tool's output", () => {
  const lines = readFileSync(join(ROOT, "core/.cargo/mutants.toml"), "utf8").trimEnd().split("\n").map((line) => line.trim());
  const isEntry = (line) => /^"(?:[^"\\]|\\.)*",$/.test(line);
  const isReason = (line) => /^# \S/.test(line);

  assert.equal(lines[0], "exclude_re = [");
  assert.equal(lines.at(-1), "]");
  const body = lines.slice(1, -1);
  assert.deepEqual(body.filter((line) => !isEntry(line) && !isReason(line)), []);
  assert.ok(body.includes('"TermHandle::kill\\\\b",'));
  // An entry stands under its reason, or under another entry with the same reason.
  assert.deepEqual(body.filter((line, at) => isEntry(line) && (at === 0 || !(isReason(body[at - 1]) || isEntry(body[at - 1])))), []);
  assert.ok(isReason(body[0]));
  assert.ok(readFileSync(join(ROOT, ".gitignore"), "utf8").split("\n").includes("/core/mutants.out*/"));
});

test("Workflow matches pinned version and runs always: the workflow pins the script's version, runs on every pull request, and shards the weekly run", () => {
  const workflow = readFileSync(join(ROOT, ".github/workflows/mutants.yml"), "utf8");
  const [, triggers, jobs] = workflow.match(/^on:\n([\s\S]*?)^permissions:[\s\S]*?^jobs:\n([\s\S]*)$/m);
  const [, gateJob, diffJob, allJob] = jobs.match(/^ {2}rust-changed:\n([\s\S]*?)^ {2}in-diff:\n([\s\S]*?)^ {2}all:\n([\s\S]*)$/m);

  assert.deepEqual([...workflow.matchAll(/cargo-mutants@(\S+)/g)].map(([, version]) => version), [VERSION, VERSION]);
  assert.doesNotMatch(workflow, /paths(-ignore)?:/);
  assert.deepEqual(triggers.match(/^ {2}\w+:/gm), ["  pull_request:", "  schedule:", "  workflow_dispatch:"]);
  assert.match(gateJob, /if: github\.event_name == 'pull_request'/);
  assert.match(diffJob, /github\.event_name == 'pull_request'/);
  assert.match(gateJob, /fetch-depth: 0/);
  assert.match(diffJob, /fetch-depth: 0/);
  assert.match(diffJob, /run: make mutants BASE=origin\/\$\{\{ github\.base_ref \}\}$/m);
  assert.match(allJob, /if: github\.event_name != 'pull_request'/);
  assert.match(allJob, /shard: \[0, 1, 2, 3, 4, 5, 6, 7\]/);
  assert.match(allJob, /run: make mutants ALL=1 REPORT=1 SHARD=\$\{\{ matrix\.shard \}\}\/8$/m);
});

test("Make variables map to script options: make mutants hands its variables to the script as arguments", () => {
  const said = (...vars) => execFileSync("make", ["-n", "mutants", ...vars], { cwd: ROOT, encoding: "utf8" }).trim().split("scripts/check/mutants.mjs ")[1].replace(/\s+/g, " ");

  assert.equal(said(), "--base origin/main");
  assert.equal(said("BASE=origin/x"), "--base origin/x");
  assert.equal(said("ALL=1", "SHARD=3/8", "JOBS=4", "REPORT=1"), "--base origin/main --all --shard 3/8 --jobs 4 --report");
  assert.equal(said("FILE=core/crates/x/src/a.rs"), "--base origin/main --file core/crates/x/src/a.rs");
});

test("Zero mutants tested exits 0: the result files of an earlier run are not read as this run's", () => {
  const dir = changed();
  write(dir, { "core/mutants.out/caught.txt": "old one\nold two\n", "core/mutants.out/missed.txt": "old survivor\n" });
  const run = mutants(dir, tool({ exit: 0 }));

  assert.equal(run.code, 0);
  assert.equal(run.err.split("\n").at(-2), "mutants: 0 changes to the code tried, each one seen by a test");
});

test("Failed git command exits 2: a git command that fails is not read as no Rust change", () => {
  const cargo = tool();
  const dir = changed();
  const broken = scratch("mutants-git-");
  const real = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  writeFileSync(join(broken, "git"), `#!/bin/sh\nfor arg in "$@"; do [ "$arg" = "--relative" ] && exit 128; done\nexec ${real} "$@"\n`);
  chmodSync(join(broken, "git"), 0o755);
  const run = mutants(dir, cargo, ["--base", "main"], { PATH: [broken, cargo, process.env.PATH].join(delimiter) });

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ mutants: cannot read the changes from git$/m);
  assert.deepEqual(calls(cargo), []);
});

test("Diff holds only changes since merge base: the changes are those since the branch left the base, not those against the base as it is now", () => {
  const cargo = tool();
  const dir = changed();
  git(dir, "checkout", "-q", "main");
  commit(dir, { "core/crates/x/src/b.rs": "fn only_on_main() {}\n" });
  git(dir, "checkout", "-q", "work");
  mutants(dir, cargo);

  assert.doesNotMatch(calls(cargo)[0].diff, /only_on_main/);
});

test("Missing missed list exits 2 / Missing timeout list exits 2: the result file that the exit code points at decides, not the other one", () => {
  const missedButTimeoutCode = mutants(changed(), tool({ exit: 3, files: { "missed.txt": MISSED, "timeout.txt": [] } }));
  const timedOutButMissedCode = mutants(changed(), tool({ exit: 2, files: { "missed.txt": [], "timeout.txt": [TIMED_OUT] } }));

  assert.equal(missedButTimeoutCode.code, 2);
  assert.equal(timedOutButMissedCode.code, 2);
});

test("Report option exits 0 and writes summary: --report with no job summary to write still words the survivor and passes", () => {
  const run = mutants(changed(), tool({ exit: 2, files: { "missed.txt": MISSED } }), ["--base", "main", "--report"]);

  assert.equal(run.code, 0);
  assert.deepEqual(atRows(run.err), MISSED);
});

test("Default base is origin main: with no --base the base is origin/main", () => {
  const cargo = tool();
  const dir = changed();
  const noSuchRef = mutants(dir, cargo, []);
  git(dir, "update-ref", "refs/remotes/origin/main", "main");
  const found = mutants(dir, cargo, []);

  assert.match(noSuchRef.err, /^✗ mutants: origin\/main names no commit$/m);
  assert.equal(found.code, 0);
  assert.equal(calls(cargo).length, 1);
});

test("Tool environment is scrubbed except HOME: each name on the list reaches the tool with the caller's value", () => {
  const cargo = tool();
  const passed = { LANG: "a", LC_ALL: "b", TERM: "c", USER: "d", LOGNAME: "e", SHELL: "f", CARGO_TERM_COLOR: "g", NO_COLOR: "h", CI: "i", GITHUB_ACTIONS: "j", RUNNER_OS: "k", RUNNER_TEMP: "l" };
  mutants(changed(), cargo, ["--base", "main"], passed);
  const [{ env }] = calls(cargo);

  assert.deepEqual(Object.fromEntries(Object.keys(passed).map((name) => [name, env[name]])), passed);
  assert.equal(env.TMPDIR, tmpdir());
});

test("Missing HOME exits 2 unless homes are named: with no HOME of the caller the check cannot place cargo and rustup, and does not start the tool", () => {
  const cargo = tool();
  const dir = changed();
  const run = spawnSync(process.execPath, [SCRIPT, "--base", "main"], { cwd: dir, encoding: "utf8", env: { PATH: [cargo, process.env.PATH].join(delimiter) } });

  assert.equal(run.status, 2);
  assert.match(run.stderr, /^✗ mutants: HOME is not set$/m);
  assert.deepEqual(calls(cargo), []);
});

test("Missing HOME exits 2 unless homes are named: with CARGO_HOME and RUSTUP_HOME named, no HOME is needed", () => {
  const cargo = tool();
  const dir = changed();
  const run = spawnSync(process.execPath, [SCRIPT, "--base", "main"], { cwd: dir, encoding: "utf8", env: { PATH: [cargo, process.env.PATH].join(delimiter), CARGO_HOME: "/elsewhere/cargo", RUSTUP_HOME: "/elsewhere/rustup" } });

  assert.equal(run.status, 0);
});

test("Missing core directory exits 2: a repository with no core/ directory is named as that", () => {
  const dir = scratch();
  write(dir, { "README.md": "x\n" });
  git(dir, "init", "-q", "-b", "main");
  const said = (args) => mutants(dir, tool(), args).err.split("\n").find((line) => line.startsWith("✗ "));

  assert.equal(said(["--base", "main"]), "✗ mutants: this repository has no core/ directory");
  assert.equal(said(["--all"]), "✗ mutants: this repository has no core/ directory");
});

test("Internal failure exits 2: a failure of the check itself is cannot run, not a finding", () => {
  const dir = changed();
  const run = mutants(dir, tool({ exit: 2, files: { "missed.txt": MISSED } }), ["--base", "main", "--report"], { GITHUB_STEP_SUMMARY: join(dir, "no-such-directory/summary.md") });

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ mutants: the check itself failed$/m);
});

test("Untracked Rust file counts as added: an untracked file of another kind is no Rust change", () => {
  const cargo = tool();
  const dir = repo();
  write(dir, { "core/notes.md": "x\n" });

  assert.match(mutants(dir, cargo).err, /no Rust change/);
  assert.deepEqual(calls(cargo), []);
});

test("Git config does not change the diff: an external diff program, colour and quoted paths in the user's git config do not reach the diff", () => {
  const cargo = tool();
  const dir = changed();
  git(dir, "config", "diff.external", "false");
  git(dir, "config", "color.diff", "always");
  write(dir, { [SOURCE]: "fn a() -> u8 {\n    4\n}\n", "core/crates/x/src/naïve é.rs": "fn n() {}\n" });
  mutants(dir, cargo);
  const [{ diff }] = calls(cargo);

  assert.match(diff, /^\+ {4}4$/m);
  assert.doesNotMatch(diff, /\x1b\[/);
  assert.match(diff, /^\+\+\+ b\/crates\/x\/src\/naïve é\.rs\t?$/m);
});

test("Docs describe make mutants: the three documents name the command, and the workflow document its CI job", () => {
  const read = (path) => readFileSync(join(ROOT, path), "utf8");
  const claude = read("CLAUDE.md").split("\n## ").find((section) => section.startsWith("Build, run, test"));

  assert.match(claude, /^- `make mutants` — /m);
  assert.match(claude, new RegExp(`cargo-mutants --version ${VERSION.replaceAll(".", "\\.")} `));
  assert.match(read("docs/workflow.md"), /`make mutants`/);
  assert.match(read("CONTRIBUTING.md"), /`mutants \(rust, in diff\)`[\s\S]*`make mutants`/);
  assert.match(read("CONTRIBUTING.md"), new RegExp(`\`cargo-mutants\` ${VERSION.replaceAll(".", "\\.")}`));
});

test("Workflow matches pinned version and runs always: a weekly run is not cancelled by another event on the same branch", () => {
  const workflow = readFileSync(join(ROOT, ".github/workflows/mutants.yml"), "utf8");

  assert.match(workflow, /cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}/);
});

test("Changed option prints true or false: --changed answers on stdout whether a run would start the tool, and starts nothing", () => {
  const cargo = tool();
  const said = (dir, args = ["--base", "main", "--changed"]) => {
    const run = mutants(dir, cargo, args);
    return [run.code, run.out, run.err];
  };
  const untracked = repo();
  write(untracked, { "core/crates/x/src/new.rs": "fn one() {}\n" });

  assert.deepEqual(said(repo()), [0, "false\n", ""]);
  assert.deepEqual(said(changed()), [0, "true\n", ""]);
  assert.deepEqual(said(untracked), [0, "true\n", ""]);
  assert.deepEqual(said(repo(), ["--all", "--changed"]), [0, "true\n", ""]);
  assert.deepEqual(said(changed(), ["--base", "no-such-ref", "--changed"]).slice(0, 2), [2, ""]);
  assert.deepEqual(calls(cargo), []);
});

test("Changed option prints true or false: a Linux job asks whether there is a Rust change; the macOS job is skipped only on a clear no (#546)", () => {
  const workflow = readFileSync(join(ROOT, ".github/workflows/mutants.yml"), "utf8");
  const [, gateJob, diffJob] = workflow.match(/^ {2}rust-changed:\n([\s\S]*?)^ {2}in-diff:\n([\s\S]*?)^ {2}all:\n/m);
  const check = diffJob.split(/^ {6}- /m).find((step) => /run: make mutants/.test(step));

  assert.match(gateJob, /runs-on: ubuntu-latest/);
  assert.match(gateJob, /rust: \$\{\{ steps\.changed\.outputs\.rust \}\}/);
  assert.match(gateJob, /rust=\$\(node scripts\/check\/mutants\.mjs --changed --base origin\/\$\{\{ github\.base_ref \}\}\)\n\s+echo "rust=\$rust" >> "\$GITHUB_OUTPUT"/);
  assert.doesNotMatch(gateJob, /rustup|install-action/);
  assert.match(diffJob, /needs: rust-changed/);
  assert.match(diffJob, /!cancelled\(\)/);
  assert.match(diffJob, /needs\.rust-changed\.outputs\.rust != 'false'/);
  assert.doesNotMatch(gateJob, /echo "rust=\$\(/);
  assert.doesNotMatch(check, /\bif:/);
});

/** A `git` that fails with `code` when `word` is among its arguments, and is the real one otherwise. */
function gitFailingOn(word, code) {
  const bin = scratch("mutants-git-");
  const real = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  writeFileSync(join(bin, "git"), `#!/bin/sh\nfor arg in "$@"; do [ "$arg" = "${word}" ] && exit ${code}; done\nexec ${real} "$@"\n`);
  chmodSync(join(bin, "git"), 0o755);
  return bin;
}

test("Failed git command exits 2: a failed listing of the untracked files, or an untracked file that cannot be read, is not no Rust change", () => {
  const cargo = tool();
  const listing = mutants(changed(), cargo, ["--base", "main"], { PATH: [gitFailingOn("ls-files", 128), cargo, process.env.PATH].join(delimiter) });
  const unreadable = repo();
  mkdirSync(join(unreadable, "core/crates/y"), { recursive: true });
  symlinkSync("../../y", join(unreadable, "core/crates/x/src/links_to_a_directory.rs"));
  const link = mutants(unreadable, cargo);
  const gone = mutants(changedUntracked(), cargo, ["--base", "main"], { PATH: [gitFailingOn("--no-index", 1), cargo, process.env.PATH].join(delimiter) });

  for (const run of [listing, link, gone]) {
    assert.equal(run.code, 2);
    assert.match(run.err, /^✗ mutants: cannot read the changes from git$/m);
  }
  assert.deepEqual(calls(cargo), []);
});

function changedUntracked() {
  const dir = repo();
  write(dir, { "core/crates/x/src/new.rs": "fn one() {}\n" });
  return dir;
}

test("Git config does not change the diff: the diff of an untracked file has the same prefixes, whatever the user's settings", () => {
  for (const setting of ["diff.mnemonicPrefix", "diff.noprefix"]) {
    const cargo = tool();
    const dir = changedUntracked();
    git(dir, "config", setting, "true");
    mutants(dir, cargo);

    assert.match(calls(cargo)[0].diff, /^\+\+\+ b\/crates\/x\/src\/new\.rs$/m, setting);
  }
});

test("Git config does not change the diff: a text conversion in the user's git config does not reach the diff", () => {
  const cargo = tool();
  const dir = changed();
  write(dir, { ".gitattributes": "*.rs diff=shout\n", [SOURCE]: "fn a() -> u8 {\n    5\n}\nfn quiet() {}\n" });
  git(dir, "config", "diff.shout.textconv", "tr a-z A-Z <");
  mutants(dir, cargo);

  assert.match(calls(cargo)[0].diff, /^\+fn quiet\(\) \{\}$/m);
});

test("Temporary directory is removed after every run: nothing is left in the temp directory when the check stops before the tool is started", () => {
  const left = (plan, env = {}) => {
    const temp = scratch("mutants-tmp-");
    const run = mutants(changed(), tool(plan), ["--base", "main"], { TMPDIR: temp, ...env });
    return [run.code, readdirSync(temp)];
  };

  assert.deepEqual(left({ version: "26.0.0" }), [2, []]);
  assert.deepEqual(left({ version: null }), [2, []]);
  assert.deepEqual(left({ exit: 0 }), [0, []]);
});

test("Passing run exits 0 and prints the count: one caught mutant is one change", () => {
  const run = mutants(changed(), tool({ exit: 0, files: { "caught.txt": ["a"] } }));

  assert.equal(run.err.split("\n").at(-2), "mutants: 1 change to the code tried, and a test saw it");
});

test("Tool exit codes four to six exit 2: a tool that a signal ended is named as that", () => {
  const cargo = tool({ signal: "SIGKILL" });
  const run = mutants(changed(), cargo);

  assert.equal(run.code, 2);
  assert.match(run.err, /^✗ mutants: cargo-mutants was ended by SIGKILL$/m);
});

test("Git config does not change the diff: a Rust file that git takes for binary still gives its changed lines", () => {
  const cargo = tool();
  const dir = changed();
  write(dir, { ".git/info/attributes": "*.rs -diff\n", [SOURCE]: "fn a() -> u8 {\n    6\n}\n", "core/crates/x/src/nul.rs": "fn with_nul() {} // \0\n" });
  mutants(dir, cargo);
  const [{ diff }] = calls(cargo);

  assert.match(diff, /^\+ {4}6$/m);
  assert.match(diff, /^\+fn with_nul\(\) \{\} \/\/ \0$/m);
  assert.doesNotMatch(diff, /^Binary files /m);
});

test("Make variables map to script options: a variable of the same name in the environment does not change what make mutants runs", () => {
  const env = { ...process.env, ALL: "1", SHARD: "3/8", JOBS: "9", REPORT: "1" };
  const said = execFileSync("make", ["-n", "mutants"], { cwd: ROOT, encoding: "utf8", env }).trim().split("scripts/check/mutants.mjs ")[1];

  assert.equal(said, "--base origin/main");
});

test("Internal failure exits 2: a failure of the check itself names the error, and make mutants as the next command", () => {
  const dir = changed();
  const run = mutants(dir, tool({ exit: 2, files: { "missed.txt": MISSED } }), ["--base", "main", "--report"], { GITHUB_STEP_SUMMARY: join(dir, "no-such-directory/summary.md") });

  assert.equal(run.code, 2);
  assert.equal(run.out, "");
  assert.match(rowOf(run.err, "why"), /\S/);
  assert.deepEqual([rowOf(run.err, "fix"), rowOf(run.err, "then")], ["make mutants", "make mutants"]);
});
