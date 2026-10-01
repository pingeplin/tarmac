import XCTest
@testable import TarmacKit

/// The one call a scheme handler makes. Ports `lib.rs`'s `respond_card_scheme`
/// tests, and pins what Tauri's stack does before that function runs: wry parses
/// the URL with `http::Uri`, which drops a `#fragment` that a WKURLSchemeTask keeps.
final class CardSchemeRouterTests: XCTestCase {
    private let shim = "/*shim*/"

    private func respond(_ url: String, disk: SchemeFixtures.Disk = .init()) -> CardProtocol.Response {
        CardSchemeRouter.respond(url: url, shim: shim, read: disk.read)
    }

    private func text(_ response: CardProtocol.Response) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    /// S18
    func testTheImgHostRoutesToTheImageHandler() {
        let path = "/tmp/s18.png"
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])
        let resp = respond(SchemeFixtures.imgURI(path), disk: .init([path: bytes]))

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "image/png")
        XCTAssertEqual(resp.body, bytes)
        XCTAssertEqual(
            CardSchemeRouter.route(url: SchemeFixtures.imgURI(path)),
            .image(.read(path: path, contentType: "image/png"))
        )
    }

    /// S18
    func testTheDocHostRoutesToTheCardHandler() {
        let path = "/tmp/s18.html"
        let resp = respond(SchemeFixtures.docURI(path), disk: .init([path: Data("<html>s18</html>".utf8)]))

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(resp.headers["Content-Security-Policy"], CardProtocol.csp)
        XCTAssertTrue(text(resp).hasPrefix("<script>"))
        XCTAssertEqual(CardSchemeRouter.route(url: SchemeFixtures.docURI(path)), .doc(.read(path: path)))
    }

    /// S18
    func testAnUnknownHostIsAnsweredWith400ByTheCardHandler() {
        let resp = respond("tarmac-card://other/x")

        XCTAssertEqual(resp.status, 400)
        guard case .doc(.reject) = CardSchemeRouter.route(url: "tarmac-card://other/x") else {
            return XCTFail("an unknown host must be the card handler's 400")
        }
    }

    func testAnImgURLIsNeverAnsweredAsHTML() {
        let path = "/tmp/a.html"
        let resp = respond(SchemeFixtures.imgURI(path), disk: .init([path: Data("CONTENTS".utf8)]))

        XCTAssertEqual(resp.status, 403)
        XCTAssertFalse(text(resp).contains("CONTENTS"))
    }

    /// `String.hasPrefix` compares by grapheme, so `/` plus a combining mark is not
    /// the prefix's `/` — and the host would be sent to the wrong handler.
    func testHostsAreMatchedOnBytes() {
        XCTAssertEqual(
            CardSchemeRouter.route(url: "tarmac-card://img/\u{301}x.png"),
            .image(.read(path: "\u{301}x.png", contentType: "image/png"))
        )
        XCTAssertEqual(
            CardSchemeRouter.route(url: "tarmac-card://doc/\u{301}x.html"),
            .doc(.read(path: "\u{301}x.html"))
        )
    }

    func testARejectionNeverReadsTheDisk() {
        let disk = SchemeFixtures.Disk()
        for url in ["tarmac-card://other/x", "tarmac-card://doc/%FF", "tarmac-card://img/%2Ftmp%2Fa.html", "tarmac-card://img/%FF"] {
            XCTAssertGreaterThanOrEqual(respond(url, disk: disk).status, 400, url)
        }
        XCTAssertEqual(disk.opened, [])
    }

    func testAReadFailureIs404OnBothHosts() {
        for url in [SchemeFixtures.docURI("/tmp/a.html"), SchemeFixtures.imgURI("/tmp/a.png")] {
            XCTAssertEqual(respond(url).status, 404, url)
        }
    }

    /// Tauri's `http::Uri` cuts at the first `#`; a WKURLSchemeTask URL keeps it, so
    /// without the cut `a.png#frag` is a 403 and `a.html#frag` names the wrong file.
    func testAFragmentOnAnImageURLDoesNotHideItsExtension() {
        let path = "/tmp/a.png"
        let disk = SchemeFixtures.Disk([path: Data([1, 2])])
        let resp = respond("tarmac-card://img/\(SchemeFixtures.encoded(path))#frag", disk: disk)

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "image/png")
        XCTAssertEqual(disk.opened, [path])
    }

    func testAFragmentOnADocURLIsNotPartOfTheFileName() {
        let path = "/tmp/a.html"
        let disk = SchemeFixtures.Disk([path: Data("<html/>".utf8)])
        let resp = respond("tarmac-card://doc/\(SchemeFixtures.encoded(path))#frag", disk: disk)

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(disk.opened, [path])
    }

    func testAFragmentIsCutWhereverItSitsAmongTheQuery() {
        let path = "/tmp/a.html"
        let enc = SchemeFixtures.encoded(path)
        for url in ["tarmac-card://doc/\(enc)?v=1#frag", "tarmac-card://doc/\(enc)#frag?v=1", "tarmac-card://doc/\(enc)#a#b"] {
            XCTAssertEqual(CardSchemeRouter.route(url: url), .doc(.read(path: path)), url)
        }
    }

    /// `%23` is a path character, in Rust as here; only a bare `#` starts a fragment.
    func testAnEncodedHashInAFileNameSurvivesWithOrWithoutAFragment() {
        for (host, name) in [("doc", "a#b.html"), ("img", "a#b.png")] {
            let path = "/tmp/\(name)"
            let url = "tarmac-card://\(host)/\(SchemeFixtures.encoded(path))"
            for candidate in [url, "\(url)#frag", "\(url)?v=1#frag"] {
                let disk = SchemeFixtures.Disk([path: Data([1])])
                XCTAssertEqual(respond(candidate, disk: disk).status, 200, candidate)
                XCTAssertEqual(disk.opened, [path], candidate)
            }
        }
    }

    func testAURLWithOnlyAFragmentAfterTheHostIsAnEmptyPath() {
        XCTAssertEqual(respond("tarmac-card://doc/#x").status, 400)
        XCTAssertEqual(respond("tarmac-card://img/#x").status, 400)
    }

    func testTheFragmentCutMatchesRustsURIRowForRow() {
        for (url, seen) in SchemeParityTables.tauriURI {
            XCTAssertEqual(CardSchemeRouter.withoutFragment(url), seen, url)
            XCTAssertEqual(CardSchemeRouter.route(url: url), CardSchemeRouter.route(url: seen), url)
        }
    }
}
