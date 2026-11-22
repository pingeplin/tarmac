use std::io::{self, IsTerminal, Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Deserializer};
use serde_json::Value;
use tarmac_protocol::{Msg, REPORT_CLEAR, REPORT_TEXT_MAX, ReportKind, cap_report_text};

use crate::daemon::{connect_until, send_acked};

const HOOK_STDIN_MAX: usize = 4 << 20;
const HOOK_STDIN_WAIT: Duration = Duration::from_secs(1);
/// From connect to `ack`. An older daemon never answers `report`, and each
/// hook would otherwise hold Claude for the 5 s of the other verbs.
const HOOK_DEADLINE: Duration = Duration::from_millis(500);

/// Always 0, and never a byte on stdout: Claude adds a hook's stdout to the
/// model's context on `UserPromptSubmit` and `SessionStart`, and a non-zero
/// exit can block a prompt or continue a turn. Claude never shows the stderr
/// of an exit 0, so the reason goes there.
pub(super) fn run_hook(args: &[String]) -> i32 {
    let outcome = std::panic::catch_unwind(|| hook(args)).unwrap_or_else(|_| Err("panicked".into()));
    if let Err(why) = outcome {
        let _ = writeln!(io::stderr(), "tarmac: hooks run: {why}");
    }
    0
}

fn hook(args: &[String]) -> Result<(), String> {
    match args {
        [agent] if agent == "claude" => {}
        [agent] => return Err(format!("unknown agent '{agent}' (claude)")),
        _ => return Err("usage: tarmac hooks run <agent>".into()),
    }
    // Outside a Tarmac terminal every hook ends here, before a read of stdin.
    let Some(term_id) = crate::calling_term() else { return Ok(()) };
    if io::stdin().is_terminal() {
        return Ok(());
    }
    let input: ClaudeInput =
        serde_json::from_slice(&read_input()?).map_err(|e| format!("the input is not a JSON object: {e}"))?;
    let Some(msg) = claude_message(&term_id, &input)? else { return Ok(()) };
    let no_answer = format!("no answer from the daemon in {} ms", HOOK_DEADLINE.as_millis());
    let until = Instant::now() + HOOK_DEADLINE;
    let mut stream = connect_until(until).map_err(|e| e.worded(&no_answer))?;
    send_acked(&mut stream, &msg, until, &no_answer)
}

/// Stdin, read on a thread of its own so that a writer that never closes it
/// costs `HOOK_STDIN_WAIT` at most.
fn read_input() -> Result<Vec<u8>, String> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut input = Vec::new();
        let read = io::stdin().lock().take(HOOK_STDIN_MAX as u64 + 1).read_to_end(&mut input);
        let _ = tx.send(read.map(|_| input));
    });
    match rx.recv_timeout(HOOK_STDIN_WAIT) {
        Ok(Ok(input)) if input.len() <= HOOK_STDIN_MAX => Ok(input),
        Ok(Ok(_)) => Err(format!("the input is over {HOOK_STDIN_MAX} bytes")),
        Ok(Err(e)) => Err(format!("cannot read the input: {e}")),
        Err(_) => Err(format!("the input did not end in {} s", HOOK_STDIN_WAIT.as_secs())),
    }
}

/// The five fields of a Claude hook input that the mapping reads; the rest,
/// a long `prompt` among them, is skipped unparsed.
#[derive(Deserialize, Default)]
#[serde(default)]
struct ClaudeInput {
    hook_event_name: Lenient,
    notification_type: Lenient,
    message: Lenient,
    last_assistant_message: Lenient,
    session_id: Lenient,
}

/// A field that counts only when it is a string; any other value is as if
/// the field were absent.
#[derive(Default)]
struct Lenient(Option<String>);

impl<'de> Deserialize<'de> for Lenient {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Lenient(match Value::deserialize(d)? {
            Value::String(s) => Some(s),
            _ => None,
        }))
    }
}

/// The frame a Claude hook input stands for, if any: a report, or at
/// `SessionStart` the command that resumes the session (spec 2611.0011).
/// `Err` is a `SessionStart` whose `session_id` is refused.
fn claude_message(term_id: &str, input: &ClaudeInput) -> Result<Option<Msg>, String> {
    let report =
        |kind: &str, text: Option<String>| Ok(Some(Msg::Report { term_id: term_id.into(), kind: kind.into(), text }));
    let text = |field: &Lenient| field.0.as_deref().and_then(report_text);
    match input.hook_event_name.0.as_deref() {
        Some("Notification") if input.notification_type.0.as_deref() == Some("permission_prompt") => {
            report(ReportKind::Blocked.name(), text(&input.message))
        }
        Some("Stop") => report(ReportKind::Done.name(), text(&input.last_assistant_message)),
        Some("UserPromptSubmit") => report(REPORT_CLEAR, None),
        Some("SessionStart") => {
            let id = input.session_id.0.as_deref().filter(|id| is_safe_session_id(id)).ok_or("session_id refused")?;
            Ok(Some(Msg::Resume { term_id: term_id.into(), cmd: Some(format!("claude --resume {id}")) }))
        }
        _ => Ok(None),
    }
}

/// `^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$` (D8): no shell metacharacter, no
/// quoting needed, and no id that reads as a flag.
fn is_safe_session_id(id: &str) -> bool {
    let mut chars = id.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && id.len() <= 128
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// The text without its control characters, its whitespace runs folded to one
/// space, trimmed and capped, in one pass that stops once the cap is passed.
/// Removal comes first so that `"a \u{1b} b"` folds to `"a b"`.
fn report_text(raw: &str) -> Option<String> {
    let mut text = String::new();
    let mut count = 0;
    let mut gap = false;
    for c in raw.chars().filter(|c| !c.is_control() || c.is_whitespace()) {
        if c.is_whitespace() {
            gap = count > 0;
            continue;
        }
        if gap {
            text.push(' ');
            count += 1;
            gap = false;
        }
        text.push(c);
        count += 1;
        if count > REPORT_TEXT_MAX {
            break;
        }
    }
    (count > 0).then(|| cap_report_text(&text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture(name: &str) -> Value {
        let path = format!("{}/tests/fixtures/hooks/{name}.json", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    fn stop(message: Value) -> Value {
        json!({"hook_event_name": "Stop", "last_assistant_message": message})
    }

    fn message_of(input: Value) -> Option<Msg> {
        claude_message("t9", &serde_json::from_value(input).unwrap()).expect("not refused")
    }

    fn refusal_of(input: Value) -> String {
        claude_message("t9", &serde_json::from_value(input).unwrap()).expect_err("refused")
    }

    fn msg(kind: &str, text: Option<&str>) -> Msg {
        Msg::Report { term_id: "t9".into(), kind: kind.into(), text: text.map(str::to_string) }
    }

    fn done_text(message: Value) -> Option<String> {
        match message_of(stop(message)) {
            Some(Msg::Report { kind, text, .. }) if kind == "done" => text,
            other => panic!("a Stop is done, got {other:?}"),
        }
    }

    #[test]
    fn s5_a_permission_notification_is_blocked_with_its_message() {
        let input = json!({
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        });
        assert_eq!(message_of(input.clone()), Some(msg("blocked", Some("Claude needs your permission to use Bash"))));
    }

    // The inputs that Claude Code 2.1.325 sent.
    #[test]
    fn s5_the_captured_inputs_map_as_the_table_says() {
        assert_eq!(
            message_of(fixture("notification-permission")),
            Some(msg("blocked", Some("Claude needs your permission")))
        );
        assert_eq!(message_of(fixture("stop")), Some(msg("done", Some("You picked red."))));
        assert_eq!(message_of(fixture("user-prompt-submit")), Some(msg("clear", None)));
        assert_eq!(
            message_of(fixture("session-start")),
            Some(Msg::Resume {
                term_id: "t9".into(),
                cmd: Some("claude --resume 00000000-0000-0000-0000-000000000000".into())
            })
        );
    }

    // Claude Code 2.1.325 sends AskUserQuestion and plan approval as a
    // permission prompt, so they are blocked too.
    #[test]
    fn a_question_and_a_plan_approval_arrive_as_permission_prompts() {
        assert_eq!(
            message_of(fixture("notification-ask-user-question")),
            Some(msg("blocked", Some("Claude needs your permission")))
        );
        assert_eq!(
            message_of(fixture("notification-plan-approval")),
            Some(msg("blocked", Some("Claude Code needs your approval for the plan")))
        );
    }

    #[test]
    fn s5_stop_is_done_with_its_text_folded() {
        assert_eq!(done_text(json!("Done.\n\n  All   tests pass.\n")), Some("Done. All tests pass.".into()));
    }

    #[test]
    fn s5_a_prompt_clears_and_a_session_start_with_no_id_is_refused() {
        let prompt = json!({"hook_event_name": "UserPromptSubmit", "prompt": "x".repeat(10_000)});
        assert_eq!(message_of(prompt), Some(msg("clear", None)));
        assert_eq!(refusal_of(json!({"hook_event_name": "SessionStart", "source": "startup"})), "session_id refused");
    }

    fn session_start(id: Value) -> Value {
        let mut input = json!({"hook_event_name": "SessionStart", "source": "resume"});
        if !id.is_null() {
            input["session_id"] = id;
        }
        input
    }

    #[test]
    fn s22_a_session_id_from_the_safe_set_gives_its_resume_command() {
        for id in ["00000000-0000-0000-0000-000000000000", "ab_12", &format!("a{}", "b".repeat(127))] {
            let want = Msg::Resume { term_id: "t9".into(), cmd: Some(format!("claude --resume {id}")) };
            assert_eq!(message_of(session_start(json!(id))), Some(want), "{id}");
        }
    }

    #[test]
    fn s22_any_other_session_id_gives_nothing() {
        let too_long = json!(format!("a{}", "b".repeat(128)));
        for id in [
            json!("-rf"),
            json!("../x"),
            json!("a b"),
            json!("a;b"),
            json!("$(x)"),
            json!(""),
            too_long,
            json!(7),
            Value::Null,
            json!("_ab"),
            json!("aé"),
            json!("a٣"),
            json!("é1"),
        ] {
            assert_eq!(refusal_of(session_start(id.clone())), "session_id refused", "{id}");
        }
    }

    // The idle notification that Claude Code 2.1.325 sent 60 s after a Stop.
    #[test]
    fn s19_the_captured_idle_notification_is_nothing() {
        assert_eq!(fixture("notification-idle")["notification_type"], "idle_prompt");
        assert_eq!(message_of(fixture("notification-idle")), None);
    }

    #[test]
    fn s19_other_notifications_are_nothing() {
        for kind in [json!("idle_prompt"), json!("elicitation_dialog"), Value::Null] {
            let mut input = json!({"hook_event_name": "Notification", "message": "Claude is waiting for your input"});
            if !kind.is_null() {
                input["notification_type"] = kind.clone();
            }
            assert_eq!(message_of(input.clone()), None, "{kind}");
        }
    }

    #[test]
    fn an_unknown_or_missing_event_is_nothing() {
        for input in [json!({"hook_event_name": "PreToolUse"}), json!({"hook_event_name": 7}), json!({}), json!([])] {
            assert_eq!(message_of(input.clone()), None, "{input}");
        }
    }

    #[test]
    fn s18_a_long_text_is_capped_to_280_chars() {
        let text = done_text(json!("a".repeat(400))).unwrap();
        assert_eq!(text.chars().count(), REPORT_TEXT_MAX);
        assert!(text.ends_with('…'));
    }

    #[test]
    fn s18_no_text_when_it_is_blank_or_not_a_string() {
        for message in [json!(" \n\t "), json!(""), json!(7)] {
            assert_eq!(done_text(message.clone()), None, "{message}");
        }
        assert_eq!(message_of(json!({"hook_event_name": "Stop"})), Some(msg("done", None)));
    }

    #[test]
    fn s18_the_ends_are_trimmed() {
        assert_eq!(done_text(json!(" \n\t Done. \n")), Some("Done.".into()));
    }

    #[test]
    fn s18_every_kind_of_whitespace_folds() {
        assert_eq!(done_text(json!("a\t\r\n\u{000b}\u{000c}b")), Some("a b".into()));
    }

    #[test]
    fn s18_control_characters_are_removed_and_nothing_else_changes() {
        assert_eq!(done_text(json!("a\u{001b}[31mb\u{0007}c\u{009b}d")), Some("a[31mbcd".into()));
        assert_eq!(done_text(json!("a \u{001b} b")), Some("a b".into()));
        assert_eq!(done_text(json!("\u{001b}\u{0007}")), None);
    }

    #[test]
    fn s18_the_cap_counts_the_text_after_the_fold() {
        let text = format!("a{}", "   \n b".repeat(200));
        let folded = format!("a{}", " b".repeat(200));
        assert_eq!(done_text(json!(text)), Some(cap_report_text(&folded)));
        assert_eq!(done_text(json!(text)).unwrap().chars().count(), REPORT_TEXT_MAX);
    }

    #[test]
    fn s18_unicode_whitespace_folds_and_is_not_removed() {
        assert_eq!(done_text(json!("a\u{000b}b\u{000c}c\u{0085}d\u{00a0}e")), Some("a b c d e".into()));
    }

    #[test]
    fn s18_the_cap_counts_the_text_after_removal() {
        let letters = "a".repeat(REPORT_TEXT_MAX);
        let with_esc = format!("{}\u{001b}{}", &letters[..140], &letters[140..]);
        assert_eq!(done_text(json!(with_esc)), Some(letters));
    }
}
