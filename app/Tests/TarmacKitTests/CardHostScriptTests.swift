import JavaScriptCore
import XCTest
@testable import TarmacKit

/// The HTML card host page's script as it ships
/// (`TarmacApp/Resources/Web/card-host.js`), run with a stand-in page: what it
/// carries from the card's document to the app, and what it cuts first. What
/// it posts is read the way the app reads it, through `CardConsole`.
final class CardHostScriptTests: XCTestCase {
    private var context: JSContext!

    private func script() throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: app.appendingPathComponent("Sources/TarmacApp/Resources/Web/card-host.js"), encoding: .utf8
        )
    }

    override func setUpWithError() throws {
        context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("the script threw: \(String(describing: error))") }
        context.evaluateScript("""
        var posted = [];
        var cardWindow = {};
        var listener = null;
        var window = { addEventListener(type, heard) { if (type === "message") listener = heard; } };
        var document = { getElementById() { return { contentWindow: cardWindow, style: {} }; } };
        var webkit = { messageHandlers: { card: { postMessage(message) { posted.push(message); } } } };
        """)
        context.evaluateScript(try script())
    }

    /// What the script posts to the app for the message `data`, a JavaScript
    /// expression, arriving from `source`.
    private func carried(_ data: String, from source: String = "cardWindow") -> [Any] {
        context.evaluateScript("posted = []; listener({ source: \(source), data: \(data) }); posted").toArray() ?? []
    }

    private func entry(_ data: String) throws -> CardConsole.Entry {
        let bodies = carried(data)
        XCTAssertEqual(bodies.count, 1, data)
        guard case .console(let entry)? = CardConsole.parse(try XCTUnwrap(bodies.first)) else {
            throw XCTSkip("not carried as a console entry: \(data)")
        }
        return entry
    }

    /// The line the console shows for the entry `data`.
    private func line(_ data: String) throws -> String {
        var buffer = CardConsole.Buffer()
        buffer.push(try entry(data))
        return CardConsole.formatArgs(buffer.entries[0].args)
    }

    private func x(_ count: Int) -> String { String(repeating: "x", count: count) }

    // MARK: - carrying

    func testOnlyTheCardsOwnDocumentIsHeard() {
        XCTAssertEqual(carried("{ tarmac: 'escape' }", from: "{}").count, 0)
        XCTAssertEqual(carried("{ tarmac: 'escape' }").count, 1)
    }

    func testAShortConsoleEntryIsCarriedWhole() throws {
        XCTAssertEqual(
            try entry("{ tarmac: 'console', level: 'warn', args: ['a', 1, { k: [1, 2] }, null, true] }"),
            CardConsole.Entry(level: .warn, args: ["a", 1, ["k": [1, 2]], .null, true])
        )
    }

    func testTheOtherMessagesAreCarriedAsTheyCame() {
        XCTAssertEqual(carried("{ tarmac: 'escape' }").first.flatMap(CardConsole.parse), .escape)
        XCTAssertEqual(
            carried("{ tarmac: 'ready', meta: 'magnify' }").first.flatMap(CardConsole.parse), .ready(meta: "magnify")
        )
        XCTAssertEqual(carried("{ tarmac: 'ready', meta: null }").first.flatMap(CardConsole.parse), .ready(meta: nil))
    }

    /// 2610.0003 S38: a scroll report is small, and crosses as it came.
    func test2610S38AScrollReportIsCarriedAsItCame() throws {
        let bodies = carried("{ tarmac: 'scrolled', offset: 120, visible: 840, total: 4800 }")
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(
            CardConsole.parse(try XCTUnwrap(bodies.first)),
            .scrolled(try XCTUnwrap(ScrollMetrics(offset: 120, visible: 840, total: 4800)))
        )
    }

    // MARK: - the cut

    func testTheScriptCutsAtTheLineCapTheAppKeeps() throws {
        let regex = try NSRegularExpression(pattern: #"const lineCap = (\d+);"#)
        let text = try script()
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        XCTAssertEqual(Int(text[try XCTUnwrap(Range(match.range(at: 1), in: text))]), CardConsole.lineCap)
    }

    /// Receiving a megabyte string costs the app's main thread ten
    /// milliseconds, and a card can send hundreds: the string is cut in the
    /// page, and the line shown is the one the app would have cut itself.
    func testALongStringIsCutBeforeItCrosses() throws {
        let cut = try entry("{ tarmac: 'console', level: 'log', args: ['x'.repeat(5000), 'tail'] }")
        XCTAssertEqual(cut.args, [.string(x(1000))])
        XCTAssertEqual(cut.dropped, 4005)
        XCTAssertEqual(
            try line("{ tarmac: 'console', level: 'log', args: ['x'.repeat(5000), 'tail'] }"),
            x(1000) + "… (+4005 more)"
        )
    }

    /// Kept characters and the count in the mark always add up to the line the
    /// card logged.
    func testTheMarkCountsAllThatWasCut() throws {
        let cases: [(args: String, shown: String)] = [
            ("['x'.repeat(998), 'yyyy']", x(998) + " y… (+3 more)"),
            ("['x'.repeat(999), 'yy']", x(999) + "… (+3 more)"),
            ("['x'.repeat(1000), 'y']", x(1000) + "… (+2 more)"),
            ("['x'.repeat(1001)]", x(1000) + "… (+1 more)"),
            ("['x'.repeat(1000)]", x(1000)),
            ("['x'.repeat(996), 12345, true]", x(996) + " 123… (+7 more)"),
        ]
        for (args, shown) in cases {
            XCTAssertEqual(try line("{ tarmac: 'console', level: 'log', args: \(args) }"), shown, args)
        }
    }

    func testManyArgsAreCutToOneLine() throws {
        let cut = try entry("{ tarmac: 'console', level: 'log', args: Array(5000).fill('ab') }")
        let kept = CardConsole.formatArgs(cut.args)
        XCTAssertLessThanOrEqual(kept.count, 1000)
        XCTAssertLessThanOrEqual(cut.args.count, 334)
        XCTAssertEqual(kept.count + cut.dropped, 5000 * 3 - 1)
        XCTAssertTrue(kept.hasPrefix("ab ab ab"))
    }

    func testAnArgThatIsNotAStringIsCutAsItsJSONText() throws {
        let cut = try entry("{ tarmac: 'console', level: 'log', args: [{ a: 'y'.repeat(3000) }] }")
        XCTAssertEqual(cut.args, [.string("{\"a\":\"" + String(repeating: "y", count: 994))])
        XCTAssertEqual(cut.dropped, 3008 - 1000)
    }

    /// What is cut is counted as JavaScript counts a string's length, without
    /// walking it: an emoji past the cut counts for two.
    func testTheCutNeverSplitsASurrogatePair() throws {
        let cut = try entry("{ tarmac: 'console', level: 'log', args: ['a'.repeat(999) + '😀😀'] }")
        XCTAssertEqual(cut.args, [.string(String(repeating: "a", count: 999) + "😀")])
        XCTAssertEqual(cut.dropped, 2)
    }

    func testAStringOfPairsShorterThanTheLineIsKeptWhole() throws {
        let cut = try entry("{ tarmac: 'console', level: 'log', args: ['😀'.repeat(600)] }")
        XCTAssertEqual(cut.args, [.string(String(repeating: "😀", count: 600))])
        XCTAssertEqual(cut.dropped, 0)
    }

    /// The count is the page's, not the card's: the card's own `dropped`, and
    /// anything else it adds to the entry, stays behind.
    func testTheCardCannotSayHowMuchWasCut() throws {
        let bodies = carried("{ tarmac: 'console', level: 'log', args: ['a'], dropped: 99999, more: 'x' }")
        let body = try XCTUnwrap(bodies.first as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["tarmac", "level", "args", "dropped"])
        XCTAssertEqual(body["dropped"] as? Int, 0)
    }

    // MARK: - what is not carried

    func testALargeMessageThatIsNoConsoleEntryIsNotCarried() {
        for data in [
            "{ tarmac: 'ready', meta: 'x'.repeat(5000) }", "'x'.repeat(5000)", "{ junk: Array(5000).fill(1) }",
            "{ tarmac: 'console', level: 'x'.repeat(5000), args: [] }", "{ tarmac: 'console', args: 'x'.repeat(5000) }",
        ] {
            XCTAssertEqual(carried(data).count, 0, data)
        }
    }

    func testAMessageThatIsNotAnObjectIsNotCarried() {
        for data in ["'escape'", "42", "null", "undefined", "true"] {
            XCTAssertEqual(carried(data).count, 0, data)
        }
    }

    /// `JSON.stringify` refuses a BigInt and a cycle; so does the bridge.
    func testAMessageThatCannotBeMeasuredIsNotCarried() {
        XCTAssertEqual(carried("{ tarmac: 'console', level: 'log', args: [1n] }").count, 0)
        XCTAssertEqual(carried("(function () { const a = { tarmac: 'ready' }; a.meta = a; return a; })()").count, 0)
    }

    /// What an uncut arg takes of the line is its length in UTF-16 units.
    func testAnArgOfPairsThatFillsTheLineLeavesNoRoomForTheNext() throws {
        let bodies = carried("{ tarmac: 'console', level: 'log', args: ['😀'.repeat(500), 'tail'] }")
        guard case .console(let entry)? = CardConsole.parse(try XCTUnwrap(bodies.first)) else {
            return XCTFail("not an entry")
        }
        XCTAssertEqual(entry.args, [.string(String(repeating: "😀", count: 500))])
        XCTAssertEqual(entry.dropped, 5)
    }

    func testAnEntryWithAnUndefinedArgIsStillCarried() {
        XCTAssertEqual(carried("{ tarmac: 'console', level: 'log', args: [undefined, 'a'] }").count, 1)
    }

    /// `{"tarmac":"ready","meta":""}` is 28 characters.
    func testAMessageOfExactlyAThousandCharactersIsCarriedAndOneMoreIsNot() {
        XCTAssertEqual(carried("{ tarmac: 'ready', meta: 'x'.repeat(972) }").count, 1)
        XCTAssertEqual(carried("{ tarmac: 'ready', meta: 'x'.repeat(973) }").count, 0)
    }
}
