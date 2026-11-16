//! `tarmac terms`: the daemon's live terminals, one JSON line each, in board
//! order (spec 2611.0012). It is how a caller outside a terminal names one.

use std::io::Write;

use serde::Serialize;
use tarmac_protocol::{Msg, TermInfo};

const USAGE: &str = "usage: tarmac terms";

pub fn run(args: &[String]) -> i32 {
    if !args.is_empty() {
        eprintln!("tarmac: {USAGE}");
        return 2;
    }
    match list() {
        Ok(terms) => {
            let mut out = std::io::stdout().lock();
            for row in &terms {
                let row = Row { term: &row.term_id, board: &row.board_id, cwd: row.cwd.as_deref(), proc: row.proc.as_deref() };
                let _ = writeln!(out, "{}", serde_json::to_string(&row).unwrap_or_default());
            }
            0
        }
        Err(why) => {
            eprintln!("tarmac: {why}");
            1
        }
    }
}

fn list() -> Result<Vec<TermInfo>, String> {
    let mut stream = crate::daemon::connect()?;
    crate::daemon::send(&mut stream, &Msg::TermsList)?;
    let no_answer = crate::daemon::no_answer("an older daemon");
    loop {
        match crate::daemon::recv_or(&mut stream, |e| crate::daemon::late_or_lost(e, &no_answer))? {
            Msg::Terms { terms } => return Ok(terms),
            Msg::Err { msg } => return Err(msg),
            _ => continue,
        }
    }
}

/// One line; its keys are written in field order.
#[derive(Serialize)]
struct Row<'a> {
    term: &'a str,
    board: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    cwd: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proc: Option<&'a str>,
}
