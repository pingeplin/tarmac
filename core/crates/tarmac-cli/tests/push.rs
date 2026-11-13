// `tarmac push` (spec 2611.0003) against a daemon double that answers each
// `push` as the test says. The daemon's own answers are its tests' business;
// here the subject is what the cli sends, prints and exits with.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, MAX_FRAME_LEN, Msg};

mod common;
use common::{Double, Report, channel, hello_ok, scratch, tarmac, tarmac_at};

const NO_ANSWER: &str = "no answer from the daemon in 5 s (an older daemon, or the app is not reading)";

/// What the double does with the `push` it has just read.
enum Answer {
    Reply(Vec<Msg>),
    /// Reads for `wait` first, recording a frame that comes in it as early.
    After(Duration, Msg),
    Close,
    /// Never answers, and records every frame after it.
    Silence,
}

fn ack() -> Answer {
    Answer::Reply(vec![Msg::Ack])
}

fn err(msg: &str) -> Answer {
    Answer::Reply(vec![Msg::Err { msg: msg.into() }])
}

struct PushDaemon {
    double: Double,
    /// Frames that came while an answer was owed.
    early: Arc<AtomicUsize>,
}

impl PushDaemon {
    /// `answer` is given the index of each `push`, from 0.
    fn start(mut answer: impl FnMut(usize) -> Answer + Send + 'static) -> Self {
        let early = Arc::new(AtomicUsize::new(0));
        let seen_early = early.clone();
        let double = Double::start("tarmacd.sock", move |peer| {
            let hello_ok = proto::encode(&hello_ok(None, None, None, None)).unwrap();
            if peer.read().is_none() || !peer.write(&hello_ok) {
                return;
            }
            let mut n = 0;
            while peer.read().is_some() {
                let replies = match answer(n) {
                    Answer::Reply(msgs) => msgs,
                    Answer::After(wait, msg) => {
                        if peer.read_within(wait).is_some() {
                            seen_early.fetch_add(1, Ordering::SeqCst);
                        }
                        vec![msg]
                    }
                    Answer::Close => return,
                    Answer::Silence => {
                        while peer.read().is_some() {}
                        return;
                    }
                };
                for msg in replies {
                    if !peer.write(&proto::encode(&msg).unwrap()) {
                        return;
                    }
                }
                n += 1;
            }
        });
        PushDaemon { double, early }
    }

    fn acking() -> Self {
        PushDaemon::start(|_| ack())
    }

    fn push(&self, args: &[&str]) -> Report {
        Report::of(tarmac_at(&self.double.sock).arg("push").args(args))
    }

    fn stream(&self, path: &str, input: impl Into<Vec<u8>>) -> Report {
        Report::of_input(tarmac_at(&self.double.sock).args(["push", path, "-"]), input.into())
    }

    /// Every frame after the `hello`, decoded; the `hello` is checked.
    fn pushes(&self) -> Vec<Msg> {
        let frames = self.double.frames();
        let (hello, rest) = frames.split_first().expect("a hello");
        assert!(matches!(proto::decode(hello).unwrap(), Msg::Hello { .. }), "the first frame is the hello");
        rest.iter().map(|f| proto::decode(f).unwrap()).collect()
    }
}

fn push_msg(path: &str, value: &str) -> Msg {
    Msg::Push { path: path.into(), value: value.into() }
}

fn no_daemon_line(sock: &Path) -> String {
    format!("tarmac: no tarmac daemon running ({} channel, socket: {})\n", channel(), sock.display())
}

// S10
#[test]
fn one_value_is_one_push_and_success_prints_nothing() {
    let daemon = PushDaemon::acking();
    let out = daemon.push(&["/a/dash.html", r#"{"n":1}"#]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
    assert_eq!(daemon.pushes(), vec![push_msg("/a/dash.html", r#"{"n":1}"#)]);
}

// S10: getcwd gives /private/var for /var.
#[test]
fn a_relative_path_is_sent_made_absolute_against_the_cwd() {
    let dir = scratch();
    let expected = std::fs::canonicalize(&dir).unwrap().join("rel/dash.html");
    let daemon = PushDaemon::acking();
    let out = Report::of(
        tarmac_at(&daemon.double.sock).current_dir(&dir).args(["push", "rel/dash.html", "1"]),
    );

    assert_eq!(out.code(), Some(0), "stderr: {}", out.stderr);
    assert_eq!(daemon.pushes(), vec![push_msg(expected.to_str().unwrap(), "1")]);
}

// S3
#[test]
fn any_other_argument_count_is_a_usage_error() {
    for args in [&["push"][..], &["push", "/p"], &["push", "/p", "1", "2"]] {
        let out = Report::of(tarmac().args(args));
        assert_eq!(out.code(), Some(2), "{args:?}");
        assert_eq!(
            out.one_stderr_line(),
            "tarmac: usage: tarmac push <path> <json>  |  tarmac push <path> -\n",
            "{args:?}"
        );
    }
}

// S11
#[test]
fn a_thousand_lines_are_a_thousand_pushes_in_order_on_one_connection() {
    let daemon = PushDaemon::acking();
    let input: String = (0..1000).map(|n| format!("{{\"n\":{n}}}\n")).collect();
    let out = daemon.stream("/a/dash.html", input);

    assert_eq!(out.code(), Some(0), "stderr: {}", out.stderr);
    assert_eq!(out.stderr, "");
    let expected: Vec<Msg> = (0..1000).map(|n| push_msg("/a/dash.html", &format!("{{\"n\":{n}}}"))).collect();
    assert_eq!(daemon.pushes(), expected);
}

// S12
#[test]
fn a_line_the_daemon_refuses_is_named_and_the_stream_goes_on() {
    let daemon = PushDaemon::start(|n| if n == 1 { err("not one JSON value: x") } else { ack() });
    let out = daemon.stream("/p", "{\"n\":1}\nnot json\n{\"n\":2}\n");

    assert_eq!(out.stderr, "tarmac: line 2: not one JSON value: x\n");
    assert_eq!(out.code(), Some(1));
    assert_eq!(
        daemon.pushes(),
        vec![push_msg("/p", r#"{"n":1}"#), push_msg("/p", "not json"), push_msg("/p", r#"{"n":2}"#)]
    );
}

// S6 and S12 through the binary: blank lines are counted and not sent.
#[test]
fn a_refused_line_is_named_by_its_number_counting_blank_lines() {
    let daemon = PushDaemon::start(|n| if n == 1 { err("x") } else { ack() });
    let out = daemon.stream("/p", "1\n\n \t\nnot json\n");

    assert_eq!(out.stderr, "tarmac: line 4: x\n");
    assert_eq!(out.code(), Some(1));
    assert_eq!(daemon.pushes(), vec![push_msg("/p", "1"), push_msg("/p", "not json")]);
}

// S6 through the binary: a blank line is neither sent nor refused.
#[test]
fn blank_lines_are_skipped_without_a_word() {
    let daemon = PushDaemon::acking();
    let out = daemon.stream("/p", "1\n\n \r\n2\n");

    assert_eq!((out.code(), out.stderr.as_str()), (Some(0), ""));
    assert_eq!(daemon.pushes(), vec![push_msg("/p", "1"), push_msg("/p", "2")]);
}

// S13
#[test]
fn one_value_the_daemon_refuses_prints_its_text() {
    let daemon = PushDaemon::start(|_| err("not an open doc: /p"));
    let out = daemon.push(&["/p", "1"]);

    assert_eq!(out.stderr, "tarmac: not an open doc: /p\n");
    assert_eq!(out.code(), Some(1));
}

// S14
#[test]
fn a_line_that_is_not_utf8_is_refused_by_the_cli_and_not_sent() {
    let daemon = PushDaemon::acking();
    let out = daemon.stream("/p", b"1\n\xff\xfe\n3\n".to_vec());

    assert_eq!(out.stderr, "tarmac: line 2: not UTF-8\n");
    assert_eq!(out.code(), Some(1));
    assert_eq!(daemon.pushes(), vec![push_msg("/p", "1"), push_msg("/p", "3")]);
}

// S8 and S42 through the pipe: a line over the limit, and a line of the limit
// whose `push` is over it, are refused; neither is sent.
#[test]
fn a_line_over_the_frame_limit_is_refused_by_the_cli_and_not_sent() {
    let daemon = PushDaemon::acking();
    let limit = MAX_FRAME_LEN as usize;
    let mut input = vec![b'7'; limit + 1];
    input.push(b'\n');
    input.extend(std::iter::repeat_n(b'7', limit));
    input.extend_from_slice(b"\n3\n");
    let out = daemon.stream("/p", input);

    assert_eq!(
        out.stderr,
        "tarmac: line 1: value is over the frame limit (16 MiB)\ntarmac: line 2: value is over the frame limit (16 MiB)\n"
    );
    assert_eq!(out.code(), Some(1));
    assert_eq!(daemon.pushes(), vec![push_msg("/p", "3")]);
}

// S15
#[test]
fn no_daemon_is_the_message_open_gives() {
    let sock = scratch().join("absent.sock");
    let out = Report::of(tarmac_at(&sock).args(["push", "/p", "1"]));

    assert_eq!(out.code(), Some(1));
    assert_eq!(out.stderr, no_daemon_line(&sock));
}

// S15: stdin stays open and holds nothing, so a cli that read first would
// never exit.
#[test]
fn no_daemon_ends_a_stream_before_stdin_is_read() {
    let sock = scratch().join("absent.sock");
    let out = Report::with_open_stdin(tarmac_at(&sock).args(["push", "/p", "-"]), Duration::from_secs(10))
        .expect("the cli exits with stdin open");

    assert_eq!(out.code(), Some(1));
    assert_eq!(out.stderr, no_daemon_line(&sock));
}

// S16
#[test]
fn one_value_with_no_answer_ends_after_the_read_timeout() {
    let daemon = PushDaemon::start(|_| Answer::Silence);
    let started = Instant::now();
    let out = daemon.push(&["/p", "1"]);

    assert_eq!(out.stderr, format!("tarmac: {NO_ANSWER}\n"));
    assert_eq!(out.code(), Some(1));
    assert!(started.elapsed() >= Duration::from_secs(5), "it waited {:?}", started.elapsed());
}

// S43
#[test]
fn one_value_on_a_lost_connection_says_so() {
    let daemon = PushDaemon::start(|_| Answer::Close);
    let out = daemon.push(&["/p", "1"]);

    assert!(out.one_stderr_line().starts_with("tarmac: daemon connection lost: "), "got: {}", out.stderr);
    assert_eq!(out.code(), Some(1));
}

// S43
#[test]
fn a_lost_connection_ends_a_stream_with_lines_still_to_come() {
    let daemon = PushDaemon::start(|_| Answer::Close);
    let out = daemon.stream("/p", "1\n2\n3\n");

    assert!(out.one_stderr_line().starts_with("tarmac: line 1: daemon connection lost: "), "got: {}", out.stderr);
    assert_eq!(out.code(), Some(1));
    assert_eq!(daemon.pushes(), vec![push_msg("/p", "1")]);
}

// S44
#[test]
fn the_next_line_is_sent_only_after_the_answer() {
    let wait = Duration::from_millis(300);
    let daemon = PushDaemon::start(move |n| if n < 3 { Answer::After(wait, Msg::Ack) } else { ack() });
    let out = daemon.stream("/p", "1\n2\n3\n4\n");

    assert_eq!(out.code(), Some(0), "stderr: {}", out.stderr);
    assert_eq!(daemon.pushes().len(), 4);
    assert_eq!(daemon.early.load(Ordering::SeqCst), 0, "a frame came while an answer was owed");
}

// S52
#[test]
fn an_answer_that_is_not_ack_or_err_is_skipped() {
    let daemon = PushDaemon::start(|_| Answer::Reply(vec![hello_ok(None, None, None, None), Msg::Ack]));
    let out = daemon.push(&["/p", "1"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(0), ""));
}

// S53: the double is dropped before `received` is read, and a connection the
// cli made would be accepted first.
#[test]
fn an_empty_path_is_refused_with_no_connection() {
    let daemon = PushDaemon::acking();
    let out = daemon.push(&["", "1"]);
    let received = daemon.double.received.clone();
    drop(daemon);

    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().starts_with("tarmac: cannot push to : "), "got: {}", out.stderr);
    assert!(received.lock().unwrap().is_empty(), "the cli connected");
}

// S54
#[test]
fn one_value_sends_a_blank_argument_as_it_is() {
    for blank in ["", " "] {
        let daemon = PushDaemon::start(|_| err("not one JSON value: EOF"));
        let out = daemon.push(&["/p", blank]);

        assert_eq!(out.code(), Some(1));
        assert_eq!(daemon.pushes(), vec![push_msg("/p", blank)], "{blank:?}");
    }
}

// S55
#[test]
fn a_read_error_on_stdin_ends_the_stream_and_names_stdin() {
    let daemon = PushDaemon::acking();
    let dir = std::fs::File::open(scratch()).unwrap();
    let out = Report::with_stdin(tarmac_at(&daemon.double.sock).args(["push", "/p", "-"]), dir);

    assert!(out.one_stderr_line().starts_with("tarmac: cannot read stdin: "), "got: {}", out.stderr);
    assert_eq!(out.code(), Some(1));
    assert_eq!(daemon.pushes(), vec![]);
}
