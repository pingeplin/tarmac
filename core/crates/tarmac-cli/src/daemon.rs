//! The daemon link every verb shares: the handshake, one frame each way, and
//! how a failure is worded. A verb keeps its own request and its own waits.

use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Instant;

use tarmac_protocol::{self as proto, Msg, frame};

#[expect(
    clippy::needless_pass_by_value,
    reason = "a borrow would also change NoHandshake::failed, which map_err takes by path"
)]
pub(crate) fn lost(e: io::Error) -> String {
    format!("daemon connection lost: {e}")
}

/// Sends `msg`, with a write that times out worded as `no_answer`.
pub(crate) fn send(stream: &mut UnixStream, msg: &Msg, no_answer: &str) -> Result<(), String> {
    let payload = proto::encode(msg).map_err(|e| format!("encode failed: {e}"))?;
    frame::write_sync(stream, &payload).map_err(|e| late_or_lost(e, no_answer))
}

/// One frame from the daemon, with a failed read worded by `read_failed`.
pub(crate) fn recv_or(stream: &mut UnixStream, read_failed: impl FnOnce(io::Error) -> String) -> Result<Msg, String> {
    decoded(&frame::read_sync(stream).map_err(read_failed)?)
}

fn decoded(payload: &[u8]) -> Result<Msg, String> {
    proto::decode(payload).map_err(|e| format!("bad frame from daemon: {e}"))
}

/// The daemon's answer to a request: `Ok(Ok(()))` for `ack`, `Ok(Err(msg))`
/// for `err`, skipping any other message. `Err` is a connection that failed,
/// with a failed read worded by `read_failed`.
pub(crate) fn answer(
    stream: &mut UnixStream,
    read_failed: impl Fn(io::Error) -> String,
) -> Result<Result<(), String>, String> {
    loop {
        match recv_or(stream, &read_failed)? {
            Msg::Ack => return Ok(Ok(())),
            Msg::Err { msg } => return Ok(Err(msg)),
            _ => continue,
        }
    }
}

/// One request and its answer, as `answer` gives it. A write or read that
/// times out is worded as `no_answer`.
pub(crate) fn exchange(stream: &mut UnixStream, payload: &[u8], no_answer: &str) -> Result<Result<(), String>, String> {
    frame::write_sync(stream, payload).map_err(|e| late_or_lost(e, no_answer))?;
    answer(stream, |e| late_or_lost(e, no_answer))
}

/// A time-out worded as `no_answer`; any other failure as a lost connection.
pub(crate) fn late_or_lost(e: io::Error, no_answer: &str) -> String {
    if is_timeout(&e) { no_answer.to_string() } else { lost(e) }
}

/// A read or write that ran out of time: a socket timeout gives either kind.
pub(crate) fn is_timeout(e: &io::Error) -> bool {
    matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

/// Gives the next read and write the time left until `until`. With none
/// left it is the time-out itself: the socket refuses a zero timeout.
pub(crate) fn time_out_at(stream: &UnixStream, until: Instant) -> io::Result<()> {
    let left = until.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Err(io::ErrorKind::TimedOut.into());
    }
    stream.set_read_timeout(Some(left))?;
    stream.set_write_timeout(Some(left))
}

/// How long `open`, `push`, `report`, `resume`, `--version` and the first answer to
/// `terms`, `events` and `wait` wait for the daemon.
pub(crate) use tarmac_protocol::DAEMON_WAIT;

/// The no-answer line of a request that every daemon answers: `open`'s,
/// and `--version`'s, whose only request is `hello`.
pub(crate) fn not_answered() -> String {
    format!("no answer from the daemon in {} s", DAEMON_WAIT.as_secs())
}

/// The no-answer line, with `why` saying what peer leaves the request unanswered.
pub(crate) fn no_answer(why: &str) -> String {
    format!("{} ({why})", not_answered())
}

/// `no_answer` for a verb whose request only a daemon that predates it leaves unanswered.
pub(crate) fn no_answer_older() -> String {
    no_answer("an older daemon")
}

/// The `hello_ok` fields; `open` needs only the reply, `--version` renders all.
pub(crate) struct DaemonInfo {
    pub(crate) daemon_version: Option<String>,
    pub(crate) daemon_pid: Option<u32>,
    pub(crate) app_version: Option<String>,
    pub(crate) app_connected: Option<bool>,
}

/// Why no `hello_ok` came back. Only a failed `connect` is evidence that nothing
/// is running; anything else, including a path we refused to dial, leaves the
/// daemon's state unobserved. A write or read that ran out of time is the
/// verb's own no-answer line.
pub(crate) enum NoHandshake {
    NoDaemon,
    TimedOut,
    Reason(String),
}

impl NoHandshake {
    /// Any other failed write or read is a lost connection.
    fn failed(e: io::Error) -> NoHandshake {
        if is_timeout(&e) { NoHandshake::TimedOut } else { NoHandshake::Reason(lost(e)) }
    }

    /// The line a verb prints, with a time-out worded as `no_answer`.
    pub(crate) fn worded(self, no_answer: &str) -> String {
        match self {
            NoHandshake::NoDaemon => format!(
                "no tarmac daemon running ({} channel, socket: {})",
                proto::channel_label(crate::current_channel()),
                crate::socket_path().display()
            ),
            NoHandshake::TimedOut => no_answer.to_string(),
            NoHandshake::Reason(why) => why,
        }
    }
}

/// Returns the live stream so `open` can keep using it. Each write and read
/// ends by `until`.
pub(crate) fn handshake(sock: &Path, until: Instant) -> Result<(UnixStream, DaemonInfo), NoHandshake> {
    proto::check_socket_path_len(sock).map_err(NoHandshake::Reason)?;
    let mut stream = UnixStream::connect(sock).map_err(|_| NoHandshake::NoDaemon)?;

    time_out_at(&stream, until).map_err(NoHandshake::failed)?;
    let hello = Msg::Hello { role: "cli".into(), v: proto::PROTOCOL_VERSION, app_version: None };
    let payload = proto::encode(&hello).map_err(|e| NoHandshake::Reason(format!("encode failed: {e}")))?;
    frame::write_sync(&mut stream, &payload).map_err(NoHandshake::failed)?;
    time_out_at(&stream, until).map_err(NoHandshake::failed)?;
    let reply = frame::read_sync(&mut stream).map_err(NoHandshake::failed)?;
    match decoded(&reply).map_err(NoHandshake::Reason)? {
        Msg::HelloOk { daemon_version, daemon_pid, app_version, app_connected, .. } => {
            Ok((stream, DaemonInfo { daemon_version, daemon_pid, app_version, app_connected }))
        }
        Msg::Err { msg } => Err(NoHandshake::Reason(format!("daemon rejected handshake: {msg}"))),
        other => Err(NoHandshake::Reason(format!("unexpected handshake reply: {other:?}"))),
    }
}

/// A connection past its handshake, or the reason there is none, as the
/// verbs that talk to the daemon print it, with a time-out worded as
/// `no_answer`. Every later read and write waits `DAEMON_WAIT`.
pub(crate) fn connect(no_answer: &str) -> Result<UnixStream, String> {
    let stream = connect_until(Instant::now() + DAEMON_WAIT).map_err(|e| e.worded(no_answer))?;
    let _ = stream.set_read_timeout(Some(DAEMON_WAIT));
    let _ = stream.set_write_timeout(Some(DAEMON_WAIT));
    Ok(stream)
}

/// The handshake on the channel's socket, ended by `until`.
pub(crate) fn connect_until(until: Instant) -> Result<UnixStream, NoHandshake> {
    handshake(&crate::socket_path(), until).map(|(stream, _)| stream)
}

/// The rest of a verb that speaks for the calling terminal, `report` or
/// `resume`, once its arguments passed: `msg` for the terminal named by
/// `TARMAC_TERM_ID`, sent and answered. Exit 1, with `needs_term` or the
/// daemon's answer on stderr, when it fails.
pub(crate) fn for_terminal(needs_term: &str, msg: impl FnOnce(String) -> Msg) -> i32 {
    let Some(term_id) = crate::calling_term() else {
        eprintln!("tarmac: {needs_term}");
        return 1;
    };
    let msg = msg(term_id);
    let until = Instant::now() + DAEMON_WAIT;
    let no_answer = no_answer_older();
    let sent = connect_until(until)
        .map_err(|e| e.worded(&no_answer))
        .and_then(|mut stream| send_acked(&mut stream, &msg, until, &no_answer));
    match sent {
        Ok(()) => 0,
        Err(why) => {
            eprintln!("tarmac: {why}");
            1
        }
    }
}

/// Sends `msg` on a connection past its handshake and waits for its `ack`
/// by `until`: each write and read gets the time that is left, and running
/// out of it is `no_answer`. Prints nothing: the error is the line the
/// caller prints.
pub(crate) fn send_acked(stream: &mut UnixStream, msg: &Msg, until: Instant, no_answer: &str) -> Result<(), String> {
    let payload = proto::encode(msg).map_err(|e| format!("encode failed: {e}"))?;
    let worded = |e| late_or_lost(e, no_answer);
    time_out_at(stream, until).map_err(worded)?;
    frame::write_sync(stream, &payload).map_err(worded)?;
    time_out_at(stream, until).map_err(worded)?;
    answer(stream, worded)?
}
