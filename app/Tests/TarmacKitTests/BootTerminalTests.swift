import XCTest
@testable import TarmacKit

/// M3: the single home for terminal-id minting.
final class BootTerminalTests: XCTestCase {
    func testMintIsNonEmpty() {
        XCTAssertFalse(BootTerminal.mint().isEmpty)
    }

    func testTwoMintsDiffer() {
        XCTAssertNotEqual(BootTerminal.mint(), BootTerminal.mint())
    }

    func testManyMintsAreUnique() {
        let ids = (0..<1000).map { _ in BootTerminal.mint() }
        XCTAssertEqual(Set(ids).count, ids.count, "minted ids collide")
    }
}
