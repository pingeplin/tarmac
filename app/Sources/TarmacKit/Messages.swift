import Foundation

/// The doc entry of docs/protocol.md: nested in `restore.docs[]`,
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
    /// Missing ⇒ nil: the term that opened the doc (provenance + gravity
    /// owner).
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

/// What the daemon keeps of one terminal across its restarts (2611.0007).
public struct TermRecord: Equatable, Sendable {
    /// The terminal's last cwd that the daemon read.
    public var lastCwd: String?
    /// 2611.0011: the command that resumes the agent session last run there.
    public var resume: ResumeRecord?

    public init(lastCwd: String?, resume: ResumeRecord? = nil) {
        self.lastCwd = lastCwd
        self.resume = resume
    }
}

/// 2611.0012: one live terminal in `terms`. `cwd` and `proc` are the
/// daemon's fresh reads; missing when it could not read them.
public struct TermInfo: Equatable, Sendable {
    public var termID: String
    public var boardID: String
    public var cwd: String?
    public var proc: String?

    public init(termID: String, boardID: String, cwd: String? = nil, proc: String? = nil) {
        self.termID = termID
        self.boardID = boardID
        self.cwd = cwd
        self.proc = proc
    }
}

public struct ResumeRecord: Equatable, Sendable {
    public var cmd: String

    public init(cmd: String) {
        self.cmd = cmd
    }
}

/// One slot in the desk tile order (`restore.tiles[]` / `layout.tiles[]`):
/// kind "term" (no path) or "doc" (registry path). Unknown kinds pass through
/// the codec; receivers skip them per the protocol.
///
/// The world-space card frame `x,y,w,h` and stacking order `z` are optional
/// (missing ⇒ nil), so a tile with no geometry decodes with all-nil geometry.
public struct LayoutTile: Equatable, Sendable {
    public var kind: String
    public var path: String?
    public var x: Double?
    public var y: Double?
    public var w: Double?
    public var h: Double?
    public var z: Int?
    /// Gravity-detached flag; missing ⇒ nil, which means attached.
    public var loose: Bool?
    /// Missing ⇒ nil. True ⇒ the doc is parked on the shelf rather than placed
    /// on the board (shelf tiles carry no geometry).
    public var shelf: Bool?
    /// Missing ⇒ nil: the `term_id` a terminal tile belongs to, so N terminal
    /// cards persist distinct positions. nil on doc tiles and on legacy
    /// single-terminal layouts.
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
/// `restore.board` / `layout.board`; whole map missing ⇒ nil.
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

/// One board's identity for the boards switcher (`board_list`). `name` is
/// the user-given display name (nil until named — manual naming only); the
/// switcher falls back to the slug `boardID`. Display order is the array order.
public struct BoardMeta: Equatable, Sendable {
    public var boardID: String
    public var name: String?
    /// Missing ⇒ nil: the daemon's count of *live* ptys on this board. The
    /// honest per-board liveness the app cannot derive for a board it has never
    /// visited this session (no cards yet); the daemon re-pushes board_list when
    /// a term spawns/exits. An older daemon omits the key.
    public var running: Int?

    public init(boardID: String, name: String? = nil, running: Int? = nil) {
        self.boardID = boardID
        self.name = name
        self.running = running
    }
}

/// Every message in docs/protocol.md.
public enum Message: Equatable, Sendable {
    /// `appVersion` (additive, missing ⇒ nil) is the client's own version. Only
    /// an app sets it; `tarmac --version` reports it back to the user.
    case hello(role: String, v: Int, appVersion: String? = nil)
    /// Every key but `v` is additive (missing ⇒ nil). `daemonVersion` and
    /// `daemonPid` are what the stale-daemon restart reads (`DaemonLaunch`).
    /// `appVersion` / `appConnected` go to `cli` clients only; they are separate
    /// because `appConnected: true` with no `appVersion` is an app that named no
    /// version, and a nil `appConnected` is a daemon that predates the key —
    /// neither is "no app".
    case helloOK(
        v: Int,
        daemonVersion: String? = nil,
        daemonPid: Int? = nil,
        appVersion: String? = nil,
        appConnected: Bool? = nil
    )
    case ack
    case err(msg: String)
    /// `boardID` (missing ⇒ the calling term's board, else the active one)
    /// names an explicit target board.
    case open(path: String, termID: String?, boardID: String? = nil)
    case docRead(path: String)
    /// Missing ⇒ nil: the board this layout/restore belongs to.
    /// App→daemon `layout` stamps the active board so the daemon persists to the
    /// right board (not just its active one); daemon→app `restore` is stamped
    /// with the restored board's id so the app binds it to the correct board
    /// (and can reject a stale restore that arrives after a later switch).
    case layout(dock: [String], tiles: [LayoutTile], board: BoardViewport?, boardID: String?)
    /// `liveTerms` (default empty): the term_ids the daemon owns a live pty for
    /// on this board. The app re-binds these cards to the running shells
    /// (consuming the replayed scrollback that follows) instead of cold-
    /// spawning; empty ⇒ cold-spawn (an older or restarted daemon, shells gone).
    ///
    /// `termRecords` (2611.0007, default empty): the board's record of each
    /// terminal, keyed by term id. A cold spawn of a persisted tile starts in
    /// its record's `lastCwd`.
    case restore(
        docs: [RestoreDoc],
        tiles: [LayoutTile],
        board: BoardViewport?,
        boardID: String?,
        liveTerms: [String],
        termRecords: [String: TermRecord] = [:]
    )
    /// `boardID` (missing ⇒ board-0 / active) is the board the new
    /// terminal belongs to. `inheritCwdFrom` (issue #77, missing ⇒ nil) names a
    /// terminal whose LIVE cwd the new one starts in; the daemon resolves it at
    /// spawn time and ignores it when `cwd` is set. `succeeds` (2611.0007,
    /// missing ⇒ nil) names the persisted terminal whose record the new one
    /// takes.
    case spawnTerm(
        termID: String,
        cols: Int,
        rows: Int,
        cwd: String?,
        cmd: [String]?,
        boardID: String? = nil,
        inheritCwdFrom: String? = nil,
        succeeds: String? = nil
    )
    /// `typed` (2611.0009): the user's own input, which marks the terminal's
    /// report read. Written only when true. `hold` (2611.0016, D11): the
    /// daemon writes the bytes once the shell takes keys; written only when true.
    case input(termID: String, bytes: Data, typed: Bool = false, hold: Bool = false)
    case resize(termID: String, cols: Int, rows: Int)
    case output(termID: String, bytes: Data)
    /// `boardID` (2611.0013): the board the terminal was filed under when it
    /// ended; nil from an older daemon.
    case exit(termID: String, code: Int?, boardID: String? = nil)
    case docOpened(doc: RestoreDoc)
    case fileEvent(path: String, mtimeMs: UInt64)
    /// Honest signals (daemon → app). `termProc` is the
    /// foreground process name on a terminal; `bell` is a seen BEL (0x07).
    case termProc(termID: String, name: String, pid: Int?)
    case bell(termID: String, boardID: String? = nil)
    /// Boards. `boardList` (daemon → app) is the
    /// full set of boards + the active one; `boardSwitch` / `boardCreate`
    /// (app → daemon) drive the switcher.
    case boardList(boards: [BoardMeta], active: String)
    case boardSwitch(boardID: String)
    case boardCreate
    /// App → daemon: rename a board (`name` empty ⇒ clear to the slug) /
    /// delete a board (the daemon refuses the last board and fixes the active one
    /// if the deleted board was active). Drive the ⌘K switcher's ⌘E / ⌘⌫.
    case boardRename(boardID: String, name: String)
    case boardDelete(boardID: String)
    /// issue #15 (app → daemon): terminate one terminal's pty so ⌘W can close a
    /// single terminal card. The daemon SIGHUPs its process group; the usual
    /// `exit` follows. An unknown term ⇒ no-op.
    case termClose(termID: String)
    /// issue #34 (app → daemon): forget a doc — registry, dock and watcher. An
    /// unknown path is a silent no-op.
    case docClose(path: String)
    /// issue #89 (app → daemon): re-stat a doc now and push the usual
    /// `file_event`, changed or not. Covers edits the watcher drops while the
    /// doc's board is in the background.
    case docRefresh(path: String)
    /// issue #311 (app → daemon): the doc `path` on board `boardID` reads the
    /// data file `file`; nil clears it. The daemon answers with a `file_event`
    /// for that file, and sends one for each change it sees.
    case dataFile(boardID: String, path: String, file: String? = nil)
    /// issue #326 (cli → daemon): one JSON value, as text, for the cards of
    /// the doc `path`; answered with `ack` or `err`. The app never gets one.
    case push(path: String, value: String)
    /// issue #326 (daemon → app): the value of a `push`, for each loaded card
    /// of the doc `path` (the registry's key).
    case docEvent(path: String, value: String)
    /// 2611.0009 (cli → daemon): a terminal's report, `blocked`, `done` or
    /// `clear`; answered with `ack` or `err`. The app never sends one.
    case report(termID: String, kind: String, text: String?)
    /// 2611.0009 (daemon → app): a terminal's current report. No `kind` is no
    /// report; a missing `read` is unread.
    /// `boardID` and `cwd` (2611.0013): the terminal's board and `last_cwd`
    /// record when the report was made; never on a frame with no `kind`.
    case termReport(
        termID: String, kind: String?, text: String?, atMs: UInt64?, proc: String?, read: Bool,
        boardID: String? = nil, cwd: String? = nil
    )
    /// 2611.0011 (cli → daemon): a terminal's resume command; nil clears it.
    /// 2611.0015 D4 (app → daemon): only the clear, which the daemon acts on
    /// only for a record no agent claimed since the restore.
    case resume(termID: String, cmd: String?)
    /// 2611.0015 (daemon → app): a live terminal's recorded command changed;
    /// nil is no command.
    case termResume(termID: String, cmd: String?)
    /// 2611.0012 (cli → daemon): the daemon's facts for a script, filtered by
    /// kind and terminal; nil is no filter. The app never sends one.
    case subscribe(kinds: [String]?, termID: String?)
    /// 2611.0012 (cli → daemon): the live terminals. The app never sends one.
    case termsList
    /// 2611.0012 (daemon → cli): the answer to `termsList`. The app never gets one.
    case terms([TermInfo])
    /// issue #41: `scrollbackRequest` (app → daemon) asks for one terminal's
    /// scrollback ring; the daemon answers with exactly one `scrollback`, always —
    /// empty bytes for a silent or unknown terminal.
    case scrollbackRequest(termID: String)
    case scrollback(termID: String, bytes: Data)
    /// 2611.0016 (daemon → app): open a terminal card on `boardID` and type
    /// `cmd` into its shell. The cli leg has no `reqID` and no `boardID`.
    case termNew(reqID: UInt64?, cmd: String, cwd: String, termID: String?, boardID: String?)
    /// 2611.0016 (app → daemon): the card's terminal. The daemon's answer to
    /// the cli has no `reqID`.
    case termNewOK(reqID: UInt64?, termID: String)
    /// 2611.0016 (app → daemon): the request was refused.
    case termNewErr(reqID: UInt64, msg: String)
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
        let fields = MapReader(map)

        switch t {
        case "hello":
            return .hello(
                role: try fields.req("role", \.stringValue),
                v: try fields.req("v", \.intValue),
                appVersion: try fields.opt("app_version", \.stringValue)
            )
        case "hello_ok":
            return .helloOK(
                v: try fields.req("v", \.intValue),
                daemonVersion: try fields.opt("daemon_version", \.stringValue),
                daemonPid: try fields.opt("daemon_pid", \.intValue),
                appVersion: try fields.opt("app_version", \.stringValue),
                appConnected: try fields.opt("app_connected", \.boolValue)
            )
        case "ack":
            return .ack
        case "err":
            return .err(msg: try fields.req("msg", \.stringValue))
        case "open":
            return .open(
                path: try fields.req("path", \.stringValue),
                termID: try fields.opt("term_id", \.stringValue),
                boardID: try fields.opt("board_id", \.stringValue)
            )
        case "doc_read":
            return .docRead(path: try fields.req("path", \.stringValue))
        case "layout":
            return .layout(
                dock: try fields.req("dock", Self.stringArray),
                tiles: try fields.req("tiles", \.arrayValue).map(Self.layoutTile(from:)),
                board: try Self.board(from: fields.opt("board", \.mapValue)),
                boardID: try fields.opt("board_id", \.stringValue)
            )
        case "restore":
            let docs = try fields.req("docs", \.arrayValue).map { entry -> RestoreDoc in
                guard let m = entry.mapValue else { throw MessageError.badField("docs") }
                return try Self.docEntry(from: MapReader(m))
            }
            let tiles = try (fields.opt("tiles", \.arrayValue) ?? []).map(Self.layoutTile(from:))
            let board = try Self.board(from: fields.opt("board", \.mapValue))
            return .restore(
                docs: docs, tiles: tiles, board: board,
                boardID: try fields.opt("board_id", \.stringValue),
                liveTerms: try fields.opt("live_terms", Self.stringArray) ?? [],
                termRecords: try Self.termRecords(from: fields.opt("term_records", \.mapValue))
            )
        case "spawn_term":
            return .spawnTerm(
                termID: try fields.req("term_id", \.stringValue),
                cols: try fields.req("cols", \.intValue),
                rows: try fields.req("rows", \.intValue),
                cwd: try fields.opt("cwd", \.stringValue),
                cmd: try fields.opt("cmd", Self.stringArray),
                boardID: try fields.opt("board_id", \.stringValue),
                inheritCwdFrom: try fields.opt("inherit_cwd_from", \.stringValue),
                succeeds: try fields.opt("succeeds", \.stringValue)
            )
        case "input":
            return .input(
                termID: try fields.req("term_id", \.stringValue),
                bytes: try fields.req("bytes", \.binaryValue),
                typed: try fields.opt("typed", \.boolValue) ?? false,
                hold: try fields.opt("hold", \.boolValue) ?? false
            )
        case "resize":
            return .resize(
                termID: try fields.req("term_id", \.stringValue),
                cols: try fields.req("cols", \.intValue),
                rows: try fields.req("rows", \.intValue)
            )
        case "output":
            return .output(
                termID: try fields.req("term_id", \.stringValue),
                bytes: try fields.req("bytes", \.binaryValue)
            )
        case "exit":
            return .exit(
                termID: try fields.req("term_id", \.stringValue),
                code: try fields.opt("code", \.intValue),
                boardID: try fields.opt("board_id", \.stringValue)
            )
        case "doc_opened":
            return .docOpened(doc: try Self.docEntry(from: fields))
        case "file_event":
            return .fileEvent(
                path: try fields.req("path", \.stringValue),
                mtimeMs: try fields.req("mtime_ms", \.uint64Value)
            )
        case "term_proc":
            return .termProc(
                termID: try fields.req("term_id", \.stringValue),
                name: try fields.req("name", \.stringValue),
                pid: try fields.opt("pid", \.intValue)
            )
        case "bell":
            return .bell(
                termID: try fields.req("term_id", \.stringValue),
                boardID: try fields.opt("board_id", \.stringValue)
            )
        case "board_list":
            let boards = try fields.req("boards", \.arrayValue).map { entry -> BoardMeta in
                guard let m = entry.mapValue else { throw MessageError.badField("boards") }
                guard let id = m["board_id"], !id.isNil, let boardID = id.stringValue else {
                    throw MessageError.missingField("boards.board_id")
                }
                let name = m["name"].flatMap { $0.isNil ? nil : $0.stringValue }
                let running = m["running"].flatMap { $0.isNil ? nil : $0.intValue }
                return BoardMeta(boardID: boardID, name: name, running: running)
            }
            return .boardList(boards: boards, active: try fields.req("active", \.stringValue))
        case "board_switch":
            return .boardSwitch(boardID: try fields.req("board_id", \.stringValue))
        case "board_create":
            return .boardCreate
        case "board_rename":
            return .boardRename(
                boardID: try fields.req("board_id", \.stringValue),
                name: try fields.req("name", \.stringValue)
            )
        case "board_delete":
            return .boardDelete(boardID: try fields.req("board_id", \.stringValue))
        case "term_close":
            return .termClose(termID: try fields.req("term_id", \.stringValue))
        case "doc_close":
            return .docClose(path: try fields.req("path", \.stringValue))
        case "doc_refresh":
            return .docRefresh(path: try fields.req("path", \.stringValue))
        case "data_file":
            return .dataFile(
                boardID: try fields.req("board_id", \.stringValue),
                path: try fields.req("path", \.stringValue),
                file: try fields.opt("file", \.stringValue)
            )
        case "push":
            return .push(path: try fields.req("path", \.stringValue), value: try fields.req("value", \.stringValue))
        case "doc_event":
            return .docEvent(path: try fields.req("path", \.stringValue), value: try fields.req("value", \.stringValue))
        case "report":
            return .report(
                termID: try fields.req("term_id", \.stringValue),
                kind: try fields.req("kind", \.stringValue),
                text: try fields.opt("text", \.stringValue)
            )
        case "term_report":
            return .termReport(
                termID: try fields.req("term_id", \.stringValue),
                kind: try fields.opt("kind", \.stringValue),
                text: try fields.opt("text", \.stringValue),
                atMs: try fields.opt("at_ms", \.uint64Value),
                proc: try fields.opt("proc", \.stringValue),
                read: try fields.opt("read", \.boolValue) ?? false,
                boardID: try fields.opt("board_id", \.stringValue),
                cwd: try fields.opt("cwd", \.stringValue)
            )
        case "resume":
            return .resume(termID: try fields.req("term_id", \.stringValue), cmd: try fields.opt("cmd", \.stringValue))
        case "term_resume":
            return .termResume(
                termID: try fields.req("term_id", \.stringValue),
                cmd: try fields.opt("cmd", \.stringValue)
            )
        case "subscribe":
            return .subscribe(
                kinds: try fields.opt("kinds", Self.stringArray),
                termID: try fields.opt("term_id", \.stringValue)
            )
        case "terms_list":
            return .termsList
        case "terms":
            return .terms(try fields.req("terms", \.arrayValue).map(Self.termInfo(from:)))
        case "scrollback_request":
            return .scrollbackRequest(termID: try fields.req("term_id", \.stringValue))
        case "scrollback":
            return .scrollback(
                termID: try fields.req("term_id", \.stringValue),
                bytes: try fields.req("bytes", \.binaryValue)
            )
        case "term_new":
            return .termNew(
                reqID: try fields.opt("req_id", \.uint64Value),
                cmd: try fields.req("cmd", \.stringValue),
                cwd: try fields.req("cwd", \.stringValue),
                termID: try fields.opt("term_id", \.stringValue),
                boardID: try fields.opt("board_id", \.stringValue)
            )
        case "term_new_ok":
            return .termNewOK(reqID: try fields.opt("req_id", \.uint64Value), termID: try fields.req("term_id", \.stringValue))
        case "term_new_err":
            return .termNewErr(reqID: try fields.req("req_id", \.uint64Value), msg: try fields.req("msg", \.stringValue))
        default:
            return .unknown(type: t)
        }
    }

    private static func termRecords(from m: [String: MsgPackValue]?) throws -> [String: TermRecord] {
        try (m ?? [:]).mapValues { value in
            guard let record = value.mapValue else { throw MessageError.badField("term_records") }
            return TermRecord(
                lastCwd: try MapReader(record).opt("last_cwd", \.stringValue),
                resume: try resumeRecord(record["resume"])
            )
        }
    }

    private static func termInfo(from raw: MsgPackValue) throws -> TermInfo {
        guard let m = raw.mapValue else { throw MessageError.badField("terms") }
        let fields = MapReader(m)
        guard let termID = try fields.opt("term_id", \.stringValue) else {
            throw MessageError.missingField("terms.term_id")
        }
        guard let boardID = try fields.opt("board_id", \.stringValue) else {
            throw MessageError.missingField("terms.board_id")
        }
        return TermInfo(
            termID: termID, boardID: boardID,
            cwd: try fields.opt("cwd", \.stringValue), proc: try fields.opt("proc", \.stringValue)
        )
    }

    private static func resumeRecord(_ raw: MsgPackValue?) throws -> ResumeRecord? {
        guard let raw, !raw.isNil else { return nil }
        guard let m = raw.mapValue else { throw MessageError.badField("resume") }
        guard let cmd = try MapReader(m).opt("cmd", \.stringValue) else { throw MessageError.missingField("resume.cmd") }
        return ResumeRecord(cmd: cmd)
    }

    private static func docEntry(from fields: MapReader) throws -> RestoreDoc {
        RestoreDoc(
            path: try fields.req("path", \.stringValue),
            via: try fields.req("via", \.stringValue),
            repo: try fields.opt("repo", \.stringValue),
            repoRoot: try fields.opt("repo_root", \.stringValue),
            repoColor: try fields.opt("repo_color", \.intValue),
            read: try fields.opt("read", \.boolValue) ?? true,
            lastChangedMs: try fields.opt("last_changed_ms", \.uint64Value),
            lastOpenedMs: try fields.opt("last_opened_ms", \.uint64Value),
            termID: try fields.opt("term_id", \.stringValue)
        )
    }

    private static func layoutTile(from value: MsgPackValue) throws -> LayoutTile {
        guard let m = value.mapValue else { throw MessageError.badField("tiles") }
        let fields = MapReader(m, prefix: "tiles.")
        return LayoutTile(
            kind: try fields.req("kind", \.stringValue),
            path: try fields.opt("path", \.stringValue),
            x: try fields.opt("x", \.doubleValue),
            y: try fields.opt("y", \.doubleValue),
            w: try fields.opt("w", \.doubleValue),
            h: try fields.opt("h", \.doubleValue),
            z: try fields.opt("z", \.intValue),
            loose: try fields.opt("loose", \.boolValue),
            shelf: try fields.opt("shelf", \.boolValue),
            termID: try fields.opt("term_id", \.stringValue)
        )
    }

    /// Decode the optional `board` viewport map. Whole map missing ⇒ nil;
    /// when present, `zoom/cx/cy` are required floats.
    private static func board(from map: [String: MsgPackValue]?) throws -> BoardViewport? {
        guard let m = map else { return nil }
        let fields = MapReader(m, prefix: "board.")
        return BoardViewport(
            zoom: try fields.req("zoom", \.doubleValue),
            cx: try fields.req("cx", \.doubleValue),
            cy: try fields.req("cy", \.doubleValue)
        )
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
        case .hello(let role, let v, let appVersion):
            return Self.tagged("hello") {
                $0.put("role", .string(role))
                $0.put("v", .int(Int64(v)))
                $0.put("app_version", unlessNil: appVersion.map(MsgPackValue.string))
            }
        case .helloOK(let v, let daemonVersion, let daemonPid, let appVersion, let appConnected):
            return Self.tagged("hello_ok") {
                $0.put("v", .int(Int64(v)))
                $0.put("daemon_version", unlessNil: daemonVersion.map(MsgPackValue.string))
                $0.put("daemon_pid", unlessNil: daemonPid.map { .int(Int64($0)) })
                $0.put("app_version", unlessNil: appVersion.map(MsgPackValue.string))
                $0.put("app_connected", unlessNil: appConnected.map(MsgPackValue.bool))
            }
        case .ack:
            return Self.tagged("ack")
        case .err(let msg):
            return Self.tagged("err") { $0.put("msg", .string(msg)) }
        case .open(let path, let termID, let boardID):
            return Self.tagged("open") {
                $0.put("path", .string(path))
                $0.put("term_id", unlessNil: termID.map(MsgPackValue.string))
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
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
        case .restore(let docs, let tiles, let board, let boardID, let liveTerms, let termRecords):
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
                $0.put("term_records", unlessNil: termRecords.isEmpty ? nil : Self.termRecordsValue(termRecords))
            }
        case .spawnTerm(let termID, let cols, let rows, let cwd, let cmd, let boardID, let inheritCwdFrom, let succeeds):
            return Self.tagged("spawn_term") {
                $0.put("term_id", .string(termID))
                $0.put("cols", .int(Int64(cols)))
                $0.put("rows", .int(Int64(rows)))
                $0.put("cwd", orNil: cwd.map(MsgPackValue.string))
                $0.put("cmd", orNil: cmd.map(Self.stringArrayValue))
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
                $0.put("inherit_cwd_from", unlessNil: inheritCwdFrom.map(MsgPackValue.string))
                $0.put("succeeds", unlessNil: succeeds.map(MsgPackValue.string))
            }
        case .report(let termID, let kind, let text):
            return Self.tagged("report") {
                $0.put("term_id", .string(termID))
                $0.put("kind", .string(kind))
                $0.put("text", unlessNil: text.map(MsgPackValue.string))
            }
        case .termReport(let termID, let kind, let text, let atMs, let proc, let read, let boardID, let cwd):
            return Self.tagged("term_report") {
                $0.put("term_id", .string(termID))
                $0.put("kind", unlessNil: kind.map(MsgPackValue.string))
                $0.put("text", unlessNil: text.map(MsgPackValue.string))
                $0.put("at_ms", unlessNil: atMs.map(Self.uintValue))
                $0.put("proc", unlessNil: proc.map(MsgPackValue.string))
                $0.put("read", unlessNil: read ? .bool(true) : nil)
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
                $0.put("cwd", unlessNil: cwd.map(MsgPackValue.string))
            }
        case .resume(let termID, let cmd):
            return Self.resumeValue("resume", termID: termID, cmd: cmd)
        case .termResume(let termID, let cmd):
            return Self.resumeValue("term_resume", termID: termID, cmd: cmd)
        case .subscribe(let kinds, let termID):
            return Self.tagged("subscribe") {
                $0.put("kinds", unlessNil: kinds.map(Self.stringArrayValue))
                $0.put("term_id", unlessNil: termID.map(MsgPackValue.string))
            }
        case .termsList:
            return Self.tagged("terms_list")
        case .terms(let terms):
            return Self.tagged("terms") { $0.put("terms", .array(terms.map(Self.termInfoValue))) }
        case .input(let termID, let bytes, let typed, let hold):
            return Self.tagged("input") {
                $0.put("term_id", .string(termID))
                $0.put("bytes", .binary(bytes))
                $0.put("typed", unlessNil: typed ? .bool(true) : nil)
                $0.put("hold", unlessNil: hold ? .bool(true) : nil)
            }
        case .termNew(let reqID, let cmd, let cwd, let termID, let boardID):
            return Self.tagged("term_new") {
                $0.put("req_id", unlessNil: reqID.map(Self.uintValue))
                $0.put("cmd", .string(cmd))
                $0.put("cwd", .string(cwd))
                $0.put("term_id", unlessNil: termID.map(MsgPackValue.string))
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
            }
        case .termNewOK(let reqID, let termID):
            return Self.tagged("term_new_ok") {
                $0.put("req_id", unlessNil: reqID.map(Self.uintValue))
                $0.put("term_id", .string(termID))
            }
        case .termNewErr(let reqID, let msg):
            return Self.tagged("term_new_err") {
                $0.put("req_id", Self.uintValue(reqID))
                $0.put("msg", .string(msg))
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
        case .exit(let termID, let code, let boardID):
            return Self.tagged("exit") {
                $0.put("term_id", .string(termID))
                $0.put("code", orNil: code.map { .int(Int64($0)) })
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
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
        case .bell(let termID, let boardID):
            return Self.tagged("bell") {
                $0.put("term_id", .string(termID))
                $0.put("board_id", unlessNil: boardID.map(MsgPackValue.string))
            }
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
        case .docClose(let path):
            return Self.tagged("doc_close") { $0.put("path", .string(path)) }
        case .docRefresh(let path):
            return Self.tagged("doc_refresh") { $0.put("path", .string(path)) }
        case .dataFile(let boardID, let path, let file):
            return Self.tagged("data_file") {
                $0.put("board_id", .string(boardID))
                $0.put("path", .string(path))
                $0.put("file", unlessNil: file.map(MsgPackValue.string))
            }
        case .push(let path, let value):
            return Self.tagged("push") {
                $0.put("path", .string(path))
                $0.put("value", .string(value))
            }
        case .docEvent(let path, let value):
            return Self.tagged("doc_event") {
                $0.put("path", .string(path))
                $0.put("value", .string(value))
            }
        case .scrollbackRequest(let termID):
            return Self.tagged("scrollback_request") { $0.put("term_id", .string(termID)) }
        case .scrollback(let termID, let bytes):
            return Self.tagged("scrollback") {
                $0.put("term_id", .string(termID))
                $0.put("bytes", .binary(bytes))
            }
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

    private static func resumeValue(_ t: String, termID: String, cmd: String?) -> MsgPackValue {
        tagged(t) {
            $0.put("term_id", .string(termID))
            $0.put("cmd", unlessNil: cmd.map(MsgPackValue.string))
        }
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

    /// Keys in sorted order, as the daemon's `BTreeMap` writes them.
    private static func termRecordsValue(_ records: [String: TermRecord]) -> MsgPackValue {
        .orderedMap(records.sorted { $0.key < $1.key }.map { id, record in
            var m = WireFields()
            m.put("last_cwd", unlessNil: record.lastCwd.map(MsgPackValue.string))
            m.put("resume", unlessNil: record.resume.map { .orderedMap([MsgPackField("cmd", .string($0.cmd))]) })
            return MsgPackField(id, .orderedMap(m.fields))
        })
    }

    private static func termInfoValue(_ info: TermInfo) -> MsgPackValue {
        var m = WireFields()
        m.put("term_id", .string(info.termID))
        m.put("board_id", .string(info.boardID))
        m.put("cwd", unlessNil: info.cwd.map(MsgPackValue.string))
        m.put("proc", unlessNil: info.proc.map(MsgPackValue.string))
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
