// Tripwire for `desktop/src/cards/xtermKittyFlags.ts` (#149). TerminalCard's key
// routing reads the kitty keyboard flags through xterm internals — there is no
// public accessor — and a missing field falls back to 0. That fallback is
// silent by design, so an xterm upgrade that moves the field would quietly put
// routing back on flags-0 behaviour. This drives a real xterm Terminal and fails
// instead.

import { describe, it, expect } from "vitest";
import { Terminal } from "@xterm/xterm";
import { xtermKittyFlags } from "./cards/xtermKittyFlags";

describe("xtermKittyFlags", () => {
  it("reads the kitty keyboard flags a program pushes to a real xterm", async () => {
    const term = new Terminal({ allowProposedApi: true, vtExtensions: { kittyKeyboard: true } });
    try {
      expect(xtermKittyFlags(term)).toBe(0);
      await new Promise<void>((resolve) => term.write("\x1b[>13u", resolve));
      expect(xtermKittyFlags(term)).toBe(13);
    } finally {
      term.dispose();
    }
  });

  it("reads 0 when xterm's internal field is missing", () => {
    expect(xtermKittyFlags({} as unknown as Terminal)).toBe(0);
  });
});
