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
const USAGE = "usage: mutants.mjs [--base <ref>] [--all [--shard <k>/<n>]] [--jobs <n>] [--report] [--changed]\n";
const cannotRun = cannotRunFor(RULE, THEN);

// What the caller may hand to the tool. Every other variable is dropped: one
// that moves a path (`TARMAC_SOCKET`, `CLAUDE_CONFIG_DIR`, `ZDOTDIR`) must not
// reach a mutant, and `RUSTUP_TOOLCHAIN` would overrule rust-toolchain.toml.
const PASSED = ["PATH", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME", "SHELL", "CARGO_TERM_COLOR", "NO_COLOR", "CI", "GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_TEMP"];
// The diff must look the same whatever the user's git config says: the tool
// reads only a `b/` prefix, and a diff it cannot match tests nothing and passes.
// A path with a letter outside ASCII is written as it is, not as a quoted escape.
const DIFF = ["-c", "core.quotePath=false", "diff", "--src-prefix=a/", "--dst-prefix=b/", "--no-ext-diff", "--no-textconv", "--no-color"];

/** A reason this check cannot run. Thrown where it is found, and worded as exit 2 in one place. */
class Blocked extends Error {
  constructor(summary, why, fix) {
    super(summary);
    this.text = cannotRun(summary, why, fix);
  }
}

/** The options of a run, or null for arguments this check does not know. */
function parse(args) {
  const options = { base: "origin/main", all: false, shard: null, jobs: "2", report: false, changed: false };
  const flags = { "--all": "all", "--report": "report", "--changed": "changed" };
  const valued = { "--base": ["base", /./], "--shard": ["shard", /^\d+\/[1-9]\d*$/], "--jobs": ["jobs", /^[1-9]\d*$/] };
  for (let at = 0; at < args.length; at++) {
    if (args[at] in flags) options[flags[args[at]]] = true;
    else if (args[at] in valued) {
      const [name, form] = valued[args[at]];
      const value = args[++at];
      if (value === undefined || !form.test(value)) return null;
      options[name] = value;
    } else return null;
  }
  return options.shard && !options.all ? null : options;
}

/** The output of a git command in `cwd`, or null when its exit code is none of `passes`. */
function git(cwd, args, passes = [0]) {
  const run = spawnSync("git", args, { cwd, encoding: "utf8", maxBuffer: 256 << 20 });
  return passes.includes(run.status) ? run.stdout : null;
}

/** As `git`, for a command that must work: a failure is never read as an empty diff, which would be a pass with nothing tested. */
function read(cwd, args, passes) {
  const out = git(cwd, args, passes);
  if (out === null) throw new Blocked("cannot read the changes from git", [`\`git ${args.filter((arg) => arg !== "-z").join(" ")}\` failed in core/`], "git status");
  return out;
}

/** The Rust changes under `core/` since the branch left `base`, as a diff with paths from `core/`. */
function rustDiff(core, base) {
  const since = ["the mutants are those in the lines changed since the branch left its base"];
  if (git(core, ["rev-parse", "--verify", "--quiet", `${base}^{commit}`]) === null) throw new Blocked(`${base} names no commit`, since, "git fetch origin, or name the base: make mutants BASE=<ref>");
  const from = git(core, ["merge-base", base, "HEAD"])?.trim();
  if (!from) throw new Blocked(`${base} and HEAD share no history`, since, "make mutants BASE=<ref>");
  const tracked = read(core, [...DIFF, "--relative", from, "--", "*.rs"]);
  // A file that is not yet committed is mutated like the rest. `--no-index` exits 1 when the two differ.
  const untracked = read(core, ["ls-files", "--others", "--exclude-standard", "-z", "--", "*.rs"])
    .split("\0")
    .filter(Boolean)
    .map((file) => read(core, [...DIFF, "--no-index", "--", "/dev/null", file], [0, 1]));
  return [tracked, ...untracked].join("");
}

/** The environment of the tool: the stand-in home, the real cargo and rustup, and the passed names. */
function environment(caller, home) {
  const placed = (name, directory) => {
    if (caller[name]) return caller[name];
    if (!caller.HOME) throw new Blocked("HOME is not set", ["cargo and rustup are looked for under the home directory; the tool itself gets another, empty one"], "set HOME, or CARGO_HOME and RUSTUP_HOME");
    return join(caller.HOME, directory);
  };
  const kept = Object.fromEntries(PASSED.filter((name) => caller[name] !== undefined).map((name) => [name, caller[name]]));
  return { ...kept, HOME: home, CARGO_HOME: placed("CARGO_HOME", ".cargo"), RUSTUP_HOME: placed("RUSTUP_HOME", ".rustup") };
}

function requireTool(core, env) {
  const run = spawnSync("cargo", ["mutants", "--version"], { cwd: core, env, encoding: "utf8" });
  const found = run.status === 0 ? /^cargo-mutants (\S+)/.exec(run.stdout)?.[1] : null;
  if (found === VERSION) return;
  const why = found
    ? [`cargo-mutants ${found} is installed; this check needs ${VERSION}`, "another version makes other mutants, so a run here and one in CI would not agree"]
    : [run.error?.code === "ENOENT" ? "cargo is not on the PATH" : "cargo has no `mutants` command"];
  throw new Blocked("cannot run cargo-mutants", why, INSTALL);
}

const linesOf = (out, name) => (existsSync(join(out, name)) ? readFileSync(join(out, name), "utf8").split("\n").filter(Boolean) : []);

function verdict(code, out) {
  const missed = linesOf(out, "missed.txt");
  const timedOut = linesOf(out, "timeout.txt").map((line) => `${line} (the tests did not end)`);
  if (code === 0) {
    const unviable = linesOf(out, "unviable.txt").length;
    return { code: 0, text: `mutants: ${linesOf(out, "caught.txt").length} changes to the code tried, each one seen by a test${unviable ? ` (${unviable} more did not compile)` : ""}\n` };
  }
  if (code === 4) throw new Blocked("the tests fail with no mutation", ["a mutant is judged by a test that fails, so the tests must pass first"], "make test");
  if (code === 5 || code === 6) throw new Blocked("the diff does not fit the tree", ["cargo-mutants could not match the changed lines with the files on disk"], "git status");
  if (code !== 2 && code !== 3) throw new Blocked(`cargo-mutants ended with exit code ${code}`, ["see its output above"], THEN);
  if ((code === 2 ? missed : timedOut).length === 0) throw new Blocked("cannot read the result of cargo-mutants", [`it ended with exit code ${code}, and its result files name no such mutant`], THEN);
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

/** Starts the tool on the lines of `diff`, or on the whole workspace for no diff. */
function mutate(core, diff, options, caller) {
  const temporary = mkdtempSync(join(tmpdir(), "tarmac-mutants-"));
  try {
    const env = environment(caller, join(temporary, "home"));
    mkdirSync(env.HOME);
    requireTool(core, env);
    const diffFile = join(temporary, "in.diff");
    if (diff !== null) writeFileSync(diffFile, diff);
    const scope = diff !== null ? ["--in-diff", diffFile] : options.shard ? ["--shard", options.shard] : [];
    // The tool writes no result when it finds no mutant, and an earlier run's files would be read as this one's.
    rmSync(join(core, "mutants.out"), { recursive: true, force: true });
    // The tool's progress is for the person who waits; stdout stays empty like the other checks'.
    const tool = spawnSync("cargo", ["mutants", "--workspace", "--no-shuffle", "--jobs", options.jobs, ...scope, "--output", core], { cwd: core, env, stdio: ["ignore", 2, 2] });
    return verdict(tool.status, join(core, "mutants.out"));
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function run(options, cwd, caller) {
  const root = repoRoot(cwd);
  if (!root) throw new Blocked("not in a git repository", ["the mutants are those in the lines a branch changed"], "cd to the repository");
  const core = join(root, "core");
  if (!existsSync(core)) throw new Blocked("this repository has no core/ directory", ["the Rust workspace is core/"], "cd to the Tarmac repository");
  const diff = options.all ? null : rustDiff(core, options.base);
  // `--changed` only answers whether a run would start the tool, so that CI can leave out the install when it would not.
  if (options.changed) return { code: 0, text: "", out: `${diff !== ""}\n` };
  if (diff === "") return { code: 0, text: `mutants: no Rust change against ${options.base}\n` };
  const result = mutate(core, diff, options, caller);
  if (!options.report || result.code !== 1) return result;
  // With `--report` a survivor is worded and written to the job summary, and fails nothing.
  if (caller.GITHUB_STEP_SUMMARY) appendFileSync(caller.GITHUB_STEP_SUMMARY, `\`\`\`\n${result.text}\`\`\`\n`);
  return { ...result, code: 0 };
}

function main(args, cwd, caller) {
  const options = parse(args);
  if (!options) return { code: 2, text: USAGE };
  try {
    return run(options, cwd, caller);
  } catch (error) {
    // Any other exception would end node with exit 1, which says "a mutant survived".
    return { code: 2, text: error instanceof Blocked ? error.text : cannotRun("the check itself failed", [String(error?.message ?? error)], THEN) };
  }
}

if (startedAs(import.meta)) {
  const { code, text, out = "" } = main(process.argv.slice(2), process.cwd(), process.env);
  process.stdout.write(out);
  process.stderr.write(text);
  process.exitCode = code;
}
