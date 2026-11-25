import TarmacKit
import XCTest

/// The memory a process uses, as Activity Monitor shows it (spec 2611.0004).
final class ProcessFootprintTests: XCTestCase {
    /// "Own process has a footprint".
    func testThisProcessHasAFootprint() throws {
        let bytes = try XCTUnwrap(ProcessFootprint.bytes(of: getpid()))
        XCTAssertGreaterThan(bytes, 0)
    }

    /// "Unknown pid has no footprint".
    /// -1 names no process, and neither does a pid past macOS's `kern.maxproc`
    /// range (pids stay under 100,000).
    func testAPidThatNamesNoProcessHasNone() {
        XCTAssertNil(ProcessFootprint.bytes(of: -1))
        XCTAssertNil(ProcessFootprint.bytes(of: 99_999_999))
    }
}
