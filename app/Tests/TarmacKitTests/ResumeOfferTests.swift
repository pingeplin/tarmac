import Foundation
import TarmacKit
import XCTest

/// 2611.0011 "Resume chip arms and runs once", "Any user byte drops the offer" and 2611.0015 "Resume all runs each card at its output", "Request runs on prime and non-prime cards", "Skip clears fresh armed and queued offers", "Input cancels only its own card's queued run": the resume
/// offer and its one reducer.
final class ResumeOfferTests: XCTestCase {
    private let uuid = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000"

    private func offer(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws -> ResumeOffer {
        try ResumeOffer.fixture(cmd)
    }

    private func armed(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws -> ResumeOffer {
        try ResumeOffer.fixture(cmd, after: [.output(byteCount: 5)])
    }

    private func queuedOffer(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws
        -> ResumeOffer
    {
        try ResumeOffer.fixture(cmd, after: [.request])
    }

    // MARK: "Resume chip arms and runs once"

    /// "Resume chip arms and runs once".
    func testAnEmptyChunkDoesNotArmAndAChunkArmsOnlyThePrimeCard() throws {
        let empty = try XCTUnwrap(ResumeOffer.step(try offer(), .output(byteCount: 0)).offer)
        XCTAssertFalse(empty.armed(prime: true))
        let up = try armed()
        XCTAssertTrue(up.armed(prime: true))
        XCTAssertFalse(up.armed(prime: false))
    }

    /// "Resume chip arms and runs once".
    func testReturnOnTheArmedPrimeCardRunsTheCommandAndOneCarriageReturnOnce() throws {
        let (gone, effect) = ResumeOffer.step(try armed(), .returnKey(prime: true))
        XCTAssertNil(gone)
        XCTAssertEqual(effect, .run(Data(uuid.utf8) + Data([0x0D])))

        let (stillGone, again) = ResumeOffer.step(gone, .returnKey(prime: true))
        XCTAssertNil(stillGone)
        XCTAssertNil(again)
    }

    /// "Resume chip arms and runs once".
    func testReturnBeforeTheShellIsUpOrOnACardThatIsNotPrimeDoesNothing() throws {
        let notUp = try offer()
        let (kept, effect) = ResumeOffer.step(notUp, .returnKey(prime: true))
        XCTAssertEqual(kept, notUp)
        XCTAssertNil(effect)

        let up = try armed()
        let (keptUp, effectUp) = ResumeOffer.step(up, .returnKey(prime: false))
        XCTAssertEqual(keptUp, up)
        XCTAssertNil(effectUp)
    }

    /// "Resume chip arms and runs once".
    func testMoreOutputKeepsAnArmedOfferArmed() throws {
        let again = try XCTUnwrap(ResumeOffer.step(try armed(), .output(byteCount: 5)).offer)
        XCTAssertTrue(again.armed(prime: true))
    }

    /// "Resume chip arms and runs once".
    func testNoOfferStaysNoOffer() {
        for event in [ResumeOffer.Event.output(byteCount: 5), .userInput] {
            let (offer, effect) = ResumeOffer.step(nil, event)
            XCTAssertNil(offer, "\(event)")
            XCTAssertNil(effect, "\(event)")
        }
    }

    /// "Resume chip arms and runs once".
    func testNoCommandOrARefusedOneMakesNoOffer() {
        XCTAssertNil(ResumeOffer.make(cmd: nil))
        XCTAssertNil(ResumeOffer.make(cmd: "echo a\necho b"))
    }

    // MARK: "Any user byte drops the offer"

    /// "Any user byte drops the offer".
    /// Each row is an offer in another state, and the Return that follows
    /// it is one that would have run that offer had it survived.
    func testAnyUserByteDropsTheOfferInEveryState() throws {
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

    // MARK: 2611.0015 "Resume all runs each card at its output", "Request runs on prime and non-prime cards": a request runs at once or queues

    private func run(_ cmd: String) -> ResumeOffer.Effect { .run(Data(cmd.utf8) + Data([0x0D])) }

    /// "Resume all runs each card at its output".
    func testARequestRunsAnOfferWhoseShellIsUpAndQueuesOneWhoseShellIsNot() throws {
        let (aAfter, aEffect) = ResumeOffer.step(try armed("echo A"), .request)
        XCTAssertNil(aAfter)
        XCTAssertEqual(aEffect, run("echo A"))

        let (b, bEffect) = ResumeOffer.step(try offer("echo B"), .request)
        XCTAssertEqual(b?.queued, true)
        XCTAssertNil(bEffect)
    }

    /// "Resume all runs each card at its output".
    func testAQueuedOfferWaitsThroughARequestAReturnAndAnEmptyChunk() throws {
        let queued = try queuedOffer("echo B")
        for event in [ResumeOffer.Event.request, .returnKey(prime: true), .output(byteCount: 0)] {
            let (kept, effect) = ResumeOffer.step(queued, event)
            XCTAssertEqual(kept, queued, "\(event)")
            XCTAssertNil(effect, "\(event)")
        }
    }

    /// "Resume all runs each card at its output".
    func testAQueuedOfferRunsAtItsFirstOutputOnceWithOneCarriageReturn() throws {
        let queued = try queuedOffer("echo B")
        let (gone, effect) = ResumeOffer.step(queued, .output(byteCount: 3))
        XCTAssertNil(gone)
        guard case .run(let bytes) = effect else { return XCTFail("\(String(describing: effect))") }
        XCTAssertEqual(bytes, Data("echo B".utf8) + Data([0x0D]))
        XCTAssertEqual(bytes.filter { $0 == 0x0D }.count, 1)
        for event in [ResumeOffer.Event.output(byteCount: 3), .request, .returnKey(prime: true)] {
            XCTAssertNil(ResumeOffer.step(gone, event).effect, "\(event)")
        }
    }

    func testANewOfferIsNotQueued() throws {
        XCTAssertFalse(try offer().queued)
        XCTAssertFalse(try armed().queued)
    }

    /// "Request runs on prime and non-prime cards".
    func testAQueuedOfferIsNeverArmed() throws {
        let queued = try queuedOffer()
        XCTAssertFalse(queued.armed(prime: true))
    }

    /// "Request runs on prime and non-prime cards".
    func testARequestRunsOnACardThatIsNotPrimeAsReturnDoesOnThePrimeCard() throws {
        let up = try armed()
        XCTAssertFalse(up.armed(prime: false))
        let request = ResumeOffer.step(up, .request)
        XCTAssertNil(request.offer)
        XCTAssertEqual(request.effect, run(uuid))
        XCTAssertEqual(request.effect, ResumeOffer.step(up, .returnKey(prime: true)).effect)
    }

    // MARK: 2611.0015 "Skip clears fresh armed and queued offers"

    /// "Skip clears fresh armed and queued offers".
    func testSkipDropsAFreshAnArmedAndAQueuedOfferWithTheSkipEffect() throws {
        let queued = try queuedOffer()
        for (name, offer) in [("fresh", try offer()), ("armed", try armed()), ("queued", queued)] {
            let (gone, effect) = ResumeOffer.step(offer, .skip)
            XCTAssertNil(gone, name)
            XCTAssertEqual(effect, .skip, name)
        }
        let (none, effect) = ResumeOffer.step(nil, .skip)
        XCTAssertNil(none)
        XCTAssertNil(effect)
    }

    // MARK: 2611.0015 "Input cancels only its own card's queued run"

    /// "Input cancels only its own card's queued run".
    func testInputToOneQueuedCardLeavesTheOtherCardsQueuedRun() throws {
        let a = try queuedOffer("echo A")
        let b = try queuedOffer("echo B")
        let (aGone, aEffect) = ResumeOffer.step(a, .userInput)
        XCTAssertNil(aGone)
        XCTAssertNil(aEffect)
        XCTAssertNil(ResumeOffer.step(aGone, .output(byteCount: 3)).effect)
        XCTAssertEqual(ResumeOffer.step(b, .output(byteCount: 3)).effect, run("echo B"))
    }
}
