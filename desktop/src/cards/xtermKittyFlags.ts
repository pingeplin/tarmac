import type { Terminal } from "@xterm/xterm";
import type { TermHandle } from "./TerminalCard";

// The kitty keyboard flags a program pushed (CSI > flags u). xterm 6.1 has no
// public accessor, so this reads its internals. A missing field reads as 0 —
// the routing Tarmac shipped before #149 — because a throw inside xterm's custom
// key handler would kill every key xterm handles; xterm-kitty-flags.test.ts
// fails if an upgrade moves the field.
// Takes `Terminal | TermHandle` rather than `Terminal` so the dev driver's
// narrowed handle is accepted — a `Pick` of `Terminal` is not assignable to
// `Terminal`. Narrow on purpose: `object` would also admit a card node, the deps
// bag, or a future wrapper, all of which read 0 and put `type` silently on the
// wrong delivery mode. Both imports are type-only, so the cycle with
// TerminalCard is erased at runtime.
export function xtermKittyFlags(term: Terminal | TermHandle): number {
  return (term as any)._core?.coreService?.kittyKeyboard?.flags ?? 0;
}
