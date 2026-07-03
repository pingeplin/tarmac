import { describe, it, expect } from "vitest";
import {
  CARD_CONSOLE_BUFFER_CAP,
  formatCardArgs,
  parseCardMessage,
  pushCardConsole,
  type CardConsoleEntry,
} from "./cardConsole";

// Spec 2607.0004 — shim payload validation (S4, S17) and ring buffer (S5).
describe("parseCardMessage (S4)", () => {
  it("accepts a well-formed console payload", () => {
    const m = parseCardMessage({ tarmac: "console", level: "warn", args: ["a", 1] });
    expect(m).toEqual({ kind: "console", level: "warn", args: ["a", 1] });
  });

  it("accepts every console level", () => {
    for (const level of ["log", "info", "warn", "error"]) {
      expect(parseCardMessage({ tarmac: "console", level, args: [] })).toEqual({
        kind: "console",
        level,
        args: [],
      });
    }
  });

  it("accepts the escape payload", () => {
    expect(parseCardMessage({ tarmac: "escape" })).toEqual({ kind: "escape" });
  });
});

describe("parseCardMessage rejects junk (S17)", () => {
  it("rejects non-tarmac and malformed payloads", () => {
    expect(parseCardMessage(null)).toBeNull();
    expect(parseCardMessage("hello")).toBeNull();
    expect(parseCardMessage(42)).toBeNull();
    expect(parseCardMessage({})).toBeNull();
    expect(parseCardMessage({ tarmac: "bogus" })).toBeNull();
    expect(parseCardMessage({ level: "log", args: [] })).toBeNull();
  });

  it("rejects console payloads with unknown level or missing args", () => {
    expect(parseCardMessage({ tarmac: "console", level: "debug", args: [] })).toBeNull();
    expect(parseCardMessage({ tarmac: "console", level: "log" })).toBeNull();
    expect(parseCardMessage({ tarmac: "console", level: "log", args: "x" })).toBeNull();
    expect(parseCardMessage({ tarmac: "console", level: 3, args: [] })).toBeNull();
  });
});

describe("pushCardConsole ring buffer (S5)", () => {
  const entry = (n: number): CardConsoleEntry => ({ level: "log", args: [n] });

  it("appends in order below the cap", () => {
    let buf: CardConsoleEntry[] = [];
    buf = pushCardConsole(buf, entry(1));
    buf = pushCardConsole(buf, entry(2));
    expect(buf.map((e) => e.args[0])).toEqual([1, 2]);
  });

  it("drops the oldest beyond the cap and preserves order", () => {
    let buf: CardConsoleEntry[] = [];
    for (let i = 0; i < CARD_CONSOLE_BUFFER_CAP; i++) buf = pushCardConsole(buf, entry(i));
    expect(buf).toHaveLength(CARD_CONSOLE_BUFFER_CAP);

    buf = pushCardConsole(buf, entry(CARD_CONSOLE_BUFFER_CAP));
    expect(buf).toHaveLength(CARD_CONSOLE_BUFFER_CAP);
    expect(buf[0].args[0]).toBe(1); // oldest (0) dropped
    expect(buf[buf.length - 1].args[0]).toBe(CARD_CONSOLE_BUFFER_CAP);
  });

  it("honors an explicit cap", () => {
    let buf: CardConsoleEntry[] = [];
    for (let i = 0; i < 5; i++) buf = pushCardConsole(buf, entry(i), 3);
    expect(buf.map((e) => e.args[0])).toEqual([2, 3, 4]);
  });
});

describe("formatCardArgs", () => {
  it("joins primitives with spaces", () => {
    expect(formatCardArgs(["tick", 42, true])).toBe("tick 42 true");
  });

  it("stringifies objects and arrays instead of [object Object]", () => {
    expect(formatCardArgs([{ a: 1 }, [1, 2]])).toBe('{"a":1} [1,2]');
  });

  it("renders null and undefined literally", () => {
    expect(formatCardArgs([null, undefined])).toBe("null undefined");
  });
});
