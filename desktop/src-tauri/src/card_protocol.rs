//! `tarmac-card://` custom URI scheme (spec 2607.0004): serves an HTML doc
//! file with a strict response-header CSP and a prepended console/escape
//! shim, so agent-written HTML/JS runs sandboxed inside a `<iframe
//! sandbox="allow-scripts">` with no network and no Tauri IPC reach. Pure
//! helpers here (decode, compose, respond) are separated from the
//! `register_uri_scheme_protocol` glue in `lib.rs` so they unit-test inline,
//! per the `bridge.rs` precedent.
//!
//! Same filesystem trust model as `commands::read_doc`: raw path, no
//! canonicalization, no jail — a deliberate non-goal (no docs-root concept
//! exists), not an oversight.

use percent_encoding::percent_decode_str;
use tauri::http::{Response, StatusCode};

/// Byte-exact per spec Interface Contract — do not reformat.
pub const CARD_CSP: &str = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:";

const URI_PREFIX: &str = "tarmac-card://doc/";

/// Decode the `<url-encoded-abs-path>` segment out of a
/// `tarmac-card://doc/<path>?v=<mtime>` URI. Errors are user-facing 400
/// messages, not panics.
pub fn decode_card_path(uri: &str) -> Result<String, String> {
    let rest = uri.strip_prefix(URI_PREFIX).ok_or_else(|| format!("malformed tarmac-card URI: {uri}"))?;
    let encoded = rest.split('?').next().unwrap_or("");
    if encoded.is_empty() {
        return Err("empty path".into());
    }
    let decoded = percent_decode_str(encoded)
        .decode_utf8()
        .map_err(|e| format!("invalid UTF-8 in path: {e}"))?;
    Ok(decoded.into_owned())
}

/// Prepend the shim, unconditionally and strictly before the first file
/// byte — no content sniffing, works identically for `<!DOCTYPE html>` or a
/// BOM-prefixed file (S9).
fn compose_body(file_bytes: &[u8]) -> Vec<u8> {
    const SHIM: &str = include_str!("card_shim.js");
    let mut body = Vec::with_capacity(SHIM.len() + 20 + file_bytes.len());
    body.extend_from_slice(b"<script>");
    body.extend_from_slice(SHIM.as_bytes());
    body.extend_from_slice(b"</script>\n");
    body.extend_from_slice(file_bytes);
    body
}

fn text_response(status: StatusCode, body: String) -> Response<Vec<u8>> {
    Response::builder()
        .status(status)
        .header("Content-Type", "text/plain; charset=utf-8")
        .body(body.into_bytes())
        .expect("static response builder never fails")
}

/// Serve one `tarmac-card://doc/...` request. 200 on success (shim + file
/// bytes, CSP header); 404 if the file can't be read; 400 on a malformed URI.
pub fn respond(uri: &str) -> Response<Vec<u8>> {
    let path = match decode_card_path(uri) {
        Ok(p) => p,
        Err(e) => return text_response(StatusCode::BAD_REQUEST, e),
    };
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) => return text_response(StatusCode::NOT_FOUND, format!("{path}: {e}")),
    };
    Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "text/html; charset=utf-8")
        .header("Content-Security-Policy", CARD_CSP)
        .body(compose_body(&bytes))
        .expect("static response builder never fails")
}

#[cfg(test)]
mod tests {
    use super::*;
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    use std::fs;

    // S3: CSP is byte-exact and never accidentally reformatted.
    #[test]
    fn csp_is_byte_exact() {
        assert_eq!(
            CARD_CSP,
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"
        );
    }

    fn write_temp(name_suffix: &str, contents: &[u8]) -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "tarmac-card-test-{}-{}-{}",
            std::process::id(),
            name_suffix,
            contents.len()
        ));
        fs::write(&path, contents).expect("write temp file");
        path
    }

    // S9: shim precedes content unconditionally, incl. DOCTYPE and BOM files.
    #[test]
    fn shim_precedes_doctype_content() {
        let path = write_temp("doctype", b"<!DOCTYPE html><html></html>");
        let uri = format!(
            "tarmac-card://doc/{}?v=1",
            utf8_percent_encode(path.to_str().unwrap(), NON_ALPHANUMERIC)
        );
        let resp = respond(&uri);
        assert_eq!(resp.status(), StatusCode::OK);
        let body = resp.body();
        let shim_pos = find(body, b"<script>").expect("shim script tag present");
        let doctype_pos = find(body, b"<!DOCTYPE html>").expect("original content present");
        assert!(shim_pos < doctype_pos, "shim must come before file content");
        fs::remove_file(&path).ok();
    }

    #[test]
    fn shim_precedes_bom_content() {
        let mut contents = vec![0xEF, 0xBB, 0xBF]; // UTF-8 BOM
        contents.extend_from_slice(b"<html>bom</html>");
        let path = write_temp("bom", &contents);
        let uri = format!(
            "tarmac-card://doc/{}?v=1",
            utf8_percent_encode(path.to_str().unwrap(), NON_ALPHANUMERIC)
        );
        let resp = respond(&uri);
        assert_eq!(resp.status(), StatusCode::OK);
        let body = resp.body();
        let shim_pos = find(body, b"<script>").expect("shim script tag present");
        let bom_pos = find(body, &[0xEF, 0xBB, 0xBF]).expect("BOM present");
        assert!(shim_pos < bom_pos, "shim must precede a BOM-prefixed file");
        assert_eq!(
            resp.headers().get("Content-Security-Policy").unwrap().to_str().unwrap(),
            CARD_CSP
        );
        assert_eq!(
            resp.headers().get("Content-Type").unwrap().to_str().unwrap(),
            "text/html; charset=utf-8"
        );
        fs::remove_file(&path).ok();
    }

    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack.windows(needle.len()).position(|w| w == needle)
    }

    // S8: round-trip a real file whose name has spaces, CJK, %, #, ?.
    #[test]
    fn round_trips_exotic_filename() {
        let name_suffix = "spaces-CJK-圖表-percent%25-hash#-q?";
        let path = write_temp(name_suffix, b"<html>exotic</html>");
        let path_str = path.to_str().unwrap();
        let encoded = utf8_percent_encode(path_str, NON_ALPHANUMERIC).to_string();
        assert_eq!(decode_card_path(&format!("tarmac-card://doc/{encoded}?v=99")).unwrap(), path_str);

        let uri = format!("tarmac-card://doc/{encoded}?v=99");
        let resp = respond(&uri);
        assert_eq!(resp.status(), StatusCode::OK);
        assert!(find(resp.body(), b"exotic").is_some());
        fs::remove_file(&path).ok();
    }

    // S15: unreadable file -> 404 text/plain naming path + error, no shim.
    #[test]
    fn missing_file_is_404_with_no_shim() {
        let path = std::env::temp_dir().join("tarmac-card-test-does-not-exist.html");
        fs::remove_file(&path).ok();
        let encoded = utf8_percent_encode(path.to_str().unwrap(), NON_ALPHANUMERIC).to_string();
        let resp = respond(&format!("tarmac-card://doc/{encoded}?v=1"));
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            resp.headers().get("Content-Type").unwrap().to_str().unwrap(),
            "text/plain; charset=utf-8"
        );
        let body = String::from_utf8(resp.body().clone()).unwrap();
        assert!(body.contains(path.to_str().unwrap()));
        assert!(!body.contains("<script>"));
    }

    // S16: malformed / undecodable URIs -> 400, never a panic.
    #[test]
    fn empty_path_is_400() {
        let resp = respond("tarmac-card://doc/?v=1");
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[test]
    fn non_utf8_percent_sequence_is_400() {
        let resp = respond("tarmac-card://doc/%FF?v=1");
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[test]
    fn wrong_shape_uri_is_400() {
        assert_eq!(respond("https://doc/foo.html").status(), StatusCode::BAD_REQUEST);
        assert_eq!(respond("tarmac-card://other/foo.html").status(), StatusCode::BAD_REQUEST);
        assert_eq!(respond("tarmac-card://doc").status(), StatusCode::BAD_REQUEST);
    }
}
