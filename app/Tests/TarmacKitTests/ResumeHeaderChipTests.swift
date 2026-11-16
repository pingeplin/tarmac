import CoreGraphics
import XCTest
import TarmacKit

/// 2611.0015 S8, S9, S23: the header chip of a terminal with a recorded
/// resume command, and where that command comes from.
final class ResumeHeaderChipTests: XCTestCase {
    private let uuid = "claude --resume 3f2a1b9c-0000-4000-8000-000000000000"

    // MARK: S8

    func testS8TheChipReadsResumeAndItsToolTipIsTheWholeCommand() throws {
        let model = try XCTUnwrap(ResumeHeaderChip.model(cmd: uuid, dead: false))
        XCTAssertEqual(model.text, "resume")
        XCTAssertEqual(model.toolTip, uuid)
        XCTAssertFalse(model.text.contains("↻"))
    }

    func testS8NoCommandARefusedCommandOrADeadCardGivesNoChip() {
        XCTAssertNil(ResumeHeaderChip.model(cmd: nil, dead: false))
        XCTAssertNil(ResumeHeaderChip.model(cmd: "echo a\necho b", dead: false))
        XCTAssertNil(ResumeHeaderChip.model(cmd: "echo \u{202E}x", dead: false))
        XCTAssertNil(ResumeHeaderChip.model(cmd: "echo HI", dead: true))
        XCTAssertNotNil(ResumeHeaderChip.model(cmd: "echo HI", dead: false))
    }

    func testS8TheCopyToastSaysTheCommandWasCopied() {
        XCTAssertEqual(ResumeHeaderChip.copiedToast, "resume command copied")
    }

    // MARK: S9

    private func term(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        .fixture(id, spawn: spawn, resume: resume)
    }

    private func records(_ id: String, _ cmd: String) -> [String: TermRecord] {
        [id: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: cmd))]
    }

    func testS9APushedCommandIsKeptOnlyWhenAccepted() {
        XCTAssertEqual(ResumeCommand.accepted("echo HI"), "echo HI")
        XCTAssertNil(ResumeCommand.accepted(nil))
        XCTAssertNil(ResumeCommand.accepted("echo a\necho b"))
    }

    // MARK: S23

    func testS23ARefusedCommandGetsNoOfferNoChipAndNoRecordedCommand() {
        let refused = "echo a\necho b"
        XCTAssertNil(ResumeOffer.make(cmd: refused))
        XCTAssertNil(ResumeHeaderChip.model(cmd: refused, dead: false))
        XCTAssertNil(RecordedResume.command(for: term("t", spawn: SpawnRequest(), resume: refused), termRecords: [:]))
        XCTAssertNil(RecordedResume.command(for: term("t", spawn: nil), termRecords: records("t", refused)))
        XCTAssertNil(ResumeCommand.accepted(refused))
    }
}
