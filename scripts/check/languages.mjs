// What the formatter check and the lint check share: which files a language
// owns, which of them it leaves alone, and which version of its tool this tree
// was written with. One table, so the two checks cannot disagree about scope.

import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

import { repoRoot } from "./git.mjs";

// `command` reads one file on stdin and writes the formatted text to stdout.
// It runs in the file's directory, which is where the formatter looks for its
// configuration.
export const LANGUAGES = {
  rust: {
    tool: "rustfmt",
    glob: "*.rs",
    // A bare rustfmt takes edition 2015; the workspace is edition 2024 (core/Cargo.toml).
    command: ["rustfmt", "--edition", "2024"],
    explain: (path) => `rustfmt --edition 2024 --check ${path}`,
    install: "rustup component add rustfmt",
  },
  swift: {
    tool: "swift-format",
    glob: "*.swift",
    command: ["swift", "format", "format", "-"],
    explain: (path) => `swift format lint ${path}`,
    install: "install Xcode, or a Swift toolchain from https://swift.org/install",
    // Rust's formatter version is pinned by rust-toolchain.toml. Swift has no
    // such file, and a minor version can lay code out differently, so only the
    // versions seen to give this tree the same bytes are let through: 6.4.4
    // formatted it, and 6.3.0 (the CI image's) accepts every file of it.
    version: { command: ["swift", "format", "--version"], expect: ["6.3", "6.4"], fix: "use a Swift 6.3 or 6.4 toolchain, then run it again" },
    // swift-format 6.4 joins the comment lines under a `#!` line onto that
    // line, and joins one more on every run, so a script is not formatted.
    leaves: (text) => text.startsWith("#!"),
  },
};

/** The paths git tracks that match the glob. */
export const tracked = (root, glob) =>
  execFileSync("git", ["ls-files", "-z", "--", glob], { cwd: root, encoding: "utf8" }).split("\0").filter(Boolean);

/**
 * The tracked files of a language that a check reads: `{ path, file, text }`.
 * A tracked path that is no longer a file (deleted or replaced, not yet
 * staged) has no text, and a file the language leaves alone is not read on.
 */
export function sources(language, root) {
  return tracked(root, language.glob)
    .map((path) => ({ path, file: join(root, path) }))
    .filter(({ file }) => statSync(file, { throwIfNoEntry: false })?.isFile())
    .map((source) => ({ ...source, text: readFileSync(source.file, "utf8") }))
    .filter(({ text }) => !language.leaves?.(text));
}

/**
 * Files that a caller names (a hook names whatever was just edited), grouped by
 * the repository each one is in: `[{ root, paths }]`, the paths relative to the
 * root. A named file need not be tracked: a new file is checked from its first
 * save. Left out, with no message: a path outside any repository, one that git
 * ignores, and one that is not a file.
 */
export function namedFiles(paths, cwd = process.cwd()) {
  const byRoot = new Map();
  for (const file of paths.map((path) => resolve(cwd, path))) {
    if (!statSync(file, { throwIfNoEntry: false })?.isFile()) continue;
    const root = repoRoot(dirname(file));
    if (!root) continue;
    // `--show-toplevel` gives the path with links resolved; the named one may not be.
    const path = relative(root, realpathSync(file));
    if (spawnSync("git", ["check-ignore", "-q", "--", path], { cwd: root }).status === 0) continue;
    byRoot.set(root, [...(byRoot.get(root) ?? []), path]);
  }
  return [...byRoot].map(([root, paths]) => ({ root, paths }));
}

/** The name of the language that owns a path, or undefined. */
export const languageOf = (path) => Object.keys(LANGUAGES).find((name) => path.endsWith(LANGUAGES[name].glob.slice(1)));

/** The sources of a language among repo-relative paths that were named. */
export const namedSources = (language, root, paths) =>
  paths
    .filter((path) => path.endsWith(language.glob.slice(1)))
    .map((path) => ({ path, file: join(root, path), text: readFileSync(join(root, path), "utf8") }))
    .filter(({ text }) => !language.leaves?.(text));

/** The parts of a "cannot run" report for a tool that is not installed. */
export const notOnPath = (language) => ({
  summary: `cannot run ${language.tool}`,
  why: [`${language.command[0]} is not on the PATH`],
  fix: language.install,
});

/** The version the tool reports, or null when it gives none; `missing` when it is not installed. */
export function toolVersion(language) {
  const [command, ...args] = language.version.command;
  const asked = spawnSync(command, args, { encoding: "utf8" });
  if (asked.error?.code === "ENOENT") return { missing: true };
  return { found: asked.status === 0 ? asked.stdout.split("\n")[0].trim() : null };
}

/** The parts of a "cannot run" report when the language's tool must not run here, else null. */
export function unusable(language, { missing, found } = language.version ? toolVersion(language) : {}) {
  if (!language.version) return null;
  const { command, expect, fix } = language.version;
  if (missing) return notOnPath(language);
  if (expect.some((minor) => found === minor || found?.startsWith(`${minor}.`))) return null;
  const have = found ? `${language.tool} ${found} is on the PATH` : `${command.join(" ")} did not answer`;
  return { summary: `cannot run ${language.tool}`, why: [`${have}; this tree is formatted with ${expect.join(" or ")}`], fix };
}
