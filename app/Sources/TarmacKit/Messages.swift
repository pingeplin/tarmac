import Foundation

/// One entry in the daemon's `restore` push.
public struct RestoreDoc: Equatable, Sendable {
    public var path: String
    public var via: String
    public var lastChangedMs: UInt64?

    public init(path: String, via: String, lastChangedMs: UInt64? = nil) {
        self.path = path
        self.via = via
        self.lastChangedMs = lastChangedMs
    }
}

/// Every message in docs/protocol.md (v1, M0 subset).
public enum Message: Equatable, Sendable {
    case hello(role: String, v: Int)
    case helloOK(v: Int)
    case ack
    case err(msg: String)
    case open(path: String)
    case restore(docs: [RestoreDoc])
    case spawnTerm(termID: String, cols: Int, rows: Int, cwd: String?, cmd: [String]?)
    case input(termID: String, bytes: Data)
    case resize(termID: String, cols: Int, rows: Int)
    case output(termID: String, bytes: Data)
    case exit(termID: String, code: Int?)
    case docOpened(path: String, via: String)
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
            return .open(path: try req("path", \.stringValue))
        case "restore":
            let docs = try req("docs", \.arrayValue)
            return .restore(docs: try docs.map { entry in
                guard let m = entry.mapValue else { throw MessageError.badField("docs") }
                func dreq(_ key: String) throws -> String {
                    guard let v = m[key]?.stringValue else { throw MessageError.missingField("docs.\(key)") }
                    return v
                }
                let last: UInt64?
                if let raw = m["last_changed_ms"], !raw.isNil {
                    guard let v = raw.uint64Value else { throw MessageError.badField("docs.last_changed_ms") }
                    last = v
                } else {
                    last = nil
                }
                return RestoreDoc(path: try dreq("path"), via: try dreq("via"), lastChangedMs: last)
            })
        case "spawn_term":
            return .spawnTerm(
                termID: try req("term_id", \.stringValue),
                cols: try req("cols", \.intValue),
                rows: try req("rows", \.intValue),
                cwd: try opt("cwd", \.stringValue),
                cmd: try opt("cmd") { raw in
                    guard let items = raw.arrayValue else { return nil }
                    var out: [String] = []
                    for item in items {
                        guard let s = item.stringValue else { return nil }
                        out.append(s)
                    }
                    return out
                }
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
            return .docOpened(path: try req("path", \.stringValue), via: try req("via", \.stringValue))
        case "file_event":
            return .fileEvent(path: try req("path", \.stringValue), mtimeMs: try req("mtime_ms", \.uint64Value))
        default:
            return .unknown(type: t)
        }
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
        case .open(let path):
            return .map(["t": .string("open"), "path": .string(path)])
        case .restore(let docs):
            return .map(["t": .string("restore"), "docs": .array(docs.map { doc in
                var entry: [String: MsgPackValue] = ["path": .string(doc.path), "via": .string(doc.via)]
                if let last = doc.lastChangedMs { entry["last_changed_ms"] = last <= UInt64(Int64.max) ? .int(Int64(last)) : .uint(last) }
                return .map(entry)
            })])
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
        case .docOpened(let path, let via):
            return .map(["t": .string("doc_opened"), "path": .string(path), "via": .string(via)])
        case .fileEvent(let path, let mtimeMs):
            return .map([
                "t": .string("file_event"),
                "path": .string(path),
                "mtime_ms": mtimeMs <= UInt64(Int64.max) ? .int(Int64(mtimeMs)) : .uint(mtimeMs),
            ])
        case .unknown(let type):
            return .map(["t": .string(type)])
        }
    }

    func encodedPayload() -> Data {
        MsgPack.encode(encodedValue())
    }
}
