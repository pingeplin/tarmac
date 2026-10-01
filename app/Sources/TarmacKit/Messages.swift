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
    /// v4 Phase 5b additive (missing ⇒ nil): the `term_id` a terminal tile
    /// belongs to, so N terminal cards persist distinct positions. nil on doc
    /// tiles and on legacy single-terminal layouts. Last init param so every
    /// existing `LayoutTile(kind:…)` call compiles unchanged.
    public var termID: String?

    public init(
        kind: String,
        path: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        w: Double? = nil,
        h: Double? = nil,
        z: Int? = nil,
        loose: Bool? = nil,
        shelf: Bool? = nil,
        termID: String? = nil
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
        self.termID = termID
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

/// M3: one board's identity for the boards switcher (`board_list`). `name` is
/// the user-given display name (nil until named — manual naming only); the
/// switcher falls back to the slug `boardID`. Display order is the array order.
public struct BoardMeta: Equatable, Sendable {
    public var boardID: String
    public var name: String?
    /// P5 additive (missing ⇒ nil): the daemon's count of *live* ptys on this
    /// board. The honest per-board liveness the app cannot derive for a board it
    /// has never visited this session (no cards yet); the daemon re-pushes
    /// board_list when a term spawns/exits. A pre-P5 sender omits the key (nil).
    public var running: Int?

    public init(boardID: String, name: String? = nil, running: Int? = nil) {
        self.boardID = boardID
        self.name = name
        self.running = running
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
    /// M3 additive (missing ⇒ nil): the board this layout/restore belongs to.
    /// App→daemon `layout` stamps the active board so the daemon persists to the
    /// right board (not just its active one); daemon→app `restore` is stamped
    /// with the restored board's id so the app binds it to the correct board
    /// (and can reject a stale restore that arrives after a later switch).
    case layout(dock: [String], tiles: [LayoutTile], board: BoardViewport?, boardID: String?)
    /// P5 additive `liveTerms` (default empty): the term_ids the daemon owns a
    /// live pty for on this board. The app re-binds these cards to the running
    /// shells (consuming the replayed scrollback that follows) instead of cold-
    /// spawning; empty ⇒ cold-spawn (pre-P5 / daemon-restart, shells gone).
    case restore(docs: [RestoreDoc], tiles: [LayoutTile], board: BoardViewport?, boardID: String?, liveTerms: [String])
    case spawnTerm(termID: String, cols: Int, rows: Int, cwd: String?, cmd: [String]?)
    case input(termID: String, bytes: Data)
    case resize(termID: String, cols: Int, rows: Int)
    case output(termID: String, bytes: Data)
    case exit(termID: String, code: Int?)
    case docOpened(doc: RestoreDoc)
    case fileEvent(path: String, mtimeMs: UInt64)
    /// M2 honest signals (daemon → app; additive types). `termProc` is the
    /// foreground process name on a terminal; `bell` is a seen BEL (0x07).
    case termProc(termID: String, name: String, pid: Int?)
    case bell(termID: String)
    /// M3 ("strips = boards"; additive types). `boardList` (daemon → app) is the
    /// full set of boards + the active one; `boardSwitch` / `boardCreate`
    /// (app → daemon) drive the switcher.
    case boardList(boards: [BoardMeta], active: String)
    case boardSwitch(boardID: String)
    case boardCreate
    /// P5.4 (app → daemon): rename a board (`name` empty ⇒ clear to the slug) /
    /// delete a board (the daemon refuses the last board and fixes the active one
    /// if the deleted board was active). Drive the ⌘K switcher's ⌘E / ⌘⌫.
    case boardRename(boardID: String, name: String)
    case boardDelete(boardID: String)
    /// issue #15 (app → daemon): terminate one terminal's pty so ⌘W can close a
    /// single terminal card. The daemon SIGHUPs its process group; the usual
    /// `exit` follows. An unknown term ⇒ no-op.
    case termClose(termID: String)
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
                board: try Self.board(from: opt("board", \.mapValue)),
                boardID: try opt("board_id", \.stringValue)
            )
        case "restore":
            let docs = try req("docs", \.arrayValue).map { entry -> RestoreDoc in
                guard let m = entry.mapValue else { throw MessageError.badField("docs") }
                return try Self.docEntry(from: m)
            }
            let tiles = try (opt("tiles", \.arrayValue) ?? []).map(Self.layoutTile(from:))
            let board = try Self.board(from: opt("board", \.mapValue))
            return .restore(
                docs: docs, tiles: tiles, board: board,
                boardID: try opt("board_id", \.stringValue),
                liveTerms: try opt("live_terms", Self.stringArray) ?? []
            )
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
        case "term_proc":
            return .termProc(
                termID: try req("term_id", \.stringValue),
                name: try req("name", \.stringValue),
                pid: try opt("pid", \.intValue)
            )
        case "bell":
            return .bell(termID: try req("term_id", \.stringValue))
        case "board_list":
            let boards = try req("boards", \.arrayValue).map { entry -> BoardMeta in
                guard let m = entry.mapValue else { throw MessageError.badField("boards") }
                guard let id = m["board_id"], !id.isNil, let boardID = id.stringValue else {
                    throw MessageError.missingField("boards.board_id")
                }
                let name = m["name"].flatMap { $0.isNil ? nil : $0.stringValue }
                let running = m["running"].flatMap { $0.isNil ? nil : $0.intValue }
                return BoardMeta(boardID: boardID, name: name, running: running)
            }
            return .boardList(boards: boards, active: try req("active", \.stringValue))
        case "board_switch":
            return .boardSwitch(boardID: try req("board_id", \.stringValue))
        case "board_create":
            return .boardCreate
        case "board_rename":
            return .boardRename(boardID: try req("board_id", \.stringValue), name: try req("name", \.stringValue))
        case "board_delete":
            return .boardDelete(boardID: try req("board_id", \.stringValue))
        case "term_close":
            return .termClose(termID: try req("term_id", \.stringValue))
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
            shelf: try opt("shelf", \.boolValue),
            termID: try opt("term_id", \.stringValue)
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
            return Self.tagged("hello") {
                $0.put("role", .string(role))
                $0.put("v", .int(Int64(v)))
            }
        case .helloOK(let v):
            return Self.tagged("hello_ok") { $0.put("v", .int(Int64(v))) }
        case .ack:
            return Self.tagged("ack")
        case .err(let msg):
            return Self.tagged("err") { $0.put("msg", .string(msg)) }
        case .open(let path, let termID):
            return Self.tagged("open") {
                $0.put("path", .string(path))
                $0.put("term_id", unlessNil: termID.map(MsgPackValue.string))
            }
        case .docRead(let path):
            return Self.tagged("doc_read") { $0.put("path", .string(path)) }
        case .layout(let dock, let tiles, let board, let boardID):
            return Self.tagged("layout") {
                $0.put("dock", Self.stringArrayValue(dock))
                $0.put("tiles", .array(tiles.map(Self.layoutTileValue)))
                $0.put("board", unlessNil: board.map(Self.boardValue))
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
            }
        case .restore(let docs, let tiles, let board, let boardID, let liveTerms):
            return Self.tagged("restore") {
                $0.put("docs", .array(docs.map { doc in
                    var entry = WireFields()
                    Self.putDocEntry(doc, into: &entry)
                    return .orderedMap(entry.fields)
                }))
                $0.put("tiles", .array(tiles.map(Self.layoutTileValue)))
                $0.put("board", unlessNil: board.map(Self.boardValue))
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
                $0.put("live_terms", unlessNil: liveTerms.isEmpty ? nil : Self.stringArrayValue(liveTerms))
            }
        case .spawnTerm(let termID, let cols, let rows, let cwd, let cmd):
            return Self.tagged("spawn_term") {
                $0.put("term_id", .string(termID))
                $0.put("cols", .int(Int64(cols)))
                $0.put("rows", .int(Int64(rows)))
                $0.put("cwd", orNil: cwd.map(MsgPackValue.string))
                $0.put("cmd", orNil: cmd.map(Self.stringArrayValue))
            }
        case .input(let termID, let bytes):
            return Self.tagged("input") {
                $0.put("term_id", .string(termID))
                $0.put("bytes", .binary(bytes))
            }
        case .resize(let termID, let cols, let rows):
            return Self.tagged("resize") {
                $0.put("term_id", .string(termID))
                $0.put("cols", .int(Int64(cols)))
                $0.put("rows", .int(Int64(rows)))
            }
        case .output(let termID, let bytes):
            return Self.tagged("output") {
                $0.put("term_id", .string(termID))
                $0.put("bytes", .binary(bytes))
            }
        case .exit(let termID, let code):
            return Self.tagged("exit") {
                $0.put("term_id", .string(termID))
                $0.put("code", orNil: code.map { .int(Int64($0)) })
            }
        case .docOpened(let doc):
            return Self.tagged("doc_opened") { Self.putDocEntry(doc, into: &$0) }
        case .fileEvent(let path, let mtimeMs):
            return Self.tagged("file_event") {
                $0.put("path", .string(path))
                $0.put("mtime_ms", Self.uintValue(mtimeMs))
            }
        case .termProc(let termID, let name, let pid):
            return Self.tagged("term_proc") {
                $0.put("term_id", .string(termID))
                $0.put("name", .string(name))
                $0.put("pid", unlessNil: pid.map { .int(Int64($0)) })
            }
        case .bell(let termID):
            return Self.tagged("bell") { $0.put("term_id", .string(termID)) }
        case .boardList(let boards, let active):
            return Self.tagged("board_list") {
                $0.put("boards", .array(boards.map { meta in
                    var entry = WireFields()
                    entry.put("board_id", .string(meta.boardID))
                    entry.put("name", unlessNil: meta.name.map(MsgPackValue.string))
                    entry.put("running", unlessNil: meta.running.map { .int(Int64($0)) })
                    return .orderedMap(entry.fields)
                }))
                $0.put("active", .string(active))
            }
        case .boardSwitch(let boardID):
            return Self.tagged("board_switch") { $0.put("board_id", .string(boardID)) }
        case .boardCreate:
            return Self.tagged("board_create")
        case .boardRename(let boardID, let name):
            return Self.tagged("board_rename") {
                $0.put("board_id", .string(boardID))
                $0.put("name", .string(name))
            }
        case .boardDelete(let boardID):
            return Self.tagged("board_delete") { $0.put("board_id", .string(boardID)) }
        case .termClose(let termID):
            return Self.tagged("term_close") { $0.put("term_id", .string(termID)) }
        case .unknown(let type):
            return Self.tagged(type)
        }
    }

    func encodedPayload() -> Data {
        MsgPack.encode(encodedValue())
    }

    private static func tagged(_ t: String, _ build: (inout WireFields) -> Void = { _ in }) -> MsgPackValue {
        var fields = WireFields()
        fields.put("t", .string(t))
        build(&fields)
        return .orderedMap(fields.fields)
    }

    private static func putDocEntry(_ doc: RestoreDoc, into entry: inout WireFields) {
        entry.put("path", .string(doc.path))
        entry.put("via", .string(doc.via))
        entry.put("repo", orNil: doc.repo.map(MsgPackValue.string))
        entry.put("repo_root", orNil: doc.repoRoot.map(MsgPackValue.string))
        entry.put("repo_color", orNil: doc.repoColor.map { .int(Int64($0)) })
        entry.put("read", .bool(doc.read))
        entry.put("last_changed_ms", orNil: doc.lastChangedMs.map(uintValue))
        entry.put("last_opened_ms", orNil: doc.lastOpenedMs.map(uintValue))
        entry.put("term_id", unlessNil: doc.termID.map(MsgPackValue.string))
    }

    private static func layoutTileValue(_ tile: LayoutTile) -> MsgPackValue {
        var m = WireFields()
        m.put("kind", .string(tile.kind))
        m.put("path", unlessNil: tile.path.map(MsgPackValue.string))
        m.put("x", unlessNil: tile.x.map(MsgPackValue.double))
        m.put("y", unlessNil: tile.y.map(MsgPackValue.double))
        m.put("w", unlessNil: tile.w.map(MsgPackValue.double))
        m.put("h", unlessNil: tile.h.map(MsgPackValue.double))
        m.put("z", unlessNil: tile.z.map { .int(Int64($0)) })
        m.put("loose", unlessNil: tile.loose.map(MsgPackValue.bool))
        m.put("shelf", unlessNil: tile.shelf.map(MsgPackValue.bool))
        m.put("term_id", unlessNil: tile.termID.map(MsgPackValue.string))
        return .orderedMap(m.fields)
    }

    private static func boardValue(_ board: BoardViewport) -> MsgPackValue {
        .orderedMap([
            MsgPackField("zoom", .double(board.zoom)),
            MsgPackField("cx", .double(board.cx)),
            MsgPackField("cy", .double(board.cy)),
        ])
    }

    private static func stringArrayValue(_ strings: [String]) -> MsgPackValue {
        .array(strings.map(MsgPackValue.string))
    }

    private static func uintValue(_ n: UInt64) -> MsgPackValue {
        n <= UInt64(Int64.max) ? .int(Int64(n)) : .uint(n)
    }
}

/// One wire map, built in the order `rmp_serde::to_vec_named` writes it: the
/// struct's fields in declaration order. The two optional forms are the two ways
/// the Rust structs declare an `Option`, which differ on the wire.
struct WireFields {
    private(set) var fields: [MsgPackField] = []

    mutating func put(_ key: String, _ value: MsgPackValue) {
        fields.append(MsgPackField(key, value))
    }

    /// `#[serde(skip_serializing_if = "Option::is_none")]` — no key when nil.
    mutating func put(_ key: String, unlessNil value: MsgPackValue?) {
        if let value { put(key, value) }
    }

    /// A bare `Option<T>` — the key is always present, msgpack nil when nil.
    mutating func put(_ key: String, orNil value: MsgPackValue?) {
        put(key, value ?? .nil)
    }
}
