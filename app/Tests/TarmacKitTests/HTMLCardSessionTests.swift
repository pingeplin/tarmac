import XCTest
@testable import TarmacKit

/// A card's file for the tests that do not look at where it is.
private extension HTMLCardSession {
    init() { self.init(html: "/a/b/dash.html") }
}

/// What the host does with each message from an HTML card's document, and what
/// a reload resets (specs 2607.0004, 2607.0006, 2609.0002, 2609.0003,
/// 2611.0002).
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

    // MARK: - fonts (2610.0010 S21–S24)

    private let fontsA = CardFontVariables(interfaceFamily: nil, documentFamily: nil, documentSize: 14)
    private let fontsB = CardFontVariables(interfaceFamily: "Menlo", documentFamily: "Georgia", documentSize: 20)

    func test2610_0010S21AReadyBringsTheFontsAfterTheCullStateAndBeforeTheZoom() {
        var session = HTMLCardSession()
        _ = session.fontsChanged(fontsA)
        XCTAssertEqual(
            session.handle(.ready(meta: nil), borrowed: false),
            [.post(.cull(false)), .post(.fonts(fontsA)), .post(magnify), .modeChanged]
        )

        var culled = HTMLCardSession()
        culled.culled = true
        _ = culled.fontsChanged(fontsA)
        XCTAssertEqual(culled.handle(.ready(meta: nil), borrowed: false).first, .post(.cull(true)))
    }

    func test2610_0010S22ASessionNeverToldAnyFontsPostsNone() {
        var session = HTMLCardSession()
        let effects = session.handle(.ready(meta: nil), borrowed: false)
        XCTAssertEqual(effects, [.post(.cull(false)), .post(magnify), .modeChanged])
    }

    func test2610_0010S23AChangeIsPostedAndTheSameValuesAreNot() {
        for culled in [false, true] {
            var session = HTMLCardSession()
            session.culled = culled
            XCTAssertEqual(session.fontsChanged(fontsA), .fonts(fontsA), "culled \(culled)")
            XCTAssertNil(session.fontsChanged(fontsA), "culled \(culled)")
            XCTAssertEqual(session.fontsChanged(fontsB), .fonts(fontsB), "culled \(culled)")
            XCTAssertNil(session.fontsChanged(fontsB), "culled \(culled)")
        }
    }

    func test2610_0010S24AReadyBringsTheNewestFontsAndAReloadKeepsThem() {
        var session = HTMLCardSession()
        _ = session.fontsChanged(fontsA)
        session.reloaded()
        XCTAssertTrue(session.handle(.ready(meta: nil), borrowed: false).contains(.post(.fonts(fontsA))))

        session.reloaded()
        _ = session.fontsChanged(fontsB)
        XCTAssertTrue(session.handle(.ready(meta: nil), borrowed: false).contains(.post(.fonts(fontsB))))
        XCTAssertTrue(session.handle(.ready(meta: nil), borrowed: false).contains(.post(.fonts(fontsB))))
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
        let load = session.reloaded()
        let before = session
        XCTAssertEqual(session.handle(.shown(load: load), borrowed: false), [.documentShown])
        XCTAssertEqual(session.handle(.shown(load: load), borrowed: true), [.documentShown])
        session.culled = true
        XCTAssertEqual(session.handle(.shown(load: load), borrowed: false), [.documentShown])
        session.culled = false
        XCTAssertEqual(session, before)
    }

    /// The view is covered from the start, and nothing was loaded yet.
    func testAShownBeforeAnyLoadIsDropped() {
        var session = HTMLCardSession()
        XCTAssertEqual(session.handle(.shown(load: 0), borrowed: false), [])
    }

    /// The file changed again while the word for the load before was on its
    /// way. The view is covered for the new load, and that word is not for it.
    func testAShownOfALoadThatWasReplacedIsDropped() {
        var session = HTMLCardSession()
        let first = session.reloaded()
        let second = session.reloaded()
        XCTAssertEqual(session.handle(.shown(load: first), borrowed: false), [])
        XCTAssertEqual(session.handle(.shown(load: second), borrowed: false), [.documentShown])
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

    // MARK: - the data file (2611.0002 S20–S31)

    private let stats = "/a/b/stats.json"

    /// A card whose current load named `name`, and what its `ready` gave.
    private func card(naming name: String? = "stats.json") -> (HTMLCardSession, [Effect]) {
        var session = HTMLCardSession(html: "/a/b/dash.html")
        let load = session.reloaded()
        let effects = session.handle(.ready(meta: nil, data: name, load: load), borrowed: false)
        return (session, effects)
    }

    private func registrations(_ effects: [Effect]) -> [String?] {
        effects.compactMap { if case .dataFile(let file) = $0 { return .some(file) } else { return nil } }
    }

    private func reload(_ session: inout HTMLCardSession, naming name: String?) -> [Effect] {
        let load = session.reloaded()
        return session.handle(.ready(meta: nil, data: name, load: load), borrowed: false)
    }

    private func line(_ path: String, _ reason: String) -> CardConsole.Entry {
        CardConsole.Entry(level: .error, args: [.string("tarmac-data: \(path): \(reason)")])
    }

    func test2611S20TheFirstReadyOfTheLoadRegistersItsFileAfterWhatReadyGivesToday() {
        var today = HTMLCardSession()
        let todays = today.handle(.ready(meta: nil), borrowed: false)
        XCTAssertEqual(card().1, todays + [.dataFile(stats)])
    }

    func test2611S21ALaterReadyOfTheLoadRegistersNothing() {
        var (session, first) = card()
        XCTAssertEqual(registrations(first), [stats])
        let later = session.handle(.ready(meta: nil, data: "other.json"), borrowed: false)
        XCTAssertEqual(registrations(later), [])
        XCTAssertEqual(later, [.post(.cull(false)), .post(magnify)])
    }

    func test2611S22AReadyOfAnotherLoadRegistersNothing() {
        for other in [-1, 1] {
            var session = HTMLCardSession()
            let load = session.reloaded()
            let effects = session.handle(.ready(meta: nil, data: "stats.json", load: load + other), borrowed: false)
            XCTAssertEqual(registrations(effects), [], "load \(load + other)")
            XCTAssertEqual(
                registrations(session.handle(.ready(meta: nil, data: "stats.json", load: load), borrowed: false)),
                [stats]
            )
        }
        var unloaded = HTMLCardSession()
        XCTAssertEqual(registrations(unloaded.handle(.ready(meta: nil, data: "x.json", load: 0), borrowed: false)), [])
    }

    func test2611S23ARefusedNameRegistersNothingAndSaysWhy() {
        let (session, effects) = card(naming: "../x.json")
        XCTAssertEqual(registrations(effects), [])
        XCTAssertTrue(effects.contains(.consoleChanged))
        XCTAssertEqual(session.console.entries, [line("/a/x.json", CardDataPath.outside)])
    }

    func test2611S24TheNextLoadClearsReplacesOrRepeatsTheRegistration() {
        var none = card().0
        XCTAssertEqual(registrations(reload(&none, naming: nil)), [nil])

        var refused = card().0
        let effects = reload(&refused, naming: "sub/x.json")
        XCTAssertEqual(registrations(effects), [nil])
        XCTAssertTrue(effects.contains(.consoleChanged))
        XCTAssertEqual(refused.console.entries, [line("/a/b/sub/x.json", CardDataPath.inSubdirectory)])

        var same = card().0
        XCTAssertEqual(registrations(reload(&same, naming: "stats.json")), [stats])

        var other = card().0
        XCTAssertEqual(registrations(reload(&other, naming: "y.json")), ["/a/b/y.json"])
    }

    func test2611S25ACardThatNeverHadAFileIsToldNothing() {
        var (session, effects) = card(naming: nil)
        XCTAssertEqual(registrations(effects), [])
        XCTAssertEqual(registrations(reload(&session, naming: nil)), [])
        XCTAssertEqual(registrations(reload(&session, naming: "../x.json")), [])
        XCTAssertEqual(registrations(reload(&session, naming: "x.json")), ["/a/b/x.json"])
    }

    func test2611S26AChangeStartsARead() throws {
        var session = card().0
        XCTAssertNil(session.nextRead(), "nothing changed yet")
        session.dataChanged()
        XCTAssertEqual(try XCTUnwrap(session.nextRead()).file, stats)
    }

    func test2611S27ChangesDuringAReadGiveOneMoreRead() throws {
        var session = card().0
        session.dataChanged()
        let read = try XCTUnwrap(session.nextRead())
        session.dataChanged()
        session.dataChanged()
        XCTAssertNil(session.nextRead())
        _ = session.readEnded(read, .text("{}"))
        XCTAssertNotNil(session.nextRead())
        XCTAssertNil(session.nextRead())
    }

    func test2611S28ACulledCardReadsWhenItIsBackInView() {
        var session = card().0
        session.culled = true
        session.dataChanged()
        XCTAssertNil(session.nextRead())
        session.culled = false
        XCTAssertNotNil(session.nextRead())
        XCTAssertNil(session.nextRead())

        var quiet = card().0
        quiet.culled = true
        quiet.culled = false
        XCTAssertNil(quiet.nextRead())
    }

    /// From a reload until the new load's first ready, the file is not yet
    /// the new document's: a change then starts no read.
    func test2611S29AChangeBetweenAReloadAndItsReadyStartsNoRead() {
        var session = card().0
        let load = session.reloaded()
        session.dataChanged()
        XCTAssertNil(session.nextRead())
        _ = session.handle(.ready(meta: nil, data: "stats.json", load: load), borrowed: false)
        session.dataChanged()
        XCTAssertEqual(session.nextRead()?.file, stats)
    }

    private func readStarted(_ session: inout HTMLCardSession) throws -> HTMLCardSession.DataRead {
        session.dataChanged()
        return try XCTUnwrap(session.nextRead())
    }

    func test2611S29AReadIsDeliveredOnlyToTheLoadAndFileItWasFor() throws {
        var session = card().0
        let read = try readStarted(&session)
        XCTAssertEqual(session.readEnded(read, .text("[1]")), [.deliver("[1]")])
        XCTAssertEqual(session.readEnded(try readStarted(&session), .text("[1]")), [.deliver("[1]")], "the same again")

        var reloaded = card().0
        let before = try readStarted(&reloaded)
        reloaded.reloaded()
        XCTAssertEqual(reloaded.readEnded(before, .text("[1]")), [])

        var renamed = card().0
        let old = try readStarted(&renamed)
        _ = reload(&renamed, naming: "y.json")
        XCTAssertEqual(renamed.readEnded(old, .text("[1]")), [])

        var repeated = card().0
        let first = try readStarted(&repeated)
        _ = reload(&repeated, naming: "stats.json")
        XCTAssertEqual(repeated.readEnded(first, .text("[1]")), [], "the same file, a later load")
    }

    func test2611S29aAReadThatEndsWhileCulledIsReadAgainInView() throws {
        var session = card().0
        let read = try readStarted(&session)
        session.culled = true
        XCTAssertEqual(session.readEnded(read, .text("[1]")), [])
        XCTAssertNil(session.nextRead())
        session.culled = false
        let again = try XCTUnwrap(session.nextRead())
        XCTAssertEqual(session.readEnded(again, .text("[2]")), [.deliver("[2]")])
    }

    func test2611S30AFailedReadDeliversNothingAndSaysWhy() throws {
        let reasons = [
            CardDataRead.leadsOutside, FileBytes.NotAFile().localizedDescription,
            FileBytes.TooLarge(limit: FileBytes.sizeCap).localizedDescription, CardDataRead.notUTF8, CardDataRead.notJSON,
        ]
        for reason in reasons {
            var session = card().0
            XCTAssertEqual(session.readEnded(try readStarted(&session), .refused(reason)), [.consoleChanged], reason)
            XCTAssertEqual(session.console.entries, [line(stats, reason)], reason)
        }
    }

    func test2611S31TheSameLineIsNotWrittenTwiceInARow() throws {
        var session = card().0
        let reason = CardDataRead.notJSON
        _ = session.readEnded(try readStarted(&session), .refused(reason))
        XCTAssertEqual(session.readEnded(try readStarted(&session), .refused(reason)), [])
        XCTAssertEqual(session.console.entries.count, 1, "twice in a row")

        _ = session.readEnded(try readStarted(&session), .refused(CardDataRead.notUTF8))
        XCTAssertEqual(session.console.entries.count, 2, "another line")

        _ = session.readEnded(try readStarted(&session), .text("{}"))
        _ = session.readEnded(try readStarted(&session), .refused(CardDataRead.notUTF8))
        XCTAssertEqual(session.console.entries.count, 3, "after a delivery")

        _ = session.handle(.console(CardConsole.Entry(level: .log, args: ["hi"])), borrowed: false)
        _ = session.readEnded(try readStarted(&session), .refused(CardDataRead.notUTF8))
        XCTAssertEqual(session.console.entries.count, 5, "after another entry")

        _ = reload(&session, naming: "stats.json")
        XCTAssertEqual(session.readEnded(try readStarted(&session), .refused(CardDataRead.notUTF8)), [])
        XCTAssertEqual(session.console.entries.count, 5, "a reload between")
    }

    /// The path rule's refusal is a line like a read's, under the same rule.
    func test2611S31ARefusedNameIsNotWrittenTwiceInARowAcrossReloads() {
        var session = card(naming: "../x.json").0
        XCTAssertFalse(reload(&session, naming: "../x.json").contains(.consoleChanged))
        XCTAssertEqual(session.console.entries.count, 1)
    }
}
