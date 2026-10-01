import XCTest
@testable import TarmacKit

/// Issue #77: which terminal a fresh ⌘T terminal inherits its cwd from.
final class CwdInheritTests: XCTestCase {
    private func term(
        _ id: String = "t1",
        prime: Bool = false,
        live: Bool = true,
        dead: Bool = false
    ) -> CwdInherit.Candidate {
        CwdInherit.Candidate(termID: id, prime: prime, live: live, dead: dead)
    }

    func testEmptyBoardHasNoSource() {
        XCTAssertNil(CwdInherit.source(in: []))
    }

    func testSourceIsTheLivePrimeTerminal() {
        let cards = [term("t1"), term("t2", prime: true)]
        XCTAssertEqual(CwdInherit.source(in: cards), "t2")
    }

    func testDeadPrimeHasNoSource() {
        let cards = [term("t1", prime: true, live: false, dead: true)]
        XCTAssertNil(CwdInherit.source(in: cards))
    }

    func testNonLivePrimeHasNoSource() {
        let cards = [term("t1", prime: true, live: false)]
        XCTAssertNil(CwdInherit.source(in: cards))
    }

    func testNoPrimeHasNoSource() {
        XCTAssertNil(CwdInherit.source(in: [term("t1"), term("t2")]))
    }

    func testPrimeTermIDSkipsAPrimeThatIsDeadAndTakesTheFirstLiveOne() {
        let cards = [term("t1", prime: true, dead: true), term("t2", prime: true)]
        XCTAssertEqual(CwdInherit.primeTermID(in: cards), "t2")
    }
}
