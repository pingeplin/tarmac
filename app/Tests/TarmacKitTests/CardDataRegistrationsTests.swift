import XCTest

@testable import TarmacKit

/// The app's table of data-file registrations (spec 2611.0002).
final class CardDataRegistrationsTests: XCTestCase {
    private typealias Card = CardDataRegistrations.Card

    private let dash0 = Card(boardID: "board-0", path: "/a/dash.html")
    private let dash1 = Card(boardID: "board-1", path: "/a/dash.html")
    private let other0 = Card(boardID: "board-0", path: "/a/other.html")

    /// The registrations of "File event is routed to registered cards".
    private func table() -> CardDataRegistrations {
        var table = CardDataRegistrations()
        table.set("/a/stats.json", for: dash0)
        table.set("/a/stats.json", for: dash1)
        table.set("/a/x.json", for: other0)
        return table
    }

    /// "File event is routed to registered cards".
    func testAChangeGoesToEveryCardThatRegisteredThePathOnEveryBoard() {
        let table = table()
        XCTAssertEqual(Set(table.cards(reading: "/a/stats.json")), [dash0, dash1])
        XCTAssertEqual(table.cards(reading: "/a/stats.json").count, 2)
        XCTAssertEqual(table.cards(reading: "/a/x.json"), [other0])
        XCTAssertEqual(table.cards(reading: "/a/none.json"), [])
        XCTAssertEqual(table.cards(reading: "/a/dash.html"), [], "a doc path is no data path")
    }

    /// "Reconnect resends every registration".
    func testAReconnectSendsOneDataFileForEachCardThatReadsAFile() {
        var table = table()
        let expected: [Message] = [
            .dataFile(boardID: "board-0", path: "/a/dash.html", file: "/a/stats.json"),
            .dataFile(boardID: "board-1", path: "/a/dash.html", file: "/a/stats.json"),
            .dataFile(boardID: "board-0", path: "/a/other.html", file: "/a/x.json"),
        ]
        XCTAssertEqual(table.resent.count, 3)
        XCTAssertEqual(Set(table.resent.map(\.debugText)), Set(expected.map(\.debugText)))

        table.set(nil, for: other0)
        XCTAssertEqual(Set(table.resent.map(\.debugText)), Set(expected.prefix(2).map(\.debugText)))
        XCTAssertEqual(table.cards(reading: "/a/x.json"), [])
    }

    /// "Closed card leaves the registrations".
    func testAClosedCardAndARemovedBoardAreForgotten() {
        var table = table()
        table.set(nil, for: dash0)
        XCTAssertEqual(table.cards(reading: "/a/stats.json"), [dash1])
        XCTAssertFalse(
            table.resent.contains(.dataFile(boardID: "board-0", path: "/a/dash.html", file: "/a/stats.json")))
        XCTAssertEqual(table.resent.count, 2)

        table.forget(board: "board-1")
        XCTAssertEqual(table.cards(reading: "/a/stats.json"), [])
        XCTAssertEqual(table.resent, [.dataFile(boardID: "board-0", path: "/a/other.html", file: "/a/x.json")])
    }

    /// "New registration replaces the old file".
    func testACardThatRegistersAnotherFileLeavesTheFirst() {
        var table = CardDataRegistrations()
        table.set("/a/stats.json", for: dash0)
        table.set("/a/y.json", for: dash0)
        XCTAssertEqual(table.cards(reading: "/a/stats.json"), [])
        XCTAssertEqual(table.cards(reading: "/a/y.json"), [dash0])
    }

    // MARK: - two forms of one name (spec 2611.0034)

    private let nfc = "/v/\u{e9}/a.md"
    private let nfd = "/v/e\u{301}/a.md"
    private let nfcData = "/v/\u{e9}/a.md/data.json"
    private let nfdData = "/v/e\u{301}/a.md/data.json"

    private func docPaths(_ messages: [Message]) -> [[UInt8]] {
        messages.compactMap { message in
            guard case .dataFile(_, let path, _) = message else { return nil }
            return Array(path.utf8)
        }
    }

    func testDataRegistrationsKeepTwoFormsApart() {
        var table = CardDataRegistrations()
        table.set(nfcData, for: Card(boardID: "board-0", path: nfc))
        table.set(nfdData, for: Card(boardID: "board-0", path: nfd))
        let reading = table.cards(reading: nfdData)
        XCTAssertEqual(reading.map { Array($0.path.utf8) }, [Array(nfd.utf8)])
        XCTAssertEqual(docPaths(table.resent).count, 2)
    }

    func testClearingOneFormKeepsTheRegistrationOfTheOtherForm() {
        var table = CardDataRegistrations()
        table.set(nfcData, for: Card(boardID: "board-0", path: nfc))
        table.set(nfdData, for: Card(boardID: "board-0", path: nfd))
        table.set(nil, for: Card(boardID: "board-0", path: nfd))
        XCTAssertEqual(docPaths(table.resent), [Array(nfc.utf8)])
    }
}

extension Message {
    /// `Message` is not `Hashable`; its description tells two apart.
    fileprivate var debugText: String { String(describing: self) }
}
