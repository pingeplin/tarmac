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
        ready: Bool = true, ownerFrame: CGRect? = nil, primeFrame: CGRect? = nil, existing: [CGRect] = [], zs: [Int] = []
    ) -> TermNewPlan.Board {
        TermNewPlan.Board(ready: ready, ownerFrame: ownerFrame, primeFrame: primeFrame, existing: existing, zs: zs)
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

    func testS12ABoardTheAppCannotSpawnOnIsRefused() {
        XCTAssertEqual(
            TermNewPlan.plan(request(board: "board-2"), on: board(ready: false, ownerFrame: owner)),
            .refuse("board board-2 is not ready in the app; show it, then retry")
        )
    }

    func testS30APlannedTermCardWithAnOwnerIsNotCarriedByItsOwnersDrag() {
        let place = placed(TermNewPlan.plan(request(), on: board(ownerFrame: owner, existing: [owner])))!
        let cards: [String: Provenance.Card<String>] = [
            "t1": .init(frame: owner, owner: nil, attached: Provenance.startsAttached(isDoc: false)),
            "t9": .init(frame: place.frame, owner: place.owner, attached: Provenance.startsAttached(isDoc: false)),
        ]

        XCTAssertEqual(place.owner, "t1")
        XCTAssertEqual(Provenance.carried(by: "t1", among: cards), [:])
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
