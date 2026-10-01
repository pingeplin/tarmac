import Foundation

/// Host side of the HTML-card console relay (spec 2607.0004): validates the
/// shim's postMessage payloads and owns the per-card ring buffer. The shim is an
/// untrusted page, so anything that is not a well-formed Tarmac payload is
/// silently ignored.
public enum CardConsole {
    public static let bufferCap = 500

    public enum Level: String, Equatable, Sendable {
        case log, info, warn, error
    }

    public struct Entry: Equatable, Sendable {
        public var level: Level
        public var args: [JSONValue]

        public init(level: Level, args: [JSONValue]) {
            self.level = level
            self.args = args
        }
    }

    /// The shim → host message kinds. `cull` and `zoom` are host → shim only and
    /// must never appear here, or a card could forge one at the host.
    public enum Message: Equatable, Sendable {
        case console(Entry)
        case escape
        case ready(meta: String?)
    }

    /// Validates a `WKScriptMessage` body. A `ready` must carry the `meta` key — a
    /// string or null; an absent key is neither — and unknown keys are ignored. A
    /// console payload whose args hold a value JSON cannot carry is rejected whole.
    public static func parse(_ body: Any) -> Message? {
        guard let payload = body as? [String: Any], let kind = payload["tarmac"] as? String else { return nil }
        switch kind {
        case "escape":
            return .escape
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
            return .console(Entry(level: level, args: args))
        default:
            return nil
        }
    }

    /// An order-preserving buffer; beyond `cap` the oldest entries fall off.
    public struct Buffer: Equatable, Sendable {
        public private(set) var entries: [Entry] = []
        public let cap: Int

        public init(cap: Int = CardConsole.bufferCap) {
            self.cap = max(0, cap)
        }

        public mutating func push(_ entry: Entry) {
            entries.append(entry)
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
        }
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
