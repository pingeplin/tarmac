import XCTest
@testable import TarmacKit

/// The app's table of data-file registrations (spec 2611.0002 S47–S50).
final class CardDataRegistrationsTests: XCTestCase {
    private typealias Card = CardDataRegistrations.Card

    private let dash0 = Card(boardID: "board-0", path: "/a/dash.html")
    private let dash1 = Card(boardID: "board-1", path: "/a/dash.html")
    private let other0 = Card(boardID: "board-0", path: "/a/other.html")

    /// S47's registrations.
    private func table() -> CardDataRegistrations {
        var table = CardDataRegistrations()
        table.set("/a/stats.json", for: dash0)
        table.set("/a/stats.json", for: dash1)
        table.set("/a/x.json", for: other0)
        return table
    }

    func test2611_0002S47AChangeGoesToEveryCardThatRegisteredThePathOnEveryBoard() {
        let table = table()
        XCTAssertEqual(Set(table.cards(reading: "/a/stats.json")), [dash0, dash1])
        XCTAssertEqual(table.cards(reading: "/a/stats.json").count, 2)
        XCTAssertEqual(table.cards(reading: "/a/x.json"), [other0])
        XCTAssertEqual(table.cards(reading: "/a/none.json"), [])
        XCTAssertEqual(table.cards(reading: "/a/dash.html"), [], "a doc path is no data path")
    }

    func test2611_0002S48AReconnectSendsOneDataFileForEachCardThatReadsAFile() {
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

    func test2611_0002S49AClosedCardAndARemovedBoardAreForgotten() {
        var table = table()
        table.set(nil, for: dash0)
        XCTAssertEqual(table.cards(reading: "/a/stats.json"), [dash1])
        XCTAssertFalse(table.resent.contains(.dataFile(boardID: "board-0", path: "/a/dash.html", file: "/a/stats.json")))
        XCTAssertEqual(table.resent.count, 2)

        table.forget(board: "board-1")
        XCTAssertEqual(table.cards(reading: "/a/stats.json"), [])
        XCTAssertEqual(table.resent, [.dataFile(boardID: "board-0", path: "/a/other.html", file: "/a/x.json")])
    }

    func test2611_0002S50ACardThatRegistersAnotherFileLeavesTheFirst() {
        var table = CardDataRegistrations()
        table.set("/a/stats.json", for: dash0)
        table.set("/a/y.json", for: dash0)
        XCTAssertEqual(table.cards(reading: "/a/stats.json"), [])
        XCTAssertEqual(table.cards(reading: "/a/y.json"), [dash0])
    }
}

private extension Message {
    /// `Message` is not `Hashable`; its description tells two apart.
    var debugText: String { String(describing: self) }
}
