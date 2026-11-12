//! `tarmac push`: one JSON value, or one per line of stdin, for the loaded
//! HTML cards of an open doc. The cli does not parse JSON: the daemon is the
//! one checker, and the cli stays std-only.

use std::io::{self, BufRead, BufReader, Read};
use std::os::unix::net::UnixStream;

use tarmac_protocol::{self as proto, Msg, frame};

const LIMIT: usize = proto::MAX_FRAME_LEN as usize;
const OVER_LIMIT: &str = "value is over the frame limit (16 MiB)";
const NO_ANSWER: &str = "no answer from the daemon in 5 s (an older daemon, or the app is not reading)";

pub fn run(args: &[String]) -> i32 {
    let Some((raw_path, mode)) = parse(args) else {
        eprintln!("tarmac: usage: tarmac push <html-path> <json>  |  tarmac push <html-path> -");
        return 2;
    };
    // No file-system call on the path, as for `open` (#267).
    let path = match std::path::absolute(raw_path) {
        Ok(path) => path.to_string_lossy().into_owned(),
        Err(e) => return fail(&format!("cannot push to '{raw_path}': {e}")),
    };
    match mode {
        Mode::One(value) => one(&path, value),
        Mode::Stream => stream(&path, io::stdin().lock()),
    }
}

fn fail(line: &str) -> i32 {
    eprintln!("tarmac: {line}");
    1
}

fn one(path: &str, value: &str) -> i32 {
    let Some(payload) = payload(path, value.to_owned(), LIMIT) else { return fail(OVER_LIMIT) };
    let mut conn = match crate::connect() {
        Ok(conn) => conn,
        Err(why) => return fail(&why),
    };
    match exchange(&mut conn, &payload) {
        Ok(Ok(())) => 0,
        Ok(Err(refusal)) | Err(refusal) => fail(&refusal),
    }
}

/// The handshake comes before the first read of `input`. A refused line does
/// not end the stream; a connection that fails does, since answers carry no
/// id and a late one could be taken for the next line's.
fn stream(path: &str, input: impl Read) -> i32 {
    let mut conn = match crate::connect() {
        Ok(conn) => conn,
        Err(why) => return fail(&why),
    };
    let mut refused = false;
    for line in Lines::new(input, LIMIT) {
        let (n, line) = match line {
            Ok(line) => line,
            Err(e) => return fail(&format!("cannot read stdin: {e}")),
        };
        let refusal = match line {
            Line::Blank => continue,
            Line::OverLimit => OVER_LIMIT.to_owned(),
            Line::NotUtf8 => "not UTF-8".to_owned(),
            Line::Value(text) => match payload(path, text, LIMIT) {
                None => OVER_LIMIT.to_owned(),
                Some(payload) => match exchange(&mut conn, &payload) {
                    Ok(Ok(())) => continue,
                    Ok(Err(refusal)) => refusal,
                    Err(why) => return fail(&format!("line {n}: {why}")),
                },
            },
        };
        eprintln!("tarmac: line {n}: {refusal}");
        refused = true;
    }
    i32::from(refused)
}

/// Sends one `push` and waits for its answer: `Ok` with the daemon's `ack` or
/// `err`, `Err` when the connection failed. Other answers are skipped.
fn exchange(conn: &mut UnixStream, payload: &[u8]) -> Result<Result<(), String>, String> {
    let lost = |e: io::Error| format!("daemon connection lost: {e}");
    frame::write_sync(conn, payload).map_err(lost)?;
    loop {
        let answer = frame::read_sync(conn).map_err(|e| match e.kind() {
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => NO_ANSWER.to_owned(),
            _ => lost(e),
        })?;
        match proto::decode(&answer).map_err(|e| format!("bad frame from daemon: {e}"))? {
            Msg::Ack => return Ok(Ok(())),
            Msg::Err { msg } => return Ok(Err(msg)),
            _ => continue,
        }
    }
}

pub enum Mode<'a> {
    One(&'a str),
    Stream,
}

/// `<path> <json>` or `<path> -`. `None` is a usage error.
pub fn parse(args: &[String]) -> Option<(&str, Mode<'_>)> {
    match args {
        [path, dash] if dash == "-" => Some((path, Mode::Stream)),
        [path, value] => Some((path, Mode::One(value))),
        _ => None,
    }
}

#[derive(Debug, PartialEq)]
pub enum Line {
    Value(String),
    Blank,
    OverLimit,
    NotUtf8,
}

/// The lines of a stream, numbered from 1.
pub struct Lines<R> {
    reader: BufReader<R>,
    limit: usize,
    number: usize,
    held: Vec<u8>,
    done: bool,
    /// The most bytes of one line held at once.
    #[cfg(test)]
    peak: usize,
}

impl<R: Read> Lines<R> {
    pub fn new(reader: R, limit: usize) -> Self {
        Lines {
            reader: BufReader::new(reader),
            limit,
            number: 0,
            held: Vec::new(),
            done: false,
            #[cfg(test)]
            peak: 0,
        }
    }
}

impl<R: Read> Iterator for Lines<R> {
    type Item = io::Result<(usize, Line)>;

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
                Ok([]) => break,
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
                #[cfg(test)]
                {
                    self.peak = self.peak.max(self.held.len());
                }
            }
            self.reader.consume(used);
        }
        self.number += 1;
        let len = len - usize::from(last_cr);
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
        Some(Ok((self.number, line)))
    }
}

/// The encoded `push`, or `None` when it is over `limit`.
pub fn payload(path: &str, data: String, limit: usize) -> Option<Vec<u8>> {
    let payload = proto::encode(&Msg::Push { path: path.into(), data }).ok()?;
    (payload.len() <= limit).then_some(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn read_all(input: &[u8], limit: usize) -> Vec<(usize, Line)> {
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
        assert_eq!(read_all(b"a\nb\n", 8), vec![(1, value("a")), (2, value("b"))]);
        assert_eq!(read_all(b"a\nb", 8), vec![(1, value("a")), (2, value("b"))]);
    }

    // S5
    #[test]
    fn one_carriage_return_before_the_newline_is_dropped() {
        assert_eq!(read_all(b"a\r\nb\r\n", 8), vec![(1, value("a")), (2, value("b"))]);
        assert_eq!(read_all(b"a\r\r\n", 8), vec![(1, value("a\r"))]);
    }

    // S6
    #[test]
    fn blank_lines_are_skipped_and_still_counted() {
        assert_eq!(
            read_all(b"a\n\n \t\nb\n", 8),
            vec![(1, value("a")), (2, Line::Blank), (3, Line::Blank), (4, value("b"))]
        );
        assert_eq!(read_all(b"\r\n \r\n", 8), vec![(1, Line::Blank), (2, Line::Blank)]);
        assert_eq!(read_all(b"          \n", 8), vec![(1, Line::Blank)], "blank over the limit");
    }

    #[test]
    fn white_space_around_a_value_is_kept() {
        assert_eq!(read_all(b" 1 \t\n", 8), vec![(1, value(" 1 \t"))]);
    }

    // S7
    #[test]
    fn a_line_that_is_not_utf8_is_refused_and_the_next_is_read() {
        assert_eq!(read_all(b"1\n\xff\xfe\n2\n", 8), vec![(1, value("1")), (2, Line::NotUtf8), (3, value("2"))]);
    }

    // S8
    #[test]
    fn a_line_over_the_limit_is_refused_with_no_more_than_the_limit_held() {
        let mut lines = Lines::new(&b"123456789\nabcdefgh\n"[..], 8);
        assert_eq!(lines.next().unwrap().unwrap(), (1, Line::OverLimit));
        assert_eq!(lines.next().unwrap().unwrap(), (2, value("abcdefgh")));
        assert!(lines.next().is_none());
        assert_eq!(lines.peak, 8);
    }

    // S8
    #[test]
    fn a_long_line_is_held_to_the_limit_whatever_the_read_size() {
        let long = vec![b'7'; 64 * 1024];
        let mut lines = Lines::new(&long[..], 8);
        assert_eq!(lines.next().unwrap().unwrap(), (1, Line::OverLimit));
        assert!(lines.peak <= 8, "held {}", lines.peak);
    }

    // S8
    #[test]
    fn a_line_over_the_limit_that_is_not_utf8_is_refused_as_over_the_limit() {
        assert_eq!(read_all(b"\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\n", 8), vec![(1, Line::OverLimit)]);
    }

    // S8: the carriage return is not part of the line.
    #[test]
    fn a_line_of_the_limit_with_a_carriage_return_is_read_whole() {
        assert_eq!(read_all(b"abcdefgh\r\n", 8), vec![(1, value("abcdefgh"))]);
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
        assert_eq!(lines.next().unwrap().unwrap(), (1, value("1")));
        assert_eq!(lines.next().unwrap().unwrap_err().to_string(), "the disk is gone");
        assert!(lines.next().is_none());
    }

    // S42
    #[test]
    fn a_push_of_exactly_the_limit_passes_and_one_byte_more_does_not() {
        let limit = proto::encode(&Msg::Push { path: "/p".into(), data: "x".repeat(100) }).unwrap().len();
        let at = payload("/p", "x".repeat(100), limit).expect("exactly the limit");
        assert_eq!(proto::decode(&at).unwrap(), Msg::Push { path: "/p".into(), data: "x".repeat(100) });
        assert_eq!(payload("/p", "x".repeat(101), limit), None);
    }
}
