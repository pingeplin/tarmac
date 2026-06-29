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
    expect(decide("term", 0)).toEqual<Action>({ kind: "closeTerminal", replace: true });
    expect(decide("term", 1)).toEqual<Action>({ kind: "closeTerminal", replace: false });
    expect(decide("term", 5)).toEqual<Action>({ kind: "closeTerminal", replace: false });
  });
});
