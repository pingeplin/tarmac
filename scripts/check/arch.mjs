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

import { repoRoot } from "./git.mjs";
import { parseList } from "./list.mjs";
import { blockedFor, failure, runCheck } from "./report.mjs";

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

// ------------------------------------------------------- code and comments

/**
 * A Rust or Swift line split at its `//` comment, with the contents of its
 * one-line strings blanked out of `code`. A string that spans lines, and a
 * `/* *\/` comment, are read as code.
 */
function partsOf(line) {
  const masked = line.replace(/"(?:[^"\\]|\\.)*"/g, (string) => `"${" ".repeat(string.length - 2)}"`);
  const at = masked.indexOf("//");
  return at < 0 ? { code: masked, comment: "" } : { code: masked.slice(0, at), comment: line.slice(at) };
}

/** `path:line` for each line `i` of the paths for which `breaks(lines, i)` holds. */
const placesWhere = (tree, paths, breaks) =>
  paths.flatMap((path) => {
    const lines = tree.lines(path);
    return lines.flatMap((_, i) => (breaks(lines, i) ? [`${path}:${i + 1}`] : []));
  });

/** The index of the nearest line above line `i` that `passOver` does not hold for, or -1 at the top of the file. */
function above(lines, i, passOver) {
  let j = i - 1;
  while (j >= 0 && passOver(lines[j])) j--;
  return j;
}

const isComment = (line) => /^\s*\/\//.test(line);

// ------------------------------------------------------------------ Rust

const RUST_ATTRIBUTE = /^\s*#!?\[/;

function skipsWithoutReason(lines, i) {
  const { code, comment } = partsOf(lines[i]);
  if (!/#!?\[\s*rustfmt::skip\b/.test(code)) return false;
  // Over the other attributes and the item's `///` doc, which is not a reason for the skip.
  const reason = /^\s*\/\/(?![/!])\s*\S/;
  const passOver = (line) => RUST_ATTRIBUTE.test(line) || /^\s*\/\/\//.test(line);
  return !/^\/\/\s*\S/.test(comment) && !reason.test(lines[above(lines, i, passOver)] ?? "");
}

const FN = /^\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?(?:(?:const|async|unsafe|extern\s+"[^"]*")\s+)*fn\s+((get|test)_\w*)/;
const TEST_ATTRIBUTE = /#\[\s*(?:\w+::)*test\s*[\](]/;
// The getter variants the Rust API guidelines name.
const GUIDELINE_GETTER = /^get_(?:mut|unchecked|unchecked_mut|or_\w+)$/;

function misnamed(lines, i) {
  const { code, comment } = partsOf(lines[i]);
  const [, name, prefix] = code.match(FN) ?? [];
  // A name chosen elsewhere (a C library's, a foreign trait's) is an extern fn, or has its reason after it on the line.
  if (!name || /\bextern\s+"/.test(code) || /^\/\/\s*\S/.test(comment)) return false;
  if (prefix === "get") return !GUIDELINE_GETTER.test(name);
  // A test is a function its attributes mark: the lines from it up over them and the doc comment.
  const top = above(lines, i, (line) => RUST_ATTRIBUTE.test(line) || isComment(line));
  return lines.slice(top + 1, i + 1).some((line) => TEST_ATTRIBUTE.test(partsOf(line).code));
}

const DEPENDENCIES = /^(?:target\..+\.|workspace\.)?(?:dev-|build-)?dependencies(?:\.|$)/;

function thiserror(tree) {
  const manifests = tree.paths.filter((path) => path === "Cargo.toml" || path.endsWith("/Cargo.toml"));
  return manifests.flatMap((path) =>
    tomlLines(tree, path)
      .filter(({ table, code }) => {
        if (!DEPENDENCIES.test(table)) return false;
        if (/^\s*\[/.test(code)) return /dependencies\.thiserror$/.test(table);
        return /^\s*"?thiserror"?\s*[.=]/.test(code) || /\bpackage\s*=\s*"thiserror"/.test(code);
      })
      .map(({ number }) => `${path}:${number}`),
  );
}

// The shared harness of each crate's integration tests: an expect there is unfulfilled in each test binary that uses the item.
const HARNESS = /^core\/crates\/[^/]+\/tests\/common\/mod\.rs$/;

const allows = (tree) => placesWhere(tree, rustFiles(tree).filter((path) => !HARNESS.test(path)), (lines, i) => /#!?\[\s*allow\s*\(/.test(partsOf(lines[i]).code));

const MILESTONES = ["m0", "m1", "m2", "m3", "v4", "v4c"];

const milestoneSuites = (tree) =>
  tree.paths
    .filter((path) => /^core\/crates\/[^/]+\/tests\/[^/]+\.rs$/.test(path))
    .filter((path) => path.slice(path.lastIndexOf("/") + 1, -".rs".length).toLowerCase().split("_").some((part) => MILESTONES.includes(part)))
    .map((path) => `${path}:1`);

// ----------------------------------------------------------------- Swift

function uncheckedWithoutComment(lines, i) {
  if (!/@unchecked\s+Sendable\b/.test(partsOf(lines[i]).code)) return false;
  // Over the attributes, and the declaration's earlier lines when a formatter split it.
  const declaration = (line) => /^\s*(?:@\w+(?:\([^)]*\))?\s*)+$/.test(line) || /[,:]\s*$/.test(partsOf(line).code);
  return !isComment(lines[above(lines, i, declaration)] ?? "");
}

const TEST_CLASS = /^\s*((?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private|final)\s+)*)class\s+(\w+)\s*:\s*XCTestCase\b/;

function unnamedTestClass(tree) {
  return tree.paths
    .filter((path) => path.startsWith("app/Tests/") && path.endsWith(".swift"))
    .flatMap((path) => {
      const name = path.slice(path.lastIndexOf("/") + 1, -".swift".length);
      const classes = tree.lines(path).flatMap((line, i) => {
        const [, modifiers, type] = partsOf(line).code.match(TEST_CLASS) ?? [];
        const final = /\bfinal\b/.test(modifiers ?? "");
        // A class that is not final and not named …Tests is a shared base case, which cannot be final.
        return type && (final || type.endsWith("Tests")) ? [{ final, type, number: i + 1 }] : [];
      });
      const named = classes.some(({ final, type }) => final && type === name);
      return classes.length > 0 && !named ? [`${path}:${classes[0].number}`] : [];
    });
}

// ------------------------------------------------------------ the codecs

const MSG = "core/crates/tarmac-protocol/src/lib.rs";
const MESSAGES = `${KIT}Messages.swift`;

/** The lines of `path` and the block that opens on the first line `opens` matches, to the `}` at that line's indentation. */
function blockOf(tree, path, opens, what) {
  if (!tree.has(path)) throw new Error(`${path} is missing`);
  const lines = tree.lines(path);
  const start = lines.findIndex((line) => opens.test(line));
  if (start < 0) throw new Error(`${path} has no ${what}`);
  const close = `${lines[start].match(/^\s*/)[0]}}`;
  const end = lines.findIndex((line, i) => i > start && line === close);
  if (end < 0) throw new Error(`${path} has no end of ${what}`);
  return { lines, start, end };
}

// serde's snake_case: an underscore before each capital but the first.
const snake = (name) => name.replace(/(?<!^)[A-Z]/g, (capital) => `_${capital}`).toLowerCase();

/** Each `Msg` variant that has a `"t"` tag on the wire, as `{ tag, number }`. */
function wireVariants(tree) {
  const { lines, start, end } = blockOf(tree, MSG, /^pub enum Msg \{/, "pub enum Msg");
  const attributes = lines.slice(above(lines, start, (line) => RUST_ATTRIBUTE.test(line)) + 1, start).join(" ");
  if (!attributes.includes('#[serde(tag = "t", rename_all = "snake_case")]')) {
    throw new Error(`${MSG}: pub enum Msg is not #[serde(tag = "t", rename_all = "snake_case")]`);
  }
  const variants = [];
  let own = [];
  for (let i = start + 1; i < end; i++) {
    if (/^ {4}#\[/.test(lines[i])) own.push(lines[i]);
    const name = lines[i].match(/^ {4}([A-Z]\w*)\s*(?:[{(,]|$)/)?.[1];
    if (!name) continue;
    // The #[serde(other)] catch-all is what an unknown tag decodes to: it has no tag of its own.
    if (!own.some((line) => /\bserde\(\s*other\s*\)/.test(line))) {
      variants.push({ tag: own.join(" ").match(/\brename\s*=\s*"([^"]*)"/)?.[1] ?? snake(name), number: i + 1 });
    }
    own = [];
  }
  return variants;
}

/** A line of Swift without its `//` comment; a `//` inside a one-line string stays. */
const codeOf = (line) => line.slice(0, partsOf(line).code.length);

/** The tags of the cases of `Message.decode`'s own switch, and those `encodedValue` passes to a `Self.<helper>` call. */
function swiftTags(tree) {
  const body = (opens, what) => {
    const { lines, start, end } = blockOf(tree, MESSAGES, opens, what);
    return lines.slice(start + 1, end).map(codeOf);
  };
  const DECODE = "static func decode(_: MsgPackValue)";
  const decode = body(/\bstatic func decode\(_ \w+: MsgPackValue\)/, DECODE);
  const encode = body(/\bfunc encodedValue\(\)/, "func encodedValue()").join("\n");
  // Swift lays a switch's cases at the switch's own indentation; a nested switch's are deeper.
  const indent = decode.find((line) => /^\s*switch\b/.test(line))?.match(/^\s*/)[0];
  if (indent === undefined) throw new Error(`${MESSAGES} has no switch in ${DECODE}`);
  const labels = decode.flatMap((line) => line.match(new RegExp(`^${indent}case\\s+("[^"]*"(?:\\s*,\\s*"[^"]*")*)\\s*:`))?.[1] ?? []);
  const decoded = labels.flatMap((label) => [...label.matchAll(/"([^"]*)"/g)].map(([, tag]) => tag));
  const encoded = [...encode.matchAll(/\bSelf\.\w+\(\s*"([^"]*)"/g)].map(([, tag]) => tag);
  return { decoded: new Set(decoded), encoded: new Set(encoded) };
}

function uncoded(tree) {
  try {
    const { decoded, encoded } = swiftTags(tree);
    return wireVariants(tree)
      .filter(({ tag }) => !decoded.has(tag) || !encoded.has(tag))
      .map(({ number }) => `${MSG}:${number}`);
  } catch (error) {
    throw new Error(`${error.message} (the codec rule in scripts/check/arch.mjs reads this path)`);
  }
}

// ------------------------------------------------------------- the rules

const swiftFiles = (tree) => tree.paths.filter((path) => path.endsWith(".swift"));
const rustFiles = (tree) => tree.paths.filter((path) => path.endsWith(".rs"));

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
    find: (tree) => linesWhere(tree, swiftFiles(tree).filter((path) => path.startsWith("app/Tests/")), "//", (code) => /\bNSPasteboard\b.*\.general\b/.test(code)),
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
  {
    summary: "#[rustfmt::skip] has no reason in a // comment beside it",
    why: "layout belongs to rustfmt; a skip is the exception, and its reason is what a reviewer weighs (docs/coding-style.md §2)",
    fix: "say why in a // comment on the line above the attribute or after it on its line, or remove the skip",
    // A `///` line is not a reason; `rustfmt.toml`'s `ignore` and a skip inside `cfg_attr` are not seen.
    find: (tree) => placesWhere(tree, rustFiles(tree), skipsWithoutReason),
  },
  {
    summary: "a Rust function is named get_…, or a test function test_…",
    why: "getters read as nouns and test names are sentences (docs/coding-style.md §3)",
    fix: "drop the prefix: name a getter for what it returns, a test for what it shows; a name fixed elsewhere (a foreign trait's, a C library's) takes a // reason after it on its line",
    // A test is a function under #[test] or #[<path>::test]; a test_ helper is not one. get_mut, get_unchecked(_mut) and
    // get_or_… are the API guidelines' names; an extern "…" fn is a C name. An attribute split over lines is not seen.
    find: (tree) => placesWhere(tree, rustFiles(tree), misnamed),
  },
  {
    summary: "a crate depends on thiserror",
    why: "errors follow the crate's role, and no crate may take thiserror (docs/coding-style.md §3)",
    fix: "return the error of the crate's role: anyhow in tarmacd, a string or a small enum in tarmac-cli, io and rmp_serde errors in tarmac-protocol",
    // Dependency tables of every tracked Cargo.toml; Cargo.lock lists what other crates bring in, which is not ours.
    find: thiserror,
  },
  {
    summary: "an integration suite is named for a milestone",
    why: "M0–M3 and v4 are closed history; a suite is named for its subject (docs/coding-style.md §1.1)",
    fix: "rename the file for the behaviour it tests, as boards_integration.rs is",
    // The milestone is a whole _-separated part of the name: m0basics.rs is not seen, and a v4_… (IPv4) or m1_…/m2_…
    // (Apple chips) suite is reported, whose fix is another name.
    find: milestoneSuites,
  },
  {
    summary: "@unchecked Sendable has no comment directly above it",
    why: "the compiler no longer checks that type's state; the comment says what guards it (docs/coding-style.md §4)",
    fix: "say what guards the state (a lock, a condition) in a comment above the declaration",
    // It sees that a comment is there, not what it says.
    find: (tree) => placesWhere(tree, swiftFiles(tree), uncheckedWithoutComment),
  },
  {
    summary: "a Swift test file does not declare final class <its name>: XCTestCase",
    why: "one final class <Module>Tests: XCTestCase per module, and one main type per file, the file named for it (docs/coding-style.md §4)",
    fix: "name the file's test class for the file, and make it final",
    // A file with no XCTestCase class is not judged, nor a shared base case (not final, not named …Tests), nor a class
    // that subclasses another test case.
    find: unnamedTestClass,
  },
  {
    summary: "#[allow] or #![allow] is used outside a shared tests/common harness",
    why: "a kept lint finding is #[expect(lint, reason = …)], which fails once it is stale; clippy refuses an outer #[allow] only (docs/coding-style.md §2)",
    fix: "use #[expect(lint, reason = \"…\")] on the narrowest item, or fix the finding",
    // A line's code, without its // comment and its one-line strings. An allow inside cfg_attr is not seen.
    find: allows,
  },
  {
    summary: "a Msg variant of the Rust codec has no decode case or no encode in the Swift codec",
    why: "the wire contract has two codecs; a tag the Swift codec does not decode is dropped as unknown, and one it does not encode the app cannot send",
    fix: `add the variant to Message in ${MESSAGES}: a case "<tag>": in decode and its encode in encodedValue, in the change that adds it to Msg`,
    // A tag is the name in snake_case or a one-line #[serde(rename = "…")]; other serde attributes that change a tag
    // (skip, alias, a split rename) are not seen. It sees that a case is there, not which keys it reads or writes:
    // the conformance vectors hold those.
    find: uncoded,
  },
];

const cannotRun = blockedFor(RULE, THEN);

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

/**
 * A rule that throws has not judged the tree, so that is "could not run" and never "a rule is broken".
 * The shared entry would say that too; this keeps arch's own wording of it, which a test holds.
 */
function guarded() {
  try {
    return main();
  } catch (error) {
    return cannotRun("cannot run the architecture check", [error.message], "correct what the line above names");
  }
}

await runCheck(import.meta, { rule: RULE, then: THEN }, guarded);
