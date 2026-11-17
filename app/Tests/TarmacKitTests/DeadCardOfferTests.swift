import XCTest
import TarmacKit

/// 2611.0011 S10, S25: what a dead card offers, and what its reopen spawns.
final class DeadCardOfferTests: XCTestCase {
    private let home = "/Users/u"

    private func makeOffer(_ cwd: String?, resume: String? = nil) throws -> DeadCardOffer.Offer {
        try XCTUnwrap(
            DeadCardOffer.make(record: TermRecord(lastCwd: cwd, resume: resume.map { ResumeRecord(cmd: $0) }), home: home)
        )
    }

    func testS10AFolderIsOfferedWithHomeShownAsTilde() throws {
        let offer = try makeOffer("/Users/u/w")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in ~/w"])
    }

    func testS10HomeIsReplacedOnlyAtAPathBoundary() throws {
        let offer = try makeOffer("/Users/u2/w")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in /Users/u2/w"])
        let atHome = try makeOffer("/Users/u")
        XCTAssertEqual(atHome.lines, ["reopen here  ⏎", "in ~"])
    }

    /// 2611.0011 S10 and 2611.0015 S19: plain words, and `↻` only ever means
    /// refresh.
    func testS10S19ASafeResumeAddsAThirdLineInPlainWordsWithNoRefreshGlyph() throws {
        let offer = try makeOffer("/Users/u/w", resume: "claude --resume 3f2a1b9c-0000-4000-8000-000000000000")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in ~/w", "then offers: claude --resume 3f2a…"])
        XCTAssertFalse(offer.lines.contains { $0.contains("↻") })
    }

    func testS10AResumeAloneIsOfferedWithNoFolderLine() throws {
        let offer = try makeOffer(nil, resume: "echo HI")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "then offers: echo HI"])
    }

    func testS10NothingToOfferGivesNoOffer() {
        XCTAssertNil(DeadCardOffer.make(record: nil, home: home))
        XCTAssertNil(DeadCardOffer.make(record: TermRecord(lastCwd: nil), home: home))
        XCTAssertNil(DeadCardOffer.make(record: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: "echo a\necho b")), home: home))
    }

    func testS10ARefusedResumeIsLeftOutOfAFolderOffer() throws {
        let offer = try makeOffer("/w", resume: "echo a\necho b")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in /w"])
        XCTAssertNil(DeadCardOffer.reopen(offer, deadID: "T").resume)
    }

    // MARK: S25

    func testS25ReopenSucceedsTheDeadIdInItsFolderAndCarriesTheResume() throws {
        let offer = try makeOffer("/w", resume: "echo HI")
        let reopen = DeadCardOffer.reopen(offer, deadID: "T")
        XCTAssertEqual(reopen.spawn, SpawnRequest(cwd: "/w", succeeds: "T"))
        XCTAssertEqual(reopen.resume, "echo HI")
    }

    func testS25ReopenWithNoFolderStillSucceedsTheDeadId() throws {
        let offer = try makeOffer(nil, resume: "echo HI")
        XCTAssertEqual(DeadCardOffer.reopen(offer, deadID: "T").spawn, SpawnRequest(cwd: nil, succeeds: "T"))
    }

    // MARK: #412: a card that ended in this run

    func testACardThatEndedHereIsOfferedInItsFolder() {
        XCTAssertEqual(DeadCardOffer.afterExit(cwd: "/Users/u/w", home: home).lines, ["reopen here  ⏎", "in ~/w"])
    }

    func testACardThatEndedHereWithNoKnownFolderIsStillOffered() {
        let offer = DeadCardOffer.afterExit(cwd: nil, home: home)
        XCTAssertEqual(offer.lines, ["reopen here  ⏎"])
        XCTAssertEqual(DeadCardOffer.reopen(offer, deadID: "T").spawn, SpawnRequest(cwd: nil, succeeds: "T"))
    }

    /// The daemon drops a terminal's resume command at its end (2611.0011 D3).
    func testACardThatEndedHereOffersNoCommand() {
        let offer = DeadCardOffer.afterExit(cwd: "/w", home: home)
        XCTAssertNil(offer.resume)
        XCTAssertFalse(offer.lines.contains { $0.hasPrefix("then offers:") })
    }
}
