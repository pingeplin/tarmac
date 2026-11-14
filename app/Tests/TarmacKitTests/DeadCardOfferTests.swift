import XCTest
import TarmacKit

/// 2611.0011 S10, S25: what a dead card offers, and what its reopen spawns.
final class DeadCardOfferTests: XCTestCase {
    private let home = "/Users/u"

    func testS10AFolderIsOfferedWithHomeShownAsTilde() throws {
        let offer = try XCTUnwrap(DeadCardOffer.make(record: TermRecord(lastCwd: "/Users/u/w"), home: home))
        XCTAssertEqual(offer.lines, ["↻ reopen here  ⏎", "in ~/w"])
    }

    func testS10HomeIsReplacedOnlyAtAPathBoundary() throws {
        let offer = try XCTUnwrap(DeadCardOffer.make(record: TermRecord(lastCwd: "/Users/u2/w"), home: home))
        XCTAssertEqual(offer.lines, ["↻ reopen here  ⏎", "in /Users/u2/w"])
        let atHome = try XCTUnwrap(DeadCardOffer.make(record: TermRecord(lastCwd: "/Users/u"), home: home))
        XCTAssertEqual(atHome.lines, ["↻ reopen here  ⏎", "in ~"])
    }

    func testS10ASafeResumeAddsAThirdLine() throws {
        let record = TermRecord(lastCwd: "/w", resume: ResumeRecord(cmd: "claude --resume 3f2a1b9c-0000-4000-8000-000000000000"))
        let offer = try XCTUnwrap(DeadCardOffer.make(record: record, home: home))
        XCTAssertEqual(offer.lines, ["↻ reopen here  ⏎", "in /w", "then offers: claude --resume 3f2a…"])
    }

    func testS10AResumeAloneIsOfferedWithNoFolderLine() throws {
        let offer = try XCTUnwrap(DeadCardOffer.make(record: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: "echo HI")), home: home))
        XCTAssertEqual(offer.lines, ["↻ reopen here  ⏎", "then offers: echo HI"])
    }

    func testS10NothingToOfferGivesNoOffer() {
        XCTAssertNil(DeadCardOffer.make(record: nil, home: home))
        XCTAssertNil(DeadCardOffer.make(record: TermRecord(lastCwd: nil), home: home))
        XCTAssertNil(DeadCardOffer.make(record: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: "echo a\necho b")), home: home))
    }

    func testS10ARefusedResumeIsLeftOutOfAFolderOffer() throws {
        let record = TermRecord(lastCwd: "/w", resume: ResumeRecord(cmd: "echo a\necho b"))
        let offer = try XCTUnwrap(DeadCardOffer.make(record: record, home: home))
        XCTAssertEqual(offer.lines, ["↻ reopen here  ⏎", "in /w"])
        XCTAssertNil(DeadCardOffer.reopen(offer, deadID: "T").resume)
    }

    // MARK: S25

    func testS25ReopenSucceedsTheDeadIdInItsFolderAndCarriesTheResume() throws {
        let offer = try XCTUnwrap(DeadCardOffer.make(record: TermRecord(lastCwd: "/w", resume: ResumeRecord(cmd: "echo HI")), home: home))
        let reopen = DeadCardOffer.reopen(offer, deadID: "T")
        XCTAssertEqual(reopen.spawn, SpawnRequest(cwd: "/w", succeeds: "T"))
        XCTAssertEqual(reopen.resume, "echo HI")
    }

    func testS25ReopenWithNoFolderStillSucceedsTheDeadId() throws {
        let offer = try XCTUnwrap(DeadCardOffer.make(record: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: "echo HI")), home: home))
        XCTAssertEqual(DeadCardOffer.reopen(offer, deadID: "T").spawn, SpawnRequest(cwd: nil, succeeds: "T"))
    }
}
