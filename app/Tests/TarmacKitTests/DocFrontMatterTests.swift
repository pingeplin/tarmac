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

    /// S1
    func test2611_0022S1TheFieldsComeOutAndTheBodyIsTheRest() {
        let split = DocFrontMatter.split("---\ntitle: Hello\nstatus: proposed\n---\n# Body\n")

        XCTAssertEqual(split.fields, [field("title", "Hello"), field("status", "proposed")])
        XCTAssertEqual(split.body, "# Body\n")
    }

    /// S2
    func test2611_0022S2OnePairOfMatchingQuotesIsRemoved() {
        XCTAssertEqual(fields("title: \"A: b\""), [field("title", "A: b")])
        XCTAssertEqual(fields("x: 'y'"), [field("x", "y")])
        XCTAssertEqual(fields("x: \"y'"), [field("x", "\"y'")])
        XCTAssertEqual(fields("x: \""), [field("x", "\"")])
    }

    /// S3
    func test2611_0022S3AnInlineListIsSplitTrimmedAndUnquoted() {
        XCTAssertEqual(fields("tags: [mcp, \"api\", , release-2]"), [field("tags", list: ["mcp", "api", "release-2"])])
    }

    /// S4
    func test2611_0022S4ABlockListAndTheLinesThatFollowAList() {
        XCTAssertEqual(
            fields("tags:\n  - a\n  - \"b\"\nnext: 1"), [field("tags", list: ["a", "b"]), field("next", "1")]
        )
        XCTAssertEqual(fields("empty:\nother: 2"), [field("empty", ""), field("other", "2")])
        XCTAssertEqual(fields("tags: [a]\n  - b\n  c"), [field("tags", list: ["a", "b", "c"])])
        XCTAssertEqual(fields("key:\n  -\nx: 1"), [field("key", list: []), field("x", "1")])
        XCTAssertEqual(fields("tags: \n- a"), [field("tags", list: ["a"])])
    }

    /// S5
    func test2611_0022S5OtherLinesJoinTheFieldAbove() {
        XCTAssertEqual(fields("desc: one\n  two\n# note\nx: 1"), [field("desc", "one\ntwo\n# note"), field("x", "1")])
        XCTAssertEqual(
            fields("metadata:\n  type: project\n  originSessionId: abc"),
            [field("metadata", "type: project\noriginSessionId: abc")]
        )
        XCTAssertEqual(fields("# before\ntitle: x"), [field("title", "x")])
        XCTAssertEqual(fields("title: x\n\n  \t\nnext: y"), [field("title", "x"), field("next", "y")])
        XCTAssertEqual(fields("key:\n  text"), [field("key", "text")])
        XCTAssertEqual(fields("a: 1\na: 2"), [field("a", "1"), field("a", "2")])
        XCTAssertEqual(fields("desc: one\n\ttwo"), [field("desc", "one\ntwo")])
        XCTAssertEqual(fields("k: \"\"\n  more"), [field("k", "more")])
    }

    /// S6
    func test2611_0022S6ABlockWithNoKeyLineOrWithAProseLineIsNotFrontMatter() {
        assertUnchanged("---\n\nSome text\n\n---\nmore")
        assertUnchanged("---\nSome prose here.\nNote: x\n---\nmore")
    }

    /// S7
    func test2611_0022S7ABlockWithNoClosingLineIsNotFrontMatter() {
        assertUnchanged("---\ntitle: x\n# Heading")
    }

    /// S8
    func test2611_0022S8CRLFLinesAndADotsClosingLine() {
        let split = DocFrontMatter.split("---\r\ntitle: x\r\n...\r\nbody")

        XCTAssertEqual(split.fields, [field("title", "x")])
        XCTAssertEqual(split.body, "body")
    }

    /// S9
    func test2611_0022S9AFenceMayEndInSpacesButNotStartWithOne() {
        let split = DocFrontMatter.split("---  \ntitle: x\n---  \nbody")
        XCTAssertEqual(split.fields, [field("title", "x")])
        XCTAssertEqual(split.body, "body")

        assertUnchanged(" ---\ntitle: x\n---\n")
        assertUnchanged("...\ntitle: x\n---\n")
    }

    /// S10 — design 2611.0020 D8's stated cost.
    func test2611_0022S10ANoteBetweenTwoBreaksIsAField() {
        let split = DocFrontMatter.split("---\nNote: text\n---\nbody")

        XCTAssertEqual(split.fields, [field("Note", "text")])
        XCTAssertEqual(split.body, "body")
    }

    /// S11
    func test2611_0022S11TheShapeOfAKey() {
        assertUnchanged("---\nkey:value\n---\n")
        for key in ["my_key-2", "my key", "a.b", "標題", "_k", "2k"] {
            XCTAssertEqual(fields("\(key): v"), [field(key, "v")], key)
        }
        assertUnchanged("---\n\"x\": v\n---\n")
        XCTAssertEqual(fields("key : v"), [field("key", "v")])
    }

    /// S12
    func test2611_0022S12AnEmptyDocAFirstLineAloneAndAClosingLineAtTheEnd() {
        assertUnchanged("")
        assertUnchanged("---")

        let split = DocFrontMatter.split("---\ntitle: x\n---")
        XCTAssertEqual(split.fields, [field("title", "x")])
        XCTAssertEqual(split.body, "")

        let first = DocFrontMatter.split("---\ntitle: x\n---\nmid\n---\nend")
        XCTAssertEqual(first.fields, [field("title", "x")])
        XCTAssertEqual(first.body, "mid\n---\nend")
    }
}
