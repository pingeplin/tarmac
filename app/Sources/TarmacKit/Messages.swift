import Foundation

/// The doc entry of docs/protocol.md "M1 subset": nested in `restore.docs[]`,
/// flattened into `doc_opened`. Defaults match the wire defaults (missing key).
public struct RestoreDoc: Equatable, Sendable {
    public var path: String
    public var via: String
    public var repo: String?
    public var repoRoot: String?
    public var repoColor: Int?
    public var read: Bool
    public var lastChangedMs: UInt64?
    public var lastOpenedMs: UInt64?
    /// v4 Phase 3 additive (missing ⇒ nil): the term that opened the doc
    /// (provenance + gravity owner).
    public var termID: String?

    public init(
        path: String,
        via: String,
        repo: String? = nil,
        repoRoot: String? = nil,
        repoColor: Int? = nil,
        read: Bool = true,
        lastChangedMs: UInt64? = nil,
        lastOpenedMs: UInt64? = nil,
        termID: String? = nil
    ) {
        self.path = path
        self.via = via
        self.repo = repo
        self.repoRoot = repoRoot
        self.repoColor = repoColor
        self.read = read
        self.lastChangedMs = lastChangedMs
        self.lastOpenedMs = lastOpenedMs
        self.termID = termID
    }
}

/// One slot in the desk tile order (`restore.tiles[]` / `layout.tiles[]`):
/// kind "term" (no path) or "doc" (registry path). Unknown kinds pass through
/// the codec; receivers skip them per the protocol.
///
/// v4 (Phase 2) adds the optional world-space card frame `x,y,w,h` and stacking
/// order `z` — all additive (missing ⇒ nil). The init params default to nil so
/// existing `LayoutTile(kind:)` / `LayoutTile(kind:path:)` calls are unchanged,
/// and an M1 tile (no geometry) decodes with all-nil geometry.
public struct LayoutTile: Equatable, Sendable {
    public var kind: String
    public var path: String?
    public var x: Double?
    public var y: Double?
    public var w: Double?
    public var h: Double?
    public var z: Int?
    /// v4 Phase 3 additive (missing ⇒ nil): gravity-detached flag (missing ⇒
    /// attached).
    public var loose: Bool?
    /// v4 Phase 3 additive (missing ⇒ nil): true ⇒ the doc is parked on the
    /// shelf rather than placed on the board (shelf tiles carry no geometry).
    public var shelf: Bool?

    public init(
        kind: String,
        path: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        w: Double? = nil,
        h: Double? = nil,
        z: Int? = nil,
        loose: Bool? = nil,
        shelf: Bool? = nil
    ) {
        self.kind = kind
        self.path = path
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.z = z
        self.loose = loose
        self.shelf = shelf
    }
}

/// The persisted board viewport for a strip: zoom factor + world-space center.
/// v4 additive (`restore.board` / `layout.board`); whole map missing ⇒ nil.
public struct BoardViewport: Equatable, Sendable {
    public var zoom: Double
    public var cx: Double
    public var cy: Double

    public init(zoom: Double, cx: Double, cy: Double) {
        self.zoom = zoom
        self.cx = cx
        self.cy = cy
    }
}

/// Every message in docs/protocol.md (v1, M0 + M1 subsets).
public enum Message: Equatable, Sendable {
    case hello(role: String, v: Int)
    case helloOK(v: Int)
    case ack
    case err(msg: String)
    case open(path: String, termID: String?)
    case docRead(path: String)
    case layout(dock: [String], tiles: [LayoutTile], board: BoardViewport?)
    case restore(docs: [RestoreDoc], tiles: [LayoutTile], board: BoardViewport?)
    case spawnTerm(termID: String, cols: Int, rows: Int, cwd: String?, cmd: [String]?)
    case input(termID: String, bytes: Data)
    case resize(termID: String, cols: Int, rows: Int)
    case output(termID: String, bytes: Data)
    case exit(termID: String, code: Int?)
    case docOpened(doc: RestoreDoc)
    case fileEvent(path: String, mtimeMs: UInt64)
    /// Unknown message types are ignored per the protocol (log and continue).
    case unknown(type: String)
}

public enum MessageError: Error, Equatable, CustomStringConvertible {
    case notAMap
    case missingField(String)
    case badField(String)

    public var description: String {
        switch self {
        case .notAMap: return "message: payload is not a map"
        case .missingField(let k): return "message: missing required field \"\(k)\""
        case .badField(let k): return "message: field \"\(k)\" has the wrong type"
        }
    }
}

public extension Message {
    static func decode(payload: Data) throws -> Message {
        try decode(MsgPack.decode(payload))
    }

    static func decode(_ value: MsgPackValue) throws -> Message {
        guard let map = value.mapValue else { throw MessageError.notAMap }
        guard let t = map["t"]?.stringValue else { throw MessageError.missingField("t") }

        func req<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T {
            guard let raw = map[key], !raw.isNil else { throw MessageError.missingField(key) }
            guard let v = extract(raw) else { throw MessageError.badField(key) }
            return v
        }
        func opt<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T? {
            guard let raw = map[key], !raw.isNil else { return nil }
            guard let v = extract(raw) else { throw MessageError.badField(key) }
            return v
        }

        switch t {
        case "hello":
            return .hello(role: try req("role", \.stringValue), v: try req("v", \.intValue))
        case "hello_ok":
            return .helloOK(v: try req("v", \.intValue))
        case "ack":
            return .ack
        case "err":
            return .err(msg: try req("msg", \.stringValue))
        case "open":
            return .open(path: try req("path", \.stringValue), termID: try opt("term_id", \.stringValue))
        case "doc_read":
            return .docRead(path: try req("path", \.stringValue))
        case "layout":
            return .layout(
                dock: try req("dock", Self.stringArray),
                tiles: try req("tiles", \.arrayValue).map(Self.layoutTile(from:)),
                board: try Self.board(from: opt("board", \.mapValue))
            )
        case "restore":
            let docs = try req("docs", \.arrayValue).map { entry -> RestoreDoc in
                guard let m = entry.mapValue else { throw MessageError.badField("docs") }
                return try Self.docEntry(from: m)
            }
            let tiles = try (opt("tiles", \.arrayValue) ?? []).map(Self.layoutTile(from:))
            let board = try Self.board(from: opt("board", \.mapValue))
            return .restore(docs: docs, tiles: tiles, board: board)
        case "spawn_term":
            return .spawnTerm(
                termID: try req("term_id", \.stringValue),
                cols: try req("cols", \.intValue),
                rows: try req("rows", \.intValue),
                cwd: try opt("cwd", \.stringValue),
                cmd: try opt("cmd", Self.stringArray)
            )
        case "input":
            return .input(termID: try req("term_id", \.stringValue), bytes: try req("bytes", \.binaryValue))
        case "resize":
            return .resize(
                termID: try req("term_id", \.stringValue),
                cols: try req("cols", \.intValue),
                rows: try req("rows", \.intValue)
            )
        case "output":
            return .output(termID: try req("term_id", \.stringValue), bytes: try req("bytes", \.binaryValue))
        case "exit":
            return .exit(termID: try req("term_id", \.stringValue), code: try opt("code", \.intValue))
        case "doc_opened":
            return .docOpened(doc: try Self.docEntry(from: map))
        case "file_event":
            return .fileEvent(path: try req("path", \.stringValue), mtimeMs: try req("mtime_ms", \.uint64Value))
        default:
            return .unknown(type: t)
        }
    }

    private static func docEntry(from m: [String: MsgPackValue]) throws -> RestoreDoc {
        func req<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T {
            guard let raw = m[key], !raw.isNil else { throw MessageError.missingField(key) }
            guard let v = extract(raw) else { throw MessageError.badField(key) }
            return v
        }
        func opt<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T? {
            guard let raw = m[key], !raw.isNil else { return nil }
            guard let v = extract(raw) else { throw MessageError.badField(key) }
            return v
        }
        return RestoreDoc(
            path: try req("path", \.stringValue),
            via: try req("via", \.stringValue),
            repo: try opt("repo", \.stringValue),
            repoRoot: try opt("repo_root", \.stringValue),
            repoColor: try opt("repo_color", \.intValue),
            read: try opt("read", \.boolValue) ?? true,
            lastChangedMs: try opt("last_changed_ms", \.uint64Value),
            lastOpenedMs: try opt("last_opened_ms", \.uint64Value),
            termID: try opt("term_id", \.stringValue)
        )
    }

    private static func layoutTile(from value: MsgPackValue) throws -> LayoutTile {
        guard let m = value.mapValue else { throw MessageError.badField("tiles") }
        guard let kindRaw = m["kind"], !kindRaw.isNil else { throw MessageError.missingField("tiles.kind") }
        guard let kind = kindRaw.stringValue else { throw MessageError.badField("tiles.kind") }
        func opt<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T? {
            guard let raw = m[key], !raw.isNil else { return nil }
            guard let v = extract(raw) else { throw MessageError.badField("tiles.\(key)") }
            return v
        }
        return LayoutTile(
            kind: kind,
            path: try opt("path", \.stringValue),
            x: try opt("x", \.doubleValue),
            y: try opt("y", \.doubleValue),
            w: try opt("w", \.doubleValue),
            h: try opt("h", \.doubleValue),
            z: try opt("z", \.intValue),
            loose: try opt("loose", \.boolValue),
            shelf: try opt("shelf", \.boolValue)
        )
    }

    /// Decode the optional v4 `board` viewport map. Whole map missing ⇒ nil;
    /// when present, `zoom/cx/cy` are required floats.
    private static func board(from map: [String: MsgPackValue]?) throws -> BoardViewport? {
        guard let m = map else { return nil }
        func req(_ key: String) throws -> Double {
            guard let raw = m[key], !raw.isNil else { throw MessageError.missingField("board.\(key)") }
            guard let v = raw.doubleValue else { throw MessageError.badField("board.\(key)") }
            return v
        }
        return BoardViewport(zoom: try req("zoom"), cx: try req("cx"), cy: try req("cy"))
    }

    private static func stringArray(_ value: MsgPackValue) -> [String]? {
        guard let items = value.arrayValue else { return nil }
        var out: [String] = []
        for item in items {
            guard let s = item.stringValue else { return nil }
            out.append(s)
        }
        return out
    }

    func encodedValue() -> MsgPackValue {
        switch self {
        case .hello(let role, let v):
            return .map(["t": .string("hello"), "role": .string(role), "v": .int(Int64(v))])
        case .helloOK(let v):
            return .map(["t": .string("hello_ok"), "v": .int(Int64(v))])
        case .ack:
            return .map(["t": .string("ack")])
        case .err(let msg):
            return .map(["t": .string("err"), "msg": .string(msg)])
        case .open(let path, let termID):
            var map: [String: MsgPackValue] = ["t": .string("open"), "path": .string(path)]
            if let termID { map["term_id"] = .string(termID) }
            return .map(map)
        case .docRead(let path):
            return .map(["t": .string("doc_read"), "path": .string(path)])
        case .layout(let dock, let tiles, let board):
            var map: [String: MsgPackValue] = [
                "t": .string("layout"),
                "dock": .array(dock.map { .string($0) }),
                "tiles": .array(tiles.map(Self.layoutTileValue)),
            ]
            if let board { map["board"] = Self.boardValue(board) }
            return .map(map)
        case .restore(let docs, let tiles, let board):
            var map: [String: MsgPackValue] = [
                "t": .string("restore"),
                "docs": .array(docs.map { .map(Self.docEntryFields($0)) }),
                "tiles": .array(tiles.map(Self.layoutTileValue)),
            ]
            if let board { map["board"] = Self.boardValue(board) }
            return .map(map)
        case .spawnTerm(let termID, let cols, let rows, let cwd, let cmd):
            var map: [String: MsgPackValue] = [
                "t": .string("spawn_term"),
                "term_id": .string(termID),
                "cols": .int(Int64(cols)),
                "rows": .int(Int64(rows)),
            ]
            if let cwd { map["cwd"] = .string(cwd) }
            if let cmd { map["cmd"] = .array(cmd.map { .string($0) }) }
            return .map(map)
        case .input(let termID, let bytes):
            return .map(["t": .string("input"), "term_id": .string(termID), "bytes": .binary(bytes)])
        case .resize(let termID, let cols, let rows):
            return .map([
                "t": .string("resize"),
                "term_id": .string(termID),
                "cols": .int(Int64(cols)),
                "rows": .int(Int64(rows)),
            ])
        case .output(let termID, let bytes):
            return .map(["t": .string("output"), "term_id": .string(termID), "bytes": .binary(bytes)])
        case .exit(let termID, let code):
            var map: [String: MsgPackValue] = ["t": .string("exit"), "term_id": .string(termID)]
            if let code { map["code"] = .int(Int64(code)) }
            return .map(map)
        case .docOpened(let doc):
            var map = Self.docEntryFields(doc)
            map["t"] = .string("doc_opened")
            return .map(map)
        case .fileEvent(let path, let mtimeMs):
            return .map([
                "t": .string("file_event"),
                "path": .string(path),
                "mtime_ms": Self.uintValue(mtimeMs),
            ])
        case .unknown(let type):
            return .map(["t": .string(type)])
        }
    }

    func encodedPayload() -> Data {
        MsgPack.encode(encodedValue())
    }

    private static func docEntryFields(_ doc: RestoreDoc) -> [String: MsgPackValue] {
        var entry: [String: MsgPackValue] = [
            "path": .string(doc.path),
            "via": .string(doc.via),
            "read": .bool(doc.read),
        ]
        if let repo = doc.repo { entry["repo"] = .string(repo) }
        if let root = doc.repoRoot { entry["repo_root"] = .string(root) }
        if let color = doc.repoColor { entry["repo_color"] = .int(Int64(color)) }
        if let ms = doc.lastChangedMs { entry["last_changed_ms"] = uintValue(ms) }
        if let ms = doc.lastOpenedMs { entry["last_opened_ms"] = uintValue(ms) }
        if let termID = doc.termID { entry["term_id"] = .string(termID) }
        return entry
    }

    private static func layoutTileValue(_ tile: LayoutTile) -> MsgPackValue {
        var m: [String: MsgPackValue] = ["kind": .string(tile.kind)]
        if let path = tile.path { m["path"] = .string(path) }
        // v4 world frame: emit each key only when present (missing ⇒ nil).
        if let x = tile.x { m["x"] = .double(x) }
        if let y = tile.y { m["y"] = .double(y) }
        if let w = tile.w { m["w"] = .double(w) }
        if let h = tile.h { m["h"] = .double(h) }
        if let z = tile.z { m["z"] = .int(Int64(z)) }
        // v4 Phase 3: emit each flag only when present (missing ⇒ nil).
        if let loose = tile.loose { m["loose"] = .bool(loose) }
        if let shelf = tile.shelf { m["shelf"] = .bool(shelf) }
        return .map(m)
    }

    private static func boardValue(_ board: BoardViewport) -> MsgPackValue {
        .map([
            "zoom": .double(board.zoom),
            "cx": .double(board.cx),
            "cy": .double(board.cy),
        ])
    }

    private static func uintValue(_ n: UInt64) -> MsgPackValue {
        n <= UInt64(Int64.max) ? .int(Int64(n)) : .uint(n)
    }
}
