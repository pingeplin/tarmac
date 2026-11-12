import Darwin

/// The lines of the app's sample log (spec 2611.0004): one JSON object each,
/// shaped after the OpenTelemetry log data model — a time, a severity, an event
/// name, attributes and a resource. Every memory value is a footprint in bytes
/// (`ProcessFootprint`), never a resident size, so no key borrows
/// `process.memory.usage`. Keys are sorted (`JSONValue.jsonString`), so the
/// text of a line is stable.
public enum SampleLine {
    public static let serviceName = "tarmac-app"

    /// Who writes the line: this process and the app's version, if it names one.
    public struct Resource: Equatable, Sendable {
        public let pid: Int32
        public let version: String?

        public init(pid: Int32, version: String?) {
            self.pid = pid
            self.version = version
        }
    }

    /// A card's web view whose content process is known: `footprint` is nil
    /// when that process could not be read.
    public struct WebContent: Equatable, Sendable {
        public let pid: Int32
        public let path: String
        public let footprint: UInt64?

        public init(pid: Int32, path: String, footprint: UInt64?) {
            self.pid = pid
            self.path = path
            self.footprint = footprint
        }
    }

    /// The largest count of pending events one HTML card reached since the
    /// sample before.
    public struct Pending: Equatable, Sendable {
        public let path: String
        public let count: Int

        public init(path: String, count: Int) {
            self.path = path
            self.count = count
        }
    }

    public struct Sample: Equatable, Sendable {
        public var appFootprint: UInt64?
        public var daemonPid: Int32?
        public var daemonFootprint: UInt64?
        public var boardsCount: Int
        public var boardsLoaded: Int
        public var cardsHTML: Int
        public var cardsMarkdown: Int
        public var cardsTerminal: Int
        public var pending: [Pending]
        public var webContent: [WebContent]

        public init(
            appFootprint: UInt64?, daemonPid: Int32?, daemonFootprint: UInt64?,
            boardsCount: Int, boardsLoaded: Int, cardsHTML: Int, cardsMarkdown: Int, cardsTerminal: Int,
            pending: [Pending], webContent: [WebContent]
        ) {
            self.appFootprint = appFootprint
            self.daemonPid = daemonPid
            self.daemonFootprint = daemonFootprint
            self.boardsCount = boardsCount
            self.boardsLoaded = boardsLoaded
            self.cardsHTML = cardsHTML
            self.cardsMarkdown = cardsMarkdown
            self.cardsTerminal = cardsTerminal
            self.pending = pending
            self.webContent = webContent
        }

        /// The sample with its footprints read: the app's, the daemon's and
        /// each web content process's. The reads are not for the main actor.
        public func reading(appPid: Int32, _ footprint: (Int32) -> UInt64?) -> Sample {
            var read = self
            read.appFootprint = footprint(appPid)
            read.daemonFootprint = daemonPid.flatMap(footprint)
            read.webContent = webContent.map { WebContent(pid: $0.pid, path: $0.path, footprint: footprint($0.pid)) }
            return read
        }
    }

    public static func sample(_ sample: Sample, resource: Resource, atMs: Int64) -> String {
        var attrs: [String: JSONValue] = [
            "tarmac.boards.count": number(sample.boardsCount),
            "tarmac.boards.loaded": number(sample.boardsLoaded),
            "tarmac.cards.html": number(sample.cardsHTML),
            "tarmac.cards.markdown": number(sample.cardsMarkdown),
            "tarmac.cards.terminal": number(sample.cardsTerminal),
        ]
        if let bytes = sample.appFootprint { attrs["tarmac.app.memory.footprint"] = number(bytes) }
        if let pid = sample.daemonPid, let bytes = sample.daemonFootprint {
            attrs["tarmac.daemon.pid"] = number(pid)
            attrs["tarmac.daemon.memory.footprint"] = number(bytes)
        }
        let pending = largest(sample.pending)
        attrs["tarmac.card.pending_events.max"] = number(pending?.count ?? 0)
        if let pending { attrs["tarmac.card.pending_events.path"] = .string(pending.path) }
        let processes = distinctReadable(sample.webContent)
        if let top = processes.max(by: { $0.bytes < $1.bytes }) {
            attrs["tarmac.webcontent.processes"] = number(processes.count)
            attrs["tarmac.webcontent.memory.footprint"] = number(processes.reduce(0) { $0 + $1.bytes })
            attrs["tarmac.webcontent.largest.memory.footprint"] = number(top.bytes)
            attrs["tarmac.webcontent.largest.path"] = .string(top.path)
        }
        return line(event: "tarmac.sample", severity: "INFO", attrs: attrs, resource: resource, atMs: atMs)
    }

    /// The pending events of the card at `path` went over `limit`.
    public static func overLimit(path: String, count: Int, limit: Int, resource: Resource, atMs: Int64) -> String {
        line(
            event: "tarmac.card.pending_events.over_limit", severity: "WARN",
            attrs: [
                "tarmac.card.pending_events.count": number(count),
                "tarmac.card.pending_events.limit": number(limit),
                "tarmac.card.pending_events.path": .string(path),
            ],
            resource: resource, atMs: atMs
        )
    }

    /// The card with the largest count, nil when no count is over 0. Ties go
    /// to the first, as `max(by:)` keeps the first of equals.
    private static func largest(_ pending: [Pending]) -> Pending? {
        pending.max { $0.count < $1.count }.flatMap { $0.count > 0 ? $0 : nil }
    }

    /// One entry for each readable pid, named by its first card in the input:
    /// cards that share a process count it once.
    private static func distinctReadable(_ entries: [WebContent]) -> [(path: String, bytes: UInt64)] {
        var seen: Set<Int32> = []
        var processes: [(path: String, bytes: UInt64)] = []
        for entry in entries {
            guard let bytes = entry.footprint, seen.insert(entry.pid).inserted else { continue }
            processes.append((entry.path, bytes))
        }
        return processes
    }

    private static func line(
        event: String, severity: String, attrs: [String: JSONValue], resource: Resource, atMs: Int64
    ) -> String {
        var service: [String: JSONValue] = [
            "process.pid": number(resource.pid),
            "service.name": .string(serviceName),
        ]
        if let version = resource.version { service["service.version"] = .string(version) }
        let object: JSONValue = .object([
            "attrs": .object(attrs),
            "event": .string(event),
            "resource": .object(service),
            "severity": .string(severity),
            "ts": .string(timestamp(ms: atMs)),
        ])
        return object.jsonString
    }

    private static func number<Value: BinaryInteger>(_ value: Value) -> JSONValue {
        .number(Double(value))
    }

    /// RFC 3339 in UTC with milliseconds and `Z`, from epoch milliseconds.
    private static func timestamp(ms: Int64) -> String {
        let (seconds, fraction) = ms.quotientAndRemainder(dividingBy: 1_000)
        var whole = time_t(fraction < 0 ? seconds - 1 : seconds)
        var parts = tm()
        gmtime_r(&whole, &parts)
        let pad = { (value: Int32, width: Int) in
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let date = "\(pad(parts.tm_year + 1900, 4))-\(pad(parts.tm_mon + 1, 2))-\(pad(parts.tm_mday, 2))"
        let time = "\(pad(parts.tm_hour, 2)):\(pad(parts.tm_min, 2)):\(pad(parts.tm_sec, 2))"
        return "\(date)T\(time).\(pad(Int32((fraction + 1_000) % 1_000), 3))Z"
    }
}
