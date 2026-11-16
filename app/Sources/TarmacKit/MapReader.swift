/// Keyed reads off one decoded map, under the protocol's rules: any key order,
/// unknown keys ignored, an explicit nil the same as a missing key. `prefix`
/// goes before the key in the error a read throws.
struct MapReader {
    let map: [String: MsgPackValue]
    let prefix: String

    init(_ map: [String: MsgPackValue], prefix: String = "") {
        self.map = map
        self.prefix = prefix
    }

    init(_ value: MsgPackValue) throws {
        guard let map = value.mapValue else { throw MessageError.notAMap }
        self.init(map)
    }

    func req<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T {
        guard let value = try opt(key, extract) else { throw MessageError.missingField(prefix + key) }
        return value
    }

    func opt<T>(_ key: String, _ extract: (MsgPackValue) -> T?) throws -> T? {
        guard let raw = map[key], !raw.isNil else { return nil }
        guard let value = extract(raw) else { throw MessageError.badField(prefix + key) }
        return value
    }

    /// The Rust wire type is `u32`.
    func uint32(_ key: String) throws -> Int? {
        guard let value = try opt(key, \.intValue) else { return nil }
        guard UInt32(exactly: value) != nil else { throw MessageError.badField(prefix + key) }
        return value
    }
}
