import { describe, it, expect } from "vitest";
import {
  CARD_CONSOLE_BUFFER_CAP,
  formatCardArgs,
  parseCardMessage,
  pushCardConsole,
  type CardConsoleEntry,
} from "./cardConsole";

// Two specs share this file: 2607.0004 (shim payload validation — S4, S17;
// ring buffer — S5) and 2607.0006 (ready-payload parsing — S4, S14; forged
// host->shim rejection — S16). Scenario IDs collide across the specs, so
// every ID below is qualified with its spec number.
describe("parseCardMessage (2607.0004 S4)", () => {
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

describe("parseCardMessage ready payload (2607.0006 S4)", () => {
  it("accepts a ready payload with string meta (2607.0006 S4)", () => {
    const m = parseCardMessage({
      tarmac: "ready",
      meta: "magnify",
      probe: { base: 400, zoomed: 200 },
    });
    expect(m).toEqual({ kind: "ready", meta: "magnify", probe: { base: 400, zoomed: 200 } });
  });

  it("accepts a ready payload with null meta (2607.0006 S4)", () => {
    const m = parseCardMessage({
      tarmac: "ready",
      meta: null,
      probe: { base: 400, zoomed: 400 },
    });
    expect(m).toEqual({ kind: "ready", meta: null, probe: { base: 400, zoomed: 400 } });
  });

  it("passes a non-finite probe value through — finiteness is zoomCapable's verdict, not parseCardMessage's (2607.0006 S4)", () => {
    const m = parseCardMessage({
      tarmac: "ready",
      meta: "magnify",
      probe: { base: NaN, zoomed: 200 },
    });
    expect(m).toEqual({ kind: "ready", meta: "magnify", probe: { base: NaN, zoomed: 200 } });
  });
});

describe("parseCardMessage rejects junk (2607.0004 S17)", () => {
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

describe("parseCardMessage rejects malformed ready payloads (2607.0006 S14)", () => {
  it("rejects a ready payload missing probe", () => {
    expect(parseCardMessage({ tarmac: "ready", meta: "magnify" })).toBeNull();
  });

  it("rejects a ready payload with non-numeric probe fields", () => {
    expect(
      parseCardMessage({ tarmac: "ready", meta: "magnify", probe: { base: "400", zoomed: 200 } }),
    ).toBeNull();
    expect(
      parseCardMessage({ tarmac: "ready", meta: "magnify", probe: { base: 400, zoomed: null } }),
    ).toBeNull();
  });

  it("rejects a ready payload with non-string, non-null meta", () => {
    expect(
      parseCardMessage({ tarmac: "ready", meta: 1, probe: { base: 400, zoomed: 200 } }),
    ).toBeNull();
  });

  it("rejects a bare ready payload", () => {
    expect(parseCardMessage({ tarmac: "ready" })).toBeNull();
  });

  it("rejects a ready payload with the meta key absent — undefined is neither string nor null (2607.0006 S14, guards 2607.0006 S8)", () => {
    expect(
      parseCardMessage({ tarmac: "ready", probe: { base: 400, zoomed: 200 } }),
    ).toBeNull();
  });

  it("rejects a ready payload with null probe (2607.0006 S14)", () => {
    expect(parseCardMessage({ tarmac: "ready", meta: "magnify", probe: null })).toBeNull();
  });

  it("still parses previously valid console and escape payloads unchanged", () => {
    expect(parseCardMessage({ tarmac: "escape" })).toEqual({ kind: "escape" });
    expect(parseCardMessage({ tarmac: "console", level: "warn", args: ["a", 1] })).toEqual({
      kind: "console",
      level: "warn",
      args: ["a", 1],
    });
  });
});

describe("parseCardMessage rejects forged host->shim payloads (2607.0006 S16)", () => {
  it("rejects an inbound {tarmac:'zoom'} payload — not a host message kind", () => {
    expect(parseCardMessage({ tarmac: "zoom", z: 40 })).toBeNull();
  });
});

describe("pushCardConsole ring buffer (2607.0004 S5)", () => {
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
