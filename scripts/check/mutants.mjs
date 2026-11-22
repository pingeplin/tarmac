// Mutation testing for the Rust workspace (spec 2611.0032): cargo-mutants
// changes one expression at a time in the lines a branch changed and runs the
// tests; a change that no test saw is a finding.
//
// A mutant is the product with one wrong expression, run on this machine. So
// the tool gets a new empty home and only the variables named below: a mutated
// path, and a shell that a mutated daemon starts, cannot reach the real home.

import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";
import { cannotRunFor, failure } from "./report.mjs";

/** The cargo-mutants this check was built on. `.github/workflows/mutants.yml` installs the same one. */
export const VERSION = "27.1.0";

const RULE = "mutants";
const THEN = "make mutants";
const INSTALL = `cargo install cargo-mutants --version ${VERSION} --locked`;
const USAGE = "usage: mutants.mjs [--base <ref>] [--all [--shard <k>/<n>]] [--jobs <n>] [--report]\n";
const cannotRun = cannotRunFor(RULE, THEN);

// What the caller may hand to the tool. Every other variable is dropped: one
// that moves a path (`TARMAC_SOCKET`, `CLAUDE_CONFIG_DIR`, `ZDOTDIR`) must not
// reach a mutant, and `RUSTUP_TOOLCHAIN` would overrule rust-toolchain.toml.
const PASSED = ["PATH", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME", "SHELL", "CARGO_TERM_COLOR", "NO_COLOR", "CI", "GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_TEMP"];
// The diff must look the same whatever the user's git config says: the tool
// reads only a `b/` prefix, and a diff it cannot match tests nothing and passes.
// A path with a letter outside ASCII is written as it is, not as a quoted escape.
const DIFF = ["-c", "core.quotePath=false", "diff", "--src-prefix=a/", "--dst-prefix=b/", "--no-ext-diff", "--no-textconv", "--no-color"];

const blocked = (text) => ({ code: 2, text });

/** The options of a run, or null for arguments this check does not know. */
function parse(args) {
  const options = { base: "origin/main", all: false, shard: null, jobs: "2", report: false };
  const valued = { "--base": ["base", /./], "--shard": ["shard", /^\d+\/[1-9]\d*$/], "--jobs": ["jobs", /^[1-9]\d*$/] };
  for (let at = 0; at < args.length; at++) {
    if (args[at] === "--all") options.all = true;
    else if (args[at] === "--report") options.report = true;
    else if (args[at] in valued) {
      const [name, form] = valued[args[at]];
      const value = args[++at];
      if (value === undefined || !form.test(value)) return null;
      options[name] = value;
    } else return null;
  }
  return options.shard && !options.all ? null : options;
}

function git(cwd, args, passes = [0]) {
  const run = spawnSync("git", args, { cwd, encoding: "utf8", maxBuffer: 256 << 20 });
  return passes.includes(run.status) ? run.stdout : null;
}

/** The Rust changes under `core/` since the branch left `base`, as a diff with paths from `core/`; `{ text }` or a blocked result. */
function rustDiff(core, base) {
  if (git(core, ["rev-parse", "--verify", "--quiet", `${base}^{commit}`]) === null) return blocked(cannotRun(`${base} names no commit`, ["the mutants are those in the lines changed since the branch left its base"], `git fetch origin, or name the base: make mutants BASE=<ref>`));
  const from = git(core, ["merge-base", base, "HEAD"])?.trim();
  if (!from) return blocked(cannotRun(`${base} and HEAD share no history`, ["the mutants are those in the lines changed since the branch left its base"], "make mutants BASE=<ref>"));
  const tracked = git(core, [...DIFF, "--relative", from, "--", "*.rs"]);
  // A file that is not yet committed is mutated like the rest. `--no-index` exits 1 when the two differ.
  const untracked = git(core, ["ls-files", "--others", "--exclude-standard", "-z", "--", "*.rs"])
    ?.split("\0")
    .filter(Boolean)
    .map((file) => git(core, [...DIFF, "--no-index", "--", "/dev/null", file], [0, 1]));
  const parts = [tracked, ...(untracked ?? [null])];
  // A git command that failed is not an empty diff: that would be a pass with nothing tested.
  if (parts.includes(null)) return blocked(cannotRun("cannot read the changes from git", ["a `git diff` or `git ls-files` in core/ failed"], "git status"));
  return { text: parts.join("") };
}

/** The environment of the tool: the stand-in home, the real cargo and rustup, and the passed names. Null when cargo and rustup cannot be placed. */
function environment(caller, home) {
  const placed = (name, directory) => caller[name] ?? (caller.HOME ? join(caller.HOME, directory) : null);
  const [cargo, rustup] = [placed("CARGO_HOME", ".cargo"), placed("RUSTUP_HOME", ".rustup")];
  if (!cargo || !rustup) return null;
  const kept = Object.fromEntries(PASSED.filter((name) => caller[name] !== undefined).map((name) => [name, caller[name]]));
  return { ...kept, HOME: home, CARGO_HOME: cargo, RUSTUP_HOME: rustup };
}

/** Null when the pinned tool is there, else the "cannot run" text. */
function toolProblem(core, env) {
  const run = spawnSync("cargo", ["mutants", "--version"], { cwd: core, env, encoding: "utf8" });
  const found = run.status === 0 ? /^cargo-mutants (\S+)/.exec(run.stdout)?.[1] : null;
  if (found === VERSION) return null;
  if (found) return cannotRun("cannot run cargo-mutants", [`cargo-mutants ${found} is installed; this check needs ${VERSION}`, "another version makes other mutants, so a run here and one in CI would not agree"], INSTALL);
  return cannotRun("cannot run cargo-mutants", [run.error?.code === "ENOENT" ? "cargo is not on the PATH" : "cargo has no `mutants` command"], INSTALL);
}

const linesOf = (out, name) => (existsSync(join(out, name)) ? readFileSync(join(out, name), "utf8").split("\n").filter(Boolean) : []);

/** The result of a tool run: the exit code of this check and what to say. */
function verdict(code, out) {
  const missed = linesOf(out, "missed.txt");
  const timedOut = linesOf(out, "timeout.txt").map((line) => `${line} (the tests did not end)`);
  if (code === 0) {
    const unviable = linesOf(out, "unviable.txt").length;
    return { code: 0, text: `mutants: ${linesOf(out, "caught.txt").length} changes to the code tried, each one seen by a test${unviable ? ` (${unviable} more did not compile)` : ""}\n` };
  }
  if (code === 4) return blocked(cannotRun("the tests fail with no mutation", ["a mutant is judged by a test that fails, so the tests must pass first"], "make test"));
  if (code === 5 || code === 6) return blocked(cannotRun("the diff does not fit the tree", ["cargo-mutants could not match the changed lines with the files on disk"], "git status"));
  if (code !== 2 && code !== 3) return blocked(cannotRun(`cargo-mutants ended with exit code ${code}`, ["see its output above"], THEN));
  if ((code === 2 ? missed : timedOut).length === 0) return blocked(cannotRun("cannot read the result of cargo-mutants", [`it ended with exit code ${code}, and its result files name no such mutant`], THEN));
  const at = [...missed, ...timedOut];
  const text = failure({
    rule: RULE,
    summary: `${at.length} ${at.length === 1 ? "change" : "changes"} to the code that no test saw`,
    at,
    why: [
      "each line is a change the tool made to the code; the tests still passed, so no test holds that behaviour",
      ...(timedOut.length ? ["a time-out is not a catch: add a test that fails fast, or exclude the mutant with its reason"] : []),
    ],
    fix: "add a test that fails with that change (see the change: core/mutants.out/diff/), or list the mutant in core/.cargo/mutants.toml with the reason it cannot be seen",
    then: THEN,
  });
  return { code: 1, text };
}

function run(options, root, caller) {
  const core = join(root, "core");
  if (!existsSync(core)) return blocked(cannotRun("this repository has no core/ directory", ["the Rust workspace is core/"], "cd to the Tarmac repository"));
  const diff = options.all ? null : rustDiff(core, options.base);
  if (diff?.code) return diff;
  if (diff?.text === "") return { code: 0, text: `mutants: no Rust change against ${options.base}\n` };

  const temporary = mkdtempSync(join(tmpdir(), "tarmac-mutants-"));
  try {
    const env = environment(caller, join(temporary, "home"));
    if (!env) return blocked(cannotRun("HOME is not set", ["cargo and rustup are looked for under the home directory; the tool itself gets another, empty one"], "set HOME, or CARGO_HOME and RUSTUP_HOME"));
    mkdirSync(env.HOME);
    const problem = toolProblem(core, env);
    if (problem) return blocked(problem);
    const scope = diff ? ["--in-diff", join(temporary, "in.diff")] : options.shard ? ["--shard", options.shard] : [];
    if (diff) writeFileSync(scope[1], diff.text);
    // The tool writes no result when it finds no mutant, and an earlier run's files would be read as this one's.
    rmSync(join(core, "mutants.out"), { recursive: true, force: true });
    // The tool's progress is for the person who waits; stdout stays empty like the other checks'.
    const tool = spawnSync("cargo", ["mutants", "--workspace", "--no-shuffle", "--jobs", options.jobs, ...scope, "--output", core], { cwd: core, env, stdio: ["ignore", 2, 2] });
    return verdict(tool.status, join(core, "mutants.out"));
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

/** With `--report` a survivor is worded and written to the job summary, and fails nothing. */
function reported(result, caller) {
  if (result.code !== 1) return result;
  if (caller.GITHUB_STEP_SUMMARY) appendFileSync(caller.GITHUB_STEP_SUMMARY, `\`\`\`\n${result.text}\`\`\`\n`);
  return { ...result, code: 0 };
}

function main(args, cwd, caller) {
  const options = parse(args);
  if (!options) return { code: 2, text: USAGE };
  const root = repoRoot(cwd);
  if (!root) return blocked(cannotRun("not in a git repository", ["the mutants are those in the lines a branch changed"], "cd to the repository"));
  // An exception here would end node with exit 1, which says "a mutant survived".
  try {
    const result = run(options, root, caller);
    return options.report ? reported(result, caller) : result;
  } catch (error) {
    return blocked(cannotRun("the check itself failed", [String(error?.message ?? error)], THEN));
  }
}

if (startedAs(import.meta)) {
  const { code, text } = main(process.argv.slice(2), process.cwd(), process.env);
  process.stderr.write(text);
  process.exit(code);
}
