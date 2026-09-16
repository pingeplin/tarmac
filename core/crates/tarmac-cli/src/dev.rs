//! `tarmac dev <verb>` — the in-app QA driver's CLI half (spec 2609.0015, #166).
//!
//! One frame out, one frame back, print `body`, exit. The CLI never parses
//! `body`, which is what keeps this crate std-only: the app owns every decision
//! about what a verb means, and this file owns only argv and exit codes.
//!
//! The whole family is debug-builds-only, and the gate is this module's own
//! `#[cfg(debug_assertions)]` in `main.rs` — nothing inside here re-checks it,
//! because inside a module that only exists in debug builds any such check is
//! constant. `main.rs` carries the matching release arm; without it the verb
//! would fall through to the unknown-command path and exit 2 instead of 1.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use tarmac_protocol::{self as proto, frame};
use proto::dev::{DevRequest, decode_reply, encode_request};

use crate::{current_channel, env_override};

/// The app's own budget, plus 3 s of slack. The three deadlines nest — the
/// frontend's `--until` poll ends at `timeout_ms`, the backend at `+2000`, the
/// CLI at `+3000` — so the innermost one always fires and an expired wait is
/// reported by the side that actually observed it. Reusing the handshake path's
/// fixed 5 s would make `--timeout 10000` die client-side and blame a healthy app.
pub fn read_deadline_ms(timeout_ms: Option<u32>) -> u64 {
    timeout_ms.unwrap_or(0) as u64 + 3_000
}

const USAGE: &str = "\
usage: tarmac dev snapshot [--until <expr>] [--timeout <ms>]
       tarmac dev zoom <z>
       tarmac dev resize <card> <w>x<h>
       tarmac dev focus <card>|board
       tarmac dev type <card> \"<text>\"
       tarmac dev key <card> \"<combo>\"";

fn usage<T>(what: &str) -> Result<T, String> {
    Err(format!("{what}\n{USAGE}"))
}

/// Parse everything after `dev`. `Err` is a usage error (exit 2); it always names
/// `tarmac dev`, via `USAGE`, so a mistyped verb points at the whole family.
pub fn parse_verb(args: &[String]) -> Result<DevRequest, String> {
    let Some(verb) = args.first().map(String::as_str) else {
        return usage("tarmac dev: no verb");
    };
    let rest = &args[1..];
    match verb {
        "snapshot" => parse_snapshot(rest),
        "zoom" => match rest {
            [z] => match z.parse::<f64>() {
                // No range check: the board clamps to [0.1, 3.0] and the reply
                // reports what it settled on (D10). A second definition of the
                // limits here could only ever drift from the first.
                Ok(z) if z.is_finite() => Ok(DevRequest::Zoom { z }),
                _ => usage(&format!("tarmac dev zoom: not a number: {z}")),
            },
            _ => usage("tarmac dev zoom: expected exactly one argument"),
        },
        "focus" => match rest {
            [target] if target == "board" => Ok(DevRequest::Focus { card: None }),
            [card] => Ok(DevRequest::Focus { card: Some(card.clone()) }),
            _ => usage("tarmac dev focus: expected <card> or board"),
        },
        "resize" => match rest {
            [card, size] => {
                let (w, h) = parse_size(size)?;
                Ok(DevRequest::Resize { card: card.clone(), w, h })
            }
            _ => usage("tarmac dev resize: expected <card> <w>x<h>"),
        },
        "type" => match rest {
            [card, text] => Ok(DevRequest::Type { card: card.clone(), text: text.clone() }),
            _ => usage("tarmac dev type: expected <card> <text>"),
        },
        "key" => match rest {
            [card, combo] => Ok(DevRequest::Key { card: card.clone(), combo: combo.clone() }),
            _ => usage("tarmac dev key: expected <card> <combo>"),
        },
        other => usage(&format!("tarmac dev: unknown verb '{other}'")),
    }
}

const DEFAULT_TIMEOUT_MS: u32 = 5_000;

fn parse_snapshot(mut rest: &[String]) -> Result<DevRequest, String> {
    let mut until = None;
    let mut timeout_ms = DEFAULT_TIMEOUT_MS;
    while let Some(flag) = rest.first().map(String::as_str) {
        let Some(value) = rest.get(1) else {
            return usage(&format!("tarmac dev snapshot: {flag} needs a value"));
        };
        match flag {
            "--until" => until = Some(value.clone()),
            // 0 is valid and means "evaluate once" — the app answers `timeout`
            // unless the expression already holds. A `> 0` guard would turn that
            // boundary into a usage error.
            "--timeout" => match value.parse::<u32>() {
                Ok(ms) => timeout_ms = ms,
                Err(_) => {
                    return usage(&format!("tarmac dev snapshot: --timeout is not a number: {value}"));
                }
            },
            other => return usage(&format!("tarmac dev snapshot: unknown flag {other}")),
        }
        rest = &rest[2..];
    }
    Ok(DevRequest::Snapshot { until, timeout_ms: Some(timeout_ms) })
}

/// `<w>x<h>` in board units. Lowercase `x` only, and both halves required: one
/// spelling means a scenario that typos the size fails loudly instead of quietly
/// resizing to something else.
fn parse_size(size: &str) -> Result<(f64, f64), String> {
    let bad = || format!("tarmac dev resize: expected <w>x<h> in board units, got {size:?}");
    let Some((w, h)) = size.split_once('x') else {
        return usage(&bad());
    };
    match (w.parse::<f64>(), h.parse::<f64>()) {
        (Ok(w), Ok(h)) if w.is_finite() && h.is_finite() => Ok((w, h)),
        _ => usage(&bad()),
    }
}

pub fn dev_socket_path() -> PathBuf {
    let over = env_override("TARMAC_DEV_SOCKET");
    let home = std::env::var_os("HOME").unwrap_or_else(|| std::ffi::OsString::from("/"));
    proto::dev::resolve_dev_socket_path(over, &home, current_channel())
}

/// Send one request, print the reply, and return the process exit code.
///
/// Errors this function raises are the CLI's own and stay **one-line plain text**
/// on stderr, exactly like `tarmac open`. Errors the *app* raises arrive as a
/// `body` and are printed verbatim — stdout when `ok`, stderr when not, so
/// `tarmac dev snapshot | jq` is never fed an error object.
pub fn run(args: &[String]) -> i32 {
    let req = match parse_verb(args) {
        Ok(req) => req,
        Err(msg) => {
            eprintln!("{msg}");
            return 2;
        }
    };
    match exchange(&req) {
        Ok(reply) => {
            if reply.ok {
                println!("{}", reply.body);
                0
            } else {
                eprintln!("{}", reply.body);
                1
            }
        }
        Err(line) => {
            eprintln!("tarmac: {line}");
            1
        }
    }
}

fn exchange(req: &DevRequest) -> Result<proto::dev::DevReply, String> {
    let sock = dev_socket_path();
    proto::check_socket_path_len(&sock)?;
    let mut stream = UnixStream::connect(&sock)
        .map_err(|_| format!("no tarmac app driver at {} (is `make run` up?)", sock.display()))?;
    let deadline = Duration::from_millis(read_deadline_ms(req.timeout_ms()));
    let _ = stream.set_read_timeout(Some(deadline));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let payload = encode_request(req).map_err(|e| format!("encode failed: {e}"))?;
    frame::write_sync(&mut stream, &payload).map_err(|e| format!("app connection lost: {e}"))?;
    let _ = stream.flush();
    let reply = frame::read_sync(&mut stream).map_err(|e| format!("app connection lost: {e}"))?;
    decode_reply(&reply).map_err(|e| format!("bad frame from app: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::dev::DevRequest;

    fn parse(args: &[&str]) -> Result<DevRequest, String> {
        let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        parse_verb(&owned)
    }

    /// S53 - the 5000 ms default is pinned here, not read back from the source.
    #[test]
    fn snapshot_defaults_to_a_five_second_budget() {
        assert_eq!(
            parse(&["snapshot"]).unwrap(),
            DevRequest::Snapshot { until: None, timeout_ms: Some(5000) },
        );
    }

    /// S54 - both flags are captured; malformed values are usage errors.
    #[test]
    fn snapshot_flags_parse_and_reject() {
        assert_eq!(
            parse(&["snapshot", "--until", "viewport.zoom == 0.5", "--timeout", "1500"]).unwrap(),
            DevRequest::Snapshot {
                until: Some("viewport.zoom == 0.5".into()),
                timeout_ms: Some(1500),
            },
        );
        for bad in [
            vec!["snapshot", "--timeout", "abc"],
            vec!["snapshot", "--timeout", "-1"],
            vec!["snapshot", "--until"],
            vec!["snapshot", "--timeout"],
            vec!["snapshot", "--nope", "1"],
        ] {
            assert!(parse(&bad).is_err(), "expected a usage error for {bad:?}");
        }
    }

    /// S54 - `--timeout 0` means "evaluate once" and is VALID. A `> 0` guard would
    /// make it a usage error; this is the boundary that catches one.
    #[test]
    fn a_zero_timeout_is_valid_and_means_evaluate_once() {
        assert_eq!(
            parse(&["snapshot", "--timeout", "0"]).unwrap(),
            DevRequest::Snapshot { until: None, timeout_ms: Some(0) },
        );
    }

    /// S55 - every other verb, with its arguments.
    #[test]
    fn each_verb_parses_to_its_variant() {
        assert_eq!(parse(&["zoom", "0.5"]).unwrap(), DevRequest::Zoom { z: 0.5 });
        assert_eq!(parse(&["focus", "board"]).unwrap(), DevRequest::Focus { card: None });
        assert_eq!(
            parse(&["focus", "t-1"]).unwrap(),
            DevRequest::Focus { card: Some("t-1".into()) },
        );
        assert_eq!(
            parse(&["type", "t-1", "hi"]).unwrap(),
            DevRequest::Type { card: "t-1".into(), text: "hi".into() },
        );
        assert_eq!(
            parse(&["key", "t-1", "ctrl+c"]).unwrap(),
            DevRequest::Key { card: "t-1".into(), combo: "ctrl+c".into() },
        );
    }

    /// S55 - `zoom abc` is a usage error, but an out-of-range zoom is NOT: the app
    /// clamps it (D10), and a range check here would be a second definition of the
    /// board's zoom limits.
    #[test]
    fn zoom_rejects_non_numbers_but_not_out_of_range_values() {
        assert!(parse(&["zoom", "abc"]).is_err());
        assert_eq!(parse(&["zoom", "99"]).unwrap(), DevRequest::Zoom { z: 99.0 });
        assert_eq!(parse(&["zoom", "0.001"]).unwrap(), DevRequest::Zoom { z: 0.001 });
    }

    /// S55 - an empty text is a present argument, so it parses; the app answers it.
    #[test]
    fn an_empty_type_text_parses() {
        assert_eq!(
            parse(&["type", "t-1", ""]).unwrap(),
            DevRequest::Type { card: "t-1".into(), text: String::new() },
        );
    }

    /// S56 - `<w>x<h>` in board units, lowercase `x` only, so a typo fails loudly
    /// rather than resizing to something else.
    #[test]
    fn resize_parses_wxh_and_rejects_every_other_spelling() {
        assert_eq!(
            parse(&["resize", "t-1", "800x600"]).unwrap(),
            DevRequest::Resize { card: "t-1".into(), w: 800.0, h: 600.0 },
        );
        for bad in ["800", "800x", "x600", "800X600", "800x600x2", "axb", ""] {
            assert!(parse(&["resize", "t-1", bad]).is_err(), "expected a usage error for {bad:?}");
        }
    }

    /// S57 - unknown verbs and wrong arity are usage errors naming `tarmac dev`.
    #[test]
    fn unknown_verbs_and_wrong_arity_are_usage_errors() {
        for bad in [
            vec![],
            vec!["teleport"],
            vec!["zoom"],
            vec!["zoom", "1", "extra"],
            vec!["focus"],
            vec!["focus", "t-1", "extra"],
            vec!["type", "t-1"],
            vec!["key", "t-1"],
            vec!["resize", "t-1"],
        ] {
            let err = parse(&bad).expect_err(&format!("expected a usage error for {bad:?}"));
            assert!(err.contains("tarmac dev"), "usage line does not name `tarmac dev`: {err}");
        }
    }

    /// S73(a) - the CLI's read deadline is the app's budget plus 3 s, so the
    /// innermost deadline is always the one that fires.
    #[test]
    fn the_read_deadline_is_the_app_budget_plus_three_seconds() {
        assert_eq!(read_deadline_ms(None), 3_000);
        assert_eq!(read_deadline_ms(Some(0)), 3_000);
        assert_eq!(read_deadline_ms(Some(10_000)), 13_000);
    }

    /// S73(a) - and it is derived from the request, so no caller can forget it.
    /// The rule lives on `DevRequest` because both ends of the socket need it.
    #[test]
    fn the_deadline_reads_the_budget_off_the_request() {
        assert_eq!(
            DevRequest::Snapshot { until: None, timeout_ms: Some(10_000) }.timeout_ms(),
            Some(10_000),
        );
        assert_eq!(DevRequest::Zoom { z: 1.0 }.timeout_ms(), None);
    }

    /// S65 - this module exists only under `#[cfg(debug_assertions)]`, so the
    /// channel it resolves is necessarily `Dev`. Asserting it is the whole of what
    /// an in-build test can say; Q1 (a real release bundle) is the coverage that
    /// matters, and the spec says so.
    #[test]
    fn the_dev_family_resolves_the_dev_channel() {
        assert_eq!(crate::current_channel(), proto::Channel::Dev);
    }
}
