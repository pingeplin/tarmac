import TarmacKit
import XCTest

/// 2611.0015 "Resume panel title buttons and full command": the panel at the foot of a card with an offer.
final class ResumePanelTests: XCTestCase {
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

    private typealias Button = ResumePanel.Button

    /// 200 characters that end in an id-like word, which `display` would cut.
    private let long = String(repeating: "a", count: 154) + " --resume 3f2a1b9c-0000-4000-8000-000000000000"

    /// "Resume panel title buttons and full command".
    func testAPanelBeforeTheShellIsUpShowsTheWholeCommandAndPlainButtons() throws {
        XCTAssertEqual(long.count, 200)
        let model = ResumePanel.model(offer: try offer(long), prime: true)
        XCTAssertEqual(model.title, "resume last agent session?")
        XCTAssertEqual(model.command, long)
        XCTAssertEqual(model.buttons, [Button(choice: .resume, text: "resume"), Button(choice: .skip, text: "skip")])
    }

    /// "Resume panel title buttons and full command".
    func testAnArmedOfferShowsTheKeyHintsOnThePrimeCardOnly() throws {
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

    /// "Resume panel title buttons and full command".
    func testAQueuedOfferSaysItWaitsAndOffersOnlySkip() throws {
        let queued = try queuedOffer(long)
        for prime in [true, false] {
            let model = ResumePanel.model(offer: queued, prime: prime)
            XCTAssertEqual(model.title, "resumes when the shell is ready", "\(prime)")
            XCTAssertEqual(model.buttons, [Button(choice: .skip, text: "skip")], "\(prime)")
            XCTAssertEqual(model.command, long)
        }
    }

    /// "Resume panel title buttons and full command".
    func testNoPanelTextHasTheRefreshGlyph() throws {
        let queued = try queuedOffer()
        for (offer, prime) in [(try offer(), true), (try armed(), true), (try armed(), false), (queued, true)] {
            let model = ResumePanel.model(offer: offer, prime: prime)
            XCTAssertFalse(model.title.contains("↻"))
            XCTAssertFalse(model.buttons.contains { $0.text.contains("↻") })
        }
    }
}
