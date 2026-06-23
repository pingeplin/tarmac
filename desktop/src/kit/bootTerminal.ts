// Port of TarmacKit/BootTerminal.swift — the single home for terminal-id
// minting (boot / ⌘T / restored-extra terminals). Isolated so id minting lives
// in one place (callers use `mint()` instead of scattering UUID generation),
// giving one spot to change the scheme later (e.g. for deterministic ids).
// Swift used `UUID().uuidString`; the TS analogue is `crypto.randomUUID()`.

/** A fresh globally-unique terminal id. */
export function mint(): string {
  return crypto.randomUUID();
}
