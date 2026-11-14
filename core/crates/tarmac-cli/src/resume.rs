//! `tarmac resume`: the command that resumes the agent session of the calling
//! terminal, or its clear (spec 2611.0011). The daemon ties it to the process
//! that set it and offers it after a restart; the cli only names the terminal.

use tarmac_protocol::{Msg, check_resume_cmd};

use crate::report::{NoAnswer, send};

const USAGE: &str = "usage: tarmac resume set \"<command>\"  |  tarmac resume clear";
const NEEDS_TERM: &str = "resume needs TARMAC_TERM_ID (run it in a Tarmac terminal)";

pub fn run(args: &[String]) -> i32 {
    let cmd = match parse(args) {
        Ok(cmd) => cmd,
        Err(why) => {
            eprintln!("tarmac: {why}");
            return 2;
        }
    };
    let Some(term_id) = crate::env_override("TARMAC_TERM_ID") else {
        eprintln!("tarmac: {NEEDS_TERM}");
        return 1;
    };
    let msg = Msg::Resume { term_id: term_id.to_string_lossy().into_owned(), cmd };
    match send(&msg, crate::DAEMON_WAIT, NoAnswer::ToTheReport(&crate::no_answer("an older daemon"))) {
        Ok(()) => 0,
        Err(why) => {
            eprintln!("tarmac: {why}");
            1
        }
    }
}

/// The command to set, or `None` to clear; `Err` is the usage line or the
/// command's refusal.
fn parse(args: &[String]) -> Result<Option<String>, String> {
    match args {
        [verb, cmd] if verb == "set" => match check_resume_cmd(cmd) {
            Ok(()) => Ok(Some(cmd.clone())),
            Err(cause) => Err(format!("resume command refused: {cause}")),
        },
        [verb] if verb == "clear" => Ok(None),
        _ => Err(USAGE.into()),
    }
}
