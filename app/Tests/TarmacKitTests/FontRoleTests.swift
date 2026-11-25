import XCTest

@testable import TarmacKit

/// 2610.0005 "Family in effect follows each role's rules": which saved family a role really uses.
final class FontRoleTests: XCTestCase {
    private let menlo = InstalledFamily(name: "Menlo", fixedPitch: true)
    private let helvetica = InstalledFamily(name: "Helvetica", fixedPitch: false)
    private let hidden = InstalledFamily(name: ".AppleSystemUIFontMonospaced", fixedPitch: true)

    func testEachRoleHasItsOwnPrefsKey() {
        XCTAssertEqual(FontRole.allCases.map(\.prefsKey), ["terminal_font", "interface_font", "document_font"])
    }

    /// 2610.0006 "Font roles define their size rules", and #394: Interface has a size too.
    func testEachRoleHasASizeRule() {
        XCTAssertEqual(FontRole.terminal.sizeRule, FontSizeRule(range: 8...32, standard: 16))
        XCTAssertEqual(FontRole.interface.sizeRule, FontSizeRule(range: 8...16, standard: 10.5))
        XCTAssertEqual(FontRole.document.sizeRule, FontSizeRule(range: 10...24, standard: 14))
        XCTAssertEqual(FontSizeRule.step, 0.5)
        XCTAssertEqual(
            FontRole.allCases.map(\.sizePrefsKey), ["terminal_font_size", "interface_font_size", "document_font_size"]
        )
    }

    /// "Settings window opens with three font rows" — the Settings rows, in their order.
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
