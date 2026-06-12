import Foundation

public enum FramingError: Error, Equatable, CustomStringConvertible {
    case frameTooLarge(Int)

    public var description: String {
        switch self {
        case .frameTooLarge(let n): return "framing: \(n)-byte frame exceeds the 16 MiB cap"
        }
    }
}

/// u32 big-endian length prefix, 16 MiB cap (docs/protocol.md "Framing").
public enum Framing {
    public static let maxFrameLength = 16 * 1024 * 1024

    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameLength else { throw FramingError.frameTooLarge(payload.count) }
        var out = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Incremental decoder for a byte stream: append arbitrary chunks, pull
    /// complete frames out. Throws on an over-cap length header (protocol error;
    /// the caller must close the connection).
    public struct StreamDecoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) {
            buffer.append(data)
        }

        public mutating func nextFrame() throws -> Data? {
            guard buffer.count >= 4 else { return nil }
            let s = buffer.startIndex
            let n = (UInt32(buffer[s]) << 24)
                | (UInt32(buffer[s + 1]) << 16)
                | (UInt32(buffer[s + 2]) << 8)
                | UInt32(buffer[s + 3])
            guard Int(n) <= Framing.maxFrameLength else { throw FramingError.frameTooLarge(Int(n)) }
            guard buffer.count >= 4 + Int(n) else { return nil }
            let payload = Data(buffer[(s + 4)..<(s + 4 + Int(n))])
            buffer = Data(buffer.dropFirst(4 + Int(n)))
            return payload
        }
    }
}
