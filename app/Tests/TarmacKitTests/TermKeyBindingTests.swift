import XCTest
@testable import TarmacKit

/// 2606.0007 / issue #21 — the pure decider for Ghostty-parity macOS line-editing
/// keys in a terminal card. Every test asserts `TermKeyBinding.bytes(...)`
/// directly. The raw `NSEvent.ModifierFlags` bits are spelled out here (the same
/// stable Cocoa values the decider mirrors). macOS always sets
/// function+numericPad on the four arrow keyCodes, never on ⌫ — so every arrow
/// case passes those two bits, exercising the real mask the decider must perform.
final class TermKeyBindingTests: XCTestCase {
    // NSEvent.ModifierFlags raw bits.
    private let capsLock: UInt   = 0x1_0000   // 1 << 16
    private let shift: UInt      = 0x2_0000   // 1 << 17
    private let control: UInt    = 0x4_0000   // 1 << 18
    private let option: UInt     = 0x8_0000   // 1 << 19
    private let command: UInt    = 0x10_0000  // 1 << 20
    private let numericPad: UInt = 0x20_0000  // 1 << 21
    private let function: UInt    = 0x80_0000 // 1 << 23

    // Physical Carbon keyCodes.
    private let delete: UInt16 = 51
    private let left: UInt16   = 123
    private let right: UInt16  = 124
    private let down: UInt16   = 125
    private let up: UInt16     = 126

    /// The two bits macOS always rides on an arrow-key event.
    private var arrow: UInt { function | numericPad }

    private func decide(_ keyCode: UInt16, _ mods: UInt, composing: Bool = false) -> [UInt8]? {
        TermKeyBinding.bytes(keyCode: keyCode, modifierFlags: mods, composing: composing)
    }

    // Expected byte sequences.
    private let ctrlU: [UInt8] = [0x15]
    private let ctrlA: [UInt8] = [0x01]
    private let ctrlE: [UInt8] = [0x05]
    private let optUp: [UInt8] = [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x41]   // ESC[1;3A
    private let optDown: [UInt8] = [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x42] // ESC[1;3B
    private let optLeft: [UInt8] = [0x1b, 0x62]                          // ESC b (backward-word)
    private let optRight: [UInt8] = [0x1b, 0x66]                         // ESC f (forward-word)

    // MARK: Happy path — Ghostty byte parity (S1–S5)

    func testCmdDeleteSendsCtrlU() {            // S1 — ⌫ is not an arrow ⇒ command only
        XCTAssertEqual(decide(delete, command), ctrlU)
    }
    func testCmdLeftSendsCtrlA() {              // S2 — ← is an arrow ⇒ +function+numericPad
        XCTAssertEqual(decide(left, command | arrow), ctrlA)
    }
    func testCmdRightSendsCtrlE() {             // S3
        XCTAssertEqual(decide(right, command | arrow), ctrlE)
    }
    func testOptUpSendsEsc1Semi3A() {           // S4
        XCTAssertEqual(decide(up, option | arrow), optUp)
    }
    func testOptDownSendsEsc1Semi3B() {         // S5
        XCTAssertEqual(decide(down, option | arrow), optDown)
    }
    func testOptLeftSendsEscB() {               // S15 — word-jump, as Terminal.app / iTerm2 send
        XCTAssertEqual(decide(left, option | arrow), optLeft)
    }
    func testOptRightSendsEscF() {              // S16
        XCTAssertEqual(decide(right, option | arrow), optRight)
    }

    // MARK: CapsLock invariance — all five rows (S6)

    /// CapsLock-on (routine for CJK ASCII/中文 switching) must yield the identical
    /// result to CapsLock-off for every recognized shortcut.
    func testCapsLockNeverChangesOutcome() {    // S6
        XCTAssertEqual(decide(delete, command | capsLock), ctrlU)
        XCTAssertEqual(decide(left, command | arrow | capsLock), ctrlA)
        XCTAssertEqual(decide(right, command | arrow | capsLock), ctrlE)
        XCTAssertEqual(decide(up, option | arrow | capsLock), optUp)
        XCTAssertEqual(decide(down, option | arrow | capsLock), optDown)
        XCTAssertEqual(decide(left, option | arrow | capsLock), optLeft)
        XCTAssertEqual(decide(right, option | arrow | capsLock), optRight)
    }

    // MARK: Exact-modifier gating (S7–S8)

    /// ⌘ shortcuts fire only when ⌘ is the SOLE intent modifier — adding control,
    /// option, or shift must defer to super (nil), keeping ⌃⌘← etc. unchanged.
    /// Checked across all three ⌘ rows (51/123/124) so loosening any single row's
    /// equality can't survive.
    func testCmdWithExtraIntentModifierDefers() {  // S7
        XCTAssertNil(decide(left, command | control | arrow))
        XCTAssertNil(decide(left, command | option | arrow))
        XCTAssertNil(decide(left, command | shift | arrow))
        XCTAssertNil(decide(delete, command | control))       // ⌘⌫ row (no arrow bits)
        XCTAssertNil(decide(right, command | shift | arrow))  // ⌘→ row
    }
    func testShiftWithOptArrowDefers() {        // S8 — ⇧⌥↑ / ⇧⌥↓ (both ⌥ rows)
        XCTAssertNil(decide(up, option | shift | arrow))
        XCTAssertNil(decide(down, option | shift | arrow))
    }
    func testShiftWithOptLeftRightDefers() {    // S17 — ⇧⌥← / ⇧⌥→
        XCTAssertNil(decide(left, option | shift | arrow))
        XCTAssertNil(decide(right, option | shift | arrow))
    }

    // MARK: IME gate (S9, S18) — paired bytes-off / nil-on on identical input
    // There is no S10: the kitty gate was dropped (#153) — the rows pre-empt a
    // kitty program's encoder like Ghostty's `text:` keybinds, so `bytes` takes no
    // kitty input for a test to flip.

    func testComposingDefers() {                // S9
        XCTAssertEqual(decide(delete, command, composing: false), ctrlU)
        XCTAssertNil(decide(delete, command, composing: true))
        // Also on an ⌥-arrow row, so the gate can't be keyCode-specific.
        XCTAssertEqual(decide(up, option | arrow, composing: false), optUp)
        XCTAssertNil(decide(up, option | arrow, composing: true))
    }
    func testComposingDefersTheOptLeftRightRowsToo() {  // S18
        XCTAssertEqual(decide(left, option | arrow, composing: false), optLeft)
        XCTAssertNil(decide(left, option | arrow, composing: true))
        XCTAssertEqual(decide(right, option | arrow, composing: false), optRight)
        XCTAssertNil(decide(right, option | arrow, composing: true))
    }

    // MARK: No-regression — keys that must stay SwiftTerm's (S11–S14)

    /// ⌃←/→ are claimed by macOS Mission Control — we must not steal them either.
    /// (S11's ⌥←/→ half is superseded by S15/S16.)
    func testControlLeftRightDefer() {          // S19
        XCTAssertNil(decide(left, control | arrow))
        XCTAssertNil(decide(right, control | arrow))
    }
    func testOptDeleteWordDeleteDefers() {      // S12 — ⌥⌫ word delete (⌫ not an arrow)
        XCTAssertNil(decide(delete, option))
    }
    func testPlainKeysDefer() {                 // S13 — bare ⌫ and plain arrows
        XCTAssertNil(decide(delete, 0))
        XCTAssertNil(decide(left, arrow))
        XCTAssertNil(decide(right, arrow))
        XCTAssertNil(decide(up, arrow))
        XCTAssertNil(decide(down, arrow))
    }
    func testUnrecognizedKeyCodeDefers() {      // S14 — guards the default even with ⌘ held
        XCTAssertNil(decide(0, command))   // 'a'
        XCTAssertNil(decide(36, command))  // Return
    }
}
