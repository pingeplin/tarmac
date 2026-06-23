// Port of TarmacKit/TermKeyBinding.swift (issue #21) — the pure decision for the
// Ghostty-parity macOS line-editing keys in a terminal card: ⌘⌫ / ⌘← / ⌘→ and
// ⌥↑ / ⌥↓. Given a key event it returns the bytes to emit to the PTY, or `null`
// to defer to xterm.js's own handling (the DOM analogue of deferring to
// SwiftTerm's `keyDown`).
//
// REWRITE for the DOM, not a 1:1 port. The Swift side matched physical Carbon
// keyCodes (51 ⌫, 123 ← , 124 →, 125 ↓, 126 ↑) and masked raw NSEvent modifier
// bits. Here we key off `KeyboardEvent.code` (also layout-/CapsLock-independent)
// and take the four intent modifiers as plain booleans. CapsLock is NOT an intent
// modifier — instead of masking it out, it simply has no place in the input, so
// it can never affect the comparison (a CJK user toggling CapsLock for ASCII/中文
// switching gets the identical result).
//
// Matching is by code AND an *exact* intent-modifier set: the ⌘ rows fire only
// when meta is the SOLE intent modifier (no alt/ctrl/shift), the ⌥ rows only when
// alt is sole. So ⌃⌘←, ⌥⌘←, ⇧⌘←, ⇧⌥↑, … all defer. While a CJK IME is composing
// or a kitty keyboard program is active we return `null` unconditionally, so
// neither the candidate preview nor a kitty-aware app (Claude Code, neovim) is
// ever corrupted.

export interface TermKeyInput {
  /** A `KeyboardEvent.code`: 'Backspace' | 'ArrowLeft' | 'ArrowRight' | 'ArrowUp' | 'ArrowDown'. */
  code: string;
  meta: boolean;
  alt: boolean;
  ctrl: boolean;
  shift: boolean;
  /** A CJK IME is mid-composition — defer everything. */
  composing: boolean;
  /** A kitty keyboard program owns the keys — defer everything. */
  kittyActive: boolean;
}

/**
 * Bytes to emit for a recognized shortcut, or `null` to defer to xterm.js.
 *
 *   ⌘⌫  → [0x15]                          Ctrl-U  (delete to line start)
 *   ⌘←  → [0x01]                          Ctrl-A  (jump to line start)
 *   ⌘→  → [0x05]                          Ctrl-E  (jump to line end)
 *   ⌥↑  → [0x1b,0x5b,0x31,0x3b,0x33,0x41] ESC[1;3A
 *   ⌥↓  → [0x1b,0x5b,0x31,0x3b,0x33,0x42] ESC[1;3B
 *
 * Returns `null` unconditionally while composing or kittyActive.
 */
export function bytes(input: TermKeyInput): number[] | null {
  if (input.composing || input.kittyActive) return null;

  // Exact intent-modifier gating: meta-only means meta down and the other three
  // up; alt-only the mirror. CapsLock is intentionally absent from the input.
  const metaOnly = input.meta && !input.alt && !input.ctrl && !input.shift;
  const altOnly = input.alt && !input.meta && !input.ctrl && !input.shift;

  switch (input.code) {
    case "Backspace":
      return metaOnly ? [0x15] : null;
    case "ArrowLeft":
      return metaOnly ? [0x01] : null;
    case "ArrowRight":
      return metaOnly ? [0x05] : null;
    case "ArrowUp":
      return altOnly ? [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x41] : null;
    case "ArrowDown":
      return altOnly ? [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x42] : null;
    default:
      return null;
  }
}
