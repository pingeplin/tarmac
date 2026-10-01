import XCTest
@testable import TarmacKit

final class TermKeyModifiersTests: XCTestCase {
    private func flags(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) -> UInt {
        TermKeyBinding.modifierFlags(shift: shift, control: control, option: option, command: command)
    }

    /// The Cocoa `NSEvent.ModifierFlags` raw values, spelled out.
    func testEachModifierMapsToItsCocoaBit() {
        XCTAssertEqual(flags(), 0)
        XCTAssertEqual(flags(shift: true), 1 << 17)
        XCTAssertEqual(flags(control: true), 1 << 18)
        XCTAssertEqual(flags(option: true), 1 << 19)
        XCTAssertEqual(flags(command: true), 1 << 20)
    }

    func testModifiersCombine() {
        XCTAssertEqual(
            flags(shift: true, control: true, option: true, command: true),
            (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        )
        XCTAssertEqual(flags(option: true, command: true), (1 << 19) | (1 << 20))
    }

    /// The flags are built to be fed to `bytes`: ⌘⌫ must still be Ctrl-U, and
    /// an added modifier must still defer.
    func testTheFlagsDriveTheLineEditingKeys() {
        XCTAssertEqual(
            TermKeyBinding.bytes(keyCode: 51, modifierFlags: flags(command: true), composing: false), [0x15]
        )
        XCTAssertEqual(
            TermKeyBinding.bytes(keyCode: 123, modifierFlags: flags(option: true), composing: false), [0x1b, 0x62]
        )
        XCTAssertNil(
            TermKeyBinding.bytes(keyCode: 51, modifierFlags: flags(shift: true, command: true), composing: false)
        )
    }
}
