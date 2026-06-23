//! Frontend → daemon commands. Each builds a `tarmac-protocol` `Msg` and pushes
//! it onto the bridge's outbound queue (fire-and-forget; the protocol has no
//! request ids). `term_attach` is the exception: it registers a per-terminal
//! binary output Channel and sends nothing to the daemon.

use tarmac_protocol::Msg;
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::{AppHandle, State};

use crate::bridge::Bridge;

/// The frontend calls this once its daemon listeners are registered, so the
/// bridge replays the status/board_list/restore it emitted before the webview
/// existed (startup race) — and re-syncs after a dev HMR reload.
#[tauri::command]
pub fn frontend_ready(app: AppHandle, state: State<Bridge>) {
    state.replay(&app);
}

/// Register the binary output sink for a terminal. The frontend creates a
/// `Channel<ArrayBuffer>` and passes it here; the bridge streams that terminal's
/// raw PTY bytes onto it (see `bridge::dispatch`).
#[tauri::command]
pub fn term_attach(state: State<Bridge>, term_id: String, on_output: Channel<InvokeResponseBody>) {
    state.attach_output(term_id, on_output);
}

#[tauri::command]
pub fn spawn_term(
    state: State<Bridge>,
    term_id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
    cmd: Option<Vec<String>>,
    board_id: Option<String>,
) {
    state.send(Msg::SpawnTerm {
        term_id,
        cols,
        rows,
        cwd,
        cmd,
        board_id,
    });
}

/// Terminal input. xterm's `onData` yields a string (typed chars + control
/// sequences); we send its UTF-8 bytes as the PTY input, matching the Swift app
/// which forwarded SwiftTerm's byte slice verbatim.
#[tauri::command]
pub fn term_input(state: State<Bridge>, term_id: String, data: String) {
    state.send(Msg::Input {
        term_id,
        bytes: data.into_bytes(),
    });
}

#[tauri::command]
pub fn term_resize(state: State<Bridge>, term_id: String, cols: u16, rows: u16) {
    state.send(Msg::Resize {
        term_id,
        cols,
        rows,
    });
}

#[tauri::command]
pub fn term_close(state: State<Bridge>, term_id: String) {
    state.detach_output(&term_id);
    state.send(Msg::TermClose { term_id });
}

#[tauri::command]
pub fn doc_open(
    state: State<Bridge>,
    path: String,
    term_id: Option<String>,
    board_id: Option<String>,
) {
    state.send(Msg::Open {
        path,
        term_id,
        board_id,
    });
}

#[tauri::command]
pub fn doc_read(state: State<Bridge>, path: String) {
    state.send(Msg::DocRead { path });
}

/// Read a doc's markdown content for rendering. The daemon sends only the path
/// (+ mtime via file_event); the UI reads the file itself, exactly as the Swift
/// app did (readMarkdown). Returns the file text, or an error string.
#[tauri::command]
pub fn read_doc(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))
}

#[tauri::command]
pub fn board_switch(state: State<Bridge>, board_id: String) {
    state.send(Msg::BoardSwitch { board_id });
}

#[tauri::command]
pub fn board_create(state: State<Bridge>) {
    state.send(Msg::BoardCreate);
}

#[tauri::command]
pub fn board_rename(state: State<Bridge>, board_id: String, name: String) {
    state.send(Msg::BoardRename { board_id, name });
}

#[tauri::command]
pub fn board_delete(state: State<Bridge>, board_id: String) {
    state.send(Msg::BoardDelete { board_id });
}
