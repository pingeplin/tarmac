import XCTest
@testable import TarmacKit

/// Ports every `#[test]` of `desktop/src-tauri/src/card_protocol.rs`, plus the
/// places Foundation's String and URL would silently answer differently from the
/// Rust byte handling.
final class CardProtocolTests: XCTestCase {
    private let shim = "/*shim*/"

    private func serve(_ uri: String, disk: SchemeFixtures.Disk = .init()) -> CardProtocol.Response {
        switch CardProtocol.resolve(uri: uri) {
        case .reject(let response):
            return response
        case .read(let path):
            return CardProtocol.respond(path: path, contents: disk.read(path), shim: shim)
        }
    }

    private func range(of needle: [UInt8], in body: Data) -> Int? {
        body.range(of: Data(needle))?.lowerBound
    }

    /// S3
    func testCSPIsByteExact() {
        XCTAssertEqual(
            CardProtocol.csp,
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"
        )
    }

    /// S9
    func testShimPrecedesDoctypeContent() throws {
        let path = "/tmp/doctype.html"
        let file = Data("<!DOCTYPE html><html></html>".utf8)
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: file]))

        XCTAssertEqual(resp.status, 200)
        let shimPos = try XCTUnwrap(range(of: Array("<script>".utf8), in: resp.body))
        let doctypePos = try XCTUnwrap(range(of: Array("<!DOCTYPE html>".utf8), in: resp.body))
        XCTAssertLessThan(shimPos, doctypePos)
    }

    /// S9
    func testShimPrecedesBomContent() throws {
        let path = "/tmp/bom.html"
        let file = Data([0xEF, 0xBB, 0xBF] + Array("<html>bom</html>".utf8))
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: file]))

        XCTAssertEqual(resp.status, 200)
        let shimPos = try XCTUnwrap(range(of: Array("<script>".utf8), in: resp.body))
        let bomPos = try XCTUnwrap(range(of: [0xEF, 0xBB, 0xBF], in: resp.body))
        XCTAssertLessThan(shimPos, bomPos)
        XCTAssertEqual(resp.headers["Content-Security-Policy"], CardProtocol.csp)
        XCTAssertEqual(resp.headers["Content-Type"], "text/html; charset=utf-8")
    }

    func testBodyIsTheShimInAScriptTagThenTheFileBytesUntouched() {
        let path = "/tmp/a.html"
        let file = Data([0x3C, 0xFF, 0x00, 0x3E])
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: file]))

        XCTAssertEqual(resp.body, Data("<script>/*shim*/</script>\n".utf8) + file)
    }

    func testTheOnlyHeadersOfASuccessAreTypeAndCSP() {
        let path = "/tmp/a.html"
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: Data("x".utf8)]))

        XCTAssertEqual(resp.headers, [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": CardProtocol.csp,
        ])
    }

    func testResolveNamesThePathToRead() {
        XCTAssertEqual(CardProtocol.resolve(uri: "tarmac-card://doc/%2Ftmp%2Fa.html?v=1"), .read(path: "/tmp/a.html"))
    }

    /// S8
    func testRoundTripsExoticFilename() throws {
        let path = "/var/folders/zz/T/tarmac-card-test-1-spaces-CJK-圖表-percent%25-hash#-q?-19"
        let uri = "tarmac-card://doc/\(SchemeFixtures.encoded(path))?v=99"

        XCTAssertEqual(try CardProtocol.decodeSchemePath(uri, prefix: CardProtocol.uriPrefix).get(), path)

        let resp = serve(uri, disk: .init([path: Data("<html>exotic</html>".utf8)]))
        XCTAssertEqual(resp.status, 200)
        XCTAssertNotNil(resp.body.range(of: Data("exotic".utf8)))
    }

    /// S15
    func testMissingFileIs404WithNoShim() throws {
        let path = "/tmp/tarmac-card-test-does-not-exist.html"
        let disk = SchemeFixtures.Disk()
        let resp = serve(SchemeFixtures.docURI(path), disk: disk)

        XCTAssertEqual(disk.opened, [path])
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(resp.headers, ["Content-Type": "text/plain; charset=utf-8"])
        let body = String(decoding: resp.body, as: UTF8.self)
        XCTAssertTrue(body.contains(path))
        XCTAssertFalse(body.contains("<script>"))
    }

    func testTheReadErrorIsNamedAfterThePathInTheBody() {
        struct Boom: LocalizedError { var errorDescription: String? { "disk on fire" } }
        let resp = CardProtocol.respond(path: "/tmp/a.html", contents: .failure(Boom()), shim: shim)

        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(String(decoding: resp.body, as: UTF8.self), "/tmp/a.html: disk on fire")
    }

    /// S16
    func testEmptyPathIs400() {
        XCTAssertEqual(serve("tarmac-card://doc/?v=1").status, 400)
    }

    /// S16
    func testNonUTF8PercentSequenceIs400() {
        XCTAssertEqual(serve("tarmac-card://doc/%FF?v=1").status, 400)
    }

    /// S16
    func testWrongShapeURIIs400() {
        XCTAssertEqual(serve("https://doc/foo.html").status, 400)
        XCTAssertEqual(serve("tarmac-card://other/foo.html").status, 400)
        XCTAssertEqual(serve("tarmac-card://doc").status, 400)
    }

    func testARejectionIsPlainTextNamingWhyAndNeverReadsTheDisk() {
        let disk = SchemeFixtures.Disk()
        let resp = serve("tarmac-card://doc/%FF?v=1", disk: disk)

        XCTAssertEqual(resp.headers, ["Content-Type": "text/plain; charset=utf-8"])
        XCTAssertEqual(
            String(decoding: resp.body, as: UTF8.self),
            "invalid UTF-8 in path: invalid utf-8 sequence of 1 bytes from index 0"
        )
        XCTAssertEqual(disk.opened, [])
    }

    func testAPathWithANulByteIsNeverReadAndAnswers404LikeStdFileOpen() {
        let disk = SchemeFixtures.Disk()
        let resp = serve("tarmac-card://doc/%2Ftmp%2Fa.html%00junk?v=1", disk: disk)

        XCTAssertEqual(disk.opened, [])
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(
            String(decoding: resp.body, as: UTF8.self),
            "/tmp/a.html\0junk: file name contained an unexpected NUL byte"
        )
    }

    /// Rows are Rust's own answers: Foundation's `split` drops the empty slice
    /// before a leading `?`, its `removingPercentEncoding` rejects a stray `%`,
    /// its `hasPrefix` compares by grapheme and so refuses a path that opens with
    /// a combining mark, and its `lowercased` is not ASCII-only. None may leak in.
    func testDecodeMatchesRustRowForRow() {
        for (prefix, uri, expected) in SchemeParityTables.decode {
            switch (CardProtocol.decodeSchemePath(uri, prefix: prefix), expected) {
            case (.success(let path), .ok(let want)):
                XCTAssertEqual(SchemeFixtures.bytes(path), SchemeFixtures.bytes(want), uri)
            case (.failure(let error), .err(let want)):
                XCTAssertEqual(error.message, want, uri)
            case (let got, _):
                XCTFail("\(uri): got \(got), want \(expected)")
            }
        }
    }

    /// `cardSrcUrl` is `encodeURIComponent`, which leaves `-_.!~*'()` raw.
    func testAnEncodeURIComponentShapedURLDecodesToTheWholePath() throws {
        let uri = "tarmac-card://doc/%2FUsers%2Fme%2Fmy-doc_v1.2%20(draft)!~*'.html?v=1700000000000"

        XCTAssertEqual(CardProtocol.resolve(uri: uri), .read(path: "/Users/me/my-doc_v1.2 (draft)!~*'.html"))
    }

    func testAHashIsPartOfThePathAndOnlyTheFirstQuestionMarkEndsIt() throws {
        XCTAssertEqual(CardProtocol.resolve(uri: "tarmac-card://doc/a#b?v=1?x"), .read(path: "a#b"))
        XCTAssertEqual(CardProtocol.resolve(uri: "tarmac-card://doc/a%23b%3Fc?v=1"), .read(path: "a#b?c"))
    }

    /// The host feeds `request.url.absoluteString`; Foundation re-encodes what it
    /// finds unencoded (space, non-ASCII, a bare `%`) and the path must survive.
    /// Not `%%41`: when any `%` is malformed Foundation re-encodes every `%` in the
    /// URL, valid escapes included, so `%41` reaches the decoder as the literal
    /// text `%41`. `encodeURIComponent` never emits a bare `%`, so no URL the app
    /// builds can hit it.
    func testFoundationURLAbsoluteStringDecodesToTheSamePathAsTheRawString() throws {
        let rewrittenByFoundation: Set<String> = ["tarmac-card://doc/%%41"]
        var checked = 0
        defer { XCTAssertGreaterThan(checked, 30) }
        for (prefix, uri, expected) in SchemeParityTables.decode {
            guard prefix == CardProtocol.uriPrefix, !rewrittenByFoundation.contains(uri), let url = URL(string: uri) else { continue }
            checked += 1
            let viaURL = CardProtocol.decodeSchemePath(url.absoluteString, prefix: prefix)
            switch (viaURL, expected) {
            case (.success(let path), .ok(let want)):
                XCTAssertEqual(SchemeFixtures.bytes(path), SchemeFixtures.bytes(want), uri)
            case (.failure, .err):
                break
            case (let got, _):
                XCTFail("\(uri): got \(got), want \(expected)")
            }
        }
    }
}
