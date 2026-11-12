import XCTest
import TarmacKit

/// The memory a process uses, as Activity Monitor shows it (spec 2611.0004).
final class ProcessFootprintTests: XCTestCase {
    func testS1ThisProcessHasAFootprint() throws {
        let bytes = try XCTUnwrap(ProcessFootprint.bytes(of: getpid()))
        XCTAssertGreaterThan(bytes, 0)
    }

    /// -1 names no process, and neither does a pid past macOS's `kern.maxproc`
    /// range (pids stay under 100,000).
    func testS2APidThatNamesNoProcessHasNone() {
        XCTAssertNil(ProcessFootprint.bytes(of: -1))
        XCTAssertNil(ProcessFootprint.bytes(of: 99_999_999))
    }
}
