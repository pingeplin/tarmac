import Foundation

/// The `tarmac-card://img/` host (spec 2609.0014): local image bytes for markdown
/// doc cards, as `desktop/src-tauri/src/image_protocol.rs` serves them. Pure — the
/// host reads the file between `resolve` and `respond`.
///
/// The extension allowlist is the boundary, not a convenience: markdown passes raw
/// `<iframe>` through, so a doc can frame this host. Nothing here is ever answered
/// as `text/html`; every 200 also carries `Content-Security-Policy: sandbox`, so a
/// framed or navigated SVG runs no script, and `nosniff`, so a format WebKit cannot
/// decode is never re-sniffed as HTML.
///
/// Same filesystem trust model as `CardProtocol`: the path is used as named, no
/// canonicalization, no jail. The extension is judged on that path's text — a
/// symlink is followed on open, and its target's extension is never looked at.
public enum ImageProtocol {
    public static let uriPrefix = "tarmac-card://img/"

    public enum Resolution: Equatable, Sendable {
        /// Read `path` as given and pass the bytes to `respond` with `contentType`.
        case read(path: String, contentType: String)
        case reject(CardProtocol.Response)
    }

    /// Whether `uri` addresses this host. Anything else belongs to `CardProtocol`,
    /// which answers an unknown host 400.
    public static func owns(uri: String) -> Bool {
        uri.utf8.starts(with: uriPrefix.utf8)
    }

    /// The Appendix A type for `path`'s extension (`Path::extension` semantics,
    /// ASCII case-insensitive), or `nil` for an unlisted or missing extension.
    public static func contentType(forPath path: String) -> String? {
        RustPathExtension.of(path).flatMap { byExtension[asciiLowercased($0)] }
    }

    /// 400 on an undecodable URI, 403 on an unlisted extension (before the file is
    /// opened), otherwise the path to read.
    public static func resolve(uri: String) -> Resolution {
        let path: String
        switch CardProtocol.decodeSchemePath(uri, prefix: uriPrefix) {
        case .failure(let error):
            return .reject(CardProtocol.textResponse(status: 400, body: error.message))
        case .success(let decoded):
            path = decoded
        }
        guard let contentType = contentType(forPath: path) else {
            return .reject(CardProtocol.textResponse(status: 403, body: "\(path): not a supported image type"))
        }
        if let nul = CardProtocol.rejectingNul(path: path) { return .reject(nul) }
        return .read(path: path, contentType: contentType)
    }

    /// 404 if the file could not be read, otherwise 200 with its bytes untouched.
    public static func respond(path: String, contentType: String, contents: Result<Data, any Error>) -> CardProtocol.Response {
        switch contents {
        case .failure(let error):
            return CardProtocol.unreadable(path: path, reason: error.localizedDescription)
        case .success(let bytes):
            return CardProtocol.Response(
                status: 200,
                headers: [
                    "Content-Type": contentType,
                    "Content-Security-Policy": "sandbox",
                    "X-Content-Type-Options": "nosniff",
                ],
                body: bytes
            )
        }
    }

    private static let byExtension: [[UInt8]: String] = Dictionary(
        imageTypes.map { (Array($0.ext.utf8), $0.type) },
        uniquingKeysWith: { first, _ in first }
    )

    /// `eq_ignore_ascii_case`: A-Z only. `String.lowercased()` would also fold the
    /// Kelvin sign U+212A into `k`.
    private static func asciiLowercased(_ s: String) -> [UInt8] {
        s.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
    }

    /// Spec 2609.0014 Appendix A, derived from mimes.info/image and the IANA image
    /// registry by the spec's collision rule. Re-derive by that rule; don't hand-pick.
    static let imageTypes: [(ext: String, type: String)] = [
        ("apng", "image/apng"),
        ("art", "image/x-jg"),
        ("avci", "image/avci"),
        ("avcs", "image/avcs"),
        ("avif", "image/avif"),
        ("azv", "image/vnd.airzip.accelerator.azv"),
        ("b16", "image/vnd.pco.b16"),
        ("bm", "image/bmp"),
        ("bmp", "image/bmp"),
        ("btf", "image/prs.btif"),
        ("btif", "image/prs.btif"),
        ("djv", "image/vnd.djvu"),
        ("djvu", "image/vnd.djvu"),
        ("dpx", "image/dpx"),
        ("drle", "image/dicom-rle"),
        ("dwg", "image/vnd.dwg"),
        ("dxf", "image/vnd.dxf"),
        ("emf", "image/emf"),
        ("exr", "image/aces"),
        ("fbs", "image/vnd.fastbidsheet"),
        ("fif", "image/fif"),
        ("fits", "image/fits"),
        ("flo", "image/florian"),
        ("fpx", "image/vnd.fpx"),
        ("fst", "image/vnd.fst"),
        ("g3", "image/g3fax"),
        ("gif", "image/gif"),
        ("hdr", "image/vnd.radiance"),
        ("heic", "image/heic"),
        ("heics", "image/heic-sequence"),
        ("heif", "image/heif"),
        ("heifs", "image/heif-sequence"),
        ("hej2", "image/hej2k"),
        ("hif", "image/heif"),
        ("hsj2", "image/hsj2"),
        ("ico", "image/vnd.microsoft.icon"),
        ("ief", "image/ief"),
        ("iefs", "image/ief"),
        ("j2c", "image/j2c"),
        ("j2k", "image/j2c"),
        ("jfif", "image/jpeg"),
        ("jfif-tbnl", "image/jpeg"),
        ("jhc", "image/jphc"),
        ("jls", "image/jls"),
        ("jp2", "image/jp2"),
        ("jpe", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("jpf", "image/jpx"),
        ("jpg", "image/jpeg"),
        ("jpg2", "image/jp2"),
        ("jpgm", "image/jpm"),
        ("jph", "image/jph"),
        ("jpm", "image/jpm"),
        ("jps", "image/x-jps"),
        ("jpx", "image/jpx"),
        ("jut", "image/jutvision"),
        ("jxl", "image/jxl"),
        ("jxr", "image/jxr"),
        ("jxra", "image/jxrA"),
        ("jxrs", "image/jxrS"),
        ("jxs", "image/jxs"),
        ("jxsc", "image/jxsc"),
        ("jxsi", "image/jxsi"),
        ("jxss", "image/jxss"),
        ("ktx", "image/ktx"),
        ("ktx2", "image/ktx2"),
        ("mcf", "image/vasa"),
        ("mdi", "image/vnd.ms-modi"),
        ("mmr", "image/vnd.fujixerox.edmics-mmr"),
        ("nap", "image/naplps"),
        ("naplps", "image/naplps"),
        ("nif", "image/x-niff"),
        ("niff", "image/x-niff"),
        ("pbm", "image/x-portable-bitmap"),
        ("pct", "image/x-pict"),
        ("pcx", "image/vnd.zbrush.pcx"),
        ("pgb", "image/vnd.globalgraphics.pgb"),
        ("pgm", "image/x-portable-graymap"),
        ("pic", "image/vnd.radiance"),
        ("pict", "image/pict"),
        ("pm", "image/x-xpixmap"),
        ("png", "image/png"),
        ("pnm", "image/x-portable-anymap"),
        ("ppm", "image/x-portable-pixmap"),
        ("psd", "image/vnd.adobe.photoshop"),
        ("pti", "image/prs.pti"),
        ("qif", "image/x-quicktime"),
        ("qti", "image/x-quicktime"),
        ("qtif", "image/x-quicktime"),
        ("ras", "image/x-cmu-raster"),
        ("rast", "image/cmu-raster"),
        ("rf", "image/vnd.rn-realflash"),
        ("rgb", "image/x-rgb"),
        ("rgbe", "image/vnd.radiance"),
        ("rlc", "image/vnd.fujixerox.edmics-rlc"),
        ("rp", "image/vnd.rn-realpix"),
        ("s1g", "image/vnd.sealedmedia.softseal.gif"),
        ("s1j", "image/vnd.sealedmedia.softseal.jpg"),
        ("s1n", "image/vnd.sealed.png"),
        ("sgi", "image/vnd.sealedmedia.softseal.gif"),
        ("sgif", "image/vnd.sealedmedia.softseal.gif"),
        ("sjp", "image/vnd.sealedmedia.softseal.jpg"),
        ("sjpg", "image/vnd.sealedmedia.softseal.jpg"),
        ("spn", "image/vnd.sealed.png"),
        ("spng", "image/vnd.sealed.png"),
        ("sub", "image/vnd.dvb.subtitle"),
        ("svf", "image/vnd.dwg"),
        ("svg", "image/svg+xml"),
        ("t38", "image/t38"),
        ("tap", "image/vnd.tencent.tap"),
        ("tfx", "image/tiff-fx"),
        ("tif", "image/tiff"),
        ("tiff", "image/tiff"),
        ("turbot", "image/florian"),
        ("uvg", "image/vnd.dece.graphic"),
        ("uvi", "image/vnd.dece.graphic"),
        ("uvvg", "image/vnd.dece.graphic"),
        ("uvvi", "image/vnd.dece.graphic"),
        ("vtf", "image/vnd.valve.source.texture"),
        ("wbmp", "image/vnd.wap.wbmp"),
        ("webp", "image/webp"),
        ("wmf", "image/wmf"),
        ("x-png", "image/png"),
        ("xbm", "image/xbm"),
        ("xif", "image/vnd.xiff"),
        ("xpm", "image/xpm"),
        ("xwd", "image/x-xwd"),
        ("xyze", "image/vnd.radiance"),
    ]
}
