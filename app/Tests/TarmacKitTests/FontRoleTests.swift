import XCTest
@testable import TarmacKit

/// 2610.0005 S50: which saved family a role really uses.
final class FontRoleTests: XCTestCase {
    private let menlo = InstalledFamily(name: "Menlo", fixedPitch: true)
    private let helvetica = InstalledFamily(name: "Helvetica", fixedPitch: false)
    private let hidden = InstalledFamily(name: ".AppleSystemUIFontMonospaced", fixedPitch: true)

    func testEachRoleHasItsOwnPrefsKey() {
        XCTAssertEqual(FontRole.allCases.map(\.prefsKey), ["terminal_font", "interface_font", "document_font"])
    }

    /// 2610.0006 S1 — Interface has no size: its chrome is set at many.
    func testTheTerminalAndTheDocumentHaveASizeRule() {
        XCTAssertEqual(FontRole.terminal.sizeRule, FontSizeRule(range: 8...32, standard: 16))
        XCTAssertEqual(FontRole.document.sizeRule, FontSizeRule(range: 10...24, standard: 14))
        XCTAssertNil(FontRole.interface.sizeRule)
        XCTAssertEqual(FontSizeRule.step, 0.5)
        XCTAssertEqual(
            FontRole.allCases.map(\.sizePrefsKey), ["terminal_font_size", "interface_font_size", "document_font_size"]
        )
    }

    /// S14 — the Settings rows, in their order.
    func testTheRolesAreTitledInRowOrder() {
        XCTAssertEqual(FontRole.allCases.map(\.title), ["Terminal", "Interface", "Document"])
    }

    func testAFixedPitchRoleUsesOnlyAnInstalledFixedPitchFamily() {
        for role in [FontRole.terminal, .interface] {
            XCTAssertTrue(role.fixedPitchOnly)
            XCTAssertNil(role.familyInEffect(saved: nil, installed: menlo), "\(role)")
            XCTAssertNil(role.familyInEffect(saved: "Menlo", installed: nil), "\(role)")
            XCTAssertNil(role.familyInEffect(saved: "Helvetica", installed: helvetica), "\(role)")
            XCTAssertEqual(role.familyInEffect(saved: "Menlo", installed: menlo), "Menlo", "\(role)")
            XCTAssertNil(role.familyInEffect(saved: "menlo", installed: menlo), "\(role)")
            XCTAssertNil(role.familyInEffect(saved: hidden.name, installed: hidden), "\(role)")
        }
    }

    func testTheDocumentRoleTakesAnyInstalledFamily() {
        XCTAssertFalse(FontRole.document.fixedPitchOnly)
        XCTAssertEqual(FontRole.document.familyInEffect(saved: "Helvetica", installed: helvetica), "Helvetica")
        XCTAssertNil(FontRole.document.familyInEffect(saved: "Helvetica", installed: nil))
        XCTAssertNil(FontRole.document.familyInEffect(saved: hidden.name, installed: hidden))
    }
}
