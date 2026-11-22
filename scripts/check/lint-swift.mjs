// The Swift lint: the rules of `.swift-format` over the tracked Swift files,
// and this repository's own rules for swift-format's ignore comment.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

import { LANGUAGES, sources, toolVersion, unusable } from "./languages.mjs";
import { CLEAN, RULE, blockedFor, findings } from "./lint-common.mjs";
import { failure } from "./report.mjs";

const THEN = "make lint";
const cannotRun = blockedFor(THEN);

const SWIFT_FIX =
  "correct each one above; `make fmt` clears a layout finding; to keep one, put the reason in a comment and `// swift-format-ignore: <Rule>` on the next line";

const CONFIG = ".swift-format";

/**
 * The rules the configuration knows by name and the ones it turns on, or the
 * parts of a "cannot run" report. Only the root file is read, while the tool
 * obeys the nearest one above each file, tracked or not; so a second one in a
 * directory above any linted file is refused.
 */
function configuredRules(root, language, files) {
  const blocked = (why, fix) => ({ blocked: { summary: `cannot run ${language.tool}`, why: [why], fix } });
  const above = new Set(files.flatMap(({ path }) => ancestors(path)));
  const nested = [...above].sort().find((dir) => existsSync(join(root, dir, CONFIG)));
  if (nested) {
    return blocked(`${nested}/${CONFIG}: only the configuration at the repository root is read`, `remove it, and put its settings in ${CONFIG} at the repository root`);
  }
  if (!existsSync(join(root, CONFIG))) return { known: new Set(), on: [] };
  const correct = `correct ${CONFIG} at the repository root`;
  let rules;
  try {
    rules = JSON.parse(readFileSync(join(root, CONFIG), "utf8"))?.rules ?? {};
  } catch {
    return blocked(`${CONFIG} is not valid JSON`, correct);
  }
  if (typeof rules !== "object" || Array.isArray(rules)) return blocked(`${CONFIG}: rules is not a table of rule names`, correct);
  return { known: new Set(Object.keys(rules)), on: Object.keys(rules).filter((name) => rules[name]) };
}

/** The directories above a repo-relative path, the root not among them: `a/b/c.swift` gives `a/b` and `a`. */
function ancestors(path) {
  const parts = path.split("/").slice(0, -1);
  return parts.map((_, i) => parts.slice(0, i + 1).join("/"));
}

/** A rule that is on in the configuration and unknown to the running tool would be off without a word. */
function missingRules(language, on, version) {
  const dumped = spawnSync("swift", ["format", "dump-configuration"], { encoding: "utf8" });
  const has = new Set(Object.keys(JSON.parse(dumped.stdout).rules));
  const missing = on.filter((name) => !has.has(name));
  if (missing.length === 0) return null;
  return {
    summary: `cannot run ${language.tool}`,
    why: missing.map((name) => `${name} is not a rule of ${language.tool} ${version}`),
    fix: "use a toolchain whose swift-format has the rule, or turn it off in .swift-format",
  };
}

const DIRECTIVE = /\/\/\s*swift-format-ignore(-file)?\b(?::\s*(.*?))?\s*$/;
// A `///` line belongs to a declaration's documentation, so it is not a reason.
const isReason = (line) => /^\/\/(?!\/)\s*\S/.test(line) && !DIRECTIVE.test(line);

/**
 * swift-format's ignore comment has no reason and never goes stale, and three
 * of its forms do something other than they say, so each use is held to one
 * shape: a named rule, on its own line, under a comment that says why.
 */
function directiveFindings({ path, text }, known) {
  const lines = text.split("\n");
  return lines.flatMap((line, i) => {
    const found = line.match(DIRECTIVE);
    if (!found) return [];
    const names = (found[2] ?? "").split(",").map((name) => name.trim()).filter(Boolean);
    const what =
      (line.slice(0, found.index).trim() !== "" && "ignore-has-no-effect") ||
      (found[1] && "ignore-file") ||
      (names.length === 0 && "ignore-without-rule") ||
      (names.some((name) => !known.has(name)) && "ignore-unknown-rule") ||
      (!isReason((lines[i - 1] ?? "").trim()) && "ignore-without-reason");
    return what ? [`${path}:${i + 1}:${found.index + 1} ${what}`] : [];
  });
}

export function lintSwift(root) {
  const language = LANGUAGES.swift;
  const files = sources(language, root);
  if (files.length === 0) return CLEAN;
  const version = toolVersion(language);
  const { known, on, blocked: badConfig } = configuredRules(root, language, files);
  const reason = unusable(language, version) ?? badConfig ?? missingRules(language, on, version.found);
  if (reason) return cannotRun(reason.summary, reason.why, reason.fix);

  const run = spawnSync("swift", ["format", "lint", "--parallel", ...files.map(({ path }) => path)], { cwd: root, encoding: "utf8", maxBuffer: 64 << 20 });
  const said = [...run.stderr.matchAll(/^(.+?):(\d+):(\d+): (warning|error): (?:\[(\w+)\] )?(.*)$/gm)].map(
    ([, file, line, column, level, rule, message]) => ({ at: `${relative(root, resolve(root, file))}:${line}:${column}`, level, rule, message }),
  );
  const errors = said.filter(({ level }) => level === "error");
  if (errors.length > 0) {
    const why = errors.map(({ at, message }) => `${at} error: ${message}`);
    const blocked = cannotRun(`cannot run ${language.tool}`, why, `see the whole error with: ${language.explain(errors[0].at.split(":")[0])}`);
    return { ...blocked, text: run.stderr + blocked.text };
  }
  const at = [...said.map(({ at, rule }) => `${at} ${rule ?? "warning"}`), ...files.flatMap((source) => directiveFindings(source, known))];
  // The tool can stop with a message that names no place (a configuration it cannot read).
  if (said.length === 0 && run.status !== 0) {
    const why = run.stderr.split("\n").filter((line) => /\berror\b/.test(line));
    return cannotRun(`cannot run ${language.tool}`, why.slice(0, 3), "correct the error above");
  }
  if (at.length === 0) return CLEAN;
  return { code: 1, text: run.stderr + failure({ rule: RULE, summary: findings(at.length, language.tool), at, fix: SWIFT_FIX, then: THEN }) };
}
