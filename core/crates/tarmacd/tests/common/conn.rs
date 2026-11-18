use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, BoardMeta, DocEntry, Msg, TermInfo, frame};

use super::{FrameLog, LONG, Logged, Restore, contains, is_file_event_for, is_report_for, temp_dir};

pub struct Conn(pub UnixStream);

impl Conn {
    pub fn connect(sock: &Path) -> Self {
        let stream = UnixStream::connect(sock).expect("connect");
        stream.set_write_timeout(Some(LONG)).unwrap();
        Conn(stream)
    }

    pub fn hello(sock: &Path, role: &str) -> Self {
        Conn::hello_as(sock, role, None).0
    }

    /// `hello` with an explicit `app_version`, returning the `hello_ok` too so a
    /// test can read what the daemon reported back (spec 2609.0012).
    pub fn hello_as(sock: &Path, role: &str, app_version: Option<&str>) -> (Self, Msg) {
        let mut conn = Conn::connect(sock);
        conn.send(&Msg::Hello {
            role: role.into(),
            v: proto::PROTOCOL_VERSION,
            app_version: app_version.map(str::to_string),
        });
        let reply = conn.recv(Instant::now() + LONG, "hello_ok");
        assert!(matches!(reply, Msg::HelloOk { v: 1, .. }), "expected hello_ok, got {reply:?}");
        (conn, reply)
    }

    /// The app-slot fields of a fresh `cli` handshake: `(app_connected, app_version)`.
    pub fn probe_app_slot(sock: &Path) -> (Option<bool>, Option<String>) {
        let (_, reply) = Conn::hello_as(sock, "cli", None);
        let Msg::HelloOk { app_connected, app_version, .. } = reply else {
            panic!("expected hello_ok, got {reply:?}")
        };
        (app_connected, app_version)
    }

    pub fn send(&mut self, msg: &Msg) {
        let payload = proto::encode(msg).unwrap();
        frame::write_sync(&mut self.0, &payload).expect("write frame");
    }

    pub fn recv(&mut self, deadline: Instant, what: &str) -> Msg {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "timed out waiting for {what}");
        self.0.set_read_timeout(Some(remaining)).unwrap();
        let payload = frame::read_sync(&mut self.0)
            .unwrap_or_else(|e| panic!("read frame while waiting for {what}: {e}"));
        proto::decode(&payload).expect("decode frame")
    }

    pub fn recv_until(&mut self, what: &str, mut pred: impl FnMut(&Msg) -> bool) -> Msg {
        let deadline = Instant::now() + LONG;
        loop {
            let msg = self.recv(deadline, what);
            if pred(&msg) {
                return msg;
            }
        }
    }

    /// Drain the board_list + restore the daemon pushes on connect and after a
    /// board create, switch or delete, so later reads see only the frames the test
    /// drives.
    pub fn drain_board(&mut self) {
        self.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
        self.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    }

    pub fn recv_board_list(&mut self) -> (Vec<BoardMeta>, String) {
        let msg = self.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
        let Msg::BoardList { boards, active } = msg else { unreachable!() };
        (boards, active)
    }

    pub fn recv_restore(&mut self) -> Restore {
        Restore::from(self.recv_until("restore", |m| matches!(m, Msg::Restore { .. })))
    }

    pub fn recv_restore_for(&mut self, board: &str) -> Restore {
        Restore::from(self.recv_until(&format!("restore for {board}"), |m| {
            matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some(board))
        }))
    }

    /// `board_create`: the daemon names the new board `id` and makes it active.
    pub fn create_board(&mut self, id: &str) -> Restore {
        self.send(&Msg::BoardCreate);
        self.recv_restore_for(id)
    }

    pub fn switch_to(&mut self, board: &str) -> Restore {
        self.send(&Msg::BoardSwitch { board_id: board.into() });
        self.recv_restore_for(board)
    }

    /// An app open of `path` onto `board`, whatever board is active.
    pub fn open_on(&mut self, board: &str, path: &str) {
        self.send(&Msg::Open { path: path.into(), term_id: None, board_id: Some(board.into()) });
        self.recv_doc_opened_for(path);
    }

    pub fn recv_doc_opened(&mut self) -> DocEntry {
        let msg = self.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));
        let Msg::DocOpened(entry) = msg else { unreachable!() };
        entry
    }

    pub fn recv_doc_opened_for(&mut self, path: &str) -> DocEntry {
        let msg = self.recv_until(&format!("doc_opened for {path}"), |m| {
            matches!(m, Msg::DocOpened(e) if e.path == path)
        });
        let Msg::DocOpened(entry) = msg else { unreachable!() };
        entry
    }

    /// The `mtime_ms` of the next file_event for `path`.
    pub fn recv_file_event_for(&mut self, path: &str) -> u64 {
        let msg = self.recv_until(&format!("file_event for {path}"), |m| is_file_event_for(m, path));
        let Msg::FileEvent { mtime_ms, .. } = msg else { unreachable!() };
        mtime_ms
    }

    /// Like `recv_file_event_for`, but skips events older than `min_mtime_ms`.
    pub fn recv_file_event_since(&mut self, path: &str, min_mtime_ms: u64) -> u64 {
        let msg = self.recv_until(&format!("file_event for {path} since {min_mtime_ms}"), |m| {
            matches!(m, Msg::FileEvent { path: p, mtime_ms } if p == path && *mtime_ms >= min_mtime_ms)
        });
        let Msg::FileEvent { mtime_ms, .. } = msg else { unreachable!() };
        mtime_ms
    }

    /// The next exit of any term: `(term_id, code)`.
    pub fn recv_exit(&mut self) -> (String, Option<i64>) {
        let msg = self.recv_until("exit", |m| matches!(m, Msg::Exit { .. }));
        let Msg::Exit { term_id, code, .. } = msg else { unreachable!() };
        (term_id, code)
    }

    /// Waits for a single output chunk of `term_id` that contains `needle`.
    pub fn recv_output_containing(&mut self, term_id: &str, needle: &str) {
        self.recv_until(&format!("output containing {needle:?}"), |m| {
            matches!(m, Msg::Output { term_id: t, bytes } if t == term_id && contains(bytes, needle.as_bytes()))
        });
    }

    /// Echo `marker` through a live `cat` and wait until the daemon has seen it, so
    /// the term's scrollback ring is known to hold it.
    pub fn echo_marker(&mut self, term_id: &str, marker: &str) {
        self.type_line(term_id, marker);
        self.recv_output_containing(term_id, marker);
    }

    /// Appends `term_id`'s output to `collected` until it contains `needle`;
    /// other terms' frames and every Exit are skipped.
    pub fn collect_output_into(&mut self, collected: &mut Vec<u8>, term_id: &str, what: &str, needle: &[u8]) {
        let deadline = Instant::now() + LONG;
        while !contains(collected, needle) {
            if let Msg::Output { term_id: t, bytes } = self.recv(deadline, what)
                && t == term_id
            {
                collected.extend_from_slice(&bytes);
            }
        }
    }

    pub fn spawn_term(&mut self, term_id: &str, cmd: &[&str]) {
        self.spawn_term_with(term_id, cmd, Spawn::default());
    }

    /// A cli `report` from the test process itself, and the daemon's answer.
    /// The walk from the test process never reaches a pty, so the caller is
    /// unattributed.
    pub fn cli_report(sock: &Path, term_id: &str, kind: &str, text: Option<&str>) -> Msg {
        let mut cli = Conn::hello(sock, "cli");
        cli.send(&Msg::Report { term_id: term_id.into(), kind: kind.into(), text: text.map(str::to_string) });
        cli.recv(Instant::now() + LONG, "the answer to a report")
    }

    /// A cli `resume` from the test process itself, and the daemon's answer.
    pub fn cli_resume(sock: &Path, term_id: &str, cmd: Option<&str>) -> Msg {
        let mut cli = Conn::hello(sock, "cli");
        cli.send(&Msg::Resume { term_id: term_id.into(), cmd: cmd.map(str::to_string) });
        cli.recv(Instant::now() + LONG, "the answer to a resume")
    }

    /// A cli `subscribe` on this connection (spec 2611.0012): the frames
    /// before `ack`. An `err`, or no `ack` in 5 s, fails the test.
    pub fn subscribe(&mut self, kinds: Option<&[&str]>, term_id: Option<&str>) -> Vec<Msg> {
        self.send(&Msg::Subscribe {
            kinds: kinds.map(|k| k.iter().map(|s| s.to_string()).collect()),
            term_id: term_id.map(str::to_string),
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut snapshot = Vec::new();
        loop {
            match self.recv(deadline, "the ack of a subscribe") {
                Msg::Ack => return snapshot,
                Msg::Err { msg } => panic!("the subscribe was refused: {msg}"),
                msg => snapshot.push(msg),
            }
        }
    }

    pub fn recv_report_for(&mut self, term_id: &str) -> Msg {
        self.recv_until(&format!("term_report for {term_id}"), |m| is_report_for(m, term_id))
    }

    /// The next frame that matches `pred` within `wait`, or `None`.
    pub fn recv_within(&mut self, wait: Duration, mut pred: impl FnMut(&Msg) -> bool) -> Option<Msg> {
        let deadline = Instant::now() + wait;
        let found = loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break None;
            }
            self.0.set_read_timeout(Some(remaining)).unwrap();
            match frame::read_sync(&mut self.0) {
                Ok(payload) => {
                    let msg = proto::decode(&payload).expect("decode frame");
                    if pred(&msg) {
                        break Some(msg);
                    }
                }
                Err(_) => break None,
            }
        };
        self.0.set_read_timeout(Some(LONG)).unwrap();
        found
    }

    /// Types `line` and a newline into `term_id`.
    pub fn type_line(&mut self, term_id: &str, line: &str) {
        self.input(term_id, format!("{line}\n").as_bytes());
    }

    /// An `input` the app marks as typed by the user.
    pub fn keystroke(&mut self, term_id: &str, bytes: &[u8]) {
        self.send(&Msg::Input { term_id: term_id.into(), bytes: bytes.to_vec(), typed: true, hold: false });
    }

    pub fn input(&mut self, term_id: &str, bytes: &[u8]) {
        self.send(&Msg::Input { term_id: term_id.into(), bytes: bytes.to_vec(), typed: false, hold: false });
    }

    /// Reads frames into `log` until one matches `pred`; its index.
    pub fn log_until(&mut self, log: &mut FrameLog, what: &str, mut pred: impl FnMut(&Msg) -> bool) -> usize {
        let deadline = Instant::now() + LONG;
        loop {
            let msg = self.recv(deadline, what);
            let hit = pred(&msg);
            log.0.push(Logged { at: Instant::now(), msg });
            if hit {
                return log.0.len() - 1;
            }
        }
    }

    /// Reads frames into `log` until `term_id`'s output from index `from` on
    /// contains `needle`; the index of the chunk that completes it.
    pub fn log_until_output(&mut self, log: &mut FrameLog, term_id: &str, from: usize, needle: &[u8]) -> usize {
        let deadline = Instant::now() + LONG;
        loop {
            if let Some(i) = log.output_index_containing(term_id, from, needle) {
                return i;
            }
            let msg = self.recv(deadline, &format!("output containing {:?}", String::from_utf8_lossy(needle)));
            log.0.push(Logged { at: Instant::now(), msg });
        }
    }

    /// Spawns a login shell `term_id` and logs frames into `log` until its
    /// prompt shows.
    pub fn login_shell_at_prompt(&mut self, log: &mut FrameLog, term_id: &str, opts: Spawn) {
        let from = log.len();
        self.spawn_term_with(term_id, &[], Spawn { login_shell: true, ..opts });
        self.log_until_output(log, term_id, from, b"$ ");
    }

    /// Spawns `term_id` as `sleep 5` run by a symlink named `claude`.
    pub fn spawn_as_claude(&mut self, term_id: &str) {
        let link = temp_dir().join("claude");
        std::os::unix::fs::symlink("/bin/sleep", &link).unwrap();
        self.spawn_term(term_id, &[link.to_str().unwrap(), "5"]);
    }

    /// Reads every frame that comes within `wait` into `log`.
    pub fn log_for(&mut self, log: &mut FrameLog, wait: Duration) {
        self.recv_within(wait, |msg| {
            log.0.push(Logged { at: Instant::now(), msg: msg.clone() });
            false
        });
    }

    pub fn spawn_term_with(&mut self, term_id: &str, cmd: &[&str], opts: Spawn) {
        self.send(&Msg::SpawnTerm {
            term_id: term_id.into(),
            cols: opts.cols,
            rows: opts.rows,
            cwd: opts.cwd,
            cmd: (!opts.login_shell).then(|| cmd.iter().map(|s| s.to_string()).collect()),
            board_id: opts.board_id,
            inherit_cwd_from: opts.inherit_cwd_from,
            succeeds: opts.succeeds,
        });
    }
}

/// The `spawn_term` fields a test seldom sets. The default is an 80x24 pty on the
/// active board with no cwd.
pub struct Spawn {
    pub cols: u16,
    pub rows: u16,
    pub cwd: Option<String>,
    pub board_id: Option<String>,
    pub inherit_cwd_from: Option<String>,
    pub succeeds: Option<String>,
    /// Sends `cmd: None`, so the daemon spawns `$SHELL -il`; the `cmd` given
    /// is not sent.
    pub login_shell: bool,
}

impl Spawn {
    pub fn login_shell() -> Self {
        Spawn { login_shell: true, ..Default::default() }
    }

    pub fn on_board(board_id: &str) -> Self {
        Spawn { board_id: Some(board_id.into()), ..Default::default() }
    }
}

impl Default for Spawn {
    fn default() -> Self {
        Spawn { cols: 80, rows: 24, cwd: None, board_id: None, inherit_cwd_from: None, succeeds: None, login_shell: false }
    }
}

/// A cli connection subscribed with `kinds` and `term_id`, and its snapshot.
pub fn subscriber(sock: &Path, kinds: Option<&[&str]>, term_id: Option<&str>) -> (Conn, Vec<Msg>) {
    let mut cli = Conn::hello(sock, "cli");
    let snapshot = cli.subscribe(kinds, term_id);
    (cli, snapshot)
}

/// The daemon's answer to a cli `terms_list`.
pub fn cli_terms(sock: &Path) -> Vec<TermInfo> {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::TermsList);
    match cli.recv(Instant::now() + LONG, "terms") {
        Msg::Terms { terms } => terms,
        other => panic!("expected terms, got {other:?}"),
    }
}

pub fn cli_open(sock: &Path, path: &str) {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::Open { path: path.into(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
}
