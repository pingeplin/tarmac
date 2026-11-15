import Foundation
import XCTest
import TarmacKit

/// 2611.0011 S8, S20 and 2611.0015 S1, S2, S6, S7, S16: the resume
/// offer, its one reducer, and the panel that shows it.
final class ResumeOfferTests: XCTestCase {
    private let uuid = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000"

    private func offer(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws -> ResumeOffer {
        try XCTUnwrap(ResumeOffer.make(cmd: cmd))
    }

    private func armed(_ cmd: String = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000") throws -> ResumeOffer {
        try XCTUnwrap(ResumeOffer.step(try offer(cmd), .output(byteCount: 5)).offer)
    }

    // MARK: S8

    func testS8AnEmptyChunkDoesNotArmAndAChunkArmsOnlyThePrimeCard() throws {
        let empty = try XCTUnwrap(ResumeOffer.step(try offer(), .output(byteCount: 0)).offer)
        XCTAssertFalse(empty.armed(prime: true))
        let up = try armed()
        XCTAssertTrue(up.armed(prime: true))
        XCTAssertFalse(up.armed(prime: false))
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

    // MARK: 2611.0015 S1, S2: a request runs at once or queues

    private func run(_ cmd: String) -> ResumeOffer.Effect { .run(Data(cmd.utf8) + Data([0x0D])) }

    func testS1ARequestRunsAnOfferWhoseShellIsUpAndQueuesOneWhoseShellIsNot() throws {
        let (aAfter, aEffect) = ResumeOffer.step(try armed("echo A"), .request)
        XCTAssertNil(aAfter)
        XCTAssertEqual(aEffect, run("echo A"))

        let (b, bEffect) = ResumeOffer.step(try offer("echo B"), .request)
        XCTAssertEqual(b?.queued, true)
        XCTAssertNil(bEffect)
    }

    func testS1AQueuedOfferWaitsThroughARequestAReturnAndAnEmptyChunk() throws {
        let queued = try XCTUnwrap(ResumeOffer.step(try offer("echo B"), .request).offer)
        for event in [ResumeOffer.Event.request, .returnKey(prime: true), .output(byteCount: 0)] {
            let (kept, effect) = ResumeOffer.step(queued, event)
            XCTAssertEqual(kept, queued, "\(event)")
            XCTAssertNil(effect, "\(event)")
        }
    }

    func testS1AQueuedOfferRunsAtItsFirstOutputOnceWithOneCarriageReturn() throws {
        let queued = try XCTUnwrap(ResumeOffer.step(try offer("echo B"), .request).offer)
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

    func testS2AQueuedOfferIsNeverArmed() throws {
        let queued = try XCTUnwrap(ResumeOffer.step(try offer(), .request).offer)
        XCTAssertFalse(queued.armed(prime: true))
    }

    func testS2ARequestRunsOnACardThatIsNotPrimeAsReturnDoesOnThePrimeCard() throws {
        let up = try armed()
        XCTAssertFalse(up.armed(prime: false))
        let request = ResumeOffer.step(up, .request)
        XCTAssertNil(request.offer)
        XCTAssertEqual(request.effect, run(uuid))
        XCTAssertEqual(request.effect, ResumeOffer.step(up, .returnKey(prime: true)).effect)
    }

    // MARK: 2611.0015 S7: skip

    func testS7SkipDropsAFreshAnArmedAndAQueuedOfferWithTheSkipEffect() throws {
        let queued = try XCTUnwrap(ResumeOffer.step(try offer(), .request).offer)
        for (name, offer) in [("fresh", try offer()), ("armed", try armed()), ("queued", queued)] {
            let (gone, effect) = ResumeOffer.step(offer, .skip)
            XCTAssertNil(gone, name)
            XCTAssertEqual(effect, .skip, name)
        }
        let (none, effect) = ResumeOffer.step(nil, .skip)
        XCTAssertNil(none)
        XCTAssertNil(effect)
    }

    // MARK: 2611.0015 S16: input cancels only its own card's queued run

    func testS16InputToOneQueuedCardLeavesTheOtherCardsQueuedRun() throws {
        let a = try XCTUnwrap(ResumeOffer.step(try offer("echo A"), .request).offer)
        let b = try XCTUnwrap(ResumeOffer.step(try offer("echo B"), .request).offer)
        let (aGone, aEffect) = ResumeOffer.step(a, .userInput)
        XCTAssertNil(aGone)
        XCTAssertNil(aEffect)
        XCTAssertNil(ResumeOffer.step(aGone, .output(byteCount: 3)).effect)
        XCTAssertEqual(ResumeOffer.step(b, .output(byteCount: 3)).effect, run("echo B"))
    }

    // MARK: 2611.0015 S6: the panel

    private typealias Button = ResumePanel.Button

    /// 200 characters that end in an id-like word, which `display` would cut.
    private let long = String(repeating: "a", count: 154) + " --resume 3f2a1b9c-0000-4000-8000-000000000000"

    func testS6APanelBeforeTheShellIsUpShowsTheWholeCommandAndPlainButtons() throws {
        XCTAssertEqual(long.count, 200)
        let model = ResumePanel.model(offer: try offer(long), prime: true)
        XCTAssertEqual(model.title, "resume last agent session?")
        XCTAssertEqual(model.command, long)
        XCTAssertEqual(model.buttons, [Button(choice: .resume, text: "resume"), Button(choice: .skip, text: "skip")])
    }

    func testS6AnArmedOfferShowsTheKeyHintsOnThePrimeCardOnly() throws {
        let up = try armed(long)
        XCTAssertEqual(
            ResumePanel.model(offer: up, prime: true).buttons,
            [Button(choice: .resume, text: "⏎ resume"), Button(choice: .skip, text: "esc skip")]
        )
        XCTAssertEqual(
            ResumePanel.model(offer: up, prime: false).buttons,
            [Button(choice: .resume, text: "resume"), Button(choice: .skip, text: "skip")]
        )
        XCTAssertEqual(ResumePanel.model(offer: up, prime: true).command, long)
    }

    func testS6AQueuedOfferSaysItWaitsAndOffersOnlySkip() throws {
        let queued = try XCTUnwrap(ResumeOffer.step(try offer(long), .request).offer)
        for prime in [true, false] {
            let model = ResumePanel.model(offer: queued, prime: prime)
            XCTAssertEqual(model.title, "resumes when the shell is ready", "\(prime)")
            XCTAssertEqual(model.buttons, [Button(choice: .skip, text: "skip")], "\(prime)")
            XCTAssertEqual(model.command, long)
        }
    }

    func testS6NoPanelTextHasTheRefreshGlyph() throws {
        let queued = try XCTUnwrap(ResumeOffer.step(try offer(), .request).offer)
        for (offer, prime) in [(try offer(), true), (try armed(), true), (try armed(), false), (queued, true)] {
            let model = ResumePanel.model(offer: offer, prime: prime)
            XCTAssertFalse(model.title.contains("↻"))
            XCTAssertFalse(model.buttons.contains { $0.text.contains("↻") })
        }
    }
}
