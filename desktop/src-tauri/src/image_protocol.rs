//! `tarmac-card://img/` host (spec 2609.0014): serves a local image file's
//! bytes to markdown doc cards, whose `<img src>` the frontend rewrites to
//! `tarmac-card://img/<url-encoded-abs-path>?v=<mtime_ms>` (`?v=` only busts
//! the cache).
//!
//! The extension allowlist is the boundary, not a convenience: marked passes
//! raw `<iframe>` through, so a doc can frame this host, and Tauri skips the
//! command ACL for pages on app-registered schemes. Nothing here is ever
//! answered as `text/html`. Every 200 also carries `Content-Security-Policy:
//! sandbox`, so a framed or navigated SVG runs no script, and `nosniff`, so a
//! format WebKit can't decode is never re-sniffed as HTML.
//!
//! Same filesystem trust model as `card_protocol.rs`: raw path, no
//! canonicalization, no jail.

use std::fs;
use std::path::Path;

use tauri::http::{Response, StatusCode};

use crate::card_protocol::{decode_scheme_path, text_response};

pub(crate) const URI_PREFIX: &str = "tarmac-card://img/";

/// Spec 2609.0014 Appendix A, derived from mimes.info/image and the IANA image
/// registry by the spec's collision rule. Re-derive by that rule; don't hand-pick.
const IMAGE_TYPES: &[(&str, &str)] = &[
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
];

/// The Appendix A type for `path`'s extension (`Path::extension` semantics,
/// ASCII case-insensitive), or `None` for an unlisted or missing extension.
pub fn image_content_type(path: &str) -> Option<&'static str> {
    let ext = Path::new(path).extension()?.to_str()?;
    IMAGE_TYPES.iter().find(|(e, _)| e.eq_ignore_ascii_case(ext)).map(|(_, ty)| *ty)
}

/// Serve one `tarmac-card://img/...` request: 400 on an undecodable URI, 403
/// on an unlisted extension (before the file is opened), 404 if the file can't
/// be read, otherwise 200 with the file's bytes.
pub fn respond(uri: &str) -> Response<Vec<u8>> {
    let path = match decode_scheme_path(uri, URI_PREFIX) {
        Ok(p) => p,
        Err(e) => return text_response(StatusCode::BAD_REQUEST, e),
    };
    let content_type = match image_content_type(&path) {
        Some(t) => t,
        None => return text_response(StatusCode::FORBIDDEN, format!("{path}: not a supported image type")),
    };
    let bytes = match fs::read(&path) {
        Ok(b) => b,
        Err(e) => return text_response(StatusCode::NOT_FOUND, format!("{path}: {e}")),
    };
    Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", content_type)
        .header("Content-Security-Policy", "sandbox")
        .header("X-Content-Type-Options", "nosniff")
        .body(bytes)
        .expect("static response builder never fails")
}

#[cfg(test)]
mod tests {
    use super::*;
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    use std::fs;
    use std::path::PathBuf;

    // Unlike card_protocol's helper, the name must END in the extension under
    // test: a length suffix would turn `.png` into `.png-12` and get a 403.
    fn write_temp(name: &str, contents: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(format!("tarmac-img-test-{}-{name}", std::process::id()));
        fs::write(&path, contents).expect("write temp file");
        path
    }

    fn img_uri(path: &Path) -> String {
        let encoded = utf8_percent_encode(path.to_str().expect("utf-8 temp path"), NON_ALPHANUMERIC);
        format!("tarmac-card://img/{encoded}?v=1")
    }

    fn header<'a>(resp: &'a Response<Vec<u8>>, name: &str) -> Option<&'a str> {
        resp.headers().get(name).map(|v| v.to_str().expect("visible ASCII header"))
    }

    // S12
    #[test]
    fn a_readable_png_is_served_byte_for_byte_with_image_only_headers() {
        // PNG signature plus 0xFF, never valid UTF-8: a text path would mangle it.
        let bytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFE];
        let path = write_temp("s12.png", &bytes);
        let resp = respond(&img_uri(&path));
        fs::remove_file(&path).ok();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.body().as_slice(), &bytes);
        assert_eq!(header(&resp, "Content-Type"), Some("image/png"));
        assert_eq!(header(&resp, "Content-Security-Policy"), Some("sandbox"));
        assert_eq!(header(&resp, "X-Content-Type-Options"), Some("nosniff"));
        assert_eq!(header(&resp, "Access-Control-Allow-Origin"), None);
    }

    // S12: the Content-Type comes from Appendix A, not a constant.
    #[test]
    fn a_readable_svg_is_served_as_image_svg_xml() {
        let bytes = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>";
        let path = write_temp("s12.svg", bytes);
        let resp = respond(&img_uri(&path));
        fs::remove_file(&path).ok();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(header(&resp, "Content-Type"), Some("image/svg+xml"));
        assert_eq!(header(&resp, "Content-Security-Policy"), Some("sandbox"));
        assert_eq!(header(&resp, "X-Content-Type-Options"), Some("nosniff"));
        assert_eq!(resp.body().as_slice(), bytes);
    }

    // S17
    #[test]
    fn an_exotic_png_name_round_trips_as_one_encoded_segment() {
        let bytes = [0x89, 0x50, 0x4E, 0x47, 0xFF];
        let path = write_temp("s17 spaces 圖表 100% hash# q?.png", &bytes);
        let resp = respond(&img_uri(&path));
        fs::remove_file(&path).ok();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.body().as_slice(), &bytes);
    }

    // S14
    #[test]
    fn a_readable_file_without_an_image_extension_is_403_and_never_served() {
        for name in ["s14.html", "s14.md", "s14.png.html", "s14-no-extension"] {
            let marker = format!("CONTENTS-OF-{name}");
            let path = write_temp(name, marker.as_bytes());
            let resp = respond(&img_uri(&path));
            fs::remove_file(&path).ok();
            assert_eq!(resp.status(), StatusCode::FORBIDDEN, "{name}");
            assert_eq!(header(&resp, "Content-Type"), Some("text/plain; charset=utf-8"), "{name}");
            assert!(!String::from_utf8_lossy(resp.body()).contains(&marker), "{name}");
        }
    }

    // S15
    #[test]
    fn a_missing_image_is_404_naming_its_path_but_a_missing_html_is_403() {
        let png = std::env::temp_dir().join(format!("tarmac-img-test-{}-s15-missing.png", std::process::id()));
        let html = png.with_extension("html");
        fs::remove_file(&png).ok();
        fs::remove_file(&html).ok();

        let resp = respond(&img_uri(&png));
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        assert_eq!(header(&resp, "Content-Type"), Some("text/plain; charset=utf-8"));
        assert!(String::from_utf8_lossy(resp.body()).contains(png.to_str().expect("utf-8 temp path")));

        assert_eq!(respond(&img_uri(&html)).status(), StatusCode::FORBIDDEN);
    }

    // S16
    #[test]
    fn an_undecodable_uri_is_400_plain_text() {
        for uri in ["tarmac-card://img/?v=1", "tarmac-card://img/%FF?v=1", "tarmac-card://doc/x.png?v=1"] {
            let resp = respond(uri);
            assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{uri}");
            assert_eq!(header(&resp, "Content-Type"), Some("text/plain; charset=utf-8"), "{uri}");
        }
    }

    // S13: the test keeps its own copy — iterating IMAGE_TYPES would pass however
    // wrong the table is; only its row count is read from production.
    #[test]
    fn every_appendix_a_extension_maps_to_exactly_its_type() {
        let expected: [(&str, &str); 128] = [
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
        ];
        for (ext, ty) in expected {
            assert_eq!(image_content_type(&format!("/d/x.{ext}")), Some(ty), "extension {ext}");
        }
        assert_eq!(IMAGE_TYPES.len(), expected.len());
    }

    // S13: case-insensitivity.
    #[test]
    fn extension_match_ignores_case() {
        assert_eq!(image_content_type("/d/x.PNG"), Some("image/png"));
        assert_eq!(image_content_type("/d/x.JpEg"), Some("image/jpeg"));
        assert_eq!(image_content_type("/d/x.HEIC"), Some("image/heic"));
        assert_eq!(image_content_type("/d/x.X-PNG"), Some("image/png"));
        assert_eq!(image_content_type("/d/x.Svg"), Some("image/svg+xml"));
    }

    // S13: names with no listed extension.
    #[test]
    fn a_name_without_a_listed_extension_has_no_type() {
        for path in ["/d/x.png.txt", "/d/README", "/d/.png", "/d/x.", "/d/x.cgm"] {
            assert_eq!(image_content_type(path), None, "{path}");
        }
    }
}
