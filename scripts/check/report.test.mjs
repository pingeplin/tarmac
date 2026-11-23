import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { after, test } from "node:test";

import "./test-env.mjs";

import { blockedFor, failure } from "./report.mjs";

test("a failure names the rule, the places, the reason and the next two commands", () => {
  const text = failure({
    rule: "arch-check",
    summary: "TarmacKit must not import AppKit",
    at: ["app/Sources/TarmacKit/Placement.swift:3"],
    why: ["TarmacKit holds the pure decisions"],
    fix: "move the AppKit call into TarmacApp",
    then: "make lint",
  });

  assert.equal(
    text,
    [
      "✗ arch-check: TarmacKit must not import AppKit",
      "  at   app/Sources/TarmacKit/Placement.swift:3",
      "  why  TarmacKit holds the pure decisions",
      "  fix  move the AppKit call into TarmacApp",
      "  then make lint",
      "",
    ].join("\n"),
  );
});

test("more places than one are in byte order, under one label", () => {
  const text = failure({ rule: "fmt", summary: "s", at: ["b/z.rs", "a/y.rs", "B/x.rs"], fix: "f", then: "t" });

  assert.deepEqual(text.split("\n").slice(1, 4), ["  at   B/x.rs", "       a/y.rs", "       b/z.rs"]);
});

test("a failure with no place and no reason has only the two commands", () => {
  const text = failure({ rule: "fmt", summary: "unknown language", fix: "f", then: "t" });

  assert.deepEqual(text.split("\n"), ["✗ fmt: unknown language", "  fix  f", "  then t", ""]);
});

for (const missing of ["fix", "then"]) {
  test(`a failure with no ${missing} cannot be written`, () => {
    const complete = { rule: "fmt", summary: "s", fix: "f", then: "t" };

    assert.throws(() => failure({ ...complete, [missing]: undefined }), new RegExp(missing));
  });
}

// ------------------------------------------------------------- the entry

test("blockedFor gives the could-not-run result of one rule and one next command", () => {
  const blocked = blockedFor("probe", "make probe");

  assert.deepEqual(blocked("not in a git repository", ["w"], "cd there"), {
    code: 2,
    text: failure({ rule: "probe", summary: "not in a git repository", why: ["w"], fix: "cd there", then: "make probe" }),
  });
});

const entryDirs = [];
after(() => entryDirs.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

/** A check script in a scratch directory whose `main` is `body`, ended with the shared entry. */
function probe(body) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "report-test-")));
  entryDirs.push(dir);
  const report = pathToFileURL(join(import.meta.dirname, "report.mjs")).href;
  writeFileSync(join(dir, "probe.mjs"), `import { runCheck } from ${JSON.stringify(report)};\nawait runCheck(import.meta, { rule: "probe", then: "make probe" }, ${body});\n`);
  return dir;
}

const started = (dir, file = "probe.mjs") => {
  const run = spawnSync(process.execPath, [join(dir, file)], { cwd: dir, encoding: "utf8" });
  return { code: run.status, out: run.stdout, err: run.stderr };
};

/** The report of a check that failed itself: the message, the place in the script if the error has one, the commands. */
const failed = (message, place = []) => failure({ rule: "probe", summary: "the check itself failed", why: [message, ...place], fix: "make probe", then: "make probe" });

const placeIn = (err) => err.split("\n").filter((line) => /^ +at .+:\d+:\d+/.test(line)).map((line) => line.trim());

for (const [what, body, message] of [
  ["throws", '() => { throw new Error("boom"); }', "boom"],
  ["is rejected", 'async () => { await null; throw new TypeError("late"); }', "late"],
  ["gives nothing", "() => undefined", "the check gave no result"],
  ["gives a finding with no text", "() => ({ code: 1 })", "the check gave no result"],
  ["gives a text with no exit code", '() => ({ text: "fine\\n" })', "the check gave no result"],
]) {
  test(`a check that ${what} could not run: exit 2, the message and its place in the reporter's form, nothing on stdout`, () => {
    const run = started(probe(body));
    const place = placeIn(run.err);

    assert.equal(place.length <= 1, true);
    assert.deepEqual(run, { code: 2, out: "", err: failed(message, place) });
  });
}

test("a failed check names the line of the script that threw", () => {
  const run = started(probe('() => { throw new Error("boom"); }'));

  assert.match(placeIn(run.err).join("\n"), /^at .*probe\.mjs:\d+:\d+\)?$/);
});

test("a thrown value that is not an Error is named as it is, with no place", () => {
  const run = started(probe('() => { throw "plain"; }'));

  assert.deepEqual(run, { code: 2, out: "", err: failed("plain") });
});

for (const code of [0, 1, 2]) {
  test(`a result with exit code ${code} is written as the check gave it, sync or async: text to stderr, out to stdout`, () => {
    for (const how of ["", "async "]) {
      const run = started(probe(`${how}() => ({ code: ${code}, text: "said ${code}\\n", out: "answer\\n" })`));

      assert.deepEqual(run, { code, out: "answer\n", err: `said ${code}\n` });
    }
  });
}

test("a result with no out writes nothing to stdout", () => {
  assert.deepEqual(started(probe('() => ({ code: 0, text: "" })')), { code: 0, out: "", err: "" });
});

test("a script that is imported does not run its check", () => {
  const dir = probe('() => { throw new Error("must not run"); }');
  writeFileSync(join(dir, "importer.mjs"), 'import "./probe.mjs";\n');

  assert.deepEqual(started(dir, "importer.mjs"), { code: 0, out: "", err: "" });
});
