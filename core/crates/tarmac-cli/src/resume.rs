//! `tarmac resume`: the command that resumes the agent session of the calling
//! terminal, or its clear (spec 2611.0011). The daemon ties it to the process
//! that set it and offers it after a restart; the cli only names the terminal.

use tarmac_protocol::{Msg, refuse_resume_cmd};

const USAGE: &str = "usage: tarmac resume set \"<command>\"  |  tarmac resume clear";
const NEEDS_TERM: &str = "resume needs TARMAC_TERM_ID (run it in a Tarmac terminal)";

pub(crate) fn run(args: &[String]) -> i32 {
    match parse(args) {
        Ok(cmd) => crate::daemon::for_terminal(NEEDS_TERM, |term_id| Msg::Resume { term_id, cmd }),
        Err(why) => {
            eprintln!("tarmac: {why}");
            2
        }
    }
}

/// The command to set, or `None` to clear; `Err` is the usage line or the
/// command's refusal.
fn parse(args: &[String]) -> Result<Option<String>, String> {
    match args {
        [verb, cmd] if verb == "set" => refuse_resume_cmd(cmd).map(|()| Some(cmd.clone())),
        [verb] if verb == "clear" => Ok(None),
        _ => Err(USAGE.into()),
    }
}
