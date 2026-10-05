import XCTest
@testable import TarmacKit

/// 2610.0005: the list a Settings row shows and the entry it selects.
final class FontMenuTests: XCTestCase {
    private func family(_ name: String, fixed: Bool = true) -> InstalledFamily {
        InstalledFamily(name: name, fixedPitch: fixed)
    }

    private var installed: [InstalledFamily] {
        [family("Menlo"), family("Helvetica", fixed: false), family("Andale Mono")]
    }

    /// S6
    func testAFixedPitchRoleListsOnlyFixedPitchFamilies() {
        for role in [FontRole.terminal, .interface] {
            let menu = FontMenu(role: role, installed: installed, saved: nil)
            XCTAssertEqual(menu.titles, ["System Default", "Andale Mono", "Menlo"], "\(role)")
        }
    }

    /// S7
    func testTheDocumentRoleListsEveryFamily() {
        let menu = FontMenu(role: .document, installed: installed, saved: nil)
        XCTAssertEqual(menu.titles, ["System Default", "Andale Mono", "Helvetica", "Menlo"])
    }

    /// S8
    func testTheSavedFamilyIsSelected() {
        let menu = FontMenu(role: .terminal, installed: installed, saved: "Menlo")
        XCTAssertEqual(menu.selected, 2)
        XCTAssertEqual(menu.choice(at: 2), "Menlo")
        XCTAssertEqual(menu.choice(at: 1), "Andale Mono")
        XCTAssertNil(menu.choice(at: 0))
    }

    /// S23
    func testHiddenSystemFamiliesAreNotListed() {
        let menu = FontMenu(
            role: .terminal, installed: [family(".SF NS Mono"), family(".AppleSystemUIFontMonospaced"), family("Menlo")],
            saved: ".SF NS Mono"
        )
        XCTAssertEqual(menu.families, ["Menlo"])
        XCTAssertEqual(menu.selected, 0)
    }

    /// S24
    func testAFamilyIsListedOnce() {
        let menu = FontMenu(role: .terminal, installed: [family("Menlo"), family("Monaco"), family("Menlo")], saved: "Monaco")
        XCTAssertEqual(menu.families, ["Menlo", "Monaco"])
        XCTAssertEqual(menu.selected, 2)
    }

    /// S25 — the order is the same on every Mac and for every input order.
    func testFamiliesAreOrderedWithoutRegardToCaseThenByCodePoint() {
        let names = ["menlo", "Menlo", "Andale Mono", "andale mono"]
        for rotation in 0..<names.count {
            let input = (names[rotation...] + names[..<rotation]).map { family($0) }
            XCTAssertEqual(
                FontMenu(role: .terminal, installed: input, saved: nil).families,
                ["Andale Mono", "andale mono", "Menlo", "menlo"], "rotation \(rotation)"
            )
        }
    }

    /// S26
    func testASavedFamilyTheListDoesNotHoldSelectsTheSystemDefault() {
        XCTAssertEqual(FontMenu(role: .terminal, installed: installed, saved: "Fira Code").selected, 0)
        XCTAssertEqual(FontMenu(role: .terminal, installed: installed, saved: "Helvetica").selected, 0)
        XCTAssertEqual(FontMenu(role: .document, installed: installed, saved: "Helvetica").selected, 2)
        XCTAssertEqual(FontMenu(role: .terminal, installed: installed, saved: "menlo").selected, 0)
        XCTAssertEqual(FontMenu(role: .terminal, installed: installed, saved: nil).selected, 0)
    }

    /// S27
    func testAnIndexOutsideTheListIsNoChoice() {
        let menu = FontMenu(role: .terminal, installed: installed, saved: nil)
        XCTAssertNil(menu.choice(at: -1))
        XCTAssertNil(menu.choice(at: menu.titles.count))
        XCTAssertEqual(menu.choice(at: menu.titles.count - 1), "Menlo")
    }

    /// S28
    func testWithNoFamilyOnlyTheSystemDefaultIsListed() {
        let menu = FontMenu(role: .document, installed: [], saved: "Menlo")
        XCTAssertEqual(menu.titles, ["System Default"])
        XCTAssertEqual(menu.selected, 0)
    }

    /// The row and the family in effect are the same answer.
    func testTheSelectedEntryIsTheFamilyInEffect() {
        for role in FontRole.allCases {
            for saved in [nil, "Menlo", "Helvetica", "menlo", "Fira Code"] {
                let menu = FontMenu(role: role, installed: installed, saved: saved)
                let inEffect = role.familyInEffect(saved: saved, installed: installed.first { $0.name == saved })
                XCTAssertEqual(menu.choice(at: menu.selected), inEffect, "\(role) \(saved ?? "nil")")
            }
        }
    }
}
