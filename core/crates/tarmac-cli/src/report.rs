//! `tarmac report`: the calling terminal's report, `blocked` or `done` with an
//! optional text, or `clear` (spec 2611.0009). The daemon finds the process
//! the report belongs to; the cli only names the terminal.

use std::io;

use tarmac_protocol::{Msg, cap_report_text};

const USAGE: &str = "usage: tarmac report blocked|done [\"<text>\"]  |  tarmac report clear";
const NEEDS_TERM: &str = "report needs TARMAC_TERM_ID (run it in a Tarmac terminal)";
const NO_ANSWER: &str = "no answer from the daemon in 5 s (an older daemon)";

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
    match send(&msg) {
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

fn send(msg: &Msg) -> Result<(), String> {
    let mut stream = crate::connect()?;
    crate::send(&mut stream, msg)?;
    crate::answer(&mut stream, |e| match e.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => NO_ANSWER.to_owned(),
        _ => crate::lost(e),
    })?
}
