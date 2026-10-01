/// Pure decision for the Ghostty-parity macOS line-editing keys in a terminal
/// card (issue #21): ⌘⌫ / ⌘← / ⌘→ and ⌥↑ / ⌥↓. Given a key event's physical
/// `keyCode`, its raw `NSEvent.ModifierFlags` bitfield, and the terminal's IME /
/// kitty state, it returns the bytes to emit to the PTY, or `nil` to defer to
/// SwiftTerm's own `keyDown`. Kept in TarmacKit so the modifier masking and the
/// three gates are unit-tested away from AppKit; `AppController`'s escMonitor is
/// only a thin wire that `send()`s a non-nil result to the focused terminal and
/// otherwise defers (CLAUDE.md: only TarmacKit is unit-tested). Mirrors the
/// `EscFocusAction` / `FocusedClose` pure-rule pattern.
///
/// Matching is by physical Carbon keyCode (layout- and CapsLock-independent) and
/// by an *exact* intent-modifier set: the raw bitfield is masked to
/// command/control/option/shift — dropping CapsLock, function, and numericPad —
/// and must equal exactly the one modifier shown. So ⌃⌘←, ⌥⌘←, ⇧⌘←, ⇧⌥↑, … all
/// fall through to `super`, and a CJK user with CapsLock toggled (a routine state
/// for input-method ASCII/中文 switching) gets the identical result.
public enum TermKeyBinding {
    // Stable Cocoa `NSEvent.ModifierFlags` raw bits, mirrored here so the masking
    // stays AppKit-free and testable. capsLock (0x1_0000), numericPad (0x20_0000),
    // and function (0x80_0000) are deliberately left OUT of the mask — the last
    // two always ride on the arrow keys, capsLock is routine for CJK users — so
    // none of them can affect the comparison.
    static let shift: UInt   = 0x2_0000   // 1 << 17
    static let control: UInt = 0x4_0000   // 1 << 18
    static let option: UInt  = 0x8_0000   // 1 << 19
    static let command: UInt = 0x10_0000  // 1 << 20
    static let intentMask: UInt = shift | control | option | command

    /// Bytes to emit for a recognized shortcut, or `nil` to defer to SwiftTerm.
    /// Returns `nil` unconditionally while a CJK IME is composing or a kitty
    /// keyboard program is active, so neither the candidate preview nor a
    /// kitty-aware app (Claude Code, neovim) is ever corrupted.
    public static func bytes(keyCode: UInt16,
                             modifierFlags: UInt,
                             composing: Bool,
                             kittyActive: Bool) -> [UInt8]? {
        if composing || kittyActive { return nil }
        let mods = modifierFlags & intentMask
        switch keyCode {
        case 51  where mods == command: return [0x15]                                // ⌘⌫ → Ctrl-U (delete to line start)
        case 123 where mods == command: return [0x01]                                // ⌘← → Ctrl-A (jump to line start)
        case 124 where mods == command: return [0x05]                                // ⌘→ → Ctrl-E (jump to line end)
        case 126 where mods == option:  return [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x41]  // ⌥↑ → ESC[1;3A
        case 125 where mods == option:  return [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x42]  // ⌥↓ → ESC[1;3B
        default: return nil
        }
    }
}
