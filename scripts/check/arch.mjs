#!/usr/bin/env node
// The architecture check: rules about the tree that no formatter, linter or
// compiler setting holds. One definition for `make arch-check` and CI.
//
//   node scripts/check/arch.mjs    exit 0 no rule broken, 1 a rule is broken, 2 could not run
//
// Each rule reads the files git tracks, as they are in the working tree, and
// reads them as text: a rule names a line, it does not parse the language.

import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { repoRoot, startedAs } from "./git.mjs";
import { parseList } from "./list.mjs";
import { failure } from "./report.mjs";

const RULE = "arch";
const THEN = "make arch-check";
const LIST = "scripts/check/arch-exceptions.json";
const CARGO = "core/Cargo.toml";
const KIT = "app/Sources/TarmacKit/";
const KIT_TESTS = "app/Tests/TarmacKitTests/";
const SWIFT_SIGNAL_SITES = ["app/Sources/TarmacApp/AppController+Connection.swift", `${KIT_TESTS}OwnChild.swift`];

// ------------------------------------------------------------- the tree

/** The tracked files that are in the working tree, and their lines. */
function treeOf(root) {
  const listed = execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8", maxBuffer: 64 << 20 }).split("\0").filter(Boolean);
  const paths = listed.filter((path) => statSync(join(root, path), { throwIfNoEntry: false })?.isFile());
  const has = new Set(paths);
  const cache = new Map();
  const text = (path) => cache.get(path) ?? cache.set(path, readFileSync(join(root, path), "utf8")).get(path);
  return { paths, has: (path) => has.has(path), text, lines: (path) => text(path).split("\n") };
}

/** `path:line` for each line of the paths for which `breaks(code, line)` holds; `code` is the line without its comment. */
const linesWhere = (tree, paths, comment, breaks) =>
  paths.flatMap((path) => tree.lines(path).flatMap((line, i) => (breaks(line.split(comment)[0]) ? [`${path}:${i + 1}`] : [])));

// --------------------------------------------------------------- imports

const IMPORT =
  /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_]\w*)/;

/** The modules a line of Swift code imports, or asks `canImport` about in an `#if`. */
function importedBy(code) {
  const asked = /^\s*#(?:if|elseif)\b/.test(code) ? [...code.matchAll(/\bcanImport\((\w+)\)/g)].map(([, module]) => module) : [];
  const named = code.match(IMPORT)?.[1];
  return named ? [named, ...asked] : asked;
}

const forbiddenImports = (directory, modules) => (tree) =>
  linesWhere(tree, tree.paths.filter((path) => path.startsWith(directory) && path.endsWith(".swift")), "//", (code) => importedBy(code).some((module) => modules.includes(module)));

// ------------------------------------------------------------------ TOML

/** The lines of a TOML file as `{ table, code, number }`: the table each line is in, and the line without its comment. */
function tomlLines(tree, path) {
  let table = "";
  return tree.lines(path).map((line, i) => {
    const code = line.split("#")[0];
    // `[[bin]]`, an array of tables, starts a table too.
    table = code.match(/^\s*\[\[?([^\]]+)\]\]?\s*$/)?.[1].trim() ?? table;
    return { table, code, number: i + 1 };
  });
}

const sets = (code, key) => new RegExp(`^\\s*${key}\\s*=`).test(code);

function profileOverrides(tree) {
  const manifests = tree.paths.filter((path) => path === CARGO || /^core\/crates\/[^/]+\/Cargo\.toml$/.test(path) || /^(core\/)?\.cargo\/config\.toml$/.test(path));
  return manifests.flatMap((path) =>
    tomlLines(tree, path)
      .filter(({ table, code }) => (table === "profile" || table.startsWith("profile.")) && sets(code, "debug-assertions"))
      .map(({ number }) => `${path}:${number}`),
  );
}

const SERDE_STACK = ["serde", "rmp-serde", "serde_bytes"];

function unpinned(tree) {
  const lines = tomlLines(tree, CARGO);
  const header = lines.find(({ table, code }) => table === "workspace.dependencies" && code.includes("["))?.number ?? 1;
  return SERDE_STACK.flatMap((name) => {
    const entry = lines.find(({ table, code }) => table === "workspace.dependencies" && sets(code, name));
    if (!entry) return [`${CARGO}:${header}`];
    const value = entry.code.slice(entry.code.indexOf("=") + 1).trim();
    const version = value.startsWith('"') ? value.match(/^"([^"]*)"/)?.[1] : value.match(/(?<![\w-])version\s*=\s*"([^"]*)"/)?.[1];
    return version?.startsWith("=") ? [] : [`${CARGO}:${entry.number}`];
  });
}

// ------------------------------------------------------------- kit tests

/** The exceptions list as `{ list }`, or `{ bad }`: why it cannot be used. */
function exceptions(tree) {
  const read = parseList(tree.has(LIST) ? tree.text(LIST) : null, LIST, ["module", "issue", "reason"]);
  const twice = read.list?.find(({ module }, i) => read.list.findIndex((other) => other.module === module) !== i);
  return twice ? { bad: `${LIST} names ${twice.module} twice` } : read;
}

function untested(tree, list) {
  // A module is a Swift file at any depth under TarmacKit, named for its type.
  // `<Module>+<Part>.swift` is a slice of a module, tested with it.
  const sources = tree.paths
    .filter((path) => path.startsWith(KIT) && path.endsWith(".swift"))
    .map((path) => ({ path, module: path.slice(path.lastIndexOf("/") + 1, -".swift".length) }))
    .filter(({ module }) => !module.includes("+"));
  const modules = sources.map(({ module }) => module);
  const tested = (module) => tree.has(`${KIT_TESTS}${module}Tests.swift`);
  const excepted = new Set(list.map(({ module }) => module));
  const bare = sources.filter(({ module }) => !tested(module) && !excepted.has(module)).map(({ path }) => `${path}:1`);
  // The line that holds the module's name as JSON writes it; line 1 if a formatter split it past recognition.
  const lineOf = (module) => Math.max(1, tree.lines(LIST).findIndex((line) => line.includes(JSON.stringify(module))) + 1);
  const stale = list.filter(({ module }) => tested(module) || !modules.includes(module)).map(({ module }) => `${LIST}:${lineOf(module)}`);
  return [...bare, ...stale];
}

// ------------------------------------------------------------- the rules

const swiftFiles = (tree) => tree.paths.filter((path) => path.endsWith(".swift"));

// Each rule: what it says when broken, why it exists, what fixes it, and
// `find(tree, exceptions)`, the places that break it. A new rule is a new entry.
const RULES = [
  {
    summary: "TarmacKit must not import AppKit, WebKit or a sibling target",
    why: "TarmacKit holds the pure decisions and is the only layer with unit tests",
    fix: "move the code that needs the module into TarmacApp, and pass the value in",
    // Cocoa and SwiftUI each bring AppKit in.
    find: forbiddenImports(KIT, ["AppKit", "Cocoa", "WebKit", "SwiftUI", "TarmacTerm", "TarmacApp"]),
  },
  {
    summary: "TarmacTerm must not import TarmacKit or TarmacApp",
    why: "the terminal card stands alone: the layering is one-way (docs/coding-style.md §4)",
    fix: "pass what it needs in from TarmacApp, through an initializer or a closure",
    find: forbiddenImports("app/Sources/TarmacTerm/", ["TarmacKit", "TarmacApp"]),
  },
  {
    summary: "Bundle.module is used outside BundledResource",
    why: "a built Tarmac.app has no package bundle, so Bundle.module traps there; BundledResource asks Bundle.main first",
    fix: "look the resource up through BundledResource",
    find: (tree) => linesWhere(tree, swiftFiles(tree).filter((path) => path !== "app/Sources/TarmacApp/BundledResource.swift"), "//", (code) => /Bundle\.module\b/.test(code)),
  },
  {
    summary: "a signal is sent outside TermHandle::kill",
    why: "a signal reaches whatever pid it is given; one site keeps that pid the PTY child's own",
    fix: "call TermHandle::kill, or move the new use into core/crates/tarmacd/src/term.rs",
    find: (tree) => {
      const sources = tree.paths.filter((path) => /^core\/crates\/[^/]+\/src\/.*\.rs$/.test(path) && path !== "core/crates/tarmacd/src/term.rs");
      return linesWhere(tree, sources, "//", (code) => /libc::kill(?:pg)?\b/.test(code));
    },
  },
  {
    summary: "kill(2) is called in Swift outside the app's wiring and the tests' fence",
    why: "a signal reaches whatever pid it is given, and -1 is every process of the user; TarmacKit is handed its sender, so a unit test decides which pid a signal may reach",
    fix: "in a source file take the sender as a parameter (DaemonClient.Signal); in a test call OwnChild.signal, which sends only to a child of the test",
    find: (tree) => {
      const sources = swiftFiles(tree).filter((path) => path.startsWith("app/") && !SWIFT_SIGNAL_SITES.includes(path));
      // Any call named kill: a module prefix (Darwin.kill) is one too, and no type under app/ has a method of that name.
      return linesWhere(tree, sources, "//", (code) => /(?<!\w)`?kill(?:pg)?`?\s*\(/.test(code));
    },
  },
  {
    summary: "a test uses the system clipboard",
    why: "NSPasteboard.general is what the developer last copied; a test that writes to it replaces that on every `make test`, and so on every push",
    fix: "give the view under test a pasteboard of the test's own (NSPasteboard.withUniqueName()), and read that one",
    find: (tree) => linesWhere(tree, swiftFiles(tree).filter((path) => path.startsWith("app/Tests/")), "//", (code) => /\bNSPasteboard\s*\.\s*general\b/.test(code)),
  },
  {
    summary: "a profile sets debug-assertions",
    why: "the daemon and the CLI pick their channel from debug_assertions; a profile that changes it moves a debug build onto the installed app's socket and state",
    fix: "remove the debug-assertions key",
    find: profileOverrides,
  },
  {
    summary: "the serde stack is not pinned with =",
    why: "the tagged enum and serde_bytes are verified together on exact versions only; the conformance vectors are the tripwire",
    fix: `pin serde, rmp-serde and serde_bytes with = in [workspace.dependencies] of ${CARGO}`,
    find: unpinned,
  },
  {
    summary: "a TarmacKit module has no paired test file, or an exception is no longer needed",
    why: "every kit module ships with its <Module>Tests.swift (docs/coding-style.md §4)",
    fix: `add ${KIT_TESTS}<Module>Tests.swift, or remove the entry from ${LIST}`,
    find: untested,
  },
];

const cannotRun = (summary, why, fix) => ({ code: 2, text: failure({ rule: RULE, summary, why, fix, then: THEN }) });

function main() {
  const root = repoRoot();
  if (!root) return cannotRun("not in a git repository", [], "run it from inside the repository");
  const tree = treeOf(root);
  if (!tree.has(CARGO)) return cannotRun("cannot run the architecture check", [`${CARGO} is missing`], "run it from the Tarmac repository");
  const { list, bad } = exceptions(tree);
  if (bad) return cannotRun("cannot run the architecture check", [bad], `correct ${LIST}`);

  const broken = RULES.map((rule) => ({ ...rule, at: [...new Set(rule.find(tree, list))] })).filter(({ at }) => at.length > 0);
  const text = broken.map(({ summary, at, why, fix }) => failure({ rule: RULE, summary, at, why: [why], fix, then: THEN })).join("");
  return { code: broken.length > 0 ? 1 : 0, text };
}

/** A rule that throws has not judged the tree, so that is "could not run" and never "a rule is broken". */
function guarded() {
  try {
    return main();
  } catch (error) {
    return cannotRun("cannot run the architecture check", [error.message], "correct what the line above names");
  }
}

if (startedAs(import.meta)) {
  const { code, text } = guarded();
  process.stderr.write(text);
  process.exitCode = code;
}
