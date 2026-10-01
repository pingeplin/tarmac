import XCTest
@testable import TarmacKit

/// `RustPathExtension` stands in for `std::path::Path::extension`, which splits
/// the last component after dropping `.` and empty ones — not `NSString.pathExtension`.
final class RustPathExtensionTests: XCTestCase {
    func testMatchesRustPathExtensionRowForRow() {
        for (path, ext, _) in SchemeParityTables.extensions {
            XCTAssertEqual(RustPathExtension.of(path).map(SchemeFixtures.bytes), ext.map(SchemeFixtures.bytes), path)
        }
    }

    func testATrailingSlashOrDotDoesNotHideTheName() {
        XCTAssertEqual(RustPathExtension.of("/d/x.jpeg/"), "jpeg")
        XCTAssertEqual(RustPathExtension.of("/d/x.jpeg/./"), "jpeg")
    }

    func testAParentComponentHasNoName() {
        XCTAssertNil(RustPathExtension.of("/d/x.png/.."))
    }

    func testALeadingDotIsAHiddenNameNotAnExtension() {
        XCTAssertNil(RustPathExtension.of("/d/.png"))
        XCTAssertEqual(RustPathExtension.of("/d/..png"), "png")
    }

    func testATrailingDotIsAnEmptyExtension() {
        XCTAssertEqual(RustPathExtension.of("/d/x."), "")
    }

    /// Rust splits bytes at `.`; a Swift `Character` split would fuse `.` with a
    /// following combining mark and never see the dot.
    func testSplitsOnBytesNotGraphemes() {
        XCTAssertEqual(RustPathExtension.of("/d/x.\u{301}png").map(SchemeFixtures.bytes), SchemeFixtures.bytes("\u{301}png"))
        XCTAssertEqual(RustPathExtension.of("/a.txt/\u{301}.png"), "png")
    }
}
