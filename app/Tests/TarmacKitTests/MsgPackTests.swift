import XCTest
import TarmacKit

final class MsgPackTests: XCTestCase {
    private func roundTrip(_ value: MsgPackValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try MsgPack.decode(MsgPack.encode(value)), value, file: file, line: line)
    }

    func testIntegerBoundariesRoundTrip() {
        let values: [Int64] = [
            0, 1, 127, 128, 255, 256, 65_535, 65_536,
            4_294_967_295, 4_294_967_296, Int64.max,
            -1, -32, -33, -128, -129, -32_768, -32_769,
            -2_147_483_648, -2_147_483_649, Int64.min,
        ]
        for n in values { roundTrip(.int(n)) }
    }

    func testCompactIntegerEncodings() {
        XCTAssertEqual(MsgPack.encode(.int(1)), Data([0x01]))
        XCTAssertEqual(MsgPack.encode(.int(120)), Data([0x78]))
        XCTAssertEqual(MsgPack.encode(.int(200)), Data([0xcc, 0xc8]))
        XCTAssertEqual(MsgPack.encode(.int(-1)), Data([0xff]))
        XCTAssertEqual(MsgPack.encode(.int(-32)), Data([0xe0]))
        XCTAssertEqual(MsgPack.encode(.int(-33)), Data([0xd0, 0xdf]))
    }

    func testUIntAboveInt64MaxRoundTrips() {
        roundTrip(.uint(UInt64.max))
        // A uint64-encoded value that fits in Int64 decodes as .int.
        XCTAssertEqual(try MsgPack.decode(Data([0xcf, 0, 0, 0, 0, 0, 0, 0, 5])), .int(5))
    }

    func testDecodesAnyIntegerWidthToSameValue() throws {
        let encodings: [Data] = [
            Data([0x05]),                                  // fixint
            Data([0xcc, 0x05]),                            // uint8
            Data([0xcd, 0x00, 0x05]),                      // uint16
            Data([0xce, 0x00, 0x00, 0x00, 0x05]),          // uint32
            Data([0xd0, 0x05]),                            // int8
            Data([0xd1, 0x00, 0x05]),                      // int16
            Data([0xd2, 0x00, 0x00, 0x00, 0x05]),          // int32
            Data([0xd3, 0, 0, 0, 0, 0, 0, 0, 5]),          // int64
        ]
        for data in encodings {
            XCTAssertEqual(try MsgPack.decode(data), .int(5))
        }
    }

    func testNilBoolDouble() {
        roundTrip(.nil)
        roundTrip(.bool(true))
        roundTrip(.bool(false))
        roundTrip(.double(0))
        roundTrip(.double(-1234.5678))
        XCTAssertEqual(MsgPack.encode(.nil), Data([0xc0]))
        XCTAssertEqual(MsgPack.encode(.double(1.0)).first, 0xcb)
        // float32 input is accepted on decode.
        XCTAssertEqual(try MsgPack.decode(Data([0xca, 0x3f, 0x80, 0x00, 0x00])), .double(1.0))
    }

    func testStringFamilyBoundaries() {
        roundTrip(.string(""))
        roundTrip(.string("héllo wörld ⌘"))
        roundTrip(.string(String(repeating: "a", count: 31)))   // fixstr max
        roundTrip(.string(String(repeating: "b", count: 32)))   // str8
        roundTrip(.string(String(repeating: "c", count: 255)))
        roundTrip(.string(String(repeating: "d", count: 256)))  // str16
        roundTrip(.string(String(repeating: "e", count: 70_000))) // str32
        XCTAssertEqual(MsgPack.encode(.string("app")), Data([0xa3, 0x61, 0x70, 0x70]))
    }

    func testBinFamilyBoundaries() {
        roundTrip(.binary(Data()))
        roundTrip(.binary(Data([0x00, 0xff])))
        roundTrip(.binary(Data(repeating: 7, count: 255)))    // bin8 max
        roundTrip(.binary(Data(repeating: 8, count: 256)))    // bin16
        roundTrip(.binary(Data(repeating: 9, count: 70_000))) // bin32
        XCTAssertEqual(MsgPack.encode(.binary(Data([1, 2]))).prefix(2), Data([0xc4, 0x02]))
    }

    func testArrayAndMapFamilies() {
        roundTrip(.array([]))
        roundTrip(.array([.int(1), .string("two"), .nil, .bool(true)]))
        roundTrip(.array(Array(repeating: MsgPackValue.int(0), count: 20))) // array16
        roundTrip(.map([:]))
        roundTrip(.map(["k": .array([.map(["nested": .binary(Data([9]))])])]))
        var big: [String: MsgPackValue] = [:]
        for i in 0..<20 { big["k\(i)"] = .int(Int64(i)) } // map16
        roundTrip(.map(big))
    }

    func testTruncatedInputThrows() {
        XCTAssertThrowsError(try MsgPack.decode(Data())) // empty
        XCTAssertThrowsError(try MsgPack.decode(Data([0xa3, 0x61]))) // fixstr len 3, 1 byte
        XCTAssertThrowsError(try MsgPack.decode(Data([0xc4, 0x05, 0x01]))) // bin8 len 5, 1 byte
        XCTAssertThrowsError(try MsgPack.decode(Data([0x81, 0xa1, 0x74]))) // map missing value
    }

    func testTrailingBytesThrow() {
        XCTAssertThrowsError(try MsgPack.decode(Data([0xc0, 0x00]))) { error in
            XCTAssertEqual(error as? MsgPackError, .trailingBytes(1))
        }
    }

    func testNonStringMapKeyThrows() {
        // {1: 2}
        XCTAssertThrowsError(try MsgPack.decode(Data([0x81, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? MsgPackError, .nonStringMapKey)
        }
    }

    func testUnsupportedTypeBytesThrow() {
        XCTAssertThrowsError(try MsgPack.decode(Data([0xc1])))
        XCTAssertThrowsError(try MsgPack.decode(Data([0xd4, 0x00, 0x00]))) // fixext1
    }
}
