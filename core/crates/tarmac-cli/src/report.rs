//! `tarmac report`: the calling terminal's report, `blocked` or `done` with an
//! optional text, or `clear` (spec 2611.0009). The daemon finds the process
//! the report belongs to; the cli only names the terminal.

use tarmac_protocol::{Msg, REPORT_CLEAR, ReportKind, cap_report_text};

const USAGE: &str = "usage: tarmac report blocked|done [\"<text>\"]  |  tarmac report clear";
const NEEDS_TERM: &str = "report needs TARMAC_TERM_ID (run it in a Tarmac terminal)";

pub fn run(args: &[String]) -> i32 {
    let Some((kind, text)) = parse(args) else {
        eprintln!("tarmac: {USAGE}");
        return 2;
    };
    crate::daemon::for_terminal(NEEDS_TERM, |term_id| Msg::Report {
        term_id,
        kind: kind.to_owned(),
        text: text.map(cap_report_text),
    })
}

/// The kind and the text; an empty text is no text. `clear ""` is plain
/// `clear`, so a hook that passes its text through never gets a usage error.
fn parse(args: &[String]) -> Option<(&str, Option<&str>)> {
    let (kind, text) = match args {
        [kind] => (kind.as_str(), None),
        [kind, text] => (kind.as_str(), Some(text.as_str()).filter(|t| !t.is_empty())),
        _ => return None,
    };
    let cleared = kind == REPORT_CLEAR && text.is_none();
    (ReportKind::named(kind).is_some() || cleared).then_some((kind, text))
}
