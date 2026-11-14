//! `tarmac push`: one JSON value, or one per line of stdin, for the loaded
//! HTML cards of an open doc. The cli does not parse JSON: the daemon is the
//! one checker, and the cli stays std-only.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;

use tarmac_protocol::{self as proto, Msg, OVER_FRAME_LIMIT};

const LIMIT: usize = proto::MAX_FRAME_LEN as usize;
const NO_ANSWER_WHY: &str = "an older daemon, or the app is not reading";

pub fn run(args: &[String]) -> i32 {
    let Some((raw_path, mode)) = parse(args) else {
        eprintln!("tarmac: usage: tarmac push <path> <json>  |  tarmac push <path> -");
        return 2;
    };
    // No file-system call on the path, as for `open` (#267).
    let path = match std::path::absolute(raw_path) {
        Ok(path) => path.to_string_lossy().into_owned(),
        Err(e) => return fail(&format!("cannot push to {raw_path}: {e}")),
    };
    match mode {
        Mode::One(value) => one(&path, value),
        // The handshake comes before the first read of stdin.
        Mode::Stream => match crate::connect() {
            Ok(mut conn) => stream(&mut conn, &path, io::stdin().lock(), &mut io::stderr()),
            Err(why) => fail(&why),
        },
    }
}

fn fail(line: &str) -> i32 {
    fail_to(&mut io::stderr(), line)
}

fn fail_to(err: &mut impl Write, line: &str) -> i32 {
    let _ = writeln!(err, "tarmac: {line}");
    1
}

fn one(path: &str, value: &str) -> i32 {
    let Some(payload) = payload(path, value.to_owned(), LIMIT) else { return fail(OVER_FRAME_LIMIT) };
    match crate::connect().map(|mut conn| exchange(&mut conn, &payload)) {
        Ok(Sent::Acked) => 0,
        Ok(Sent::Refused(why) | Sent::Ended(why)) | Err(why) => fail(&why),
    }
}

/// A refused line does not end the stream; a connection that fails does,
/// since answers carry no id and a late one could be taken for the next
/// line's.
fn stream(conn: &mut UnixStream, path: &str, input: impl Read, err: &mut impl Write) -> i32 {
    let mut refused = false;
    for (line, n) in Lines::new(input, LIMIT).zip(1usize..) {
        let refusal = match line {
            Err(e) => return fail_to(err, &format!("cannot read stdin: {e}")),
            Ok(Line::Blank) => continue,
            Ok(Line::OverLimit) => OVER_FRAME_LIMIT.to_owned(),
            Ok(Line::NotUtf8) => "not UTF-8".to_owned(),
            Ok(Line::Value(text)) => match send_value(conn, path, text) {
                Sent::Acked => continue,
                Sent::Refused(refusal) => refusal,
                Sent::Ended(why) => return fail_to(err, &format!("line {n}: {why}")),
            },
        };
        fail_to(err, &format!("line {n}: {refusal}"));
        refused = true;
    }
    i32::from(refused)
}

#[derive(Debug, PartialEq)]
enum Sent {
    Acked,
    Refused(String),
    /// The connection failed: the stream ends.
    Ended(String),
}

fn send_value(conn: &mut UnixStream, path: &str, text: String) -> Sent {
    let Some(payload) = payload(path, text, LIMIT) else { return Sent::Refused(OVER_FRAME_LIMIT.to_owned()) };
    exchange(conn, &payload)
}

/// Sends one `push` and waits for its answer (`crate::exchange`).
fn exchange(conn: &mut UnixStream, payload: &[u8]) -> Sent {
    match crate::exchange(conn, payload, NO_ANSWER_WHY) {
        Ok(Ok(())) => Sent::Acked,
        Ok(Err(refusal)) => Sent::Refused(refusal),
        Err(why) => Sent::Ended(why),
    }
}

enum Mode<'a> {
    One(&'a str),
    Stream,
}

/// `<path> <json>` or `<path> -`. `None` is a usage error.
fn parse(args: &[String]) -> Option<(&str, Mode<'_>)> {
    match args {
        [path, dash] if dash == "-" => Some((path, Mode::Stream)),
        [path, value] => Some((path, Mode::One(value))),
        _ => None,
    }
}

#[derive(Debug, PartialEq)]
enum Line {
    Value(String),
    Blank,
    OverLimit,
    NotUtf8,
}

/// The lines of a stream, each held only to `limit` bytes.
struct Lines<R> {
    reader: BufReader<R>,
    limit: usize,
    held: Vec<u8>,
    done: bool,
}

impl<R: Read> Lines<R> {
    fn new(reader: R, limit: usize) -> Self {
        Lines { reader: BufReader::new(reader), limit, held: Vec::new(), done: false }
    }
}

impl<R: Read> Iterator for Lines<R> {
    type Item = io::Result<Line>;

    // The line is read in the reader's own chunks and held only to `limit`,
    // so a line of any length costs no more memory than that.
    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        self.held.clear();
        let (mut len, mut blank, mut last_cr, mut ended) = (0usize, true, false, false);
        while !ended {
            let chunk = match self.reader.fill_buf() {
                Ok([]) if len == 0 => {
                    self.done = true;
                    return None;
                }
                // The end is kept: on a terminal a second read would wait
                // for one more end of input.
                Ok([]) => {
                    self.done = true;
                    break;
                }
                Ok(chunk) => chunk,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    self.done = true;
                    return Some(Err(e));
                }
            };
            let (part, used) = match chunk.iter().position(|&b| b == b'\n') {
                Some(at) => (&chunk[..at], at + 1),
                None => (chunk, chunk.len()),
            };
            ended = used > part.len();
            if let Some(&last) = part.last() {
                len += part.len();
                blank &= part.iter().all(|b| matches!(b, b' ' | b'\t' | b'\r'));
                last_cr = last == b'\r';
                let room = self.limit.saturating_sub(self.held.len()).min(part.len());
                self.held.extend_from_slice(&part[..room]);
            }
            self.reader.consume(used);
        }
        let len = len - usize::from(last_cr && ended);
        let line = if blank {
            Line::Blank
        } else if len > self.limit {
            Line::OverLimit
        } else {
            self.held.truncate(len);
            match String::from_utf8(std::mem::take(&mut self.held)) {
                Ok(text) => Line::Value(text),
                Err(_) => Line::NotUtf8,
            }
        };
        Some(Ok(line))
    }
}

/// The encoded `push`, or `None` when it is over `limit`.
fn payload(path: &str, value: String, limit: usize) -> Option<Vec<u8>> {
    proto::encode_within(&Msg::Push { path: path.into(), value }, limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn read_all(input: &[u8], limit: usize) -> Vec<Line> {
        Lines::new(input, limit).map(Result::unwrap).collect()
    }

    fn value(text: &str) -> Line {
        Line::Value(text.into())
    }

    // S3
    #[test]
    fn a_value_argument_is_one_value_and_a_bare_dash_is_a_stream() {
        let one = args(&["/p", r#"{"n":1}"#]);
        assert!(matches!(parse(&one), Some(("/p", Mode::One(r#"{"n":1}"#)))));
        let stream = args(&["/p", "-"]);
        assert!(matches!(parse(&stream), Some(("/p", Mode::Stream))));
        let minus_one = args(&["/p", "-1"]);
        assert!(matches!(parse(&minus_one), Some(("/p", Mode::One("-1")))));
    }

    // S3
    #[test]
    fn any_other_argument_count_is_a_usage_error() {
        for list in [&[][..], &["/p"], &["/p", "1", "2"], &["/p", "-", "x", "y"]] {
            assert!(parse(&args(list)).is_none(), "{list:?}");
        }
    }

    // S4
    #[test]
    fn lines_end_at_a_newline_and_the_last_needs_none() {
        assert_eq!(read_all(b"a\nb\n", 8), vec![value("a"), value("b")]);
        assert_eq!(read_all(b"a\nb", 8), vec![value("a"), value("b")]);
    }

    // S5
    #[test]
    fn one_carriage_return_before_the_newline_is_dropped() {
        assert_eq!(read_all(b"a\r\nb\r\n", 8), vec![value("a"), value("b")]);
        assert_eq!(read_all(b"a\r\r\n", 8), vec![value("a\r")]);
    }

    // S6
    #[test]
    fn blank_lines_are_given_as_blank() {
        assert_eq!(
            read_all(b"a\n\n \t\nb\n", 8),
            vec![value("a"), Line::Blank, Line::Blank, value("b")]
        );
        assert_eq!(read_all(b"\r\n \r\n", 8), vec![Line::Blank, Line::Blank]);
        assert_eq!(read_all(b"          \n", 8), vec![Line::Blank], "blank over the limit");
        assert_eq!(read_all(b"        x\n", 8), vec![Line::OverLimit], "a value past the limit");
    }

    /// Interrupted once, then its bytes.
    struct Interrupted {
        interrupted: bool,
        rest: &'static [u8],
    }

    impl Read for Interrupted {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if !self.interrupted {
                self.interrupted = true;
                return Err(io::ErrorKind::Interrupted.into());
            }
            self.rest.read(buf)
        }
    }

    #[test]
    fn a_read_that_was_interrupted_is_made_again() {
        let input = Interrupted { interrupted: false, rest: b"1\n" };
        let lines: Vec<Line> = Lines::new(input, 8).map(Result::unwrap).collect();
        assert_eq!(lines, vec![value("1")]);
    }

    #[test]
    fn white_space_around_a_value_is_kept() {
        assert_eq!(read_all(b" 1 \t\n", 8), vec![value(" 1 \t")]);
    }

    // S7
    #[test]
    fn a_line_that_is_not_utf8_is_refused_and_the_next_is_read() {
        assert_eq!(read_all(b"1\n\xff\xfe\n2\n", 8), vec![value("1"), Line::NotUtf8, value("2")]);
    }

    // S8
    #[test]
    fn a_line_over_the_limit_is_refused_with_no_more_than_the_limit_held() {
        let mut lines = Lines::new(&b"123456789\nabcdefgh\n"[..], 8);
        assert_eq!(lines.next().unwrap().unwrap(), Line::OverLimit);
        assert_eq!(lines.held.len(), 8);
        assert_eq!(lines.next().unwrap().unwrap(), value("abcdefgh"));
        assert!(lines.next().is_none());
    }

    // S8
    #[test]
    fn a_long_line_is_held_to_the_limit_whatever_the_read_size() {
        let long = vec![b'7'; 64 * 1024];
        let mut lines = Lines::new(&long[..], 8);
        assert_eq!(lines.next().unwrap().unwrap(), Line::OverLimit);
        assert_eq!(lines.held.len(), 8);
    }

    // S8
    #[test]
    fn a_line_over_the_limit_that_is_not_utf8_is_refused_as_over_the_limit() {
        assert_eq!(read_all(b"\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\n", 8), vec![Line::OverLimit]);
    }

    // S8: the carriage return is not part of the line.
    #[test]
    fn a_line_of_the_limit_with_a_carriage_return_is_read_whole() {
        assert_eq!(read_all(b"abcdefgh\r\n", 8), vec![value("abcdefgh")]);
    }

    /// One byte for each read: every line ends across reads.
    struct OneByte(&'static [u8]);

    impl Read for OneByte {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let Some((&first, rest)) = self.0.split_first() else { return Ok(0) };
            buf[0] = first;
            self.0 = rest;
            Ok(1)
        }
    }

    // S5, S7, S8 with every line split across reads.
    #[test]
    fn lines_split_across_reads_are_read_as_whole_lines() {
        let input = b"a\r\nabcdefgh\r\nx\xe2\x82\xacy\n123456789\nlast";
        let lines: Vec<Line> = Lines::new(OneByte(input), 8).map(Result::unwrap).collect();
        assert_eq!(lines, vec![value("a"), value("abcdefgh"), value("x\u{20ac}y"), Line::OverLimit, value("last")]);
    }

    // S5: a `\r` is dropped only before a `\n`.
    #[test]
    fn a_carriage_return_at_the_end_of_input_stays_in_the_line() {
        assert_eq!(read_all(b"a\r", 8), vec![value("a\r")]);
        assert_eq!(read_all(b"abcdefgh\r", 8), vec![Line::OverLimit]);
    }

    /// `input`, then the end, after which a read panics: on a terminal a read
    /// after the end waits for one more end.
    struct EndsOnce {
        input: &'static [u8],
        ended: bool,
    }

    impl Read for EndsOnce {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            assert!(!self.ended, "a read after the end of input");
            let n = self.input.len().min(buf.len());
            buf[..n].copy_from_slice(&self.input[..n]);
            self.input = &self.input[n..];
            self.ended = n == 0;
            Ok(n)
        }
    }

    #[test]
    fn the_end_of_input_is_read_once() {
        for input in [&b"a"[..], b"a\n", b""] {
            let lines = Lines::new(EndsOnce { input, ended: false }, 8);
            let expected = if input.is_empty() { vec![] } else { vec![value("a")] };
            assert_eq!(lines.map(Result::unwrap).collect::<Vec<_>>(), expected, "{input:?}");
        }
    }

    // S9
    #[test]
    fn empty_input_has_no_line() {
        assert_eq!(read_all(b"", 8), vec![]);
    }

    /// One line, then an I/O error for every read after it.
    struct FailsAfter(&'static [u8]);

    impl Read for FailsAfter {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.0.is_empty() {
                return Err(io::Error::other("the disk is gone"));
            }
            let n = self.0.len().min(buf.len());
            buf[..n].copy_from_slice(&self.0[..n]);
            self.0 = &self.0[n..];
            Ok(n)
        }
    }

    // S55
    #[test]
    fn a_read_error_comes_after_the_lines_before_it_and_ends_the_lines() {
        let mut lines = Lines::new(FailsAfter(b"1\n"), 8);
        assert_eq!(lines.next().unwrap().unwrap(), value("1"));
        assert_eq!(lines.next().unwrap().unwrap_err().to_string(), "the disk is gone");
        assert!(lines.next().is_none());
    }

    // S42
    #[test]
    fn a_push_of_exactly_the_limit_passes_and_one_byte_more_does_not() {
        let limit = proto::encode(&Msg::Push { path: "/p".into(), value: "x".repeat(100) }).unwrap().len();
        let at = payload("/p", "x".repeat(100), limit).expect("exactly the limit");
        assert_eq!(proto::decode(&at).unwrap(), Msg::Push { path: "/p".into(), value: "x".repeat(100) });
        assert_eq!(payload("/p", "x".repeat(101), limit), None);
    }
    /// A connection whose daemon end reads and never answers, and whose cli
    /// end waits `wait` for an answer.
    fn silent_daemon(wait: std::time::Duration) -> (UnixStream, UnixStream) {
        let (cli, daemon) = UnixStream::pair().unwrap();
        cli.set_read_timeout(Some(wait)).unwrap();
        (cli, daemon)
    }

    // S16: the binary's own run of this, with the real 5 s, is in tests/push.rs.
    #[test]
    fn no_answer_in_the_read_timeout_is_worded_as_no_answer() {
        let (mut cli, _daemon) = silent_daemon(std::time::Duration::from_millis(100));
        let payload = payload("/p", "1".into(), LIMIT).unwrap();
        assert_eq!(exchange(&mut cli, &payload), Sent::Ended(crate::no_answer(NO_ANSWER_WHY)));
    }

    // S16
    #[test]
    fn a_stream_with_no_answer_ends_at_that_line() {
        let (mut cli, mut daemon) = silent_daemon(std::time::Duration::from_millis(100));
        let mut err = Vec::new();
        assert_eq!(stream(&mut cli, "/p", &b"1\n2\n"[..], &mut err), 1);
        assert_eq!(
            String::from_utf8(err).unwrap(),
            "tarmac: line 1: no answer from the daemon in 5 s (an older daemon, or the app is not reading)\n"
        );
        drop(cli);
        let sent: Vec<Msg> =
            std::iter::from_fn(|| proto::frame::read_sync(&mut daemon).ok()).map(|p| proto::decode(&p).unwrap()).collect();
        assert_eq!(sent, vec![Msg::Push { path: "/p".into(), value: "1".into() }]);
    }
}
