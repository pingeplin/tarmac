import CoreGraphics
import XCTest
@testable import TarmacKit

/// The board ↔ layout-tile codec: `build` (persist) and `parse` (restore), and
/// their round trip — the contract that a board survives a restart.
final class LayoutTilesTests: XCTestCase {
    private func term(_ termID: String, x: CGFloat, dead: Bool = false, z: Double = 0) -> LayoutTiles.TermInput {
        LayoutTiles.TermInput(
            termID: termID, frame: CGRect(x: x, y: 80, width: 470, height: 330), z: z, dead: dead
        )
    }

    private func doc(_ path: String, x: CGFloat, attached: Bool = true, z: Double = 1) -> LayoutTiles.DocInput {
        LayoutTiles.DocInput(
            path: path, frame: CGRect(x: x, y: 80, width: 392, height: 310), z: z, attached: attached
        )
    }

    // MARK: - build

    func testEmitsTermTilesWithTermIDAndIntegerZAndExcludesDeadTerminals() {
        let tiles = LayoutTiles.build(terms: [term("t1", x: 80), term("t2", x: 600, dead: true)], docs: [])
        XCTAssertEqual(
            tiles,
            [LayoutTile(kind: "term", x: 80, y: 80, w: 470, h: 330, z: 0, termID: "t1")]
        )
        XCTAssertNil(tiles.first?.path)
    }

    func testRoundsZToAnInteger() {
        XCTAssertEqual(LayoutTiles.build(terms: [term("t1", x: 0, z: 2.7)], docs: []).first?.z, 3)
    }

    func testRoundsAZTieTowardPositiveInfinityLikeTheDesktopBoardDid() {
        XCTAssertEqual(LayoutTiles.build(terms: [term("t1", x: 0, z: -2.5)], docs: []).first?.z, -2)
    }

    func testClampsACorruptOutOfRangeZSoItCannotTruncate() {
        let huge = LayoutTiles.build(terms: [term("t1", x: 0, z: 1.7e308)], docs: [])
        XCTAssertEqual(huge.first?.z, 2_000_000_000)
        let tiny = LayoutTiles.build(terms: [term("t1", x: 0, z: -1.7e308)], docs: [])
        XCTAssertEqual(tiny.first?.z, -2_000_000_000)
        let infinite = LayoutTiles.build(terms: [term("t1", x: 0, z: .infinity)], docs: [])
        XCTAssertEqual(infinite.first?.z, 2_000_000_000)
    }

    func testANaNZPersistsAsZeroRatherThanTrapping() {
        XCTAssertEqual(LayoutTiles.build(terms: [term("t1", x: 0, z: .nan)], docs: []).first?.z, 0)
    }

    func testEmitsBoardDocTilesWithLooseAsNotAttachedSortedByPath() {
        let tiles = LayoutTiles.build(terms: [], docs: [doc("/b.md", x: 600), doc("/a.md", x: 600, attached: false)])
        XCTAssertEqual(tiles.map(\.path), ["/a.md", "/b.md"])
        XCTAssertEqual(tiles.map(\.loose), [true, false])
        XCTAssertEqual(tiles.map(\.kind), ["doc", "doc"])
    }

    func testDocPathsSortByUTF16CodeUnitLikeTheDesktopBoardDid() {
        // U+FF5E sorts above U+1F600 by UTF-16 code unit (0xFF5E > 0xD83D) but below it by scalar.
        let tiles = LayoutTiles.build(terms: [], docs: [doc("/\u{1F600}.md", x: 0), doc("/\u{FF5E}.md", x: 0)])
        XCTAssertEqual(tiles.map(\.path), ["/\u{1F600}.md", "/\u{FF5E}.md"])
    }

    func testOrdersTermsFirstThenBoardDocs() {
        let tiles = LayoutTiles.build(terms: [term("t1", x: 80)], docs: [doc("/d.md", x: 600)])
        XCTAssertEqual(tiles.map(\.kind), ["term", "doc"])
    }

    func testNeverEmitsShelfTiles() {
        let tiles = LayoutTiles.build(terms: [term("t1", x: 80)], docs: [doc("/d.md", x: 600)])
        XCTAssertTrue(tiles.allSatisfy { $0.shelf == nil })
    }

    // MARK: - parse

    func testSplitsTermAndBoardDocTiles() {
        let parsed = LayoutTiles.parse([
            LayoutTile(kind: "term", x: 80, y: 80, w: 470, h: 330, z: 0, termID: "t1"),
            LayoutTile(kind: "doc", path: "/a.md", x: 600, y: 80, w: 392, h: 310, z: 1, loose: false),
        ])
        XCTAssertEqual(
            parsed.terms,
            [LayoutTiles.ParsedTerm(termID: "t1", frame: CGRect(x: 80, y: 80, width: 470, height: 330), z: 0)]
        )
        XCTAssertEqual(
            parsed.docs,
            [LayoutTiles.ParsedDoc(
                path: "/a.md", frame: CGRect(x: 600, y: 80, width: 392, height: 310), z: 1, attached: true
            )]
        )
    }

    func testDropsLegacyShelfTilesSilently() {
        let parsed = LayoutTiles.parse([LayoutTile(kind: "doc", path: "/parked.md", loose: true, shelf: true)])
        XCTAssertEqual(parsed.docs, [])
    }

    func testAGeometryLessTileIsM1AndANilTermIDIsLegacy() {
        let parsed = LayoutTiles.parse([LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/m1.md")])
        XCTAssertEqual(parsed.terms, [LayoutTiles.ParsedTerm(termID: nil, frame: nil, z: 0)])
        XCTAssertEqual(parsed.docs, [LayoutTiles.ParsedDoc(path: "/m1.md", frame: nil, z: 0, attached: true)])
    }

    func testATileMissingAnyOneGeometryKeyHasNoFrame() {
        let partial = LayoutTile(kind: "term", x: 1, y: 2, w: 3, termID: "t1")
        XCTAssertNil(LayoutTiles.parse([partial]).terms.first?.frame)
    }

    func testADocTileWithLooseTrueIsDetached() {
        let parsed = LayoutTiles.parse([LayoutTile(kind: "doc", path: "/x.md", x: 0, y: 0, w: 1, h: 1, loose: true)])
        XCTAssertEqual(parsed.docs.first?.attached, false)
    }

    func testSkipsUnknownKindsAndPathlessDocTiles() {
        let parsed = LayoutTiles.parse([
            LayoutTile(kind: "frame"),
            LayoutTile(kind: "doc"),
            LayoutTile(kind: "term", termID: "t1"),
        ])
        XCTAssertEqual(parsed.terms.count, 1)
        XCTAssertEqual(parsed.docs, [])
    }

    // MARK: - round trip

    func testRoundTripPreservesTermIDsFramesAndDocAttachment() {
        let terms = [term("t1", x: 80), term("t2", x: 600)]
        let docs = [doc("/a.md", x: 1100, attached: true), doc("/b.md", x: 1100, attached: false)]
        let parsed = LayoutTiles.parse(LayoutTiles.build(terms: terms, docs: docs))

        XCTAssertEqual(parsed.terms.map(\.termID), ["t1", "t2"])
        XCTAssertEqual(parsed.terms.first?.frame, terms[0].frame)
        XCTAssertEqual(parsed.docs.first { $0.path == "/a.md" }?.attached, true)
        XCTAssertEqual(parsed.docs.first { $0.path == "/b.md" }?.attached, false)
        XCTAssertEqual(parsed.docs.first { $0.path == "/a.md" }?.frame, docs[0].frame)
    }

    func testS11TermTileZSurvivesTheRoundTrip() {
        let parsed = LayoutTiles.parse(LayoutTiles.build(terms: [term("t1", x: 0, z: 7)], docs: []))
        XCTAssertEqual(parsed.terms.first?.z, 7)
    }

    func testS12DocTileZSurvivesTheRoundTrip() {
        let parsed = LayoutTiles.parse(LayoutTiles.build(terms: [], docs: [doc("/c.md", x: 0, z: 5)]))
        XCTAssertEqual(parsed.docs.first?.z, 5)
    }
}
