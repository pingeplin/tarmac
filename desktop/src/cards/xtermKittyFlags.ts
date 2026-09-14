import type { Terminal } from "@xterm/xterm";

// The kitty keyboard flags a program pushed (CSI > flags u). xterm 6.1 has no
// public accessor, so this reads its internals. A missing field reads as 0 —
// the routing Tarmac shipped before #149 — because a throw inside xterm's custom
// key handler would kill every key xterm handles; xterm-kitty-flags.test.ts
// fails if an upgrade moves the field.
export function xtermKittyFlags(term: Terminal): number {
  return (term as any)._core?.coreService?.kittyKeyboard?.flags ?? 0;
}
