import Foundation

/// The in-app QA driver's wire types (spec 2609.0015, issue #166) — the Swift
/// twin of `tarmac_protocol::dev`. Deliberately NOT `Message` cases: the driver
/// has its own socket (`ChannelPaths.devSocketPath`), a debug-build side channel
/// the APP serves, and anything added to the daemon protocol is permanent under
/// its additive-only rule.
///
/// The framing is the daemon socket's (`Framing`), one request per connection:
/// read a `DevRequest` frame, write a `DevReply` frame, close. This file is the
/// codec only — what a verb means, and the bounded waits around answering it,
/// belong to the app.
public enum DevRequest: Equatable, Sendable {
    case snapshot(until: String?, timeoutMs: Int?)
    case zoom(z: Double)
    /// `card: nil` is the board background, which is what blurs a focused
    /// terminal. Card ids are term ids or absolute paths, never the literal
    /// "board", so absence carries the meaning with no sentinel.
    case focus(card: String?)
    case resize(card: String, w: Double, h: Double)
    case type(card: String, text: String)
    case key(card: String, combo: String)
    /// A native ⌘ chord posted in-process (spec 2609.0018, #183). The app parses
    /// `combo`; the CLI has already range-checked the flags against the maxima
    /// below.
    case press(combo: String, holdMs: Int?, ageMs: Int?, busyMs: Int?)
    /// A verb this build does not know. A value rather than a decode error, so
    /// the app can answer "unsupported" instead of dropping the frame.
    case unknown(type: String)

    /// `press --hold` is `1...holdMsMax`, `--age` is `0...ageMsMax`, `--busy` is
    /// `1...busyMsMax`. `busyMsMax` sits below the ⌘Q guard's 2000 ms freshness
    /// bound: past it a frozen page's ⌘Q really quits.
    public static let holdMsMax = 10_000
    public static let ageMsMax = 60_000
    public static let busyMsMax = 1_800

    /// The caller's own budget, where the verb has one: `snapshot` carries its
    /// `--timeout`, `press` its `--busy` (the page answers only once the freeze
    /// ends). Both ends of the socket size their wait from it — the app adds
    /// 2000 ms of slack, the CLI 3000 ms — so the innermost deadline always
    /// fires first.
    public var timeoutMs: Int? {
        switch self {
        case .snapshot(_, let timeoutMs): return timeoutMs
        case .press(_, _, _, let busyMs): return busyMs
        default: return nil
        }
    }
}

/// `body` is an opaque string the CLI prints verbatim and never parses: stdout
/// when `ok`, stderr when not.
public struct DevReply: Equatable, Sendable {
    public var ok: Bool
    public var body: String

    public init(ok: Bool, body: String) {
        self.ok = ok
        self.body = body
    }
}

public extension DevRequest {
    static func decode(payload: Data) throws -> DevRequest {
        try decode(MsgPack.decode(payload))
    }

    static func decode(_ value: MsgPackValue) throws -> DevRequest {
        let fields = try DevFields(value)
        let t = try fields.req("t", \.stringValue)
        switch t {
        case "snapshot":
            return .snapshot(
                until: try fields.opt("until", \.stringValue),
                timeoutMs: try fields.milliseconds("timeout_ms")
            )
        case "zoom":
            return .zoom(z: try fields.req("z", \.doubleValue))
        case "focus":
            return .focus(card: try fields.opt("card", \.stringValue))
        case "resize":
            return .resize(
                card: try fields.req("card", \.stringValue),
                w: try fields.req("w", \.doubleValue),
                h: try fields.req("h", \.doubleValue)
            )
        case "type":
            return .type(card: try fields.req("card", \.stringValue), text: try fields.req("text", \.stringValue))
        case "key":
            return .key(card: try fields.req("card", \.stringValue), combo: try fields.req("combo", \.stringValue))
        case "press":
            return .press(
                combo: try fields.req("combo", \.stringValue),
                holdMs: try fields.milliseconds("hold_ms"),
                ageMs: try fields.milliseconds("age_ms"),
                busyMs: try fields.milliseconds("busy_ms")
            )
        default:
            return .unknown(type: t)
        }
    }

    func encodedPayload() -> Data {
        var fields = WireFields()
        func int(_ n: Int?) -> MsgPackValue? { n.map { .int(Int64($0)) } }
        switch self {
        case .snapshot(let until, let timeoutMs):
            fields.put("t", .string("snapshot"))
            fields.put("until", unlessNil: until.map(MsgPackValue.string))
            fields.put("timeout_ms", unlessNil: int(timeoutMs))
        case .zoom(let z):
            fields.put("t", .string("zoom"))
            fields.put("z", .double(z))
        case .focus(let card):
            fields.put("t", .string("focus"))
            fields.put("card", unlessNil: card.map(MsgPackValue.string))
        case .resize(let card, let w, let h):
            fields.put("t", .string("resize"))
            fields.put("card", .string(card))
            fields.put("w", .double(w))
            fields.put("h", .double(h))
        case .type(let card, let text):
            fields.put("t", .string("type"))
            fields.put("card", .string(card))
            fields.put("text", .string(text))
        case .key(let card, let combo):
            fields.put("t", .string("key"))
            fields.put("card", .string(card))
            fields.put("combo", .string(combo))
        case .press(let combo, let holdMs, let ageMs, let busyMs):
            fields.put("t", .string("press"))
            fields.put("combo", .string(combo))
            fields.put("hold_ms", unlessNil: int(holdMs))
            fields.put("age_ms", unlessNil: int(ageMs))
            fields.put("busy_ms", unlessNil: int(busyMs))
        case .unknown(let type):
            fields.put("t", .string(type))
        }
        return MsgPack.encode(.orderedMap(fields.fields))
    }
}

public extension DevReply {
    static func decode(payload: Data) throws -> DevReply {
        let fields = try DevFields(MsgPack.decode(payload))
        return DevReply(ok: try fields.req("ok", \.boolValue), body: try fields.req("body", \.stringValue))
    }

    func encodedPayload() -> Data {
        MsgPack.encode(.orderedMap([MsgPackField("ok", .bool(ok)), MsgPackField("body", .string(body))]))
    }
}

/// Keyed reads off one decoded map, under the daemon protocol's rules: any key
/// order, unknown keys ignored, an explicit nil the same as a missing key.
private struct DevFields {
    let map: [String: MsgPackValue]

    init(_ value: MsgPackValue) throws {
        guard let map = value.mapValue else { throw MessageError.notAMap }
        self.map = map
    }

    func req<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T {
        guard let value = try opt(key, extract) else { throw MessageError.missingField(key) }
        return value
    }

    func opt<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T? {
        guard let raw = map[key], !raw.isNil else { return nil }
        guard let value = extract(raw) else { throw MessageError.badField(key) }
        return value
    }

    /// The Rust wire type is `u32`.
    func milliseconds(_ key: String) throws -> Int? {
        guard let value = try opt(key, \.intValue) else { return nil }
        guard UInt32(exactly: value) != nil else { throw MessageError.badField(key) }
        return value
    }
}
