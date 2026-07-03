import { describe, it, expect } from "vitest";
import { decide, type Action } from "./focusedClose";

// Port of FocusedCloseTests.swift (2606.0004): ⌘W "close the focused card"
// routing (issue #15). Nothing focused ⇒ no-op; a doc shelves; a terminal closes
// and only replaces when it was the board's last live terminal.
describe("FocusedClose", () => {
  // Nothing focused ⇒ no-op, regardless of the live-terminal count.
  it("none is noop", () => {
    expect(decide("none", 0)).toEqual<Action>("noop");
    expect(decide("none", 3)).toEqual<Action>("noop");
  });

  // A focused doc always shelves (recoverable), independent of terminals.
  it("doc shelves", () => {
    expect(decide("doc", 0)).toEqual<Action>("shelfDoc");
    expect(decide("doc", 3)).toEqual<Action>("shelfDoc");
  });

  // A focused terminal closes; `replace` is true ONLY when it was the last live
  // terminal (otherLive === 0), mirroring the clean-exit last-terminal guarantee.
  // The 0→replace / 1→undo boundary is the load-bearing anti-mutation pin (it
  // fails if `replace` is hard-wired or keyed off the wrong threshold).
  it("terminal replaces only when last", () => {
    expect(decide("term", 0, false)).toEqual<Action>({
      kind: "closeTerminal",
      replace: true,
      signalClose: true,
    });
    expect(decide("term", 1, false)).toEqual<Action>({
      kind: "closeTerminal",
      replace: false,
      signalClose: true,
    });
    expect(decide("term", 5, false)).toEqual<Action>({
      kind: "closeTerminal",
      replace: false,
      signalClose: true,
    });
  });

  // Omitting `dead` defaults to `false` — pins the default-arg contract for any
  // future two-arg caller (today's one production call site passes `card.dead`).
  it("omitted dead defaults to false (signalClose true)", () => {
    expect(decide("term", 0)).toEqual<Action>({
      kind: "closeTerminal",
      replace: true,
      signalClose: true,
    });
    expect(decide("term", 3)).toEqual<Action>({
      kind: "closeTerminal",
      replace: false,
      signalClose: true,
    });
  });

  // A dead terminal has no live pty to signal: signalClose is false regardless
  // of otherLive, but replace still follows the same otherLive===0 rule as the
  // live case — dead must not change `replace`'s derivation. This is the
  // load-bearing anti-mutation pin for `signalClose = !dead`: a hard-wired
  // `signalClose: true` (ignoring `dead`) fails both assertions below.
  it("dead terminal never signals close, but replace is unaffected", () => {
    expect(decide("term", 0, true)).toEqual<Action>({
      kind: "closeTerminal",
      replace: true,
      signalClose: false,
    });
    expect(decide("term", 3, true)).toEqual<Action>({
      kind: "closeTerminal",
      replace: false,
      signalClose: false,
    });
  });

  // `dead` is meaningless for "doc"/"none" — passing it must not regress those
  // branches.
  it("dead argument is ignored for doc/none", () => {
    expect(decide("doc", 0, true)).toEqual<Action>("shelfDoc");
    expect(decide("none", 0, true)).toEqual<Action>("noop");
  });
});
