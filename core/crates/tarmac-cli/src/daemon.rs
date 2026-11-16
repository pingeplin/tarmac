//! The daemon link every verb shares: the handshake, one frame each way, and
//! how a failure is worded. A verb keeps its own request and its own waits.

use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg, frame};

pub(crate) fn lost(e: io::Error) -> String {
    format!("daemon connection lost: {e}")
}

pub(crate) fn send(stream: &mut UnixStream, msg: &Msg) -> Result<(), String> {
    let payload = proto::encode(msg).map_err(|e| format!("encode failed: {e}"))?;
    frame::write_sync(stream, &payload).map_err(lost)
}

/// One frame from the daemon, with a failed read worded by `read_failed`.
pub(crate) fn recv_or(stream: &mut UnixStream, read_failed: impl FnOnce(io::Error) -> String) -> Result<Msg, String> {
    let payload = frame::read_sync(stream).map_err(read_failed)?;
    proto::decode(&payload).map_err(|e| format!("bad frame from daemon: {e}"))
}

/// The daemon's answer to a request: `Ok(Ok(()))` for `ack`, `Ok(Err(msg))`
/// for `err`, skipping any other message. `Err` is a connection that failed,
/// with a failed read worded by `read_failed`.
pub(crate) fn answer(stream: &mut UnixStream, read_failed: impl Fn(io::Error) -> String) -> Result<Result<(), String>, String> {
    loop {
        match recv_or(stream, &read_failed)? {
            Msg::Ack => return Ok(Ok(())),
            Msg::Err { msg } => return Ok(Err(msg)),
            _ => continue,
        }
    }
}

/// One request and its answer, as `answer` gives it. A read that times out
/// is worded as no answer, with `why` saying what peer leaves one unanswered.
pub(crate) fn exchange(stream: &mut UnixStream, payload: &[u8], why: &str) -> Result<Result<(), String>, String> {
    frame::write_sync(stream, payload).map_err(lost)?;
    answer(stream, |e| late_or_lost(e, &no_answer(why)))
}

/// `exchange` inside `until`: each write and read gets the time that is left,
/// and running out of it is worded as `no_answer`.
pub(crate) fn exchange_until(
    stream: &mut UnixStream,
    payload: &[u8],
    until: Instant,
    no_answer: &str,
) -> Result<Result<(), String>, String> {
    let worded = |e| late_or_lost(e, no_answer);
    time_out_at(stream, until).map_err(worded)?;
    frame::write_sync(stream, payload).map_err(worded)?;
    time_out_at(stream, until).map_err(worded)?;
    answer(stream, worded)
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

/// How long `open`, `push`, `report`, `--version` and the first answer to
/// `terms`, `events` and `wait` wait for the daemon.
pub(crate) const DAEMON_WAIT: Duration = Duration::from_secs(5);

pub(crate) fn no_answer(why: &str) -> String {
    format!("no answer from the daemon in {} s ({why})", DAEMON_WAIT.as_secs())
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
/// daemon's state unobserved.
pub(crate) enum NoHandshake {
    NoDaemon,
    Reason(String),
}

/// Returns the live stream so `open` can keep using it. Each write and read
/// ends by `until`; a failed one is worded by `failed`.
pub(crate) fn handshake(
    sock: &Path,
    until: Instant,
    failed: &dyn Fn(io::Error) -> String,
) -> Result<(UnixStream, DaemonInfo), NoHandshake> {
    proto::check_socket_path_len(sock).map_err(NoHandshake::Reason)?;
    let mut stream = UnixStream::connect(sock).map_err(|_| NoHandshake::NoDaemon)?;
    let timed = |stream: &UnixStream| time_out_at(stream, until).map_err(|e| NoHandshake::Reason(failed(e)));

    timed(&stream)?;
    let hello = Msg::Hello { role: "cli".into(), v: proto::PROTOCOL_VERSION, app_version: None };
    let payload = proto::encode(&hello).map_err(|e| NoHandshake::Reason(format!("encode failed: {e}")))?;
    frame::write_sync(&mut stream, &payload).map_err(|e| NoHandshake::Reason(failed(e)))?;
    timed(&stream)?;
    match recv_or(&mut stream, failed).map_err(NoHandshake::Reason)? {
        Msg::HelloOk { daemon_version, daemon_pid, app_version, app_connected, .. } => Ok((
            stream,
            DaemonInfo { daemon_version, daemon_pid, app_version, app_connected },
        )),
        Msg::Err { msg } => Err(NoHandshake::Reason(format!("daemon rejected handshake: {msg}"))),
        other => Err(NoHandshake::Reason(format!("unexpected handshake reply: {other:?}"))),
    }
}

/// A connection past its handshake, or the reason there is none, as the
/// verbs that talk to the daemon print it. Every later read and write waits
/// `DAEMON_WAIT`.
pub(crate) fn connect() -> Result<UnixStream, String> {
    let stream = connect_until(Instant::now() + DAEMON_WAIT, &lost)?;
    let _ = stream.set_read_timeout(Some(DAEMON_WAIT));
    let _ = stream.set_write_timeout(Some(DAEMON_WAIT));
    Ok(stream)
}

/// `connect`, with the handshake ended by `until` and a failed write or read
/// worded by `failed`.
pub(crate) fn connect_until(until: Instant, failed: &dyn Fn(io::Error) -> String) -> Result<UnixStream, String> {
    let sock = crate::socket_path();
    let (stream, _) = handshake(&sock, until, failed).map_err(|e| match e {
        NoHandshake::NoDaemon => format!(
            "no tarmac daemon running ({} channel, socket: {})",
            proto::channel_label(crate::current_channel()),
            sock.display()
        ),
        NoHandshake::Reason(why) => why,
    })?;
    Ok(stream)
}
