use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::{self as proto, Msg, frame};

use super::{Conn, FrameLog, LONG, Restore, Spawn};

// Counter, not just a timestamp: parallel test threads can hit the same
// nanosecond and would then share (and tear down) each other's socket dir.
static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

pub fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-it-{}-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

pub struct TestDaemon {
    pub child: Child,
    pub dir: PathBuf,
    pub sock: PathBuf,
}

impl TestDaemon {
    pub fn start() -> Self {
        Self::start_with(|_| {})
    }

    /// `configure` runs after the default environment is set, so it can override it.
    pub fn start_with(configure: impl FnOnce(&mut Command)) -> Self {
        Self::launch(temp_dir(), configure)
    }

    /// A daemon whose `cmd: None` spawns are `/bin/sh -il` with `HOME` an empty
    /// dir: a job-control shell that reads no rc file of the user (spec
    /// 2611.0009, OQ4).
    pub fn start_sh() -> Self {
        let dir = temp_dir();
        let home = dir.join("home");
        std::fs::create_dir_all(&home).unwrap();
        Self::launch(dir, |cmd| {
            cmd.env("SHELL", "/bin/sh").env("HOME", &home);
        })
    }

    /// A shell command that sends `frames`, each framed, from a process in a
    /// pty: the frames go to a file in the daemon's dir, and `nc` sends them
    /// (spec 2611.0009, OQ3). The daemon's answers are written to the pty.
    pub fn nc_reporter(&self, name: &str, frames: &[Msg]) -> String {
        let mut bytes = Vec::new();
        for msg in frames {
            frame::write_sync(&mut bytes, &proto::encode(msg).unwrap()).unwrap();
        }
        let file = self.dir.join(format!("{name}.frames"));
        std::fs::write(&file, bytes).unwrap();
        format!("/usr/bin/nc -U -w 2 {} < {}", self.sock.display(), file.display())
    }

    /// `nc_reporter` for a `resume` of `term_id` (spec 2611.0011): the hello
    /// and the frame.
    pub fn nc_resume(&self, name: &str, term_id: &str, cmd: &str) -> String {
        let hello = Msg::Hello { role: "cli".into(), v: proto::PROTOCOL_VERSION, app_version: None };
        self.nc_reporter(name, &[hello, Msg::Resume { term_id: term_id.into(), cmd: Some(cmd.into()) }])
    }

    /// A new app connection, which takes the app's place, and the restore of
    /// the active board it gets: every later app frame goes on it.
    pub fn probe(&self) -> (Conn, Restore) {
        let mut app = self.connect_app();
        app.recv_board_list();
        let restore = app.recv_restore();
        (app, restore)
    }

    /// The inode of `state.json`: each save renames a new file in, so a save
    /// that writes the same bytes still changes it.
    pub fn state_inode(&self) -> u64 {
        std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(self.state_file()).unwrap())
    }

    /// A daemon that loads `state` (a `state.json`) at its start.
    pub fn start_seeded(state: &serde_json::Value) -> Self {
        Self::start_seeded_with(state, |_| {})
    }

    pub fn start_seeded_with(state: &serde_json::Value, configure: impl FnOnce(&mut Command)) -> Self {
        let dir = temp_dir();
        std::fs::write(dir.join("state.json"), state.to_string()).unwrap();
        Self::launch(dir, configure)
    }

    fn launch(dir: PathBuf, configure: impl FnOnce(&mut Command)) -> Self {
        let sock = dir.join("tarmacd.sock");
        let child = spawn_daemon_with(&sock, configure);
        wait_for_socket(&sock);
        TestDaemon { child, dir, sock }
    }

    /// A new daemon on the same socket and state, once the last one has exited.
    pub fn relaunch(&mut self) {
        self.child = spawn_daemon(&self.sock);
        wait_for_socket(&self.sock);
    }

    pub fn state_file(&self) -> PathBuf {
        self.dir.join("state.json")
    }

    pub fn state_json(&self) -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(self.state_file()).unwrap()).unwrap()
    }

    pub fn wait_for_state(&self, what: &str, pred: impl Fn(&serde_json::Value) -> bool) {
        let deadline = Instant::now() + LONG;
        loop {
            if let Ok(bytes) = std::fs::read(self.state_file())
                && let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes)
                && pred(&v)
            {
                return;
            }
            assert!(Instant::now() < deadline, "state file never showed {what}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// An app connection whose connect-time board_list + restore are still unread.
    pub fn connect_app(&self) -> Conn {
        Conn::hello(&self.sock, "app")
    }

    pub fn connect_app_drained(&self) -> Conn {
        self.connect_app_drained_as(None)
    }

    /// A drained app connection with a login shell `term_id` at its prompt.
    pub fn shell_at_prompt(&self, term_id: &str, opts: Spawn, log: &mut FrameLog) -> Conn {
        let mut app = self.connect_app_drained();
        app.login_shell_at_prompt(log, term_id, opts);
        app
    }

    /// A drained app connection announcing `app_version`.
    pub fn connect_app_drained_as(&self, app_version: Option<&str>) -> Conn {
        let (mut app, _) = Conn::hello_as(&self.sock, "app", app_version);
        app.drain_board();
        app
    }

    // SIGKILL + relaunch against the same socket/state paths.
    pub fn restart(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.relaunch();
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

pub fn spawn_daemon(sock: &Path) -> Child {
    spawn_daemon_with(sock, |_| {})
}

fn spawn_daemon_with(sock: &Path, configure: impl FnOnce(&mut Command)) -> Child {
    let state = sock.parent().expect("socket has a parent dir").join("state.json");
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_tarmacd"));
    cmd.env("TARMAC_SOCKET", sock)
        .env("TARMAC_STATE", state)
        .env("RUST_LOG", "debug")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    configure(&mut cmd);
    cmd.spawn().expect("spawn tarmacd")
}

pub fn wait_for_socket(sock: &Path) {
    let deadline = Instant::now() + LONG;
    while Instant::now() < deadline {
        if UnixStream::connect(sock).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("daemon socket never became connectable: {}", sock.display());
}

/// Probes until the active board's restore satisfies `done`, to `deadline`;
/// the newest connection and its restore.
pub fn probe_until(
    daemon: &TestDaemon,
    what: &str,
    deadline: Instant,
    done: impl Fn(&Restore) -> bool,
) -> (Conn, Restore) {
    loop {
        let (app, restore) = daemon.probe();
        if done(&restore) {
            return (app, restore);
        }
        assert!(Instant::now() < deadline, "the restore never showed {what}: {:?}", restore.term_records);
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Probes until the active board's record of `term_id` has `want`.
pub fn probe_until_cwd(daemon: &TestDaemon, term_id: &str, want: &str) -> Conn {
    probe_until(daemon, &format!("{term_id} in {want}"), Instant::now() + LONG, |r| r.last_cwd(term_id) == Some(want)).0
}

/// Send `sig` to a daemon child and wait, to a deadline, for it to exit.
/// Returns the exit status so a test can distinguish a clean `exit(0)` from a
/// death by signal (`status.code() == None`).
pub fn signal_and_wait(child: &mut Child, sig: libc::c_int) -> std::process::ExitStatus {
    signal(child, sig);
    wait_exit(child)
}

pub fn signal(child: &Child, sig: libc::c_int) {
    // SAFETY: kill(2) on the test's own daemon child; a failure only means
    // it is gone.
    unsafe { libc::kill(child.id() as libc::pid_t, sig) };
}

/// Waits, to a deadline, for a daemon child to exit.
pub fn wait_exit(child: &mut Child) -> std::process::ExitStatus {
    let deadline = Instant::now() + LONG;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "daemon never exited");
        std::thread::sleep(Duration::from_millis(25));
    }
}
