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
        var heardOfTheFrame = {};
        var card = {
          contentWindow: cardWindow,
          style: {},
          addEventListener(type, heard) { heardOfTheFrame[type] = heard; },
        };
        var document = { getElementById() { return card; } };
        var askedFrames = [];
        function requestAnimationFrame(drawn) { askedFrames.push(drawn); }
        function drawFrame() { for (const drawn of askedFrames.splice(0)) drawn(); }
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

    // MARK: - the app is told when the document is on screen (#213)

    private func load(_ source: String = "tarmac-card://doc/a.html?v=1", number: Int = 1) {
        context.evaluateScript("window.tarmacCard.load('\(source)', \(number))")
    }

    private func hear(_ data: String, from source: String = "cardWindow") {
        context.evaluateScript("listener({ source: \(source), data: \(data) })")
    }

    /// The frame's own `load` event.
    private func frameLoaded() {
        context.evaluateScript("heardOfTheFrame.load && heardOfTheFrame.load({})")
    }

    /// Lets the page draw `count` frames, and gives what it has posted to the
    /// app since the page was made.
    @discardableResult
    private func frames(_ count: Int) -> [NSDictionary] {
        context.evaluateScript("for (let i = 0; i < \(count); i++) drawFrame(); posted").toArray() as? [NSDictionary] ?? []
    }

    private let shown = shown(1)

    private static func shown(_ load: Int) -> NSDictionary { ["tarmac": "shown", "load": load] }

    /// The app keeps the web view out of sight until this. Two frames: the
    /// first is drawn with the document in it, and the word posted in the
    /// second reaches the app after that drawing has.
    func testTheAppIsToldTwoFramesAfterTheDocumentSaysItHasStarted() {
        load()
        hear("{ tarmac: 'started' }")
        XCTAssertEqual(frames(1), [])
        XCTAssertEqual(frames(1), [shown])
        XCTAssertEqual(frames(3), [shown])
    }

    func testOnlyTheFramesOwnDocumentStartsIt() {
        load()
        hear("{ tarmac: 'started' }", from: "{}")
        hear("{ tarmac: 'started' }", from: "window")
        XCTAssertEqual(frames(3), [])
    }

    /// What is served for a file that cannot be read carries no shim, and
    /// says nothing: no card stays out of sight.
    func testAFrameThatLoadedIsOnScreenThoughItsDocumentSaidNothing() {
        load()
        frameLoaded()
        XCTAssertEqual(frames(1), [])
        XCTAssertEqual(frames(1), [shown])
    }

    func testTheAppIsToldOnceForASource() {
        load()
        frameLoaded()
        hear("{ tarmac: 'started' }")
        frames(2)
        hear("{ tarmac: 'started' }")
        frameLoaded()
        XCTAssertEqual(frames(3), [shown])
    }

    func testNothingIsToldBeforeTheFrameIsGivenASource() {
        frameLoaded()
        hear("{ tarmac: 'started' }")
        XCTAssertEqual(frames(3), [])
    }

    /// A file that changed is a new source. The document it replaces is still
    /// in the frame, and what it posts is not the new one's start.
    func testANewSourceIsToldOfAgainWhenItsOwnDocumentStarts() {
        load("tarmac-card://doc/a.html?v=1")
        hear("{ tarmac: 'started' }")
        frames(2)

        load("tarmac-card://doc/a.html?v=2", number: 2)
        hear("{ tarmac: 'ready', meta: null }")
        hear("{ tarmac: 'scrolled', offset: 0, visible: 10, total: 20 }")
        XCTAssertEqual(frames(3).filter { $0["tarmac"] as? String == "shown" }, [shown])

        hear("{ tarmac: 'started' }")
        XCTAssertEqual(frames(2).filter { $0["tarmac"] as? String == "shown" }, [shown, Self.shown(2)])
    }

    /// The app has covered the web view again for the new source: a word for
    /// the one it replaced would uncover a frame with no document in it.
    func testASourceReplacedBeforeItWasOnScreenIsNotToldOf() {
        load("tarmac-card://doc/a.html?v=1")
        hear("{ tarmac: 'started' }")
        frames(1)

        load("tarmac-card://doc/a.html?v=2", number: 2)
        XCTAssertEqual(frames(3), [])

        hear("{ tarmac: 'started' }")
        XCTAssertEqual(frames(2), [Self.shown(2)])
    }

    /// The app can have asked for a newer source than this page knows of, so
    /// the word carries the app's own number for the load and the app decides.
    func testTheWordNamesTheLoadWithTheAppsNumber() throws {
        load(number: 7)
        hear("{ tarmac: 'started' }")
        XCTAssertEqual(CardConsole.parse(try XCTUnwrap(frames(2).last)), .shown(load: 7))
    }

    /// The document a source replaced is still in the frame for a moment, and
    /// its shim can say `started` after the frame was given the new source.
    func testTheStartOfTheDocumentThatWasReplacedIsNotTheNewOnes() {
        load("tarmac-card://doc/a.html?v=1")
        load("tarmac-card://doc/a.html?v=2", number: 2)
        hear("{ tarmac: 'started', source: 'tarmac-card://doc/a.html?v=1' }")
        XCTAssertEqual(frames(3), [])

        hear("{ tarmac: 'started', source: 'tarmac-card://doc/a.html?v=2' }")
        XCTAssertEqual(frames(2), [Self.shown(2)])
    }

    /// Only the source that was replaced is refused: a start that names
    /// another address, or none, still counts, so no card stays out of sight.
    func testAStartThatNamesAnAddressThePageDoesNotKnowStillCounts() {
        load("tarmac-card://doc/a.html?v=1")
        load("tarmac-card://doc/a.html?v=2", number: 2)
        hear("{ tarmac: 'started', source: 'tarmac-card://doc/A.HTML?v=2' }")
        XCTAssertEqual(frames(2), [Self.shown(2)])
    }

    /// The start is for the host page alone, and that the document is on
    /// screen is the host page's to say: neither crosses from the card.
    func testACardsStartIsNotCarriedAndItCannotSayItIsOnScreen() {
        XCTAssertEqual(carried("{ tarmac: 'started' }").count, 0)
        XCTAssertEqual(carried("{ tarmac: 'started', more: 'x' }").count, 0)
        XCTAssertEqual(carried("{ tarmac: 'shown' }").count, 0)
        load()
        hear("{ tarmac: 'shown' }")
        XCTAssertEqual(frames(3), [])
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
