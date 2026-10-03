import XCTest
@testable import TarmacKit

final class TermPrimeTests: XCTestCase {
    private func terms(_ pairs: (String, Bool)...) -> [TermPrime.Term] {
        pairs.map { TermPrime.Term(termID: $0.0, isLive: $0.1) }
    }

    func testALivePrimeKeepsPrime() {
        XCTAssertEqual(TermPrime.reassign(terms(("a", true), ("b", true)), prime: "b"), "b")
    }

    /// The first live terminal in card order, not the one after the dead prime.
    func testADeadPrimeHandsOverToTheFirstLiveTerminal() {
        XCTAssertEqual(
            TermPrime.reassign(terms(("a", true), ("b", false), ("c", true)), prime: "b"),
            "a"
        )
    }

    func testARemovedPrimeHandsOverToTheFirstLiveTerminal() {
        XCTAssertEqual(TermPrime.reassign(terms(("a", false), ("c", true), ("d", true)), prime: "gone"), "c")
    }

    func testNoPrimePromotesTheFirstLiveTerminal() {
        XCTAssertEqual(TermPrime.reassign(terms(("a", false), ("b", true)), prime: nil), "b")
    }

    func testNoLiveTerminalMeansNoPrime() {
        XCTAssertNil(TermPrime.reassign(terms(("a", false), ("b", false)), prime: "a"))
        XCTAssertNil(TermPrime.reassign([], prime: nil))
    }
}
