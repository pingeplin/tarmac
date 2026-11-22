import assert from "node:assert/strict";
import { test } from "node:test";

import { failure } from "./report.mjs";

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

test("a failure with no fix cannot be written", () => {
  assert.throws(() => failure({ rule: "fmt", summary: "s", then: "t" }), /fix/);
});

test("a failure with no then cannot be written", () => {
  assert.throws(() => failure({ rule: "fmt", summary: "s", fix: "f" }), /then/);
});
