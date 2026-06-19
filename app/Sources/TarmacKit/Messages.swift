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
        case .layout(let dock, let tiles, let board, let boardID):
            var map: [String: MsgPackValue] = [
                "t": .string("layout"),
                "dock": .array(dock.map { .string($0) }),
                "tiles": .array(tiles.map(Self.layoutTileValue)),
            ]
            if let board { map["board"] = Self.boardValue(board) }
            if let boardID { map["board_id"] = .string(boardID) }
            return .map(map)
        case .restore(let docs, let tiles, let board, let boardID, let liveTerms):
            var map: [String: MsgPackValue] = [
                "t": .string("restore"),
                "docs": .array(docs.map { .map(Self.docEntryFields($0)) }),
                "tiles": .array(tiles.map(Self.layoutTileValue)),
            ]
            if let board { map["board"] = Self.boardValue(board) }
            if let boardID { map["board_id"] = .string(boardID) }
            if !liveTerms.isEmpty { map["live_terms"] = .array(liveTerms.map { .string($0) }) }
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
        case .termProc(let termID, let name, let pid):
            var map: [String: MsgPackValue] = [
                "t": .string("term_proc"),
                "term_id": .string(termID),
                "name": .string(name),
            ]
            if let pid { map["pid"] = .int(Int64(pid)) }
            return .map(map)
        case .bell(let termID):
            return .map(["t": .string("bell"), "term_id": .string(termID)])
        case .boardList(let boards, let active):
            return .map([
                "t": .string("board_list"),
                "boards": .array(boards.map { meta in
                    var m: [String: MsgPackValue] = ["board_id": .string(meta.boardID)]
                    if let name = meta.name { m["name"] = .string(name) }
                    if let running = meta.running { m["running"] = .int(Int64(running)) }
                    return .map(m)
                }),
                "active": .string(active),
            ])
        case .boardSwitch(let boardID):
            return .map(["t": .string("board_switch"), "board_id": .string(boardID)])
        case .boardCreate:
            return .map(["t": .string("board_create")])
        case .boardRename(let boardID, let name):
            return .map(["t": .string("board_rename"), "board_id": .string(boardID), "name": .string(name)])
        case .boardDelete(let boardID):
            return .map(["t": .string("board_delete"), "board_id": .string(boardID)])
        case .termClose(let termID):
            return .map(["t": .string("term_close"), "term_id": .string(termID)])
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
        // v4 Phase 5b: emit the terminal tile's term_id only when present.
        if let termID = tile.termID { m["term_id"] = .string(termID) }
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
