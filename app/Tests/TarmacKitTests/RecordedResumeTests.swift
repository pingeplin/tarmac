import XCTest
import TarmacKit

/// 2611.0015 S9: where a terminal's recorded resume command comes from.
final class RecordedResumeTests: XCTestCase {
    private func term(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        .fixture(id, spawn: spawn, resume: resume)
    }

    private func records(_ id: String, _ cmd: String) -> [String: TermRecord] {
        [id: TermRecord(lastCwd: nil, resume: ResumeRecord(cmd: cmd))]
    }

    func testS9AColdSpawnTakesThePlansCommandWhateverTheTableHolds() {
        let cold = term("new", spawn: SpawnRequest(succeeds: "old"), resume: "echo HI")
        XCTAssertEqual(RecordedResume.command(for: cold, termRecords: records("new", "echo HO")), "echo HI")
        XCTAssertNil(RecordedResume.command(for: term("new", spawn: SpawnRequest()), termRecords: records("new", "echo HO")))
    }

    func testS9AReboundTermTakesItsRecordedCommandWhenAccepted() {
        let rebound = term("t", spawn: nil)
        XCTAssertEqual(RecordedResume.command(for: rebound, termRecords: records("t", "echo HO")), "echo HO")
        XCTAssertNil(RecordedResume.command(for: rebound, termRecords: [:]))
        XCTAssertNil(RecordedResume.command(for: rebound, termRecords: records("u", "echo HO")))
        XCTAssertNil(RecordedResume.command(for: rebound, termRecords: records("t", "echo a\necho b")))
    }
}
