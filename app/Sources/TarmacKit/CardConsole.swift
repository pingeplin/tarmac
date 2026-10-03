import Foundation

/// Host side of the HTML-card console relay (spec 2607.0004): validates the
/// shim's postMessage payloads and owns the per-card ring buffer. The shim is an
/// untrusted page, so anything that is not a well-formed Tarmac payload is
/// silently ignored.
public enum CardConsole {
    public static let bufferCap = 500
    /// The most characters of one entry's line that are kept. A card is not
    /// trusted with how much it logs: one entry may be megabytes.
    public static let lineCap = 1000
    /// The least time between two updates of what the card shows of its
    /// console, however fast the card logs.
    public static let refreshInterval: Double = 0.1

    public enum Level: String, Equatable, Sendable {
        case log, info, warn, error
    }

    public struct Entry: Equatable, Sendable {
        public var level: Level
        public var args: [JSONValue]
        /// How many characters the host page cut from the args before they
        /// crossed into the app, counted as the page counts a string's
        /// length: in UTF-16 units.
        public var dropped: Int

        public init(level: Level, args: [JSONValue], dropped: Int = 0) {
            self.level = level
            self.args = args
            self.dropped = dropped
        }
    }

    /// The shim → host message kinds. `cull` and `zoom` are host → shim only and
    /// must never appear here, or a card could forge one at the host.
    public enum Message: Equatable, Sendable {
        case console(Entry)
        case escape
        case ready(meta: String?)
        /// Where the document's root is scrolled to.
        case scrolled(ScrollMetrics)
    }

    /// Validates a `WKScriptMessage` body. A `ready` must carry the `meta` key — a
    /// string or null; an absent key is neither — and unknown keys are ignored. A
    /// console payload whose args hold a value JSON cannot carry is rejected whole.
    /// Its `dropped` is the host page's count of what it cut, never the card's:
    /// the page writes the key itself.
    public static func parse(_ body: Any) -> Message? {
        guard let payload = body as? [String: Any], let kind = payload["tarmac"] as? String else { return nil }
        switch kind {
        case "escape":
            return .escape
        case "scrolled":
            return ScrollMetrics(report: payload).map(Message.scrolled)
        case "ready":
            guard let meta = payload["meta"] else { return nil }
            if meta is NSNull { return .ready(meta: nil) }
            guard let text = meta as? String else { return nil }
            return .ready(meta: text)
        case "console":
            guard let name = payload["level"] as? String, let level = Level(rawValue: name),
                  let rawArgs = payload["args"] as? [Any]
            else { return nil }
            var args: [JSONValue] = []
            for raw in rawArgs {
                guard let arg = JSONValue(foundation: raw) else { return nil }
                args.append(arg)
            }
            let dropped = (payload["dropped"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) } ?? 0
            return .console(Entry(level: level, args: args, dropped: max(0, dropped)))
        default:
            return nil
        }
    }

    /// An order-preserving buffer; beyond `cap` the oldest entries fall off,
    /// and an entry is kept no longer than `lineCap`.
    public struct Buffer: Equatable, Sendable {
        public private(set) var entries: [Entry] = []
        public let cap: Int

        public init(cap: Int = CardConsole.bufferCap) {
            self.cap = max(0, cap)
        }

        public mutating func push(_ entry: Entry) {
            entries.append(CardConsole.capped(entry))
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
        }
    }

    /// `entry`, or when its line runs past `lineCap` or the host page already
    /// cut it, the head of that line as its one arg, ending in how much was
    /// cut in all. The mark names no unit: the page counts its cut in UTF-16
    /// units, which for an emoji is twice the characters.
    static func capped(_ entry: Entry) -> Entry {
        let line = formatArgs(entry.args)
        let head = line.prefix(lineCap)
        let cut = line.distance(from: head.endIndex, to: line.endIndex) + entry.dropped
        guard cut > 0 else { return entry }
        return Entry(level: entry.level, args: [.string("\(head)… (+\(cut) more)")])
    }

    /// One display line for an entry's args, space-joined, objects and arrays as JSON.
    public static func formatArgs(_ args: [JSONValue]) -> String {
        args.map(\.displayString).joined(separator: " ")
    }

    /// The header badge of a card whose console holds `count` entries, or nil
    /// while it holds none.
    public static func badgeLabel(count: Int) -> String? {
        count > 0 ? "⌥ \(count)" : nil
    }
}
