use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use tarmac_protocol::{BoardViewport, DocEntry, Msg, TermRecord, Tile};

use super::Conn;

/// The `ack` frame's payload, as a pty shows it.
pub(crate) const ACK: &[u8] = &[0x81, 0xa1, 0x74, 0xa3, 0x61, 0x63, 0x6b];

#[track_caller]
pub(crate) fn assert_ack(answer: &Msg) {
    assert!(matches!(answer, Msg::Ack), "expected ack, got {answer:?}");
}

pub(crate) struct Restore {
    pub board_id: Option<String>,
    pub docs: Vec<DocEntry>,
    pub tiles: Vec<Tile>,
    pub board: Option<BoardViewport>,
    pub live_terms: Vec<String>,
    pub term_records: BTreeMap<String, TermRecord>,
}

impl Restore {
    /// The `last_cwd` of `term_id`'s record.
    pub(crate) fn last_cwd(&self, term_id: &str) -> Option<&str> {
        self.term_records.get(term_id)?.last_cwd.as_deref()
    }

    /// The resume command of `term_id`'s record.
    pub(crate) fn resume_cmd(&self, term_id: &str) -> Option<&str> {
        Some(self.term_records.get(term_id)?.resume.as_ref()?.cmd.as_str())
    }

    pub(crate) fn last_changed(&self, path: &str) -> Option<u64> {
        self.docs.iter().find(|d| d.path == path).expect("the doc is on the board").last_changed_ms
    }
}

impl From<Msg> for Restore {
    fn from(msg: Msg) -> Self {
        let Msg::Restore { board_id, docs, tiles, board, live_terms, term_records } = msg else {
            panic!("expected restore, got {msg:?}")
        };
        Restore { board_id, docs, tiles, board, live_terms, term_records }
    }
}

/// One frame of a `FrameLog`, with the time it was read.
pub(crate) struct Logged {
    pub at: Instant,
    pub msg: Msg,
}

/// Every frame an app connection read, in order. The `recv_*` helpers drop
/// what does not match; a test that asserts the order of two frames reads into
/// a log instead.
#[derive(Default)]
pub(crate) struct FrameLog(pub Vec<Logged>);

impl FrameLog {
    pub(crate) fn len(&self) -> usize {
        self.0.len()
    }

    /// The index of `term_id`'s output chunk, from index `from` on, at which
    /// the concatenated output first contains `needle`.
    pub(crate) fn output_index_containing(&self, term_id: &str, from: usize, needle: &[u8]) -> Option<usize> {
        let mut text = Vec::new();
        for (i, logged) in self.0.iter().enumerate().skip(from) {
            if let Msg::Output { term_id: t, bytes } = &logged.msg
                && t == term_id
            {
                text.extend_from_slice(bytes);
                if contains(&text, needle) {
                    return Some(i);
                }
            }
        }
        None
    }

    /// The indexes of `term_id`'s `term_report`s from index `from` on.
    pub(crate) fn reports_for(&self, term_id: &str, from: usize) -> Vec<usize> {
        (from..self.0.len()).filter(|&i| is_report_for(&self.0[i].msg, term_id)).collect()
    }

    /// The name of `term_id`'s last `term_proc`.
    pub(crate) fn last_proc_name(&self, term_id: &str) -> Option<String> {
        self.0.iter().rev().find_map(|l| match &l.msg {
            Msg::TermProc { term_id: t, name, .. } if t == term_id => Some(name.clone()),
            _ => None,
        })
    }
}

pub(crate) fn is_report_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::TermReport { term_id, .. } if term_id == want)
}

pub(crate) fn is_term_resume(msg: &Msg) -> bool {
    matches!(msg, Msg::TermResume { .. })
}

pub(crate) fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

// Drain all messages arriving within `timeout`, returning true if none of them
// match `pred`. Used to assert the absence of a message (e.g. no FileEvent for a
// closed doc's path after it has been unwatched). Sets the stream's read timeout
// around the window and restores the LONG timeout afterwards.
pub(crate) fn none_within(conn: &mut Conn, timeout: Duration, pred: impl FnMut(&Msg) -> bool) -> bool {
    conn.recv_within(timeout, pred).is_none()
}

/// True when no `err` frame comes before the answer to a `scrollback_request`
/// sent now: the daemon handles one connection's frames in order, so an
/// `err` of a frame sent before it would come first.
pub(crate) fn no_err_frame(conn: &mut Conn) -> bool {
    conn.send(&Msg::ScrollbackRequest { term_id: "no-err-frame".into() });
    let answer = conn.recv_until("the scrollback answer", |m| {
        matches!(m, Msg::Err { .. }) || matches!(m, Msg::Scrollback { term_id, .. } if term_id == "no-err-frame")
    });
    matches!(answer, Msg::Scrollback { .. })
}

pub(crate) fn is_term_proc_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::TermProc { term_id, .. } if term_id == want)
}

/// The name a pty child has until it execs: the daemon's fork.
pub(crate) const FORK_NAME: &str = "tarmacd";

/// A `term_proc` for `want` that names the process after its exec.
pub(crate) fn is_exec_proc_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::TermProc { term_id, name, .. } if term_id == want && name != FORK_NAME)
}

pub(crate) fn is_exit_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::Exit { term_id, .. } if term_id == want)
}

pub(crate) fn is_bell_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::Bell { term_id, .. } if term_id == want)
}

pub(crate) fn is_file_event_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::FileEvent { path, .. } if path == want)
}

/// True when no `file_event` for `path` comes for 800 ms. With the result
/// dropped it lets the watcher go quiet: a `file_event` of an earlier edit that
/// is still on its way would be taken for the one a test waits for next.
pub(crate) fn quiet(conn: &mut Conn, path: &str) -> bool {
    none_within(conn, Duration::from_millis(800), |m| is_file_event_for(m, path))
}
