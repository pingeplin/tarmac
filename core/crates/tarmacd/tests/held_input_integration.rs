// Spec 2611.0016, D11: an `input` with `hold` waits until the pty's line
// discipline leaves canonical mode, where a line over 1024 bytes is cut.

mod common;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use common::{Conn, TestDaemon};
use tarmac_protocol::Msg;

/// A child that leaves canonical mode after `delay` (never, with `None`),
/// then writes the first `count` bytes it reads to `out`.
fn reader(app: &mut Conn, dir: &Path, delay: Option<&str>, count: usize) -> PathBuf {
    let out = dir.join("out");
    let raw = delay.map(|d| format!("sleep {d}; stty -icanon; ")).unwrap_or_default();
    let script = format!("{raw}head -c {count} > '{}'; sleep 5", out.display());
    app.spawn_term("t1", &["/bin/sh", "-c", &script]);
    out
}

fn send(app: &mut Conn, bytes: Vec<u8>, hold: bool) {
    app.send(&Msg::Input { term_id: "t1".into(), bytes, typed: false, hold });
}

/// `out` once it holds `len` bytes, or what it holds after `within`.
fn read_out(out: &Path, len: usize, within: Duration) -> String {
    let deadline = Instant::now() + within;
    loop {
        let got = std::fs::read(out).unwrap_or_default();
        if got.len() >= len || Instant::now() >= deadline {
            return String::from_utf8(got).unwrap();
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn line(c: char, n: usize) -> Vec<u8> {
    format!("{}\r", c.to_string().repeat(n)).into_bytes()
}

/// The child's view of `line`: the tty maps the `\r` to `\n` (ICRNL).
fn as_read(c: char, n: usize) -> String {
    format!("{}\n", c.to_string().repeat(n))
}

// S31
#[test]
fn s31_a_held_input_over_the_canonical_limit_arrives_whole_once_the_shell_takes_keys() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let out = reader(&mut app, &daemon.dir, Some("0.3"), 4097);

    send(&mut app, line('x', 4096), true);

    assert_eq!(read_out(&out, 4097, Duration::from_secs(5)), as_read('x', 4096));
}

// S32
#[test]
fn s32_input_after_a_held_input_is_written_after_it() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let out = reader(&mut app, &daemon.dir, Some("0.5"), 2001 + 11);

    send(&mut app, line('a', 2000), true);
    send(&mut app, line('b', 10), false);

    let mut want = as_read('a', 2000);
    want.push_str(&as_read('b', 10));
    assert_eq!(read_out(&out, want.len(), Duration::from_secs(5)), want);
}

// S34
#[test]
fn s34_an_input_with_no_hold_is_written_at_once_to_a_canonical_child() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let out = reader(&mut app, &daemon.dir, None, 6);
    std::thread::sleep(Duration::from_millis(300));

    send(&mut app, line('y', 5), false);

    assert_eq!(read_out(&out, 6, Duration::from_secs(3)), as_read('y', 5));
}

// D11: a hold keeps taking the app's input into the terminal's own queue, so
// the app connection never waits on a full input channel; order is kept.
#[test]
fn more_inputs_than_the_channel_holds_during_a_hold_block_no_later_frame_and_keep_their_order() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let numbered: Vec<String> = (0..300).map(|i| format!("{i:03},")).collect();
    let behind = numbered.concat();
    let out = reader(&mut app, &daemon.dir, Some("2"), 11 + behind.len());
    send(&mut app, line('h', 10), true);
    for input in &numbered {
        send(&mut app, input.clone().into_bytes(), false);
    }
    let asked = Instant::now();

    app.send(&Msg::ScrollbackRequest { term_id: "t1".into() });

    app.recv_until("the scrollback reply", |m| matches!(m, Msg::Scrollback { .. }));
    assert!(asked.elapsed() < Duration::from_millis(1000), "the app connection waited {:?}", asked.elapsed());
    assert_eq!(read_out(&out, 11 + behind.len(), Duration::from_secs(6)), format!("{}{behind}", as_read('h', 10)));
}
