import TarmacKit
import XCTest

/// 2611.0011 "Dead card offer shows folder and command", "Reopen succeeds the dead id": what a dead card offers, and what its reopen spawns.
final class DeadCardOfferTests: XCTestCase {
    private let home = "/Users/u"

    private func makeOffer(_ cwd: String?, resume: String? = nil) throws -> DeadCardOffer.Offer {
        try XCTUnwrap(
            DeadCardOffer.make(
                record: TermRecord(lastCwd: cwd, resume: resume.map { ResumeRecord(cmd: $0) }), home: home)
        )
    }

    /// "Dead card offer shows folder and command".
    func testAFolderIsOfferedWithHomeShownAsTilde() throws {
        let offer = try makeOffer("/Users/u/w")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in ~/w"])
    }

    /// "Dead card offer shows folder and command".
    func testHomeIsReplacedOnlyAtAPathBoundary() throws {
        let offer = try makeOffer("/Users/u2/w")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in /Users/u2/w"])
        let atHome = try makeOffer("/Users/u")
        XCTAssertEqual(atHome.lines, ["reopen here  ⏎", "in ~"])
    }

    /// 2611.0011 "Dead card offer shows folder and command" and 2611.0015 "Dead card text has no refresh glyph": plain words, and `↻` only ever means
    /// refresh.
    func testASafeResumeAddsAThirdLineInPlainWordsWithNoRefreshGlyph() throws {
        let offer = try makeOffer("/Users/u/w", resume: "claude --resume 3f2a1b9c-0000-4000-8000-000000000000")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in ~/w", "then offers: claude --resume 3f2a…"])
        XCTAssertFalse(offer.lines.contains { $0.contains("↻") })
    }

    /// "Dead card offer shows folder and command".
    func testAResumeAloneIsOfferedWithNoFolderLine() throws {
        let offer = try makeOffer(nil, resume: "echo HI")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "then offers: echo HI"])
    }

    /// "Dead card offer shows folder and command".
    func testNothingToOfferGivesNoOffer() {
        XCTAssertNil(DeadCardOffer.make(record: nil, home: home))
        XCTAssertNil(DeadCardOffer.make(record: TermRecord(lastCwd: nil), home: home))
        XCTAssertNil(
            DeadCardOffer.make(
                record: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: "echo a\necho b")), home: home))
    }

    /// "Dead card offer shows folder and command".
    func testARefusedResumeIsLeftOutOfAFolderOffer() throws {
        let offer = try makeOffer("/w", resume: "echo a\necho b")
        XCTAssertEqual(offer.lines, ["reopen here  ⏎", "in /w"])
        XCTAssertNil(DeadCardOffer.reopen(offer, deadID: "T").resume)
    }

    // MARK: "Reopen succeeds the dead id"

    /// "Reopen succeeds the dead id".
    func testReopenSucceedsTheDeadIdInItsFolderAndCarriesTheResume() throws {
        let offer = try makeOffer("/w", resume: "echo HI")
        let reopen = DeadCardOffer.reopen(offer, deadID: "T")
        XCTAssertEqual(reopen.spawn, SpawnRequest(cwd: "/w", succeeds: "T"))
        XCTAssertEqual(reopen.resume, "echo HI")
    }

    /// "Reopen succeeds the dead id".
    func testReopenWithNoFolderStillSucceedsTheDeadId() throws {
        let offer = try makeOffer(nil, resume: "echo HI")
        XCTAssertEqual(DeadCardOffer.reopen(offer, deadID: "T").spawn, SpawnRequest(cwd: nil, succeeds: "T"))
    }

    // MARK: #412: a card that ended in this run

    private let record = TermRecord(lastCwd: "/Users/u/a", resume: ResumeRecord(cmd: "echo HI"))

    private func endedHere(_ lastCwd: String?) throws -> DeadCardOffer.Offer {
        try XCTUnwrap(DeadCardOffer.make(record: record, endedHere: true, lastCwd: lastCwd, home: home))
    }

    /// The app's folder is the freshest it knows (a restore corrects it); the
    /// record of an older restore is not.
    func testACardThatEndedHereShowsTheAppsFolderNotTheRecords() throws {
        XCTAssertEqual(try endedHere("/Users/u/b").lines, ["reopen here  ⏎", "in ~/b"])
    }

    func testACardThatEndedHereWithNoKnownFolderIsStillOffered() throws {
        let offer = try XCTUnwrap(DeadCardOffer.make(record: nil, endedHere: true, lastCwd: nil, home: home))
        XCTAssertEqual(offer.lines, ["reopen here  ⏎"])
    }

    /// The daemon's record of the dead id is at least as fresh as anything the
    /// app saw, so the reopen asks for no folder and the daemon picks it.
    func testACardThatEndedHereReopensInTheDaemonsFolder() throws {
        let offer = try endedHere("/Users/u/b")
        XCTAssertEqual(DeadCardOffer.reopen(offer, deadID: "T").spawn, SpawnRequest(cwd: nil, succeeds: "T"))
    }

    /// The daemon drops a terminal's resume command at its end (2611.0011 D3).
    func testACardThatEndedHereOffersNoCommand() throws {
        let offer = try endedHere("/Users/u/b")
        XCTAssertNil(offer.resume)
        XCTAssertNil(DeadCardOffer.reopen(offer, deadID: "T").resume)
        XCTAssertFalse(offer.lines.contains { $0.hasPrefix("then offers:") })
    }

    func testACardFoundDeadAtARestoreIsOfferedItsRecordUnchanged() {
        XCTAssertEqual(
            DeadCardOffer.make(record: record, endedHere: false, lastCwd: "/Users/u/b", home: home),
            DeadCardOffer.make(record: record, home: home)
        )
        XCTAssertNil(DeadCardOffer.make(record: nil, endedHere: false, lastCwd: "/Users/u/b", home: home))
    }

    // MARK: #412: Return arms a second after the exit

    func testReturnReopensACardThatEndedHereOnlyOneSecondAfterItsExit() {
        let ended = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(DeadCardOffer.returnKey(endedAt: ended, now: ended), .reopenArming)
        XCTAssertEqual(DeadCardOffer.returnKey(endedAt: ended, now: ended + 0.999), .reopenArming)
        XCTAssertEqual(DeadCardOffer.returnKey(endedAt: ended, now: ended + 1), .reopen)
    }

    func testReturnReopensACardFoundDeadAtARestoreAtOnce() {
        XCTAssertEqual(DeadCardOffer.returnKey(endedAt: nil, now: Date()), .reopen)
    }
}
