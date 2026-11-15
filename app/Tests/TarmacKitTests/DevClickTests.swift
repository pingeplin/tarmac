import CoreGraphics
import XCTest
@testable import TarmacKit

/// 2611.0015 D16: the controls `tarmac dev click` names, which of them a card
/// shows, where the veil is pressed, and what a click answers.
final class DevClickTests: XCTestCase {
    private func offer(_ events: [ResumeOffer.Event]) throws -> ResumeOffer {
        try XCTUnwrap(events.reduce(ResumeOffer.make(cmd: "echo HI")) { ResumeOffer.step($0, $1).offer })
    }

    func testEachTargetHasItsOwnClosedSetOfNames() {
        XCTAssertEqual(DevClick.controls(of: .card).map(\.rawValue), ["resume", "skip", "resume_chip"])
        XCTAssertEqual(
            DevClick.controls(of: .restoreCard).map(\.rawValue), ["resume_all", "decide_per_card", "skip_all", "veil"]
        )
    }

    func testAPanelAndAChipArePresentInOrder() throws {
        let panel = ResumePanel.model(offer: try offer([]), prime: false)
        let chip = ResumeHeaderChip.model(cmd: "echo HI", dead: false)
        XCTAssertEqual(DevClick.present(panel: panel, chip: chip), [.panel(.resume), .panel(.skip), .resumeChip])
        XCTAssertEqual(DevClick.present(panel: panel, chip: nil), [.panel(.resume), .panel(.skip)])
        XCTAssertEqual(DevClick.present(panel: nil, chip: chip), [.resumeChip])
        XCTAssertEqual(DevClick.present(panel: nil, chip: nil), [])
    }

    func testAQueuedPanelHasOnlySkip() throws {
        let queued = ResumePanel.model(offer: try offer([.request]), prime: true)
        XCTAssertEqual(DevClick.present(panel: queued, chip: nil), [.panel(.skip)])
    }

    func testTheVeilIsPressedOnlyOutsideTheCard() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let card = CGRect(x: 200, y: 200, width: 200, height: 200)
        let points = DevClick.veilPoints(in: bounds, card: card)
        XCTAssertFalse(points.isEmpty)
        XCTAssertFalse(points.contains { card.contains($0) })
        XCTAssertTrue(points.allSatisfy { bounds.contains($0) })
    }

    func testTheReplyNamesTheControlAndTheFocusAfterIt() {
        let reply = DevClick.reply(card: "t-1", control: .panel(.resume), selectedCard: "t-1", keyboardFocus: .none)
        guard case .object(let fields) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(fields["card"], "t-1")
        XCTAssertEqual(fields["control"], "resume")
        XCTAssertEqual(fields["focused_card"], "t-1")
        XCTAssertNotNil(fields["active_element"])
    }

    func testTheRestoreCardsReplyHasANullCard() {
        let reply = DevClick.reply(card: nil, control: .restore(.resumeAll), selectedCard: nil, keyboardFocus: .none)
        guard case .object(let fields) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(fields["card"], .null)
        XCTAssertEqual(fields["control"], "resume_all")
        XCTAssertEqual(fields["focused_card"], .null)
    }
}
