import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalEngineTests: XCTestCase {
    func testFeedingPlainBytesShowsThemOnTheScreen() throws {
        let engine = try TerminalEngine(cols: 20, rows: 4)
        engine.feed(Array("hello".utf8))
        XCTAssertEqual(engine.plainText(), "hello")
    }

    func testStyledOutputKeepsOnlyItsText() throws {
        let engine = try TerminalEngine(cols: 20, rows: 4)
        engine.feed(Array("a\u{1b}[1;32mb\u{1b}[0mc\r\nd".utf8))
        XCTAssertEqual(engine.plainText(), "abc\nd")
    }
}
