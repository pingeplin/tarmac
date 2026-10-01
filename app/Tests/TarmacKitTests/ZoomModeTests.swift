import XCTest
@testable import TarmacKit

/// Spec 2607.0006 S1 — the magnify-or-reveal decision for an HTML card from its
/// `<meta name="tarmac-zoom">`. The capability probe that once split declared from
/// effective died with the macOS 26 floor (#94), so the declaration is the verdict.
final class ZoomModeTests: XCTestCase {
    // MARK: - declared (2607.0006 S1)

    func testRecognizesMagnifyCaseAndWhitespaceInsensitively() {
        XCTAssertEqual(ZoomMode.declared(metaContent: "magnify"), .magnify)
        XCTAssertEqual(ZoomMode.declared(metaContent: "  MAGNIFY  "), .magnify)
        XCTAssertEqual(ZoomMode.declared(metaContent: "Magnify"), .magnify)
    }

    func testRecognizesRevealCaseAndWhitespaceInsensitivelyTheOnlyOptOut() {
        XCTAssertEqual(ZoomMode.declared(metaContent: "reveal"), .reveal)
        XCTAssertEqual(ZoomMode.declared(metaContent: "  REVEAL  "), .reveal)
        XCTAssertEqual(ZoomMode.declared(metaContent: "Reveal"), .reveal)
    }

    func testDefaultsToMagnifyWhenTheMetaIsAbsent() {
        XCTAssertEqual(ZoomMode.declared(metaContent: nil), .magnify)
        XCTAssertEqual(ZoomMode.declared(metaContent: ""), .magnify)
    }

    func testDefaultsToMagnifyOnAMalformedValueSoOptingOutMustBeDeliberate() {
        XCTAssertEqual(ZoomMode.declared(metaContent: "revealing"), .magnify)
        XCTAssertEqual(ZoomMode.declared(metaContent: "magnifying"), .magnify)
        XCTAssertEqual(ZoomMode.declared(metaContent: "rEvEaL more"), .magnify)
    }

    // MARK: - ready (2609.0003, #99)

    // A document that reloads ITSELF changes neither `src` nor `lastChangedMs`, so
    // the host's per-load state never resets and its `ready` arrives with a mode
    // already in force. `magnify` is true whenever the host should answer the
    // ready with the frozen magnification; its factor is the view layer's.
    private func logLine(_ mode: ZoomMode) -> String { "zoom-mode declared=\(mode.rawValue) effective=\(mode.rawValue)" }

    private func ready(_ inForce: ZoomMode?, _ meta: String?) -> ZoomMode.ReadyActions {
        ZoomMode.ready(inForce: inForce, meta: meta)
    }

    func testS1AdoptsMagnifyLogsTheLineAndMagnifiesWhenMagnifyIsDeclared() {
        XCTAssertEqual(
            ready(nil, "magnify"),
            ZoomMode.ReadyActions(adopt: .magnify, logLine: logLine(.magnify), magnify: true)
        )
    }

    func testS2AMetaLessDocumentTakesTheMagnifyDefaultAndMagnifiesButLogsNothing() {
        XCTAssertEqual(ready(nil, nil), ZoomMode.ReadyActions(adopt: .magnify, logLine: nil, magnify: true))
    }

    /// A present-but-useless tag still logs — only an ABSENT tag is silent. The
    /// shim's `el.content || ""` really can deliver "", and a typo is still a tag
    /// the author wrote. Expected values are literal per row.
    func testS2APresentButUselessTagStillLogsResolvingToTheDefault() {
        let rows: [(meta: String, mode: ZoomMode, magnify: Bool)] = [
            ("", .magnify, true),
            ("banana", .magnify, true),
            ("magnifying", .magnify, true),
            ("  REVEAL  ", .reveal, false),
        ]
        for row in rows {
            XCTAssertEqual(
                ready(nil, row.meta),
                ZoomMode.ReadyActions(adopt: row.mode, logLine: logLine(row.mode), magnify: row.magnify),
                row.meta.debugDescription
            )
        }
    }

    func testS3AdoptsRevealLogsTheLineAndDoesNotMagnifyWhenRevealIsDeclared() {
        XCTAssertEqual(
            ready(nil, "reveal"),
            ZoomMode.ReadyActions(adopt: .reveal, logLine: logLine(.reveal), magnify: false)
        )
    }

    /// Every shape that must answer with magnification — first ready and repeat
    /// alike. In the desktop app the answer carried the frozen root zoom K; the
    /// constant is the view's, so what is pinned here is that the decision is made.
    func testS5EveryMagnifyingShapeAnswersWithMagnification() {
        let cases: [(label: String, inForce: ZoomMode?, meta: String?)] = [
            ("a first magnify ready", nil, "magnify"),
            ("a first meta-less ready", nil, nil),
            ("a meta-less repeat", .magnify, nil),
            ("a repeat forging reveal", .magnify, "reveal"),
        ]
        for c in cases {
            XCTAssertTrue(ready(c.inForce, c.meta).magnify, c.label)
        }
    }

    func testS4TheSelfReloadShapeIsAnsweredWithMagnificationAdoptingAndLoggingNothing() {
        XCTAssertEqual(
            ready(.magnify, "magnify"),
            ZoomMode.ReadyActions(adopt: nil, logLine: nil, magnify: true)
        )
    }

    func testS4AndWithNoMetaAtAllTheCommonerRealShape() {
        XCTAssertEqual(ready(.magnify, nil), ZoomMode.ReadyActions(adopt: nil, logLine: nil, magnify: true))
    }

    func testS6AForgedRevealCannotFlipAMagnifyCardsModeOrAddAConsoleLine() {
        XCTAssertEqual(ready(.magnify, "reveal"), ZoomMode.ReadyActions(adopt: nil, logLine: nil, magnify: true))
    }

    /// The in-force invariant: a repeat decides from the mode already adopted,
    /// never from its own meta. Deciding from `declared` here would hand a reveal
    /// document root magnification and break its layout outright.
    func testS7AForgedMagnifyCannotInjectMagnificationIntoARevealCard() {
        XCTAssertEqual(ready(.reveal, "magnify"), ZoomMode.ReadyActions(adopt: nil, logLine: nil, magnify: false))
    }

    func testS7ARevealCardsHonestRepeatIsEquallySilent() {
        XCTAssertEqual(ready(.reveal, "reveal"), ZoomMode.ReadyActions(adopt: nil, logLine: nil, magnify: false))
    }

    /// Completes the inForce × meta grid: without this, "reveal in force" is only
    /// ever exercised with a meta present.
    func testS7AndARevealCardsMetaLessRepeatTheLastCellOfTheTable() {
        XCTAssertEqual(ready(.reveal, nil), ZoomMode.ReadyActions(adopt: nil, logLine: nil, magnify: false))
    }
}
