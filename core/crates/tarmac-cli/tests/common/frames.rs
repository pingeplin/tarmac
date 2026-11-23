// The daemon's event frames, as the cli tests write them.

use tarmac_protocol::Msg;

pub(crate) fn bell(term_id: &str) -> Msg {
    Msg::Bell { term_id: term_id.into(), board_id: None }
}

pub(crate) fn exit(term_id: &str, code: Option<i64>) -> Msg {
    Msg::Exit { term_id: term_id.into(), code, board_id: None }
}

/// A `term_report`; one with a `kind` is at 1 700 000 000 000 ms.
pub(crate) fn term_report(
    term_id: &str,
    kind: Option<&str>,
    text: Option<&str>,
    proc: Option<&str>,
    read: bool,
) -> Msg {
    Msg::TermReport {
        term_id: term_id.into(),
        kind: kind.map(str::to_string),
        text: text.map(str::to_string),
        at_ms: kind.map(|_| 1_700_000_000_000),
        proc: proc.map(str::to_string),
        read,
        board_id: None,
        cwd: None,
    }
}
