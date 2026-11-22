import Foundation
import TarmacKit
import XCTest

/// 2611.0011 S31: `tarmac-protocol`'s `tests/fixtures/resume_cmd_cases.json`,
/// the table its own `s31_the_resume_command_check` runs, so both languages
/// accept and refuse the same commands with the same cause.
final class ResumeCommandTests: XCTestCase {
    private struct Table: Decodable {
        struct Case: Decodable {
            let parts: [Part]
            let cause: String?
        }

        /// A text and how many times it is repeated: `["a", 256]`.
        struct Part: Decodable {
            let text: String
            let count: Int

            init(from decoder: Decoder) throws {
                var pair = try decoder.unkeyedContainer()
                text = try pair.decode(String.self)
                count = try pair.decode(Int.self)
            }
        }

        let cases: [Case]
    }

    private func cases() throws -> [(cmd: String, cause: String?)] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("core/crates/tarmac-protocol/tests/fixtures/resume_cmd_cases.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: fixture))
        return table.cases.map { c in
            (c.parts.map { String(repeating: $0.text, count: $0.count) }.joined(), c.cause)
        }
    }

    func spikeOff_testTheSharedTable() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 30)
        for (cmd, cause) in all {
            XCTAssertEqual(ResumeCommand.check(cmd), cause, cmd.debugDescription)
        }
    }

    /// A grapheme count would accept the table's 257-scalar command of
    /// combining marks.
    func spikeOff_testTheCombiningCase() throws {
        let combining = try cases()[3].cmd
        XCTAssertEqual(combining.unicodeScalars.count, 256)
        XCTAssertLessThan(combining.count, 256)
    }
}
