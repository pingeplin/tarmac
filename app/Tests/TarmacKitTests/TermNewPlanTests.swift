import CoreGraphics
import XCTest
@testable import TarmacKit

final class TermNewPlanTests: XCTestCase {
    private let owner = CGRect(x: 300, y: 200, width: 470, height: 330)
    private let prime = CGRect(x: 2000, y: 0, width: 470, height: 330)

    private func request(owner ownerID: String? = "t1", board: String = "board-0") -> TermNewPlan.Request {
        TermNewPlan.Request(reqID: 4, cmd: "claude --model opus", cwd: "/w/api", ownerTermID: ownerID, boardID: board)
    }

    private func board(
        built: Bool = true, restored: Bool = true, ownerFrame: CGRect? = nil, primeFrame: CGRect? = nil,
        existing: [CGRect] = [], zs: [Int] = []
    ) -> TermNewPlan.Board {
        TermNewPlan.Board(
            built: built, restored: restored, ownerFrame: ownerFrame, primeFrame: primeFrame, existing: existing, zs: zs
        )
    }

    private func placed(_ decision: TermNewPlan.Decision) -> TermNewPlan.Place? {
        if case .place(let place) = decision { return place }
        return nil
    }

    func testS6TheCardTakesTheFirstFreeSlotAroundItsOwnerWithTheOwnerAndTheTopZ() {
        let existing = [owner, prime]
        let place = placed(TermNewPlan.plan(
            request(), on: board(ownerFrame: owner, primeFrame: prime, existing: existing, zs: [2, 5])
        ))

        XCTAssertEqual(place?.boardID, "board-0")
        XCTAssertEqual(place?.frame, TermPlacement.newTerminalFrame(prime: owner, existing: existing))
        XCTAssertEqual(place?.z, 6)
        XCTAssertEqual(place?.owner, "t1")
        XCTAssertEqual(place?.spawn, SpawnRequest(cwd: "/w/api"))
    }

    func testS7WithNoOwnerCardTheCardIsAnchoredOnThePrimeAndHasNoOwner() {
        for ownerID in [nil, "t-not-here"] as [String?] {
            let place = placed(TermNewPlan.plan(
                request(owner: ownerID), on: board(primeFrame: prime, existing: [prime])
            ))

            XCTAssertEqual(place?.frame, TermPlacement.newTerminalFrame(prime: prime, existing: [prime]))
            XCTAssertNil(place?.owner ?? nil)
        }
    }

    func testS7WithNoPrimeEitherTheCardCirclesTheBootFrame() {
        let place = placed(TermNewPlan.plan(request(owner: nil), on: board()))

        XCTAssertEqual(place?.frame, TermPlacement.newTerminalFrame(prime: nil, existing: []))
    }

    func testS12ABoardNotBuiltOrNotRestoredOnThisConnectionIsRefused() {
        for (built, restored) in [(true, false), (false, true), (false, false)] {
            XCTAssertEqual(
                TermNewPlan.plan(request(board: "board-2"), on: board(built: built, restored: restored, ownerFrame: owner)),
                .refuse("board board-2 is not ready in the app; show it, then retry"),
                "built \(built), restored \(restored)"
            )
        }
    }

    func testS14TheInputIsTheCommandAndAReturnAsUTF8HeldAndNotTyped() {
        let place = placed(TermNewPlan.plan(
            TermNewPlan.Request(reqID: 1, cmd: "echo 中", cwd: "/w", ownerTermID: nil, boardID: "board-0"), on: board()
        ))

        XCTAssertEqual(
            place?.input(termID: "t9"), .input(termID: "t9", bytes: Data("echo 中\r".utf8), typed: false, hold: true)
        )
    }
}
