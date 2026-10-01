import XCTest
import TarmacKit

/// Spec 2609.0009 for the suffix (ported from `desktop/src/kit/devTitle.test.ts`)
/// and `App.tsx`'s title effect for the rest.
final class WindowTitleTests: XCTestCase {
    /// S1 — a label yields a suffix.
    func testTheSuffixAppendsTheWorktreeLabel() {
        XCTAssertEqual(WindowTitle.devSuffix(label: "102-dev-bundle-id"), " · 102-dev-bundle-id")
    }

    func testTheSuffixTrimsSoPaddingNeverReachesTheTitle() {
        XCTAssertEqual(WindowTitle.devSuffix(label: "  41-reload  "), WindowTitle.devSuffix(label: "41-reload"))
        XCTAssertEqual(WindowTitle.devSuffix(label: "\n41-reload\t"), " · 41-reload")
    }

    /// S2 — no label yields none.
    func testAnAbsentOrBlankLabelYieldsNoSuffix() {
        XCTAssertEqual(WindowTitle.devSuffix(label: nil), "")
        XCTAssertEqual(WindowTitle.devSuffix(label: ""), "")
        XCTAssertEqual(WindowTitle.devSuffix(label: "   \t "), "")
    }

    /// The glyph and the padding spaces are literal.
    func testTheTitleNamesTheActiveBoard() {
        XCTAssertEqual(WindowTitle.text(boardName: "infra", boardID: "board-2", devLabel: nil), " ▞ infra ")
    }

    func testTheBoardNameIsTrimmed() {
        XCTAssertEqual(WindowTitle.text(boardName: "  infra \n", boardID: "board-2", devLabel: nil), " ▞ infra ")
    }

    func testAnUnnamedBoardShowsItsID() {
        XCTAssertEqual(WindowTitle.text(boardName: nil, boardID: "board-2", devLabel: nil), " ▞ board-2 ")
        XCTAssertEqual(WindowTitle.text(boardName: "", boardID: "board-2", devLabel: nil), " ▞ board-2 ")
        XCTAssertEqual(WindowTitle.text(boardName: "  ", boardID: "board-2", devLabel: nil), " ▞ board-2 ")
    }

    func testWithNoBoardAtAllTheTitleIsTarmac() {
        XCTAssertEqual(WindowTitle.text(boardName: nil, boardID: "", devLabel: nil), " ▞ tarmac ")
    }

    func testADevBuildAppendsItsWorktree() {
        XCTAssertEqual(
            WindowTitle.text(boardName: "infra", boardID: "board-2", devLabel: " 41-reload "),
            " ▞ infra · 41-reload "
        )
        XCTAssertEqual(WindowTitle.text(boardName: nil, boardID: "board-0", devLabel: " "), " ▞ board-0 ")
    }
}
