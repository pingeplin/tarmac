//! `tarmac term new`: a terminal card beside the calling terminal, whose shell
//! types the command (spec 2611.0016). The app makes the card; the daemon
//! passes the request on and answers with the new terminal's id.

use std::path::Path;

use serde::Serialize;
use tarmac_protocol::{Msg, refuse_term_new_cmd};

const USAGE: &str = "usage: tarmac term new [--cwd DIR] \"<command>\"";

pub fn run(args: &[String]) -> i32 {
    let (cmd, cwd) = match parse(args) {
        Ok(parsed) => parsed,
        Err(why) => {
            eprintln!("tarmac: {why}");
            return 2;
        }
    };
    match folder(cwd).and_then(|cwd| ask(cmd, cwd)) {
        Ok(term) => {
            println!("{}", serde_json::to_string(&Line { term: &term }).unwrap_or_default());
            0
        }
        Err(why) => {
            eprintln!("tarmac: {why}");
            1
        }
    }
}

/// The command and the `--cwd` given; `Err` is the usage line or the
/// command's refusal.
fn parse(args: &[String]) -> Result<(&str, Option<&str>), String> {
    let (cmd, cwd) = match args {
        [verb, cmd] if verb == "new" && !cmd.starts_with("--") => (cmd, None),
        [verb, flag, dir, cmd] if verb == "new" && flag == "--cwd" && !dir.is_empty() && !cmd.starts_with("--") => (cmd, Some(dir.as_str())),
        _ => return Err(USAGE.into()),
    };
    refuse_term_new_cmd(cmd)?;
    Ok((cmd, cwd))
}

/// D3: the folder, absolute against this process's own, with no file-system
/// call on it: a volume that does not answer cannot hold the cli. The daemon
/// checks it.
fn folder(cwd: Option<&str>) -> Result<String, String> {
    let path = std::path::absolute(Path::new(cwd.unwrap_or("."))).map_err(|_| "cannot read the current directory".to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

fn ask(cmd: &str, cwd: String) -> Result<String, String> {
    let no_answer = crate::daemon::no_answer_older();
    let mut stream = crate::daemon::connect(&no_answer)?;
    let msg = Msg::TermNew { req_id: None, cmd: cmd.into(), cwd, term_id: crate::calling_term(), board_id: None };
    crate::daemon::send(&mut stream, &msg, &no_answer)?;
    loop {
        match crate::daemon::recv_or(&mut stream, |e| crate::daemon::late_or_lost(e, &no_answer))? {
            Msg::TermNewOk { term_id, .. } => return Ok(term_id),
            Msg::Err { msg } => return Err(msg),
            _ => continue,
        }
    }
}

/// The one line on stdout.
#[derive(Serialize)]
struct Line<'a> {
    term: &'a str,
}
