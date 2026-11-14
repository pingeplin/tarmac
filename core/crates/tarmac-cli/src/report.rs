//! `tarmac report`: the calling terminal's report, `blocked` or `done` with an
//! optional text, or `clear` (spec 2611.0009). The daemon finds the process
//! the report belongs to; the cli only names the terminal.

use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg, cap_report_text};

const USAGE: &str = "usage: tarmac report blocked|done [\"<text>\"]  |  tarmac report clear";
const NEEDS_TERM: &str = "report needs TARMAC_TERM_ID (run it in a Tarmac terminal)";


pub fn run(args: &[String]) -> i32 {
    let Some((kind, text)) = parse(args) else {
        eprintln!("tarmac: {USAGE}");
        return 2;
    };
    let Some(term_id) = crate::env_override("TARMAC_TERM_ID") else {
        eprintln!("tarmac: {NEEDS_TERM}");
        return 1;
    };
    let msg = Msg::Report {
        term_id: term_id.to_string_lossy().into_owned(),
        kind: kind.to_owned(),
        text: text.map(cap_report_text),
    };
    match send(&msg, crate::DAEMON_WAIT, NoAnswer::ToTheReport(&crate::no_answer("an older daemon"))) {
        Ok(()) => 0,
        Err(why) => {
            eprintln!("tarmac: {why}");
            1
        }
    }
}

/// The kind and the text; an empty text is no text. `clear ""` is plain
/// `clear`, so a hook that passes its text through never gets a usage error.
fn parse(args: &[String]) -> Option<(&str, Option<&str>)> {
    let (kind, text) = match args {
        [kind] => (kind.as_str(), None),
        [kind, text] => (kind.as_str(), Some(text.as_str()).filter(|t| !t.is_empty())),
        _ => return None,
    };
    match (kind, text) {
        ("blocked" | "done", _) | ("clear", None) => Some((kind, text)),
        _ => None,
    }
}

/// The line for a daemon that does not answer in time, and the time-outs it
/// stands for.
pub(crate) enum NoAnswer<'a> {
    /// A time-out on the report only; one in the handshake is a lost
    /// connection, as `tarmac report` has always said.
    ToTheReport(&'a str),
    /// A time-out anywhere from connect to answer.
    Anywhere(&'a str),
}

/// Sends `msg` and waits for its `ack`, from connect to answer inside `wait`.
/// Prints nothing: the error is the line the caller prints.
pub(crate) fn send(msg: &Msg, wait: Duration, no_answer: NoAnswer) -> Result<(), String> {
    let payload = proto::encode(msg).map_err(|e| format!("encode failed: {e}"))?;
    let until = Instant::now() + wait;
    let (line, in_handshake) = match no_answer {
        NoAnswer::ToTheReport(line) => (line, false),
        NoAnswer::Anywhere(line) => (line, true),
    };
    let late = |e| if in_handshake { crate::late_or_lost(e, line) } else { crate::lost(e) };
    let mut stream = crate::connect_until(until, &late)?;
    crate::exchange_until(&mut stream, &payload, until, line)?
}
