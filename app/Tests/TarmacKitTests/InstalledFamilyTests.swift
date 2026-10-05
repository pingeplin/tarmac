import XCTest
@testable import TarmacKit

/// 2610.0005 S51: which member of a family is its regular face, and so
/// whether the family is fixed pitch.
final class InstalledFamilyTests: XCTestCase {
    private typealias Face = InstalledFamily.Face

    private func fixedPitch(_ faces: [Face]) -> Bool? {
        InstalledFamily(name: "Family", faces: faces)?.fixedPitch
    }

    func testTheFamilyKeepsItsName() {
        let faces = [Face(weight: 5, italic: false, fixedPitch: true)]
        XCTAssertEqual(InstalledFamily(name: "Menlo", faces: faces), InstalledFamily(name: "Menlo", fixedPitch: true))
    }

    func testTheUprightFaceNearestRegularWeightDecides() {
        let light = Face(weight: 3, italic: false, fixedPitch: true)
        let medium = Face(weight: 6, italic: false, fixedPitch: false)
        let bold = Face(weight: 9, italic: false, fixedPitch: true)
        XCTAssertEqual(fixedPitch([light, medium, bold]), false)
        XCTAssertEqual(fixedPitch([bold, light]), true)
        XCTAssertEqual(fixedPitch([Face(weight: 9, italic: false, fixedPitch: false), Face(weight: 4, italic: false, fixedPitch: true)]), true)
    }

    /// Osaka lists its proportional face before Osaka-Mono, both at weight 5.
    func testOnATieTheFirstListedFaceDecides() {
        let proportional = Face(weight: 5, italic: false, fixedPitch: false)
        let mono = Face(weight: 5, italic: false, fixedPitch: true)
        XCTAssertEqual(fixedPitch([proportional, mono]), false)
        XCTAssertEqual(fixedPitch([mono, proportional]), true)
    }

    func testAnItalicFaceDoesNotDecideWhileAnUprightOneExists() {
        let italic = Face(weight: 5, italic: true, fixedPitch: true)
        let uprightBold = Face(weight: 9, italic: false, fixedPitch: false)
        XCTAssertEqual(fixedPitch([italic, uprightBold]), false)
    }

    func testAFamilyOfItalicsOnlyIsJudgedByThem() {
        XCTAssertEqual(fixedPitch([Face(weight: 5, italic: true, fixedPitch: true)]), true)
    }

    func testAFamilyWithNoFaceIsNotInstalled() {
        XCTAssertNil(InstalledFamily(name: "Family", faces: []))
    }
}
