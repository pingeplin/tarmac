import XCTest

@testable import TarmacKit

final class MapReaderTests: XCTestCase {
    private func assertThrows<T>(
        _ read: @autoclosure () throws -> T, _ expected: MessageError, line: UInt = #line
    ) {
        XCTAssertThrowsError(try read(), line: line) { error in
            XCTAssertEqual(error as? MessageError, expected, line: line)
        }
    }

    private let fields = MapReader(["s": .string("a"), "n": .int(7), "none": .nil, "big": .int(Int64(UInt32.max) + 1)])

    func testAPresentFieldOfTheRightTypeIsRead() throws {
        XCTAssertEqual(try fields.req("s", \.stringValue), "a")
        XCTAssertEqual(try fields.opt("n", \.intValue), 7)
        XCTAssertEqual(try fields.uint32("n"), 7)
    }

    func testAMissingOrNilFieldIsMissingWhenRequiredAndNilWhenOptional() throws {
        assertThrows(try fields.req("absent", \.stringValue), .missingField("absent"))
        assertThrows(try fields.req("none", \.stringValue), .missingField("none"))
        XCTAssertNil(try fields.opt("absent", \.stringValue))
        XCTAssertNil(try fields.opt("none", \.stringValue))
        XCTAssertNil(try fields.uint32("none"))
    }

    func testAMistypedFieldIsBadRequiredOrNot() {
        assertThrows(try fields.req("n", \.stringValue), .badField("n"))
        assertThrows(try fields.opt("s", \.intValue), .badField("s"))
        assertThrows(try fields.uint32("s"), .badField("s"))
    }

    func testANumberOutsideU32IsBad() {
        assertThrows(try fields.uint32("big"), .badField("big"))
        assertThrows(try MapReader(["n": .int(-1)]).uint32("n"), .badField("n"))
    }

    func testThePrefixGoesBeforeTheKeyInEveryError() {
        let tile = MapReader(["x": .string("1"), "z": .int(-1)], prefix: "tiles.")
        assertThrows(try tile.req("kind", \.stringValue), .missingField("tiles.kind"))
        assertThrows(try tile.opt("x", \.doubleValue), .badField("tiles.x"))
        assertThrows(try tile.uint32("z"), .badField("tiles.z"))
    }

    func testOnlyAMapIsRead() throws {
        assertThrows(try MapReader(.array([])), .notAMap)
        XCTAssertEqual(try MapReader(.map(["s": .string("a")])).req("s", \.stringValue), "a")
    }
}
