//! `tarmac terms`: the daemon's live terminals, one JSON line each, in board
//! order (spec 2611.0012). It is how a caller outside a terminal names one.

use std::io::Write;

use serde_json::{Map, json};
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
                let _ = writeln!(out, "{}", line(row));
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
    let mut stream = crate::connect()?;
    crate::send(&mut stream, &Msg::TermsList)?;
    let no_answer = crate::no_answer("an older daemon");
    loop {
        match crate::recv_or(&mut stream, |e| crate::late_or_lost(e, &no_answer))? {
            Msg::Terms { terms } => return Ok(terms),
            Msg::Err { msg } => return Err(msg),
            _ => continue,
        }
    }
}

fn line(row: &TermInfo) -> serde_json::Value {
    let mut m = Map::new();
    m.insert("term".into(), json!(row.term_id));
    m.insert("board".into(), json!(row.board_id));
    if let Some(cwd) = &row.cwd {
        m.insert("cwd".into(), json!(cwd));
    }
    if let Some(proc) = &row.proc {
        m.insert("proc".into(), json!(proc));
    }
    serde_json::Value::Object(m)
}
