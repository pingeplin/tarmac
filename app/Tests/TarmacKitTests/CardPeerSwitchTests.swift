import XCTest
@testable import TarmacKit

/// What the app says of WebKit's own switch for WebRTC in an HTML card.
final class CardPeerSwitchTests: XCTestCase {
    private let line =
        "HTML cards: the PeerConnectionEnabled switch is not in force; the shim alone removes WebRTC"

    func testASwitchThatReadsOffIsInForceAndSaysNothing() {
        XCTAssertNil(CardPeerSwitch.logLine(readback: false))
    }

    func testASystemWithoutTheSwitchIsLogged() {
        XCTAssertEqual(CardPeerSwitch.logLine(readback: nil), line)
    }

    func testASwitchThatStillReadsOnIsLogged() {
        XCTAssertEqual(CardPeerSwitch.logLine(readback: true), line)
    }
}
