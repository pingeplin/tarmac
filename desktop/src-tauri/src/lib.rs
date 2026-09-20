//! Tarmac desktop (Tauri 2) — the UI shell that replaces the Swift/AppKit app.
//!
//! The Rust backend is a thin bridge: it owns the Unix-socket connection to the
//! untouched `tarmacd` daemon (see `bridge.rs`), speaks the wire protocol via the
//! reused `tarmac-protocol` crate, and translates daemon `Msg`s ↔ Tauri IPC for
//! the React frontend. All UI (board, terminals via xterm.js, doc cards) lives in
//! the frontend; the only privileged work down here is the socket + process spawn.

mod app_prefs;
mod bridge;
mod card_protocol;
mod commands;
// Dev-only QA driver (issue #166): compiled out of release builds entirely.
#[cfg(debug_assertions)]
mod dev_driver;
#[cfg(any(test, debug_assertions))]
mod dev_press;
mod image_protocol;
mod quit_guard;
mod quit_intercept;
mod quit_notice;
mod window_lifecycle;

use bridge::Bridge;
use tauri::Manager;
use tokio::sync::mpsc;

/// The one dispatch point for the `tarmac-card` scheme: the `img` host serves
/// markdown doc-card images; everything else goes to the HTML card handler,
/// which answers an unknown host 400.
fn respond_card_scheme(uri: &str) -> tauri::http::Response<Vec<u8>> {
    if uri.starts_with(image_protocol::URI_PREFIX) {
        image_protocol::respond(uri)
    } else {
        card_protocol::respond(uri)
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Read before the builder: the menu's check item needs its initial state,
    // and so does the guard (#171). One read, one source of truth.
    let warn_before_quit = app_prefs::load(&bridge::app_prefs_path());
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .menu(move |handle| quit_intercept::app_menu(handle, warn_before_quit))
        .on_menu_event(|app, event| quit_intercept::on_menu_event(app, &event))
        // The red button hides the window instead of quitting: a hidden Tarmac
        // still owns live terminals, and ⌘Q stays guarded (#171). `app.exit(0)`
        // sends no CloseRequested, so the guard's own quit cannot land here.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
                window.app_handle().state::<window_lifecycle::HiddenByClose>().close_requested();
            }
        })
        // Async variant: `respond` does a blocking file read, and the sync
        // registration would run the handler inline on the WKWebView
        // scheme-handler thread (the main thread on macOS), stalling the UI
        // on a cold or large file. spawn_blocking moves that read off it.
        .register_asynchronous_uri_scheme_protocol("tarmac-card", |_ctx, request, responder| {
            let uri = request.uri().to_string();
            tauri::async_runtime::spawn_blocking(move || {
                responder.respond(respond_card_scheme(&uri));
            });
        })
        .setup(move |app| {
            // The outbound queue: commands push Msgs here, the connection task
            // drains it onto the socket. The task also owns reconnect + dispatch.
            let (tx, rx) = mpsc::unbounded_channel();
            app.manage(Bridge::new(tx));
            bridge::start(app.handle().clone(), rx);
            // Managed before the retarget: the Quit handler reads the toggle,
            // and the activation observer reads the hide state.
            app.manage(quit_intercept::QuitToggle::new(warn_before_quit));
            app.manage(window_lifecycle::HiddenByClose::default());
            quit_intercept::install(app.handle().clone());
            #[cfg(debug_assertions)]
            {
                app.manage(std::sync::Arc::new(dev_driver::DevDriver::default()));
                dev_driver::start(app.handle().clone());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::frontend_ready,
            commands::term_attach,
            commands::term_detach,
            commands::spawn_term,
            commands::term_input,
            commands::term_input_bytes,
            commands::term_resize,
            commands::term_close,
            commands::doc_open,
            commands::doc_read,
            commands::doc_close,
            commands::doc_refresh,
            commands::read_doc,
            commands::persist_layout,
            commands::board_switch,
            commands::board_create,
            commands::board_rename,
            commands::board_delete,
            // Dev-only, and `generate_handler!` honours a per-entry cfg — so the
            // list stays single and cannot drift between the two builds.
            #[cfg(debug_assertions)]
            dev_driver::dev_ready,
            #[cfg(debug_assertions)]
            dev_driver::dev_reply,
            #[cfg(debug_assertions)]
            quit_intercept::dev_quit_guard,
            #[cfg(debug_assertions)]
            quit_intercept::dev_press,
        ])
        // `build().run(..)` rather than `run(ctx)` — the same call underneath —
        // so `RunEvent::Reopen` is visible: a Dock click on an already-active
        // Tarmac raises no activation notification (#171).
        .build(tauri::generate_context!())
        .expect("error while running tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::Reopen { .. } = event {
                quit_intercept::restore_window(app);
            }
        });
}

// Keep a tiny self-test of the reused codec link (the crate's own conformance
// vectors cover byte-exactness; this only asserts the path-dep wiring compiles
// and round-trips), plus the `tarmac-card` scheme dispatch.
#[cfg(test)]
mod tests {
    use super::{card_protocol, respond_card_scheme};
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    use std::fs;
    use std::path::{Path, PathBuf};
    use tarmac_protocol::{decode, encode, Msg};
    use tauri::http::{Response, StatusCode};

    #[test]
    fn protocol_crate_roundtrips_via_path_dep() {
        let msg = Msg::Hello {
            role: "app".into(),
            v: tarmac_protocol::PROTOCOL_VERSION,
            app_version: Some("0.0.0-test".into()),
        };
        let bytes = encode(&msg).expect("encode");
        assert_eq!(decode(&bytes).expect("decode"), msg);
    }

    #[test]
    fn repo_color_index_matches_reference() {
        assert_eq!(tarmac_protocol::repo_color_index("api"), 3);
        assert_eq!(tarmac_protocol::repo_color_index("infra"), 1);
    }

    // S18 (spec 2609.0014): scheme dispatch.
    fn scheme_temp(name: &str, contents: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(format!("tarmac-scheme-test-{}-{name}", std::process::id()));
        fs::write(&path, contents).expect("write temp file");
        path
    }

    fn card_uri(host: &str, path: &Path) -> String {
        let encoded = utf8_percent_encode(path.to_str().expect("utf-8 temp path"), NON_ALPHANUMERIC);
        format!("tarmac-card://{host}/{encoded}?v=1")
    }

    fn header<'a>(resp: &'a Response<Vec<u8>>, name: &str) -> Option<&'a str> {
        resp.headers().get(name).map(|v| v.to_str().expect("visible ASCII header"))
    }

    #[test]
    fn respond_card_scheme_routes_the_img_host_to_the_image_handler() {
        let bytes = [0x89, 0x50, 0x4E, 0x47, 0xFF];
        let path = scheme_temp("s18.png", &bytes);
        let resp = respond_card_scheme(&card_uri("img", &path));
        fs::remove_file(&path).ok();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(header(&resp, "Content-Type"), Some("image/png"));
        assert_eq!(resp.body().as_slice(), &bytes);
    }

    #[test]
    fn respond_card_scheme_routes_the_doc_host_to_the_card_handler() {
        let path = scheme_temp("s18.html", b"<html>s18</html>");
        let resp = respond_card_scheme(&card_uri("doc", &path));
        fs::remove_file(&path).ok();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(header(&resp, "Content-Type"), Some("text/html; charset=utf-8"));
        assert_eq!(header(&resp, "Content-Security-Policy"), Some(card_protocol::CARD_CSP));
        assert!(resp.body().starts_with(b"<script>"));
    }

    #[test]
    fn respond_card_scheme_answers_an_unknown_host_with_400() {
        assert_eq!(respond_card_scheme("tarmac-card://other/x").status(), StatusCode::BAD_REQUEST);
    }
}
