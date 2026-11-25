import XCTest

@testable import TarmacKit

/// 2611.0022 D1–D3: the front matter a markdown doc opens with, as fields,
/// and the body the card renders.
final class DocFrontMatterTests: XCTestCase {
    private typealias Field = DocFrontMatter.Field

    private func field(_ key: String, _ text: String) -> Field { Field(key: key, value: .text(text)) }

    private func field(_ key: String, list: [String]) -> Field { Field(key: key, value: .list(list)) }

    private func fields(_ block: String) -> [Field] { DocFrontMatter.split("---\n" + block + "\n---\n").fields }

    private func assertUnchanged(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
        let split = DocFrontMatter.split(markdown)
        XCTAssertEqual(split.fields, [], file: file, line: line)
        XCTAssertEqual(split.body, markdown, file: file, line: line)
    }

    /// "Basic front matter gives fields and body"
    func testTheFieldsComeOutAndTheBodyIsTheRest() {
        let split = DocFrontMatter.split("---\ntitle: Hello\nstatus: proposed\n---\n# Body\n")

        XCTAssertEqual(split.fields, [field("title", "Hello"), field("status", "proposed")])
        XCTAssertEqual(split.body, "# Body\n")
    }

    /// "Quoted values lose their quotes"
    func testOnePairOfMatchingQuotesIsRemoved() {
        XCTAssertEqual(fields("title: \"A: b\""), [field("title", "A: b")])
        XCTAssertEqual(fields("x: 'y'"), [field("x", "y")])
        XCTAssertEqual(fields("x: \"y'"), [field("x", "\"y'")])
        XCTAssertEqual(fields("x: \""), [field("x", "\"")])
    }

    /// "Inline list drops empty items"
    func testAnInlineListIsSplitTrimmedAndUnquoted() {
        XCTAssertEqual(fields("tags: [mcp, \"api\", , release-2]"), [field("tags", list: ["mcp", "api", "release-2"])])
    }

    /// "Block lists and empty keys parse"
    func testABlockListAndTheLinesThatFollowAList() {
        XCTAssertEqual(
            fields("tags:\n  - a\n  - \"b\"\nnext: 1"), [field("tags", list: ["a", "b"]), field("next", "1")]
        )
        XCTAssertEqual(fields("empty:\nother: 2"), [field("empty", ""), field("other", "2")])
        XCTAssertEqual(fields("tags: [a]\n  - b\n  c"), [field("tags", list: ["a", "b", "c"])])
        XCTAssertEqual(fields("key:\n  -\nx: 1"), [field("key", list: []), field("x", "1")])
        XCTAssertEqual(fields("tags: \n- a"), [field("tags", list: ["a"])])
        XCTAssertEqual(fields("tags:\n - a\n -"), [field("tags", list: ["a"])])
    }

    /// "Continuation comment and nested lines parse"
    func testOtherLinesJoinTheFieldAbove() {
        XCTAssertEqual(fields("desc: one\n  two\n# note\nx: 1"), [field("desc", "one\ntwo\n# note"), field("x", "1")])
        XCTAssertEqual(
            fields("metadata:\n  type: project\n  originSessionId: abc"),
            [field("metadata", "type: project\noriginSessionId: abc")]
        )
        XCTAssertEqual(fields("# before\ntitle: x"), [field("title", "x")])
        XCTAssertEqual(fields("title: x\n\n  \t\nnext: y"), [field("title", "x"), field("next", "y")])
        XCTAssertEqual(fields("key:\n  text"), [field("key", "text")])
        XCTAssertEqual(fields("desc: one\n- x"), [field("desc", "one\n- x")])
        XCTAssertEqual(fields("a: 1\na: 2"), [field("a", "1"), field("a", "2")])
        XCTAssertEqual(fields("desc: one\n\ttwo"), [field("desc", "one\ntwo")])
        XCTAssertEqual(fields("k: \"\"\n  more"), [field("k", "more")])
    }

    /// "Prose between fences is not front matter"
    func testABlockWithNoKeyLineOrWithAProseLineIsNotFrontMatter() {
        assertUnchanged("---\n\nSome text\n\n---\nmore")
        assertUnchanged("---\nSome prose here.\nNote: x\n---\nmore")
    }

    /// "Missing closing line leaves text unchanged"
    func testABlockWithNoClosingLineIsNotFrontMatter() {
        assertUnchanged("---\ntitle: x\n# Heading")
    }

    /// "CRLF and dot closing line parse"
    func testCRLFLinesAndADotsClosingLine() {
        let split = DocFrontMatter.split("---\r\ntitle: x\r\n...\r\nbody")

        XCTAssertEqual(split.fields, [field("title", "x")])
        XCTAssertEqual(split.body, "body")
    }

    /// "Fence with trailing spaces parses"
    func testAFenceMayEndInSpacesButNotStartWithOne() {
        let split = DocFrontMatter.split("---  \ntitle: x\n---  \nbody")
        XCTAssertEqual(split.fields, [field("title", "x")])
        XCTAssertEqual(split.body, "body")

        assertUnchanged(" ---\ntitle: x\n---\n")
        assertUnchanged("---\t\ntitle: x\n---\n")
        assertUnchanged("...\ntitle: x\n---\n")
    }

    /// "Setext rule is read as front matter" — design 2611.0020 D8's stated cost.
    func testANoteBetweenTwoBreaksIsAField() {
        let split = DocFrontMatter.split("---\nNote: text\n---\nbody")

        XCTAssertEqual(split.fields, [field("Note", "text")])
        XCTAssertEqual(split.body, "body")
    }

    /// "Key shape decides what is a field"
    func testTheShapeOfAKey() {
        assertUnchanged("---\nkey:value\n---\n")
        for key in ["my_key-2", "my key", "a.b", "標題", "_k", "2k"] {
            XCTAssertEqual(fields("\(key): v"), [field(key, "v")], key)
        }
        assertUnchanged("---\n\"x\": v\n---\n")
        XCTAssertEqual(fields("key : v"), [field("key", "v")])
    }

    /// "Empty doc and fence at end of text"
    func testAnEmptyDocAFirstLineAloneAndAClosingLineAtTheEnd() {
        assertUnchanged("")
        assertUnchanged("---")

        let split = DocFrontMatter.split("---\ntitle: x\n---")
        XCTAssertEqual(split.fields, [field("title", "x")])
        XCTAssertEqual(split.body, "")

        let first = DocFrontMatter.split("---\ntitle: x\n---\nmid\n---\nend")
        XCTAssertEqual(first.fields, [field("title", "x")])
        XCTAssertEqual(first.body, "mid\n---\nend")
    }

    /// D19: the fields as the page takes them, `[key, value]`, a list as an array.
    func test2611_0022D19TheFieldsThePageIsGiven() {
        let page = DocFrontMatter.page([field("title", "a\nb"), field("tags", list: ["x", "y"])])
        XCTAssertEqual(page as NSArray, [["title", "a\nb"], ["tags", ["x", "y"]]] as NSArray)
        XCTAssertEqual(DocFrontMatter.page([]) as NSArray, [] as NSArray)
    }
}
