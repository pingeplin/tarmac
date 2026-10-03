import XCTest
import TarmacKit

final class FramingTests: XCTestCase {
    func testFramePrependsBigEndianLength() throws {
        let payload = hexData("81 a1 74 a3 61 63 6b")
        let framed = try Framing.frame(payload)
        XCTAssertEqual(framed, hexData("00 00 00 07 81 a1 74 a3 61 63 6b"))
    }

    func testEmptyPayloadFrames() throws {
        XCTAssertEqual(try Framing.frame(Data()), Data([0, 0, 0, 0]))
        var decoder = Framing.StreamDecoder()
        decoder.append(Data([0, 0, 0, 0]))
        XCTAssertEqual(try decoder.nextFrame(), Data())
        XCTAssertNil(try decoder.nextFrame())
    }

    func testOversizedPayloadRefusesToFrame() {
        let oversized = Data(count: Framing.maxFrameLength + 1)
        XCTAssertThrowsError(try Framing.frame(oversized)) { error in
            XCTAssertEqual(error as? FramingError, .frameTooLarge(Framing.maxFrameLength + 1))
        }
    }

    func testExactly16MiBIsAllowed() throws {
        let payload = Data(count: Framing.maxFrameLength)
        let framed = try Framing.frame(payload)
        XCTAssertEqual(framed.count, Framing.maxFrameLength + 4)

        var decoder = Framing.StreamDecoder()
        decoder.append(framed)
        XCTAssertEqual(try decoder.nextFrame()?.count, Framing.maxFrameLength)
    }

    func testStreamDecoderReassemblesAcrossArbitraryChunks() throws {
        let one = try Framing.frame(Data("first".utf8))
        let two = try Framing.frame(Data("second-frame".utf8))
        var stream = one
        stream.append(two)

        var decoder = Framing.StreamDecoder()
        var frames: [Data] = []
        // Feed in 3-byte chunks so headers and payloads split across appends.
        var index = stream.startIndex
        while index < stream.endIndex {
            let next = stream.index(index, offsetBy: 3, limitedBy: stream.endIndex) ?? stream.endIndex
            decoder.append(stream[index..<next])
            while let frame = try decoder.nextFrame() {
                frames.append(frame)
            }
            index = next
        }
        XCTAssertEqual(frames, [Data("first".utf8), Data("second-frame".utf8)])
    }

    func testTwoFramesInOneAppend() throws {
        var decoder = Framing.StreamDecoder()
        var stream = try Framing.frame(Data([1, 2, 3]))
        stream.append(try Framing.frame(Data([4])))
        decoder.append(stream)
        XCTAssertEqual(try decoder.nextFrame(), Data([1, 2, 3]))
        XCTAssertEqual(try decoder.nextFrame(), Data([4]))
        XCTAssertNil(try decoder.nextFrame())
    }

    func testIncompleteHeaderYieldsNoFrame() throws {
        var decoder = Framing.StreamDecoder()
        decoder.append(Data([0, 0]))
        XCTAssertNil(try decoder.nextFrame())
    }

    func testOverCapHeaderIsAProtocolError() {
        var decoder = Framing.StreamDecoder()
        // 16 MiB + 1 = 0x01000001
        decoder.append(Data([0x01, 0x00, 0x00, 0x01]))
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? FramingError, .frameTooLarge(16 * 1024 * 1024 + 1))
        }
    }

    func testExactlyCapHeaderIsNotAnErrorJustIncomplete() throws {
        var decoder = Framing.StreamDecoder()
        // Header announcing exactly 16 MiB with no payload yet: legal, just incomplete.
        decoder.append(Data([0x01, 0x00, 0x00, 0x00]))
        XCTAssertNil(try decoder.nextFrame())
    }

    func testFramedConformanceVectorMatchesReconObservation() throws {
        // The recon report's framed vector 1: 00 00 00 07 81 a1 74 a3 61 63 6b
        var decoder = Framing.StreamDecoder()
        decoder.append(hexData("00 00 00 07 81 a1 74 a3 61 63 6b"))
        let frame = try XCTUnwrap(try decoder.nextFrame())
        XCTAssertEqual(try Message.decode(payload: frame), .ack)
    }
}
