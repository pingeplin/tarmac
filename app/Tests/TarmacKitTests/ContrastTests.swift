import XCTest
@testable import TarmacKit

/// 2610.0007: the WCAG 2 contrast ratio the palette tests measure with.
final class ContrastTests: XCTestCase {
    /// S11 — the two ends of the scale, and the grey WCAG's own examples use.
    func testS11TheRatioIsTheWCAGOne() {
        XCTAssertEqual(Contrast.ratio(0x000000, 0xffffff), 21, accuracy: 0.01)
        XCTAssertEqual(Contrast.ratio(0x777777, 0xffffff), 4.48, accuracy: 0.01)
    }

    /// S11
    func testS11AColourHasNoContrastWithItself() {
        for colour: UInt32 in [0x000000, 0x12846e, 0xffffff] {
            XCTAssertEqual(Contrast.ratio(colour, colour), 1, String(colour, radix: 16))
        }
    }

    /// S11
    func testS11TheRatioDoesNotDependOnTheOrder() {
        let pairs: [(UInt32, UInt32)] = [(0x000000, 0xffffff), (0x12846e, 0xeff0f1), (0xed1515, 0x31363b)]
        for (a, b) in pairs {
            XCTAssertEqual(Contrast.ratio(a, b), Contrast.ratio(b, a), String(a, radix: 16))
            XCTAssertGreaterThan(Contrast.ratio(a, b), 1, String(a, radix: 16))
        }
    }

    /// Each channel has its own weight: green counts the most and blue the
    /// least.
    func testEachChannelIsWeighedApart() {
        let onBlack = [0xff0000, 0x00ff00, 0x0000ff].map { Contrast.ratio($0, 0x000000) }
        XCTAssertEqual(onBlack[0], 5.25, accuracy: 0.01)
        XCTAssertEqual(onBlack[1], 15.3, accuracy: 0.01)
        XCTAssertEqual(onBlack[2], 2.44, accuracy: 0.01)
    }
}
