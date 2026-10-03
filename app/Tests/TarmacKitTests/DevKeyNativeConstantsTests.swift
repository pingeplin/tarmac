import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TarmacKit

/// The kit restates AppKit's modifier bits and key characters, and the tests
/// restate Carbon's virtual key codes, so that neither needs the frameworks.
/// This is the one place that checks them against the system's own values.
final class DevKeyNativeConstantsTests: XCTestCase {
    private typealias VK = HIToolboxVirtualKeyCodes

    func testTheModifierBitsAreNSEventModifierFlags() {
        typealias Flags = DevKeyStroke.ModifierFlags
        XCTAssertEqual(Flags.shift.rawValue, NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertEqual(Flags.control.rawValue, NSEvent.ModifierFlags.control.rawValue)
        XCTAssertEqual(Flags.option.rawValue, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(Flags.numericPad.rawValue, NSEvent.ModifierFlags.numericPad.rawValue)
        XCTAssertEqual(Flags.function.rawValue, NSEvent.ModifierFlags.function.rawValue)
    }

    func testTheKeyCodeFixtureIsCarbonsTable() {
        let ansi: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("=", kVK_ANSI_Equal), ("-", kVK_ANSI_Minus), ("]", kVK_ANSI_RightBracket), ("[", kVK_ANSI_LeftBracket),
            ("'", kVK_ANSI_Quote), (";", kVK_ANSI_Semicolon), ("\\", kVK_ANSI_Backslash), (",", kVK_ANSI_Comma),
            ("/", kVK_ANSI_Slash), (".", kVK_ANSI_Period), ("`", kVK_ANSI_Grave),
        ]
        XCTAssertEqual(ansi.count, VK.ansi.count)
        for (key, code) in ansi {
            XCTAssertEqual(VK.ansi[key], UInt16(code), String(key))
        }
        XCTAssertEqual(VK.returnKey, UInt16(kVK_Return))
        XCTAssertEqual(VK.tab, UInt16(kVK_Tab))
        XCTAssertEqual(VK.space, UInt16(kVK_Space))
        XCTAssertEqual(VK.delete, UInt16(kVK_Delete))
        XCTAssertEqual(VK.escape, UInt16(kVK_Escape))
        XCTAssertEqual(VK.leftArrow, UInt16(kVK_LeftArrow))
        XCTAssertEqual(VK.rightArrow, UInt16(kVK_RightArrow))
        XCTAssertEqual(VK.downArrow, UInt16(kVK_DownArrow))
        XCTAssertEqual(VK.upArrow, UInt16(kVK_UpArrow))
    }

    func testTheNamedKeysCarryAppKitsOwnCharacters() {
        func characters(_ combo: String) -> String? {
            guard case .stroke(let stroke) = DevKeyCombo.parse(combo) else { return nil }
            return stroke.characters
        }
        func appKit(_ value: Int) -> String { String(UnicodeScalar(UInt32(value))!) }
        XCTAssertEqual(characters("enter"), appKit(NSCarriageReturnCharacter))
        XCTAssertEqual(characters("tab"), appKit(NSTabCharacter))
        XCTAssertEqual(characters("shift+tab"), appKit(NSBackTabCharacter))
        XCTAssertEqual(characters("backspace"), appKit(NSDeleteCharacter))
        XCTAssertEqual(characters("up"), appKit(NSUpArrowFunctionKey))
        XCTAssertEqual(characters("down"), appKit(NSDownArrowFunctionKey))
        XCTAssertEqual(characters("left"), appKit(NSLeftArrowFunctionKey))
        XCTAssertEqual(characters("right"), appKit(NSRightArrowFunctionKey))
    }

    /// The table is checked against the layout itself, so a wrong shifted face
    /// cannot hide behind a fixture written from the same memory.
    func testThePhysicalKeyTableIsTheSystemsUSLayout() throws {
        let layout = try usLayout()
        for value in UInt8(0x20)...0x7E {
            let scalar = UnicodeScalar(value)
            let key = try XCTUnwrap(DevKeyCombo.physicalKey(for: scalar), String(scalar))
            XCTAssertEqual(
                translate(layout, keyCode: key.keyCode, carbonModifiers: key.shift ? shiftKey : 0),
                String(scalar)
            )
        }
    }

    func testControlLetterCharactersAreTheUSLayoutsOwn() throws {
        let layout = try usLayout()
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            guard case .stroke(let stroke) = DevKeyCombo.parse("ctrl+\(letter)") else {
                return XCTFail("ctrl+\(letter) did not plan a stroke")
            }
            XCTAssertEqual(
                translate(layout, keyCode: stroke.keyCode, carbonModifiers: controlKey),
                stroke.characters,
                String(letter)
            )
        }
    }

    private func usLayout() throws -> Data {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { throw XCTSkip("the US keyboard layout is not installed") }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private func translate(_ layout: Data, keyCode: UInt16, carbonModifiers: Int) -> String {
        var deadKeyState: UInt32 = 0
        var units = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                keyCode,
                UInt16(kUCKeyActionDown),
                UInt32((carbonModifiers >> 8) & 0xFF),
                UInt32(LMGetKbdType()),
                0,
                &deadKeyState,
                units.count,
                &length,
                &units
            )
        }
        return status == noErr ? String(utf16CodeUnits: units, count: length) : ""
    }
}
