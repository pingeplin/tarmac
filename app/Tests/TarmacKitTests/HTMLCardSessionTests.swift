import XCTest
@testable import TarmacKit

/// What the host does with each message from an HTML card's document, and what
/// a reload resets (specs 2607.0004, 2607.0006, 2609.0002, 2609.0003).
final class HTMLCardSessionTests: XCTestCase {
    private typealias Effect = HTMLCardSession.Effect
    private let magnify = CardHostMessage.zoom(Double(CardZoom.magnifyK))

    // MARK: - scrolled (2610.0003 S11)

    /// The session passes the document's report on and keeps nothing of it.
    func test2610S11AScrollReportIsPassedOnWhateverTheCardIsDoing() throws {
        let metrics = try XCTUnwrap(ScrollMetrics(offset: 30, visible: 100, total: 400))
        var session = HTMLCardSession()
        let before = session
        XCTAssertEqual(session.handle(.scrolled(metrics), borrowed: false), [.scrollChanged(metrics)])
        XCTAssertEqual(session.handle(.scrolled(metrics), borrowed: true), [.scrollChanged(metrics)])
        XCTAssertEqual(session, before)
    }

    // MARK: - ready

    /// The cull state goes first on every ready: each generation of a
    /// self-reloading document must be told the state it is born into.
    func testAFirstReadyAssertsTheCullStateThenMagnifiesAndAdoptsTheMode() {
        var session = HTMLCardSession()
        XCTAssertEqual(
            session.handle(.ready(meta: nil), borrowed: false),
            [.post(.cull(false)), .post(magnify), .modeChanged]
        )
        XCTAssertEqual(session.mode, .magnify)
    }

    func testAReadyOnACulledCardRepeatsThatItIsCulled() {
        var session = HTMLCardSession()
        session.culled = true
        XCTAssertEqual(session.handle(.ready(meta: nil), borrowed: false).first, .post(.cull(true)))
    }

    func testARevealDocumentIsNotMagnified() {
        var session = HTMLCardSession()
        XCTAssertEqual(
            session.handle(.ready(meta: "reveal"), borrowed: false),
            [.post(.cull(false)), .consoleChanged, .modeChanged]
        )
        XCTAssertEqual(session.mode, .reveal)
    }

    /// 2607.0006: a tag the author wrote is reported once, at level info.
    func testADeclaredModeIsLoggedToTheCardsConsole() {
        var session = HTMLCardSession()
        _ = session.handle(.ready(meta: "reveal"), borrowed: false)
        XCTAssertEqual(
            session.console.entries,
            [CardConsole.Entry(level: .info, args: ["zoom-mode declared=reveal effective=reveal"])]
        )
    }

    /// 2609.0003: a document that reloads itself is answered again, but can
    /// neither change the mode nor log a second line.
    func testALaterReadyOfTheSameLoadIsMagnifiedAgainButChangesNothing() {
        var session = HTMLCardSession()
        _ = session.handle(.ready(meta: "magnify"), borrowed: false)
        XCTAssertEqual(
            session.handle(.ready(meta: "reveal"), borrowed: false),
            [.post(.cull(false)), .post(magnify)]
        )
        XCTAssertEqual(session.mode, .magnify)
        XCTAssertEqual(session.console.entries.count, 1)
    }

    func testAForgedMagnifyCannotMagnifyARevealCard() {
        var session = HTMLCardSession()
        _ = session.handle(.ready(meta: "reveal"), borrowed: false)
        XCTAssertEqual(session.handle(.ready(meta: "magnify"), borrowed: false), [.post(.cull(false))])
        XCTAssertEqual(session.mode, .reveal)
    }

    // MARK: - reload

    /// A reload drops the per-load mode — a removed meta tag must not leak the
    /// old mode forward — and keeps the console.
    func testAReloadResetsTheModeAndKeepsTheConsole() {
        var session = HTMLCardSession()
        _ = session.handle(.ready(meta: "reveal"), borrowed: false)
        session.reloaded()
        XCTAssertNil(session.mode)
        XCTAssertEqual(session.console.entries.count, 1)
        XCTAssertEqual(
            session.handle(.ready(meta: nil), borrowed: false),
            [.post(.cull(false)), .post(magnify), .modeChanged]
        )
    }

    // MARK: - shown (#213)

    /// The view keeps the web view out of sight from each load until this.
    /// The session keeps nothing of it: a reload covers the view again.
    func testADocumentOnScreenIsPassedOnWhateverTheCardIsDoing() {
        var session = HTMLCardSession()
        let before = session
        XCTAssertEqual(session.handle(.shown, borrowed: false), [.documentShown])
        XCTAssertEqual(session.handle(.shown, borrowed: true), [.documentShown])
        session.culled = true
        XCTAssertEqual(session.handle(.shown, borrowed: false), [.documentShown])
        session.culled = false
        XCTAssertEqual(session, before)
    }

    // MARK: - escape and console

    func testEscapeGoesHomeOnlyWhileTheCardIsBorrowed() {
        var session = HTMLCardSession()
        XCTAssertEqual(session.handle(.escape, borrowed: true), [.escapeHome])
        XCTAssertEqual(session.handle(.escape, borrowed: false), [])
    }

    func testAConsoleMessageIsBuffered() {
        var session = HTMLCardSession()
        let entry = CardConsole.Entry(level: .warn, args: ["a", 1])
        XCTAssertEqual(session.handle(.console(entry), borrowed: false), [.consoleChanged])
        XCTAssertEqual(session.console.entries, [entry])
    }
}
