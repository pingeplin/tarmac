import XCTest

@testable import TarmacKit

private func line(_ text: String) -> [InlineRun] { InlineMarkdown.line(text).runs }

/// Spec 2611.0017 "Text without markdown is unchanged": texts with no markdown, which must read as before.
enum S10 {
    static let texts = [
        "May I?", "  May\n\tI  run\r\n rm?  ", "snake_case_name", "2 * 3 * 4", "#412 done",
        "price: $5 (approx)", "a [b] c", "C:\\path\\*", "a\n\n\nb", "__init__.py", "self.__dict__",
    ]
}

/// Spec 2611.0017: a report's text as one line of inline marks.
final class InlineMarkdownTests: XCTestCase {
    // MARK: - Happy path

    /// "Code and bold marks render in a sentence".
    func testInlineMarksBecomeRuns() {
        XCTAssertEqual(
            line("Need OK to run `cargo test -p tarmacd` — it **touches** the dev socket."),
            [p("Need OK to run "), c("cargo test -p tarmacd"), p(" — it "), b("touches"), p(" the dev socket.")]
        )
    }

    /// "Each inline mark gets its own run".
    func testEachMark() {
        XCTAssertEqual(line("*a*"), [i("a")])
        XCTAssertEqual(line("_a_"), [i("a")])
        XCTAssertEqual(line("**a**"), [b("a")])
        XCTAssertEqual(line("__a__"), [b("a")])
        XCTAssertEqual(line("[run 88](https://x.invalid/88)"), [l("run 88")])
    }

    /// "Heading marker is dropped".
    func testAHeadingIsPlainText() {
        XCTAssertEqual(line("## Blocked"), [p("Blocked")])
    }

    /// "List items become bullet runs".
    func testListItemsGetOneBulletAndOrderedItemsKeepTheirMark() {
        XCTAssertEqual(line("- a\n- b"), [dot(), p(" a "), dot(), p(" b")])
        XCTAssertEqual(line("1. a\n2) b"), [dot("1."), p(" a "), dot("2)"), p(" b")])
    }

    /// "Fenced code becomes a code run".
    func testAFenceIsOneCodeRun() {
        XCTAssertEqual(line("## Blocked\n```\nrm -rf target/\n```"), [p("Blocked "), c("rm -rf target/")])
    }

    /// "Paragraphs and blocks join by one space".
    func testParagraphsAndBlocksJoinByOneSpace() {
        let text = InlineMarkdown.line("Done: **x**.\n- a\n\nLeft: run `make qa`.")
        XCTAssertEqual(text.runs, [p("Done: "), b("x"), p(". "), dot(), p(" a Left: run "), c("make qa"), p(".")])
        XCTAssertEqual(text.plain, "Done: x. • a Left: run make qa.")
    }

    // MARK: - Edge cases

    /// "Text without markdown is unchanged".
    func testTextWithNoMarkdownIsOnePlainRunOfItsOneLineForm() {
        for text in S10.texts {
            XCTAssertEqual(line(text), [p(ChromeText.oneLine(text))], text)
        }
    }

    /// "CRLF list lines render as bullets".
    func testCRLFEndsALine() {
        XCTAssertEqual(InlineMarkdown.line("- a\r\n- b").plain, "• a • b")
        XCTAssertEqual(InlineMarkdown.line("- a\r- b").plain, "• a • b")
    }

    /// "Unclosed marks stay as typed".
    func testAnUnclosedMarkIsLiteral() {
        XCTAssertEqual(line("**half"), [p("**half")])
        XCTAssertEqual(line("run `cargo"), [p("run `cargo")])
        XCTAssertEqual(line("```\nrm -rf"), [c("rm -rf")])
    }

    /// "Fence info string and empty fence".
    func testAFenceIgnoresItsInfoStringAndAnEmptyBodyGivesNoRun() {
        XCTAssertEqual(line("```swift\nlet x = 1\n```"), [c("let x = 1")])
        XCTAssertEqual(line("a\n```\n```\nb"), [p("a b")])
        XCTAssertEqual(line("a\n```\n  \n```\nb"), [p("a b")])
        XCTAssertEqual(InlineMarkdown.line("```\n```"), .literal("``` ```"))
        XCTAssertEqual(InlineMarkdown.line("```\n  \n```"), .literal("``` ```"))
    }

    /// "Marks do not nest".
    func testMarksDoNotNest() {
        XCTAssertEqual(line("**see `x`**"), [b("see `x`")])
    }

    /// "Star inside a word is italic".
    func testAStarInsideAWordIsAMark() {
        XCTAssertEqual(line("a*b*c"), [p("a"), i("b"), p("c")])
    }

    /// "Whitespace in code is collapsed".
    func testWhitespaceInCodeIsOneSpaceAndAFenceBodyIsTrimmed() {
        XCTAssertEqual(line("`a   b`"), [c("a b")])
        XCTAssertEqual(line("```\nx\n\n  y\n```"), [c("x y")])
        XCTAssertEqual(line("a\n```\n\n  x\n```\nb"), [p("a "), c("x"), p(" b")])
    }

    /// "Empty link text stays literal".
    func testALinkWithNoTextIsLiteral() {
        XCTAssertEqual(line("[](u)"), [p("[](u)")])
    }

    /// "Backslash is not an escape".
    func testABackslashIsNotAnEscape() {
        XCTAssertEqual(line("\\*a\\*"), [p("\\"), i("a\\")])
    }

    /// "Pill cut lands on a bullet".
    func testAPillCutThatLandsOnABullet() {
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

    /// "Star works as list mark and as italic".
    func testAStarIsAListMarkOnlyWithWhitespaceAfterIt() {
        XCTAssertEqual(line("* a *b*"), [dot(), p(" a "), i("b")])
        XCTAssertEqual(line("*a* b"), [i("a"), p(" b")])
    }

    /// "Other list marks and line joins".
    func testOtherListMarks() {
        XCTAssertEqual(line("+ a"), [dot(), p(" a")])
        XCTAssertEqual(line("  - a"), [dot(), p(" a")])
        XCTAssertEqual(line("- a\nb"), [dot(), p(" a b")])
        XCTAssertEqual(line("a  \n- b"), [p("a "), dot(), p(" b")])
    }

    /// "Mark in a heading still renders".
    func testAMarkInAHeading() {
        XCTAssertEqual(line("## **a** b"), [b("a"), p(" b")])
    }

    /// "Image syntax and marks in link text".
    func testImageSyntaxAndMarksInLinkText() {
        XCTAssertEqual(line("![alt](src)"), [p("!"), l("alt")])
        XCTAssertEqual(line("[**a**](u)"), [l("**a**")])
    }

    /// "Underscore next to punctuation is italic".
    func testAnUnderscoreNextToPunctuationIsAMark() {
        XCTAssertEqual(line("(_a_)"), [p("("), i("a"), p(")")])
    }

    /// "Blank input gives no runs".
    func testBlankInputGivesNoRuns() {
        for text in ["", "  ", "\n", "\t", " "] {
            XCTAssertEqual(InlineMarkdown.line(text).runs, [], text.debugDescription)
            XCTAssertEqual(InlineMarkdown.line(text).plain, "")
        }
        XCTAssertEqual(InlineMarkdown.line("## "), .literal("##"))
    }

    /// "Closing marks pair with the nearest opener".
    func testTheClosingMarkIsTheNextOne() {
        XCTAssertEqual(line("*a *b*"), [p("*a "), i("b")])
        XCTAssertEqual(line("***a***"), [b("*a"), p("*")])
        XCTAssertEqual(line("[a](b (c))"), [l("a"), p(")")])
        XCTAssertEqual(line("[a] (b)"), [p("[a] (b)")])
    }

    /// "Underscore italic needs word edges".
    func testTheUnderscoreWordTest() {
        XCTAssertEqual(line("_a_."), [i("a"), p(".")])
        XCTAssertEqual(line("_snake_case is odd_"), [i("snake_case is odd")])
        XCTAssertEqual(line("__pycache__/"), [b("pycache"), p("/")])
    }

    /// "Spaces inside code span or link are trimmed".
    func testACodeSpanAndALinkAreTrimmed() {
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

    /// "Same-line backticks form a span not fence".
    func testALineThatOpensAndClosesItsBackticksIsNotAFence() {
        XCTAssertEqual(line("ok\n```make qa``` failed"), [p("ok "), c("make qa"), p(" failed")])
        XCTAssertEqual(line("```make qa``` failed\nsee the log"), [c("make qa"), p(" failed see the log")])
        XCTAssertEqual(line("```sh`\nx"), [p("```sh` x")])
    }

    /// "Code spans of more than one backtick".
    func testACodeSpanClosesAtARunOfAsManyBackticksAsOpenedIt() {
        XCTAssertEqual(line("a ``b`` c"), [p("a "), c("b"), p(" c")])
        XCTAssertEqual(line("``a`b``"), [c("a`b")])
        XCTAssertEqual(line("`a``b`"), [c("a``b")])
        XCTAssertEqual(line("x ``` y ``` z"), [p("x "), c("y"), p(" z")])
    }

    /// "Code spans of more than one backtick".
    func testARunOfBackticksWithNoRunOfItsLengthAfterItIsLiteral() {
        XCTAssertEqual(line("``a`"), [p("``a`")])
        XCTAssertEqual(line("`a``"), [p("`a``")])
        XCTAssertEqual(line("``a` `b`"), [p("``a` "), c("b")])
        XCTAssertEqual(line("`` ``"), [p("`` ``")])
        XCTAssertEqual(line("` ` x`"), [p("` "), c("x")])
        XCTAssertEqual(line("`` `` x``"), [p("`` "), c("x")])
    }

    /// "Four backtick fence and early closing line".
    func testAFenceOfMoreBackticksStillOpensAndALineInsideAFenceStillClosesIt() {
        XCTAssertEqual(line("````\nx\n````"), [c("x")])
        XCTAssertEqual(line("```\nx\n```y``` z\nw"), [c("x"), p(" w")])
    }

    func testAnOrderedItemNeedsASCIIDigits() {
        XCTAssertEqual(line(". x"), [p(". x")])
        XCTAssertEqual(line("١. x"), [p("١. x")])
    }

    // MARK: - Error scenarios

    /// "Every cut of a real text keeps invariants".
    func testEveryCutOfARealTextIsWellFormed() {
        let seed = "Need **OK** to _run_ `make qa` — see [log](u).\n* a *b*\n12) c\n## H\n```sh\nx  y\n```\n"
        let scalars = Array(String(repeating: seed, count: 10).unicodeScalars.prefix(280))
        for k in 0...scalars.count {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars.prefix(k))
            let input = String(view)
            let text = InlineMarkdown.line(input)
            let oneLine = ChromeText.oneLine(input)
            XCTAssertFalse(text.runs.contains { $0.text.isEmpty }, "k=\(k)")
            XCTAssertFalse(
                zip(text.runs, text.runs.dropFirst()).contains { $0.mark == .plain && $1.mark == .plain }, "k=\(k)")
            XCTAssertEqual(text.runs.isEmpty, oneLine.isEmpty, "k=\(k)")
            XCTAssertLessThanOrEqual(text.plain.unicodeScalars.count, oneLine.unicodeScalars.count, "k=\(k)")
            XCTAssertEqual(text.plain, ChromeText.oneLine(text.plain), "k=\(k)")
        }
    }
}
