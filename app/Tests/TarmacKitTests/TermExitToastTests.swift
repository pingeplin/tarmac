import XCTest
@testable import TarmacKit

final class TermExitToastTests: XCTestCase {
    func testACleanExitRaisesNoToast() {
        XCTAssertNil(TermExitToast.title(code: 0))
    }

    func testAnErrorExitNamesItsCode() {
        XCTAssertEqual(TermExitToast.title(code: 1), "shell exited · 1")
        XCTAssertEqual(TermExitToast.title(code: 130), "shell exited · 130")
    }

    func testASignalExitSaysSo() {
        XCTAssertEqual(TermExitToast.title(code: nil), "killed by signal")
    }

    func testTheIconIsTheTerminalGlyph() {
        XCTAssertEqual(TermExitToast.icon, "›_")
    }
}
