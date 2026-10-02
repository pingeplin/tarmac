import XCTest
@testable import TarmacKit

/// Ports every `#[test]` of `desktop/src-tauri/src/image_protocol.rs` and the
/// scheme-dispatch tests of `lib.rs`.
final class ImageProtocolTests: XCTestCase {
    private let imageOnlyHeaders = ["Content-Security-Policy": "sandbox", "X-Content-Type-Options": "nosniff"]

    private func serve(_ uri: String, disk: SchemeFixtures.Disk = .init()) -> CardProtocol.Response {
        switch ImageProtocol.resolve(uri: uri) {
        case .reject(let response):
            return response
        case .read(let path, let contentType):
            return ImageProtocol.respond(path: path, contentType: contentType, contents: disk.read(path))
        }
    }

    private func text(_ response: CardProtocol.Response) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    /// S12: two types in one run, so a constant Content-Type fails.
    func testAReadableImageIsServedByteForByteWithItsTypeAndImageOnlyHeaders() {
        // PNG signature plus 0xFF, never valid UTF-8: a text path would mangle it.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFE])
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>".utf8)
        for (path, bytes, type) in [("/tmp/s12.png", png, "image/png"), ("/tmp/s12.svg", svg, "image/svg+xml")] {
            let resp = serve(SchemeFixtures.imgURI(path), disk: .init([path: bytes]))

            XCTAssertEqual(resp.status, 200, path)
            XCTAssertEqual(resp.body, bytes, path)
            XCTAssertEqual(resp.headers["Content-Type"], type, path)
            XCTAssertEqual(resp.headers["Content-Security-Policy"], "sandbox", path)
            XCTAssertEqual(resp.headers["X-Content-Type-Options"], "nosniff", path)
            XCTAssertNil(resp.headers["Access-Control-Allow-Origin"], path)
        }
    }

    func testTheOnlyHeadersOfASuccessAreTypeSandboxAndNosniff() {
        let path = "/tmp/a.png"
        let resp = serve(SchemeFixtures.imgURI(path), disk: .init([path: Data([1])]))

        XCTAssertEqual(resp.headers, imageOnlyHeaders.merging(["Content-Type": "image/png"]) { $1 })
    }

    /// S17
    func testAnExoticPngNameRoundTripsAsOneEncodedSegment() {
        let path = "/var/folders/zz/T/tarmac-img-test-1-s17 spaces 圖表 100% hash# q?.png"
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])
        let resp = serve(SchemeFixtures.imgURI(path), disk: .init([path: bytes]))

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.body, bytes)
    }

    /// S14: the extension is judged on the path, so a refused file is never opened.
    func testAReadableFileWithoutAnImageExtensionIs403AndNeverServed() {
        for name in ["s14.html", "s14.md", "s14.png.html", "s14-no-extension"] {
            let path = "/tmp/\(name)"
            let marker = "CONTENTS-OF-\(name)"
            let disk = SchemeFixtures.Disk([path: Data(marker.utf8)])
            let resp = serve(SchemeFixtures.imgURI(path), disk: disk)

            XCTAssertEqual(resp.status, 403, name)
            XCTAssertEqual(resp.headers, ["Content-Type": "text/plain; charset=utf-8"], name)
            XCTAssertFalse(text(resp).contains(marker), name)
            XCTAssertEqual(disk.opened, [], name)
        }
    }

    func testTheRefusalNamesThePathAndWhy() {
        XCTAssertEqual(
            text(serve(SchemeFixtures.imgURI("/tmp/a.html"))),
            "/tmp/a.html: not a supported image type"
        )
    }

    /// S15
    func testAMissingImageIs404NamingItsPathButAMissingHtmlIs403() {
        let png = "/tmp/tarmac-img-test-1-s15-missing.png"
        let html = "/tmp/tarmac-img-test-1-s15-missing.html"

        let resp = serve(SchemeFixtures.imgURI(png))
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(resp.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertTrue(text(resp).contains(png))

        XCTAssertEqual(serve(SchemeFixtures.imgURI(html)).status, 403)
    }

    func testTheReadErrorIsNamedAfterThePathInTheBody() {
        struct Boom: LocalizedError { var errorDescription: String? { "disk on fire" } }
        let resp = ImageProtocol.respond(path: "/tmp/a.png", contentType: "image/png", contents: .failure(Boom()))

        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(resp.headers, ["Content-Type": "text/plain; charset=utf-8"])
        XCTAssertEqual(text(resp), "/tmp/a.png: disk on fire")
    }

    /// S16
    func testAnUndecodableURIIs400PlainText() {
        for uri in ["tarmac-card://img/?v=1", "tarmac-card://img/%FF?v=1", "tarmac-card://doc/x.png?v=1"] {
            let resp = serve(uri)

            XCTAssertEqual(resp.status, 400, uri)
            XCTAssertEqual(resp.headers["Content-Type"], "text/plain; charset=utf-8", uri)
        }
    }

    /// std rejects the NUL in the open, after the extension check; a POSIX `open`
    /// would instead truncate at it and read a different file.
    func testAPathWithANulByteIsNeverReadAndAnswers404WhenItsExtensionIsListed() {
        let disk = SchemeFixtures.Disk()
        let resp = serve("tarmac-card://img/%2Ftmp%2Fa.png%00junk.png?v=1", disk: disk)

        XCTAssertEqual(disk.opened, [])
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(text(resp), "/tmp/a.png\0junk.png: file name contained an unexpected NUL byte")
    }

    func testANulByteAfterTheExtensionHidesIt() {
        XCTAssertEqual(serve("tarmac-card://img/%2Ftmp%2Fa.png%00?v=1").status, 403)
    }

    /// S13: the test keeps its own copy — iterating the production table would pass
    /// however wrong it is; only its row count is read from production.
    func testEveryAppendixAExtensionMapsToExactlyItsType() {
        XCTAssertEqual(SchemeParityTables.appendixA.count, 128)
        for (ext, type) in SchemeParityTables.appendixA {
            XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.\(ext)"), type, "extension \(ext)")
        }
        XCTAssertEqual(ImageProtocol.imageTypes.count, SchemeParityTables.appendixA.count)
    }

    /// S13
    func testExtensionMatchIgnoresCase() {
        XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.PNG"), "image/png")
        XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.JpEg"), "image/jpeg")
        XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.HEIC"), "image/heic")
        XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.X-PNG"), "image/png")
        XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.Svg"), "image/svg+xml")
    }

    /// S13
    func testANameWithoutAListedExtensionHasNoType() {
        for path in ["/d/x.png.txt", "/d/README", "/d/.png", "/d/x.", "/d/x.cgm"] {
            XCTAssertNil(ImageProtocol.contentType(forPath: path), path)
        }
    }

    /// `eq_ignore_ascii_case` folds A-Z only; Swift's `lowercased()` would map the
    /// Kelvin sign U+212A to `k` and serve `x.\u{212A}tx` as KTX.
    func testCaseFoldingIsASCIIOnly() {
        XCTAssertEqual(ImageProtocol.contentType(forPath: "/d/x.KTX"), "image/ktx")
        XCTAssertNil(ImageProtocol.contentType(forPath: "/d/x.\u{212A}tx"))
        XCTAssertNil(ImageProtocol.contentType(forPath: "/d/x.\u{17F}vg"))
    }

    func testContentTypeMatchesRustRowForRow() {
        for (path, _, contentType) in SchemeParityTables.extensions {
            XCTAssertEqual(ImageProtocol.contentType(forPath: path), contentType, path)
        }
    }

    func testOnlyTheImgHostIsOwnedByTheImageProtocol() {
        XCTAssertTrue(ImageProtocol.owns(uri: "tarmac-card://img/%2Fd%2Fx.png?v=1"))
        XCTAssertFalse(ImageProtocol.owns(uri: "tarmac-card://doc/%2Fd%2Fx.html?v=1"))
        XCTAssertFalse(ImageProtocol.owns(uri: "tarmac-card://img"))
        XCTAssertFalse(ImageProtocol.owns(uri: "tarmac-card://other/x"))
    }

    /// `String.hasPrefix` would not see the prefix's `/` once a combining mark follows it.
    func testTheHostPrefixIsMatchedOnBytes() {
        XCTAssertTrue(ImageProtocol.owns(uri: "tarmac-card://img/\u{301}x.png"))
    }

    func testImageHostURLsNeverResolveToTheCardHandler() {
        guard case .reject(let resp) = CardProtocol.resolve(uri: SchemeFixtures.imgURI("/tmp/a.png")) else {
            return XCTFail("the doc handler accepted an img URL")
        }
        XCTAssertEqual(resp.status, 400)
    }

    // MARK: - The file a name leads to

    private func serveFollowingLinks(_ path: String, disk: SchemeFixtures.Disk) -> CardProtocol.Response {
        ImageProtocol.respond(path: path, file: disk.resolve(path), read: disk.read)
    }

    /// A repo can hold `logo.png`, a symlink to a private key outside it. The
    /// name is an image's; the file is not, and it is never opened.
    func testASymlinkNamedLikeAnImageThatLeadsToAnotherKindOfFileIsRefused() {
        let key = "/Users/me/.ssh/id_rsa"
        let disk = SchemeFixtures.Disk([key: Data("PRIVATE KEY".utf8)], links: ["/repo/logo.png": key])
        let resp = serveFollowingLinks("/repo/logo.png", disk: disk)

        XCTAssertEqual(resp.status, 403)
        XCTAssertEqual(resp.headers, ["Content-Type": "text/plain; charset=utf-8"])
        XCTAssertEqual(text(resp), "/repo/logo.png: not a supported image type")
        XCTAssertEqual(disk.opened, [])
    }

    func testASymlinkToAFileWithNoExtensionIsRefused() {
        let disk = SchemeFixtures.Disk(["/etc/passwd": Data("root".utf8)], links: ["/repo/a.svg": "/etc/passwd"])

        XCTAssertEqual(serveFollowingLinks("/repo/a.svg", disk: disk).status, 403)
        XCTAssertEqual(disk.opened, [])
    }

    /// The file is what is read and typed, not the name that led to it.
    func testAnImageReachedThroughASymlinkIsServedAsTheFileItIs() {
        let photo = "/repo/assets/photo.jpg"
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let disk = SchemeFixtures.Disk([photo: bytes], links: ["/repo/logo.png": photo])
        let resp = serveFollowingLinks("/repo/logo.png", disk: disk)

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.body, bytes)
        XCTAssertEqual(resp.headers["Content-Type"], "image/jpeg")
        XCTAssertEqual(disk.opened, [photo])
    }

    func testAnImageThatIsNoSymlinkIsServedAsBefore() {
        let disk = SchemeFixtures.Disk(["/repo/a.png": Data([1])])
        let resp = serveFollowingLinks("/repo/a.png", disk: disk)

        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers, imageOnlyHeaders.merging(["Content-Type": "image/png"]) { $1 })
    }

    func testANameThatLeadsNowhereIs404NamingThePathAndWhy() {
        struct Loop: LocalizedError { var errorDescription: String? { "Too many levels of symbolic links (os error 62)" } }
        let disk = SchemeFixtures.Disk()
        let resp = ImageProtocol.respond(path: "/repo/loop.png", file: .failure(Loop()), read: disk.read)

        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(text(resp), "/repo/loop.png: Too many levels of symbolic links (os error 62)")
        XCTAssertEqual(disk.opened, [])
    }
}
