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

    private func text(_ response: CardProtocol.Response) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    /// S3
    func testCSPIsByteExact() {
        XCTAssertEqual(
            CardProtocol.csp,
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"
        )
    }

    /// S9
    func testTheShimFollowsALeadingDoctype() {
        let path = "/tmp/doctype.html"
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: Data("<!DOCTYPE html><html></html>".utf8)]))

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(text(resp), "<!DOCTYPE html><script>/*shim*/</script>\n<html></html>")
    }

    /// S10
    func testTheShimFollowsTheBomCommentAndDoctypeAheadOfTheContent() {
        let path = "/tmp/lead.html"
        let lead = Data([0xEF, 0xBB, 0xBF] + Array("<!-- n -->\n<!doctype html>".utf8))
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: lead + Data("<p>x</p>".utf8)]))

        XCTAssertEqual(text(resp), "\u{FEFF}<!-- n -->\n<!doctype html><script>/*shim*/</script>\n<p>x</p>")
        XCTAssertEqual(Array(resp.body.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    /// S11
    func testTheShimFollowsALeadingBomWhenThereIsNoDoctype() {
        let path = "/tmp/bom.html"
        let file = Data([0xEF, 0xBB, 0xBF] + Array("<html>bom</html>".utf8))
        let resp = serve(SchemeFixtures.docURI(path), disk: .init([path: file]))

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(text(resp), "\u{FEFF}<script>/*shim*/</script>\n<html>bom</html>")
        XCTAssertEqual(resp.headers["Content-Security-Policy"], CardProtocol.csp)
        XCTAssertEqual(resp.headers["Content-Type"], "text/html; charset=utf-8")
    }

    func testTheOffsetIsCountedFromTheStartOfASliceOfFile() {
        let file = Data("zz<!doctype html><p>x</p>".utf8)[2...]
        let resp = CardProtocol.respond(path: "/tmp/a.html", contents: .success(file), shim: "S")

        XCTAssertEqual(text(resp), "<!doctype html><script>S</script>\n<p>x</p>")
    }

    /// S14
    func testTheFilledFontValuesSitInsideTheScriptAfterTheDoctype() throws {
        let fonts = CardFontVariables(interfaceFamily: nil, documentFamily: nil, documentSize: 20)
        let filled = fonts.filling("const f=[\(CardFontVariables.marker)][0];")
        let file = Data("<!doctype html><p>x</p>".utf8)
        let resp = CardProtocol.respond(path: "/tmp/a.html", contents: .success(file), shim: filled)
        let body = String(decoding: resp.body, as: UTF8.self)

        XCTAssertEqual(body.components(separatedBy: fonts.json).count - 1, 1)
        let doctypeEnd = try XCTUnwrap(body.range(of: "<!doctype html>")).upperBound
        let open = try XCTUnwrap(body.range(of: "<script>"))
        let values = try XCTUnwrap(body.range(of: fonts.json))
        let close = try XCTUnwrap(body.range(of: "</script>"))
        XCTAssertEqual(open.lowerBound, doctypeEnd)
        XCTAssertTrue(open.upperBound <= values.lowerBound && values.upperBound <= close.lowerBound)
        XCTAssertEqual(body.components(separatedBy: "</script>").count - 1, 1)
        XCTAssertTrue(body.hasSuffix("</script>\n<p>x</p>"))
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

    /// `decode_scheme_path` itself keeps a bare `#` as path text. Tauri never shows
    /// it one — `CardSchemeRouter` cuts the fragment first and the visible
    /// behaviour is in `CardSchemeRouterTests` — so only `%23` names a `#` in a file.
    func testOnlyTheFirstQuestionMarkEndsThePathAndEncodedMarksStayInIt() throws {
        XCTAssertEqual(CardProtocol.resolve(uri: "tarmac-card://doc/a?b?c"), .read(path: "a"))
        XCTAssertEqual(CardProtocol.resolve(uri: "tarmac-card://doc/a%23b%3Fc?v=1"), .read(path: "a#b?c"))
        XCTAssertEqual(CardProtocol.resolve(uri: "tarmac-card://doc/a#b?v=1"), .read(path: "a#b"))
    }

    /// The host feeds `request.url.absoluteString`; `URL(string:)` re-encodes what
    /// it finds unencoded (space, non-ASCII, a bare `%`) and the path must survive.
    /// Not `%%41`: when any `%` is malformed `URL(string:)` re-encodes every `%` in
    /// the string, valid escapes included, so `%41` reaches the decoder as the
    /// literal text `%41`. WebKit's own parser (an iframe `src`) re-encodes only the
    /// bare `%` and matches Rust; and `encodeURIComponent` never emits a bare `%`,
    /// so no URL the app builds can hit it.
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
