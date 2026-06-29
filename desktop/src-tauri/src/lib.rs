//! Tarmac desktop (Tauri 2) — the UI shell that replaces the Swift/AppKit app.
//!
//! The Rust backend is a thin bridge: it owns the Unix-socket connection to the
//! untouched `tarmacd` daemon (see `bridge.rs`), speaks the wire protocol via the
//! reused `tarmac-protocol` crate, and translates daemon `Msg`s ↔ Tauri IPC for
//! the React frontend. All UI (board, terminals via xterm.js, doc cards) lives in
//! the frontend; the only privileged work down here is the socket + process spawn.

mod bridge;
mod commands;

use bridge::Bridge;
use tauri::Manager;
use tokio::sync::mpsc;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // The outbound queue: commands push Msgs here, the connection task
            // drains it onto the socket. The task also owns reconnect + dispatch.
            let (tx, rx) = mpsc::unbounded_channel();
            app.manage(Bridge::new(tx));
            bridge::start(app.handle().clone(), rx);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::frontend_ready,
            commands::term_attach,
            commands::term_detach,
            commands::spawn_term,
            commands::term_input,
            commands::term_resize,
            commands::term_close,
            commands::doc_open,
            commands::doc_read,
            commands::read_doc,
            commands::persist_layout,
            commands::board_switch,
            commands::board_create,
            commands::board_rename,
            commands::board_delete,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// Keep a tiny self-test of the reused codec link (the crate's own conformance
// vectors cover byte-exactness; this only asserts the path-dep wiring compiles
// and round-trips). The unused imports above are silenced when not testing.
#[cfg(test)]
mod tests {
    use tarmac_protocol::{decode, encode, Msg};

    #[test]
    fn protocol_crate_roundtrips_via_path_dep() {
        let msg = Msg::Hello {
            role: "app".into(),
            v: tarmac_protocol::PROTOCOL_VERSION,
        };
        let bytes = encode(&msg).expect("encode");
        assert_eq!(decode(&bytes).expect("decode"), msg);
    }

    #[test]
    fn repo_color_index_matches_reference() {
        assert_eq!(tarmac_protocol::repo_color_index("api"), 3);
        assert_eq!(tarmac_protocol::repo_color_index("infra"), 1);
    }
}
