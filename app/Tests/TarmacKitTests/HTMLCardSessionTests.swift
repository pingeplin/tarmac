import XCTest
@testable import TarmacKit

/// A card's file for the tests that do not look at where it is.
private extension HTMLCardSession {
    init() { self.init(html: "/a/b/dash.html") }
}

/// What the host does with each message from an HTML card's document, and what
/// a reload resets (specs 2607.0004, 2607.0006, 2609.0002, 2609.0003,
/// 2611.0002, 2611.0003).
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
        _ = session.setCulled(true)
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
        _ = culled.setCulled(true)
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
            _ = session.setCulled(culled)
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
        _ = session.setCulled(true)
        XCTAssertEqual(session.handle(.shown(load: load), borrowed: false), [.documentShown])
        _ = session.setCulled(false)
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
        let effects = reload(&session, naming: name)
        return (session, effects)
    }

    private func registrations(_ effects: [Effect]) -> [String?] {
        effects.compactMap { if case .dataFile(let file) = $0 { return .some(file) } else { return nil } }
    }

    /// The reads the effects start.
    private func reads(_ effects: [Effect]) -> [HTMLCardSession.DataRead] {
        effects.compactMap { if case .read(let read) = $0 { return read } else { return nil } }
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

    /// The host page stamps one ready for each load. The session holds the
    /// rule too: a second one that is stamped with the same load names no
    /// file, and a read of the first file is still delivered.
    func test2611S21aASecondStampedReadyOfTheLoadRegistersNothing() throws {
        var session = HTMLCardSession()
        let load = session.reloaded()
        _ = session.handle(.ready(meta: nil, data: "stats.json", load: load), borrowed: false)
        let read = try readStarted(&session)
        let second = session.handle(.ready(meta: nil, data: "other.json", load: load), borrowed: false)
        XCTAssertEqual(registrations(second), [])
        XCTAssertEqual(session.readEnded(read, .text("{}")), [.deliver("{}")])
        XCTAssertEqual(reads(session.dataChanged()).map(\.file), [stats])
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

    /// The read is an effect of the change itself.
    func test2611S26AChangeStartsARead() throws {
        var (session, registered) = card()
        XCTAssertEqual(reads(registered), [], "nothing changed yet")
        let read = try XCTUnwrap(reads(session.dataChanged()).first)
        XCTAssertEqual(read.file, stats)
        XCTAssertEqual(read.html, "/a/b/dash.html")
    }

    func test2611S27ChangesDuringAReadGiveOneMoreRead() throws {
        var session = card().0
        let read = try XCTUnwrap(reads(session.dataChanged()).first)
        XCTAssertEqual(reads(session.dataChanged()), [])
        XCTAssertEqual(reads(session.dataChanged()), [])
        let ended = session.readEnded(read, .text("{}"))
        XCTAssertEqual(ended.first, .deliver("{}"), "the outcome before the next read")
        let next = reads(ended)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(reads(session.readEnded(try XCTUnwrap(next.first), .text("{}"))), [])
    }

    func test2611S28ACulledCardReadsWhenItIsBackInView() {
        var session = card().0
        XCTAssertEqual(reads(session.setCulled(true)), [])
        XCTAssertEqual(reads(session.dataChanged()), [])
        let back = session.setCulled(false)
        XCTAssertEqual(back.first, .post(.cull(false)), "the document is told before it reads")
        XCTAssertEqual(reads(back).count, 1)
        XCTAssertEqual(reads(session.setCulled(false)), [])

        var quiet = card().0
        XCTAssertEqual(reads(quiet.setCulled(true)), [])
        XCTAssertEqual(reads(quiet.setCulled(false)), [])
    }

    /// From a reload until the new load's first ready, the file is not yet
    /// the new document's: a change then starts no read.
    func test2611S29AChangeBetweenAReloadAndItsReadyStartsNoRead() {
        var session = card().0
        let load = session.reloaded()
        XCTAssertEqual(reads(session.dataChanged()), [])
        XCTAssertEqual(reads(session.handle(.ready(meta: nil, data: "stats.json", load: load), borrowed: false)), [])
        XCTAssertEqual(reads(session.dataChanged()).map(\.file), [stats])
    }

    /// A change of the file a card read before is not a change of the file
    /// its next load names: that one is read when the daemon reports it. A
    /// file that is not there would else be read, and write a line.
    func test2611S28aAChangeOfTheFileBeforeStartsNoReadOfANewlyNamedFile() throws {
        var culled = card().0
        _ = culled.setCulled(true)
        XCTAssertEqual(reads(culled.dataChanged()), [])
        _ = reload(&culled, naming: "y.json")
        XCTAssertEqual(reads(culled.setCulled(false)), [])
        XCTAssertEqual(reads(culled.dataChanged()).map(\.file), ["/a/b/y.json"])

        var reading = card().0
        let read = try readStarted(&reading)
        XCTAssertEqual(reads(reading.dataChanged()), [])
        _ = reload(&reading, naming: "y.json")
        XCTAssertEqual(reads(reading.readEnded(read, .text("{}"))), [])
        XCTAssertEqual(reads(reading.dataChanged()).map(\.file), ["/a/b/y.json"])
    }

    private func readStarted(_ session: inout HTMLCardSession) throws -> HTMLCardSession.DataRead {
        try XCTUnwrap(reads(session.dataChanged()).first)
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

    /// The new load's file changed while the old load's read was out: that
    /// read is not delivered, and its end starts the read for the new load.
    func test2611S29AStaleReadThatEndsStartsTheReadThatWaitedForIt() throws {
        var session = card().0
        let old = try readStarted(&session)
        _ = reload(&session, naming: "stats.json")
        XCTAssertEqual(reads(session.dataChanged()), [], "one read at a time")
        let ended = session.readEnded(old, .text("[1]"))
        XCTAssertFalse(ended.contains(.deliver("[1]")))
        let next = try XCTUnwrap(reads(ended).first)
        XCTAssertEqual(reads(ended).count, 1)
        XCTAssertEqual(session.readEnded(next, .text("[2]")), [.deliver("[2]")])
    }

    func test2611S29aAReadThatEndsWhileCulledIsReadAgainInView() throws {
        var session = card().0
        let read = try readStarted(&session)
        _ = session.setCulled(true)
        XCTAssertEqual(session.readEnded(read, .text("[1]")), [])
        let back = reads(session.setCulled(false))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(session.readEnded(try XCTUnwrap(back.first), .text("[2]")), [.deliver("[2]")])
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

    // MARK: - events (2611.0003 S25–S33)

    private let text = #"{"n":1}"#

    /// A card whose current load's stamped ready was heard, its document
    /// naming no data file.
    private func ready() -> HTMLCardSession { card(naming: nil).0 }

    func test2611_0003S25ACardReadyForItsLoadGetsTheEvent() {
        var session = ready()
        XCTAssertEqual(session.event(text), [.flushEvents])
        XCTAssertEqual(session.takeEvents(), [text])
    }

    func test2611_0003S26ACardWithNoReadyYetGetsNothing() {
        var fresh = HTMLCardSession()
        XCTAssertEqual(fresh.event(text), [])
        fresh.reloaded()
        XCTAssertEqual(fresh.event(text), [])
        XCTAssertEqual(fresh.takeEvents(), [])
    }

    func test2611_0003S27NothingBetweenAReloadAndTheNewLoadsReady() {
        var session = ready()
        let load = session.reloaded()
        XCTAssertEqual(session.event(text), [])
        XCTAssertEqual(session.takeEvents(), [])
        _ = session.handle(.ready(meta: nil, data: nil, load: load), borrowed: false)
        XCTAssertEqual(session.event(text), [.flushEvents])
        XCTAssertEqual(session.takeEvents(), [text])
    }

    func test2611_0003S28ACulledCardGetsTheEvent() {
        var session = ready()
        _ = session.setCulled(true)
        XCTAssertEqual(session.event(text), [.flushEvents])
        XCTAssertEqual(session.takeEvents(), [text])
    }

    /// A ready with no stamp, or the stamp of a load that is not the current
    /// one, adopts a mode and names nothing.
    func test2611_0003S29AReadyOfAnOldLoadOrWithNoStampIsNotReady() {
        var old = HTMLCardSession()
        let load = old.reloaded()
        old.reloaded()
        _ = old.handle(.ready(meta: nil, data: nil, load: load), borrowed: false)
        XCTAssertEqual(old.event(text), [])
        XCTAssertEqual(old.takeEvents(), [])

        var unstamped = HTMLCardSession()
        unstamped.reloaded()
        _ = unstamped.handle(.ready(meta: nil), borrowed: false)
        XCTAssertNotNil(unstamped.mode, "the ready was heard")
        XCTAssertEqual(unstamped.event(text), [])
        XCTAssertEqual(unstamped.takeEvents(), [])
    }

    /// The event starts no read and takes no read's outcome; the outcome
    /// takes no event.
    func test2611_0003S30AnEventAndTheDataFileDoNotTouchEachOther() throws {
        var session = card().0
        let read = try readStarted(&session)
        XCTAssertEqual(session.event(text), [.flushEvents])
        XCTAssertEqual(session.readEnded(read, .text("[1]")), [.deliver("[1]")])
        XCTAssertEqual(session.takeEvents(), [text])
        XCTAssertEqual(reads(session.dataChanged()).map(\.file), [stats], "one read at a time, as before")
    }

    func test2611_0003S31TheFirstEventAsksForAFlushAndTheNextBeforeItDoesNot() {
        var session = ready()
        XCTAssertEqual(session.event("a"), [.flushEvents])
        XCTAssertEqual(session.event("b"), [])
    }

    func test2611_0003S32ATakeGivesTheEventsInOrderAndEmptiesThem() {
        var session = ready()
        for text in ["a", "b", "c"] { _ = session.event(text) }
        XCTAssertEqual(session.takeEvents(), ["a", "b", "c"])
        XCTAssertEqual(session.takeEvents(), [])
        XCTAssertEqual(session.event("d"), [.flushEvents])
        XCTAssertEqual(session.takeEvents(), ["d"])
    }

    /// The document is asked for again: what the old one was to get is not
    /// the next one's, and a flush already queued takes nothing.
    func test2611_0003S33AReloadDropsTheEventsNotYetTaken() {
        var session = ready()
        _ = session.event("a")
        _ = session.event("b")
        let load = session.reloaded()
        XCTAssertEqual(session.takeEvents(), [])
        _ = session.handle(.ready(meta: nil, data: nil, load: load), borrowed: false)
        XCTAssertEqual(session.event("c"), [.flushEvents])
        XCTAssertEqual(session.takeEvents(), ["c"])
    }
}
