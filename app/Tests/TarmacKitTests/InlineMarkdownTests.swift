import XCTest
@testable import TarmacKit

private func line(_ text: String) -> [InlineRun] { InlineMarkdown.line(text).runs }

/// Spec 2611.0017 S10: texts with no markdown, which must read as before.
enum S10 {
    static let texts = [
        "May I?", "  May\n\tI  run\r\n rm?  ", "snake_case_name", "2 * 3 * 4", "#412 done",
        "price: $5 (approx)", "a [b] c", "C:\\path\\*", "a\n\n\nb", "__init__.py", "self.__dict__",
    ]
}

/// Spec 2611.0017: a report's text as one line of inline marks.
final class InlineMarkdownTests: XCTestCase {
    // MARK: - Happy path

    func testS1InlineMarksBecomeRuns() {
        XCTAssertEqual(
            line("Need OK to run `cargo test -p tarmacd` — it **touches** the dev socket."),
            [p("Need OK to run "), c("cargo test -p tarmacd"), p(" — it "), b("touches"), p(" the dev socket.")]
        )
    }

    func testS2EachMark() {
        XCTAssertEqual(line("*a*"), [i("a")])
        XCTAssertEqual(line("_a_"), [i("a")])
        XCTAssertEqual(line("**a**"), [b("a")])
        XCTAssertEqual(line("__a__"), [b("a")])
        XCTAssertEqual(line("[run 88](https://x.invalid/88)"), [l("run 88")])
    }

    func testS3AHeadingIsPlainText() {
        XCTAssertEqual(line("## Blocked"), [p("Blocked")])
    }

    func testS4ListItemsGetOneBulletAndOrderedItemsKeepTheirMark() {
        XCTAssertEqual(line("- a\n- b"), [dot(), p(" a "), dot(), p(" b")])
        XCTAssertEqual(line("1. a\n2) b"), [dot("1."), p(" a "), dot("2)"), p(" b")])
    }

    func testS5AFenceIsOneCodeRun() {
        XCTAssertEqual(line("## Blocked\n```\nrm -rf target/\n```"), [p("Blocked "), c("rm -rf target/")])
    }

    func testS6ParagraphsAndBlocksJoinByOneSpace() {
        let text = InlineMarkdown.line("Done: **x**.\n- a\n\nLeft: run `make qa`.")
        XCTAssertEqual(text.runs, [p("Done: "), b("x"), p(". "), dot(), p(" a Left: run "), c("make qa"), p(".")])
        XCTAssertEqual(text.plain, "Done: x. • a Left: run make qa.")
    }

    // MARK: - Edge cases

    func testS10TextWithNoMarkdownIsOnePlainRunOfItsOneLineForm() {
        for text in S10.texts {
            XCTAssertEqual(line(text), [p(ChromeText.oneLine(text))], text)
        }
    }

    func testS11CRLFEndsALine() {
        XCTAssertEqual(InlineMarkdown.line("- a\r\n- b").plain, "• a • b")
        XCTAssertEqual(InlineMarkdown.line("- a\r- b").plain, "• a • b")
    }

    func testS12AnUnclosedMarkIsLiteral() {
        XCTAssertEqual(line("**half"), [p("**half")])
        XCTAssertEqual(line("run `cargo"), [p("run `cargo")])
        XCTAssertEqual(line("```\nrm -rf"), [c("rm -rf")])
    }

    func testS13AFenceIgnoresItsInfoStringAndAnEmptyBodyGivesNoRun() {
        XCTAssertEqual(line("```swift\nlet x = 1\n```"), [c("let x = 1")])
        XCTAssertEqual(line("a\n```\n```\nb"), [p("a b")])
        XCTAssertEqual(line("a\n```\n  \n```\nb"), [p("a b")])
        XCTAssertEqual(InlineMarkdown.line("```\n```"), .literal("``` ```"))
        XCTAssertEqual(InlineMarkdown.line("```\n  \n```"), .literal("``` ```"))
    }

    func testS14MarksDoNotNest() {
        XCTAssertEqual(line("**see `x`**"), [b("see `x`")])
    }

    func testS15AStarInsideAWordIsAMark() {
        XCTAssertEqual(line("a*b*c"), [p("a"), i("b"), p("c")])
    }

    func testS16WhitespaceInCodeIsOneSpaceAndAFenceBodyIsTrimmed() {
        XCTAssertEqual(line("`a   b`"), [c("a b")])
        XCTAssertEqual(line("```\nx\n\n  y\n```"), [c("x y")])
        XCTAssertEqual(line("a\n```\n\n  x\n```\nb"), [p("a "), c("x"), p(" b")])
    }

    func testS17ALinkWithNoTextIsLiteral() {
        XCTAssertEqual(line("[](u)"), [p("[](u)")])
    }

    func testS18ABackslashIsNotAnEscape() {
        XCTAssertEqual(line("\\*a\\*"), [p("\\"), i("a\\")])
    }

    func testS20APillCutThatLandsOnABullet() {
        XCTAssertEqual(
            InlineMarkdown.line("abcdefghijklmnopqrstu\n- xyz").prefix(scalars: 24).runs,
            [p("abcdefghijklmnopqrstu "), dot(), p("…")]
        )
        XCTAssertEqual(
            InlineMarkdown.line("abcdefghijklmnopqrstuv\n- xyz").prefix(scalars: 24).runs,
            [p("abcdefghijklmnopqrstuv …")]
        )
        XCTAssertEqual(
            InlineMarkdown.line("abcdefghijklmnopqrstu\n12. x").prefix(scalars: 24).runs,
            [p("abcdefghijklmnopqrstu "), dot("1"), p("…")]
        )
    }

    func testS25AStarIsAListMarkOnlyWithWhitespaceAfterIt() {
        XCTAssertEqual(line("* a *b*"), [dot(), p(" a "), i("b")])
        XCTAssertEqual(line("*a* b"), [i("a"), p(" b")])
    }

    func testS26OtherListMarks() {
        XCTAssertEqual(line("+ a"), [dot(), p(" a")])
        XCTAssertEqual(line("  - a"), [dot(), p(" a")])
        XCTAssertEqual(line("- a\nb"), [dot(), p(" a b")])
        XCTAssertEqual(line("a  \n- b"), [p("a "), dot(), p(" b")])
    }

    func testS27AMarkInAHeading() {
        XCTAssertEqual(line("## **a** b"), [b("a"), p(" b")])
    }

    func testS28ImageSyntaxAndMarksInLinkText() {
        XCTAssertEqual(line("![alt](src)"), [p("!"), l("alt")])
        XCTAssertEqual(line("[**a**](u)"), [l("**a**")])
    }

    func testS29AnUnderscoreNextToPunctuationIsAMark() {
        XCTAssertEqual(line("(_a_)"), [p("("), i("a"), p(")")])
    }

    func testS30BlankInputGivesNoRuns() {
        for text in ["", "  ", "\n", "\t", " "] {
            XCTAssertEqual(InlineMarkdown.line(text).runs, [], text.debugDescription)
            XCTAssertEqual(InlineMarkdown.line(text).plain, "")
        }
        XCTAssertEqual(InlineMarkdown.line("## "), .literal("##"))
    }

    func testS31TheClosingMarkIsTheNextOne() {
        XCTAssertEqual(line("*a *b*"), [p("*a "), i("b")])
        XCTAssertEqual(line("***a***"), [b("*a"), p("*")])
        XCTAssertEqual(line("[a](b (c))"), [l("a"), p(")")])
        XCTAssertEqual(line("[a] (b)"), [p("[a] (b)")])
    }

    func testS32TheUnderscoreWordTest() {
        XCTAssertEqual(line("_a_."), [i("a"), p(".")])
        XCTAssertEqual(line("_snake_case is odd_"), [i("snake_case is odd")])
        XCTAssertEqual(line("__pycache__/"), [b("pycache"), p("/")])
    }

    func testS33ACodeSpanAndALinkAreTrimmed() {
        let text = InlineMarkdown.line("a ` b` c")
        XCTAssertEqual(text.runs, [p("a "), c("b"), p(" c")])
        XCTAssertEqual(text.plain, "a b c")
        XCTAssertEqual(line("a ` ` b"), [p("a ` ` b")])
        XCTAssertEqual(line("[ x ](u)"), [l("x")])
    }

    // MARK: - Rules a whole-line trim or a common input would hide

    func testALinkInsideALineIsTrimmed() {
        XCTAssertEqual(line("a [ x ](u) b"), [p("a "), l("x"), p(" b")])
    }

    func testEmphasisContentCannotStartWithWhitespace() {
        XCTAssertEqual(line("a * b*"), [p("a * b*")])
    }

    func testABlankLineEndsAParagraph() {
        XCTAssertEqual(line("*a\n\nb*"), [p("*a b*")])
    }

    func testAHeadingEndsTheOpenParagraph() {
        XCTAssertEqual(line("a\n## H"), [p("a H")])
    }

    func testTheUnderscoreWordTestCountsDigits() {
        XCTAssertEqual(line("1_a_"), [p("1_a_")])
        XCTAssertEqual(line("_a_.5"), [p("_a_.5")])
    }

    func testAHeadingHasAtMostSixHashes() {
        XCTAssertEqual(line("####### x"), [p("####### x")])
    }

    func testAFenceClosesAtALineThatStartsWithThreeBackticks() {
        XCTAssertEqual(line("```\nx\n```sh\ny"), [c("x"), p(" y")])
    }

    func testS36ALineThatOpensAndClosesItsBackticksIsNotAFence() {
        XCTAssertEqual(line("ok\n```make qa``` failed"), [p("ok "), c("make qa"), p(" failed")])
        XCTAssertEqual(line("```make qa``` failed\nsee the log"), [c("make qa"), p(" failed see the log")])
        XCTAssertEqual(line("```sh`\nx"), [p("```sh` x")])
    }

    func testS38ACodeSpanClosesAtARunOfAsManyBackticksAsOpenedIt() {
        XCTAssertEqual(line("a ``b`` c"), [p("a "), c("b"), p(" c")])
        XCTAssertEqual(line("``a`b``"), [c("a`b")])
        XCTAssertEqual(line("`a``b`"), [c("a``b")])
        XCTAssertEqual(line("x ``` y ``` z"), [p("x "), c("y"), p(" z")])
    }

    func testS38ARunOfBackticksWithNoRunOfItsLengthAfterItIsLiteral() {
        XCTAssertEqual(line("``a`"), [p("``a`")])
        XCTAssertEqual(line("`a``"), [p("`a``")])
        XCTAssertEqual(line("``a` `b`"), [p("``a` "), c("b")])
        XCTAssertEqual(line("`` ``"), [p("`` ``")])
        XCTAssertEqual(line("` ` x`"), [p("` "), c("x")])
        XCTAssertEqual(line("`` `` x``"), [p("`` "), c("x")])
    }

    func testS37AFenceOfMoreBackticksStillOpensAndALineInsideAFenceStillClosesIt() {
        XCTAssertEqual(line("````\nx\n````"), [c("x")])
        XCTAssertEqual(line("```\nx\n```y``` z\nw"), [c("x"), p(" w")])
    }

    func testAnOrderedItemNeedsASCIIDigits() {
        XCTAssertEqual(line(". x"), [p(". x")])
        XCTAssertEqual(line("١. x"), [p("١. x")])
    }

    // MARK: - Error scenarios

    func testS24EveryCutOfARealTextIsWellFormed() {
        let seed = "Need **OK** to _run_ `make qa` — see [log](u).\n* a *b*\n12) c\n## H\n```sh\nx  y\n```\n"
        let scalars = Array(String(repeating: seed, count: 10).unicodeScalars.prefix(280))
        for k in 0...scalars.count {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars.prefix(k))
            let input = String(view)
            let text = InlineMarkdown.line(input)
            let oneLine = ChromeText.oneLine(input)
            XCTAssertFalse(text.runs.contains { $0.text.isEmpty }, "k=\(k)")
            XCTAssertFalse(zip(text.runs, text.runs.dropFirst()).contains { $0.mark == .plain && $1.mark == .plain }, "k=\(k)")
            XCTAssertEqual(text.runs.isEmpty, oneLine.isEmpty, "k=\(k)")
            XCTAssertLessThanOrEqual(text.plain.unicodeScalars.count, oneLine.unicodeScalars.count, "k=\(k)")
            XCTAssertEqual(text.plain, ChromeText.oneLine(text.plain), "k=\(k)")
        }
    }
}
