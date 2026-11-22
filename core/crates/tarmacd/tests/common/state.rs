use super::TestDaemon;

/// Board `board`'s `term_records` in a saved state.
pub fn term_records(v: &serde_json::Value, board: usize) -> serde_json::Value {
    v["boards"][board]["term_records"].clone()
}

pub fn has_record(v: &serde_json::Value, board: usize, term_id: &str) -> bool {
    !term_records(v, board)[term_id].is_null()
}

pub fn saved_cwd(v: &serde_json::Value, board: usize, term_id: &str) -> serde_json::Value {
    term_records(v, board)[term_id]["last_cwd"].clone()
}

pub fn doc_entry(v: &serde_json::Value, board: usize, path: &str) -> serde_json::Value {
    v["boards"][board]["docs"]
        .as_array()
        .and_then(|docs| docs.iter().find(|e| e["path"] == serde_json::json!(path)))
        .cloned()
        .unwrap_or(serde_json::Value::Null)
}

pub fn wait_for_last_changed(daemon: &TestDaemon, what: &str, board: usize, path: &str, want: serde_json::Value) {
    daemon.wait_for_state(what, |v| doc_entry(v, board, path)["last_changed_ms"] == want);
}

pub fn has_doc(v: &serde_json::Value, board: usize, path: &str) -> bool {
    !doc_entry(v, board, path).is_null()
}

// persist.rs writes `docs` in dock order, so a doc's index is its dock slot.
pub fn dock_index(v: &serde_json::Value, board: usize, path: &str) -> Option<usize> {
    v["boards"][board]["docs"].as_array()?.iter().position(|e| e["path"] == serde_json::json!(path))
}
