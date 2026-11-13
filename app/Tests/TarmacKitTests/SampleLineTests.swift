import XCTest
import TarmacKit

/// The lines of the app's sample log, `tarmac-app.jsonl` (spec 2611.0004).
final class SampleLineTests: XCTestCase {
    private typealias Sample = SampleLine.Sample
    private typealias WebContent = SampleLine.WebContent
    private typealias Pending = SampleLine.Pending

    /// 2026-11-12T10:15:00.000Z.
    private let atMs: Int64 = 1_794_478_500_000
    private let resource = SampleLine.Resource(pid: 9156, version: "0.20.1")

    /// The spec's example sample.
    private var full: Sample {
        Sample(
            appFootprint: 149_063_264,
            daemonPid: 9160,
            daemonFootprint: 6_504_928,
            boardsCount: 2,
            boardsLoaded: 1,
            cardsHTML: 3,
            cardsMarkdown: 2,
            cardsTerminal: 1,
            pending: [Pending(path: "/a/dash.html", count: 6, timesOver: 0)],
            webContent: [
                WebContent(pid: 9201, path: "/a/dash.html", footprint: 120_390_544),
                WebContent(pid: 9202, path: "/a/b.md", footprint: 100_000_000),
                WebContent(pid: 9203, path: "/a/c.md", footprint: 90_000_000),
                WebContent(pid: 9204, path: "/a/d.html", footprint: 52_486_256),
                WebContent(pid: 9205, path: "/a/e.html", footprint: 50_000_000),
            ]
        )
    }

    private func object(_ line: String) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func attrs(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(object(line)["attrs"] as? [String: Any])
    }

    private func attrs(of sample: Sample) throws -> [String: Any] {
        try attrs(SampleLine.sample(sample, resource: resource, atMs: atMs))
    }

    func test2611_0004S3ASampleWithEveryValueIsExactlyTheExpectedText() throws {
        let line = SampleLine.sample(full, resource: resource, atMs: atMs)
        XCTAssertEqual(line, #"{"attrs":{"tarmac.app.memory.footprint":149063264,"tarmac.boards.count":2,"tarmac.boards.loaded":1,"tarmac.card.pending_events.max":6,"tarmac.card.pending_events.over_limit.times":0,"tarmac.card.pending_events.path":"/a/dash.html","tarmac.cards.html":3,"tarmac.cards.markdown":2,"tarmac.cards.terminal":1,"tarmac.daemon.memory.footprint":6504928,"tarmac.daemon.pid":9160,"tarmac.webcontent.largest.memory.footprint":120390544,"tarmac.webcontent.largest.path":"/a/dash.html","tarmac.webcontent.memory.footprint":412876800,"tarmac.webcontent.processes.count":5},"event":"tarmac.sample","resource":{"process.pid":9156,"service.name":"tarmac-app","service.version":"0.20.1"},"severity":"INFO","ts":"2026-11-12T10:15:00.000Z"}"#)
        XCTAssertNoThrow(try object(line))
    }

    func test2611_0004S4NoDaemonPidOrNoDaemonFootprintLeavesOutBothDaemonKeys() throws {
        var noPid = full
        noPid.daemonPid = nil
        var noFootprint = full
        noFootprint.daemonFootprint = nil
        for sample in [noPid, noFootprint] {
            let attrs = try attrs(of: sample)
            XCTAssertNil(attrs["tarmac.daemon.pid"])
            XCTAssertNil(attrs["tarmac.daemon.memory.footprint"])
            XCTAssertNotNil(attrs["tarmac.app.memory.footprint"])
        }
    }

    func testTheAppFootprintIsLeftOutWhenItCannotBeRead() throws {
        var sample = full
        sample.appFootprint = nil
        let attrs = try attrs(of: sample)
        XCTAssertNil(attrs["tarmac.app.memory.footprint"])
        XCTAssertNotNil(attrs["tarmac.daemon.pid"])
    }

    private let webKeys = [
        "tarmac.webcontent.processes.count", "tarmac.webcontent.memory.footprint",
        "tarmac.webcontent.largest.memory.footprint", "tarmac.webcontent.largest.path",
    ]

    /// No view known, or none whose process could be read.
    func test2611_0004S5NoWebContentProcessLeavesOutTheFourWebContentKeys() throws {
        var none = full
        none.webContent = []
        var unreadable = full
        unreadable.webContent = [WebContent(pid: 9201, path: "/a/dash.html", footprint: nil)]
        for sample in [none, unreadable] {
            let attrs = try attrs(of: sample)
            for key in webKeys { XCTAssertNil(attrs[key], key) }
            XCTAssertNotNil(attrs["tarmac.cards.html"])
        }
    }

    /// Two cards in one process: the process counts once, and its first card
    /// names it. The largest is neither the last entry nor the last process.
    func test2611_0004S6WebContentCountsDistinctPidsOnceAndNamesTheLargest() throws {
        var sample = full
        sample.webContent = [
            WebContent(pid: 2, path: "/a/thirty.html", footprint: 30),
            WebContent(pid: 1, path: "/a/ten.html", footprint: 10),
            WebContent(pid: 2, path: "/a/twenty.md", footprint: 20),
        ]
        let attrs = try attrs(of: sample)
        XCTAssertEqual(attrs["tarmac.webcontent.processes.count"] as? Int, 2)
        XCTAssertEqual(attrs["tarmac.webcontent.memory.footprint"] as? Int, 40)
        XCTAssertEqual(attrs["tarmac.webcontent.largest.memory.footprint"] as? Int, 30)
        XCTAssertEqual(attrs["tarmac.webcontent.largest.path"] as? String, "/a/thirty.html")
    }

    /// An entry whose process could not be read is left out of the count, the
    /// sum and the largest.
    func testAnUnreadableEntryIsNotCounted() throws {
        var sample = full
        sample.webContent = [
            WebContent(pid: 1, path: "/a/gone.html", footprint: nil),
            WebContent(pid: 2, path: "/a/b.md", footprint: 5),
        ]
        let attrs = try attrs(of: sample)
        XCTAssertEqual(attrs["tarmac.webcontent.processes.count"] as? Int, 1)
        XCTAssertEqual(attrs["tarmac.webcontent.memory.footprint"] as? Int, 5)
        XCTAssertEqual(attrs["tarmac.webcontent.largest.path"] as? String, "/a/b.md")
    }

    func test2611_0004S7aTheTimesOverTheLimitAreSummedOverTheCardsAnd0IsWritten() throws {
        for pending in [[], [Pending(path: "/a/dash.html", count: 6, timesOver: 0)]] {
            var sample = full
            sample.pending = pending
            XCTAssertEqual(try attrs(of: sample)["tarmac.card.pending_events.over_limit.times"] as? Int, 0)
        }
        var sample = full
        sample.pending = [
            Pending(path: "/a/two.html", count: 1_001, timesOver: 2),
            Pending(path: "/a/dash.html", count: 1_500, timesOver: 3),
        ]
        XCTAssertEqual(try attrs(of: sample)["tarmac.card.pending_events.over_limit.times"] as? Int, 5)
    }

    func test2611_0004S7APendingMaxOf0HasNoPathAndAMaxOf6NamesItsCard() throws {
        for pending in [[], [Pending(path: "/a/dash.html", count: 0, timesOver: 0)]] {
            var sample = full
            sample.pending = pending
            let attrs = try attrs(of: sample)
            XCTAssertEqual(attrs["tarmac.card.pending_events.max"] as? Int, 0)
            XCTAssertNil(attrs["tarmac.card.pending_events.path"])
        }
        var sample = full
        sample.pending = [
            Pending(path: "/a/two.html", count: 2, timesOver: 0),
            Pending(path: "/a/dash.html", count: 6, timesOver: 0),
            Pending(path: "/a/five.html", count: 5, timesOver: 0),
        ]
        let attrs = try attrs(of: sample)
        XCTAssertEqual(attrs["tarmac.card.pending_events.max"] as? Int, 6)
        XCTAssertEqual(attrs["tarmac.card.pending_events.path"] as? String, "/a/dash.html")
    }

    func test2611_0004S8NoAppVersionLeavesOutServiceVersion() throws {
        let line = SampleLine.sample(full, resource: SampleLine.Resource(pid: 42, version: nil), atMs: atMs)
        let resource = try XCTUnwrap(object(line)["resource"] as? [String: Any])
        XCTAssertNil(resource["service.version"])
        XCTAssertEqual(resource["service.name"] as? String, "tarmac-app")
        XCTAssertEqual(resource["process.pid"] as? Int, 42)
    }

    /// 07:05:09.007 in Taipei is 23:05:09.007 of the day before in UTC. The
    /// process runs in Taipei for the test, so a line in local time cannot
    /// pass on a machine whose zone is UTC.
    func test2611_0004S9TheTimeIsUTCWithThreeDecimalsAndZ() throws {
        let saved = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "Asia/Taipei", 1)
        tzset()
        defer {
            if let saved { setenv("TZ", saved, 1) } else { unsetenv("TZ") }
            tzset()
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 12, hour: 7, minute: 5, second: 9, nanosecond: 7_000_000
        )))
        let ms = Int64((date.timeIntervalSince1970 * 1_000).rounded())
        let line = SampleLine.sample(full, resource: resource, atMs: ms)
        XCTAssertEqual(try object(line)["ts"] as? String, "2026-11-11T23:05:09.007Z")
    }

    func test2611_0004S10APathWithAQuoteABackslashAndANonASCIILetterComesBackTheSame() throws {
        let path = #"/a/"q"\b/é.html"#
        var sample = full
        sample.pending = [Pending(path: path, count: 1, timesOver: 0)]
        sample.webContent = [WebContent(pid: 1, path: path, footprint: 1)]
        let attrs = try attrs(of: sample)
        XCTAssertEqual(attrs["tarmac.card.pending_events.path"] as? String, path)
        XCTAssertEqual(attrs["tarmac.webcontent.largest.path"] as? String, path)
    }

    func test2611_0004S11TheOverLimitLineIsExactlyTheExpectedText() throws {
        let line = SampleLine.overLimit(path: "/a/dash.html", count: 1001, limit: 1000, resource: resource, atMs: atMs)
        XCTAssertEqual(line, #"{"attrs":{"tarmac.card.pending_events.held":1001,"tarmac.card.pending_events.limit":1000,"tarmac.card.pending_events.path":"/a/dash.html"},"event":"tarmac.card.pending_events.over_limit","resource":{"process.pid":9156,"service.name":"tarmac-app","service.version":"0.20.1"},"severity":"WARN","ts":"2026-11-12T10:15:00.000Z"}"#)
        XCTAssertNoThrow(try object(line))
    }

    func testReadingFillsTheAppTheDaemonAndEachWebContentFootprint() {
        var unread = full
        unread.appFootprint = nil
        unread.daemonFootprint = nil
        unread.webContent = [
            WebContent(pid: 9201, path: "/a/dash.html", footprint: nil),
            WebContent(pid: 9202, path: "/a/gone.md", footprint: nil),
        ]
        let footprints: [Int32: UInt64] = [9156: 149_063_264, 9160: 6_504_928, 9201: 120_390_544]

        let read = unread.reading(appPid: 9156) { footprints[$0] }

        var expected = full
        expected.webContent = [
            WebContent(pid: 9201, path: "/a/dash.html", footprint: 120_390_544),
            WebContent(pid: 9202, path: "/a/gone.md", footprint: nil),
        ]
        XCTAssertEqual(read, expected)
    }

    func testReadingWithNoDaemonPidAsksForNoDaemonFootprint() {
        var unread = full
        unread.daemonPid = nil
        unread.daemonFootprint = nil
        unread.webContent = []
        var asked: [Int32] = []

        let read = unread.reading(appPid: 9156) { asked.append($0); return 1 }

        XCTAssertEqual(asked, [9156])
        XCTAssertNil(read.daemonFootprint)
    }
}
