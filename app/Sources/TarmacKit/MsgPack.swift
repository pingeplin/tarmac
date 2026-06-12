import Foundation

/// Minimal MessagePack value model for the Tarmac wire protocol.
/// Maps are restricted to string keys per docs/protocol.md ("every message is a
/// MessagePack map with string keys"); a non-string key is a decode error.
public enum MsgPackValue: Equatable, Sendable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    /// Only used for values above Int64.max; all other integers decode as `.int`
    /// so that round-trips compare equal regardless of encoded width.
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map([String: MsgPackValue])
}

public extension MsgPackValue {
    var isNil: Bool { if case .nil = self { return true }; return false }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let n): return Int(exactly: n)
        case .uint(let n): return Int(exactly: n)
        default: return nil
        }
    }

    var uint64Value: UInt64? {
        switch self {
        case .int(let n): return n >= 0 ? UInt64(n) : nil
        case .uint(let n): return n
        default: return nil
        }
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var binaryValue: Data? {
        if case .binary(let d) = self { return d }
        return nil
    }

    var arrayValue: [MsgPackValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var mapValue: [String: MsgPackValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    subscript(key: String) -> MsgPackValue? { mapValue?[key] }
}

public enum MsgPackError: Error, Equatable, CustomStringConvertible {
    case truncated
    case trailingBytes(Int)
    case unsupportedType(UInt8)
    case invalidUTF8
    case nonStringMapKey

    public var description: String {
        switch self {
        case .truncated: return "msgpack: truncated input"
        case .trailingBytes(let n): return "msgpack: \(n) trailing bytes after value"
        case .unsupportedType(let b): return String(format: "msgpack: unsupported type byte 0x%02x", b)
        case .invalidUTF8: return "msgpack: string is not valid UTF-8"
        case .nonStringMapKey: return "msgpack: map key is not a string"
        }
    }
}

public enum MsgPack {
    public static func encode(_ value: MsgPackValue) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    public static func decode(_ data: Data) throws -> MsgPackValue {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.readValue()
        guard reader.remaining == 0 else { throw MsgPackError.trailingBytes(reader.remaining) }
        return value
    }

    // MARK: - Encoding

    private static func append(_ value: MsgPackValue, to out: inout Data) {
        switch value {
        case .nil:
            out.append(0xc0)
        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)
        case .int(let n):
            if n >= 0 {
                appendUInt(UInt64(n), to: &out)
            } else {
                appendNegative(n, to: &out)
            }
        case .uint(let n):
            appendUInt(n, to: &out)
        case .double(let d):
            out.append(0xcb)
            appendBE(d.bitPattern, to: &out)
        case .string(let s):
            let utf8 = Array(s.utf8)
            switch utf8.count {
            case ..<32:
                out.append(0xa0 | UInt8(utf8.count))
            case ..<0x100:
                out.append(0xd9)
                out.append(UInt8(utf8.count))
            case ..<0x1_0000:
                out.append(0xda)
                appendBE(UInt16(utf8.count), to: &out)
            default:
                out.append(0xdb)
                appendBE(UInt32(utf8.count), to: &out)
            }
            out.append(contentsOf: utf8)
        case .binary(let d):
            switch d.count {
            case ..<0x100:
                out.append(0xc4)
                out.append(UInt8(d.count))
            case ..<0x1_0000:
                out.append(0xc5)
                appendBE(UInt16(d.count), to: &out)
            default:
                out.append(0xc6)
                appendBE(UInt32(d.count), to: &out)
            }
            out.append(d)
        case .array(let items):
            switch items.count {
            case ..<16:
                out.append(0x90 | UInt8(items.count))
            case ..<0x1_0000:
                out.append(0xdc)
                appendBE(UInt16(items.count), to: &out)
            default:
                out.append(0xdd)
                appendBE(UInt32(items.count), to: &out)
            }
            for item in items { append(item, to: &out) }
        case .map(let entries):
            switch entries.count {
            case ..<16:
                out.append(0x80 | UInt8(entries.count))
            case ..<0x1_0000:
                out.append(0xde)
                appendBE(UInt16(entries.count), to: &out)
            default:
                out.append(0xdf)
                appendBE(UInt32(entries.count), to: &out)
            }
            for (key, item) in entries {
                append(.string(key), to: &out)
                append(item, to: &out)
            }
        }
    }

    private static func appendUInt(_ n: UInt64, to out: inout Data) {
        switch n {
        case ..<0x80:
            out.append(UInt8(n))
        case ..<0x100:
            out.append(0xcc)
            out.append(UInt8(n))
        case ..<0x1_0000:
            out.append(0xcd)
            appendBE(UInt16(n), to: &out)
        case ..<0x1_0000_0000:
            out.append(0xce)
            appendBE(UInt32(n), to: &out)
        default:
            out.append(0xcf)
            appendBE(n, to: &out)
        }
    }

    private static func appendNegative(_ n: Int64, to out: inout Data) {
        switch n {
        case (-32)...:
            out.append(UInt8(truncatingIfNeeded: n))
        case (-0x80)...:
            out.append(0xd0)
            out.append(UInt8(bitPattern: Int8(n)))
        case (-0x8000)...:
            out.append(0xd1)
            appendBE(UInt16(bitPattern: Int16(n)), to: &out)
        case (-0x8000_0000)...:
            out.append(0xd2)
            appendBE(UInt32(bitPattern: Int32(n)), to: &out)
        default:
            out.append(0xd3)
            appendBE(UInt64(bitPattern: n), to: &out)
        }
    }

    private static func appendBE<T: FixedWidthInteger>(_ n: T, to out: inout Data) {
        withUnsafeBytes(of: n.bigEndian) { out.append(contentsOf: $0) }
    }

    // MARK: - Decoding

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var remaining: Int { bytes.count - index }

        mutating func readByte() throws -> UInt8 {
            guard index < bytes.count else { throw MsgPackError.truncated }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func readBytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard remaining >= n else { throw MsgPackError.truncated }
            defer { index += n }
            return bytes[index..<index + n]
        }

        mutating func readBE(_ width: Int) throws -> UInt64 {
            let slice = try readBytes(width)
            var v: UInt64 = 0
            for b in slice { v = (v << 8) | UInt64(b) }
            return v
        }

        mutating func readString(_ length: Int) throws -> String {
            let slice = try readBytes(length)
            guard let s = String(bytes: slice, encoding: .utf8) else { throw MsgPackError.invalidUTF8 }
            return s
        }

        mutating func readValue() throws -> MsgPackValue {
            let b = try readByte()
            switch b {
            case 0x00...0x7f:
                return .int(Int64(b))
            case 0x80...0x8f:
                return try readMap(count: Int(b & 0x0f))
            case 0x90...0x9f:
                return try readArray(count: Int(b & 0x0f))
            case 0xa0...0xbf:
                return .string(try readString(Int(b & 0x1f)))
            case 0xc0:
                return .nil
            case 0xc2:
                return .bool(false)
            case 0xc3:
                return .bool(true)
            case 0xc4:
                return .binary(Data(try readBytes(Int(try readBE(1)))))
            case 0xc5:
                return .binary(Data(try readBytes(Int(try readBE(2)))))
            case 0xc6:
                return .binary(Data(try readBytes(Int(try readBE(4)))))
            case 0xca:
                return .double(Double(Float(bitPattern: UInt32(try readBE(4)))))
            case 0xcb:
                return .double(Double(bitPattern: try readBE(8)))
            case 0xcc:
                return .int(Int64(try readBE(1)))
            case 0xcd:
                return .int(Int64(try readBE(2)))
            case 0xce:
                return .int(Int64(try readBE(4)))
            case 0xcf:
                let v = try readBE(8)
                return v <= UInt64(Int64.max) ? .int(Int64(v)) : .uint(v)
            case 0xd0:
                return .int(Int64(Int8(bitPattern: UInt8(try readBE(1)))))
            case 0xd1:
                return .int(Int64(Int16(bitPattern: UInt16(try readBE(2)))))
            case 0xd2:
                return .int(Int64(Int32(bitPattern: UInt32(try readBE(4)))))
            case 0xd3:
                return .int(Int64(bitPattern: try readBE(8)))
            case 0xd9:
                return .string(try readString(Int(try readBE(1))))
            case 0xda:
                return .string(try readString(Int(try readBE(2))))
            case 0xdb:
                return .string(try readString(Int(try readBE(4))))
            case 0xdc:
                return try readArray(count: Int(try readBE(2)))
            case 0xdd:
                return try readArray(count: Int(try readBE(4)))
            case 0xde:
                return try readMap(count: Int(try readBE(2)))
            case 0xdf:
                return try readMap(count: Int(try readBE(4)))
            case 0xe0...0xff:
                return .int(Int64(Int8(bitPattern: b)))
            default:
                // 0xc1 (never used) and the ext family (unneeded by the protocol)
                throw MsgPackError.unsupportedType(b)
            }
        }

        mutating func readArray(count: Int) throws -> MsgPackValue {
            var items: [MsgPackValue] = []
            items.reserveCapacity(min(count, 4096))
            for _ in 0..<count { items.append(try readValue()) }
            return .array(items)
        }

        mutating func readMap(count: Int) throws -> MsgPackValue {
            var entries: [String: MsgPackValue] = [:]
            entries.reserveCapacity(min(count, 4096))
            for _ in 0..<count {
                guard case .string(let key) = try readValue() else { throw MsgPackError.nonStringMapKey }
                entries[key] = try readValue()
            }
            return .map(entries)
        }
    }
}
