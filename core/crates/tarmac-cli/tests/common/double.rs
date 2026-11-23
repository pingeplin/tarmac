// A peer the cli dials: a scratch unix socket whose one connection a per-test
// handler drives frame by frame. Every wait has a deadline, so a cli bug fails a
// test instead of hanging it, and dropping the double ends its thread.

use std::io::{ErrorKind, Read};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use tarmac_protocol::frame;

use super::scratch;

/// The longest any one wait lasts: past every cli deadline under test.
const WAIT: Duration = Duration::from_secs(30);
/// How long the double keeps listening after its reply for anything more.
const LINGER: Duration = Duration::from_secs(2);
const POLL: Duration = Duration::from_millis(10);

pub(crate) struct Double {
    pub dir: PathBuf,
    pub sock: PathBuf,
    /// Raw payloads received, in order. Raw (not decoded) so a test can assert
    /// which keys were on the wire, not just what they decoded to.
    pub received: Arc<Mutex<Vec<Vec<u8>>>>,
    server: Mutex<Option<JoinHandle<()>>>,
    stop: Option<Sender<()>>,
}

impl Double {
    pub(crate) fn start(name: &str, handler: impl FnOnce(&mut Peer) + Send + 'static) -> Self {
        let dir = scratch();
        let sock = dir.join(name);
        let listener = UnixListener::bind(&sock).unwrap();
        listener.set_nonblocking(true).unwrap();
        let received = Arc::new(Mutex::new(Vec::new()));
        let (stop, stopped) = mpsc::channel();

        let rx = received.clone();
        let server = std::thread::spawn(move || {
            let Some(stream) = accept(&listener, &stopped) else { return };
            handler(&mut Peer { stream, received: rx, stopped });
        });
        Double { dir, sock, received, server: Mutex::new(Some(server)), stop: Some(stop) }
    }

    /// Wait for the handler to finish, so the list is complete rather than
    /// whatever had arrived by the time the client exited.
    pub(crate) fn frames(&self) -> Vec<Vec<u8>> {
        if let Some(handle) = self.server.lock().unwrap().take() {
            handle.join().unwrap();
        }
        self.received.lock().unwrap().clone()
    }
}

impl Drop for Double {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(handle) = self.server.get_mut().unwrap_or_else(PoisonError::into_inner).take() {
            let _ = handle.join();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Polled so that dropping the double ends a wait for a client that never dials.
fn accept(listener: &UnixListener, stopped: &Receiver<()>) -> Option<UnixStream> {
    let deadline = Instant::now() + WAIT;
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                // macOS hands the accepted socket the listener's O_NONBLOCK.
                stream.set_nonblocking(false).unwrap();
                limit_reads(&stream, WAIT);
                return Some(stream);
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => {}
            Err(_) => return None,
        }
        if Instant::now() >= deadline || stopped.recv_timeout(POLL) == Err(RecvTimeoutError::Disconnected) {
            return None;
        }
    }
}

/// A limit on each read of `stream`. macOS refuses the option with EINVAL once
/// the peer has gone, which a client that exits at once can do first. No limit
/// is needed then: a read gets what was sent, then EOF.
fn limit_reads(stream: &UnixStream, wait: Duration) {
    let _ = stream.set_read_timeout(Some(wait));
}

/// The accepted connection, as a handler sees it.
pub(crate) struct Peer {
    stream: UnixStream,
    received: Arc<Mutex<Vec<Vec<u8>>>>,
    stopped: Receiver<()>,
}

impl Peer {
    /// One frame, recorded.
    pub(crate) fn read(&mut self) -> Option<Vec<u8>> {
        let payload = frame::read_sync(&mut self.stream).ok()?;
        self.received.lock().unwrap().push(payload.clone());
        Some(payload)
    }

    /// A frame that comes within `wait`, recorded; `None` when none does.
    pub(crate) fn read_within(&mut self, wait: Duration) -> Option<Vec<u8>> {
        limit_reads(&self.stream, wait);
        let payload = self.read();
        limit_reads(&self.stream, WAIT);
        payload
    }

    pub(crate) fn write(&mut self, payload: &[u8]) -> bool {
        frame::write_sync(&mut self.stream, payload).is_ok()
    }

    /// Keep reading so the test can observe whether the client sends anything
    /// after its request. EOF (the client exiting) ends it.
    pub(crate) fn drain(&mut self) {
        limit_reads(&self.stream, LINGER);
        while self.read().is_some() {}
    }

    /// `drain`, but whatever bytes arrive are recorded as one entry, framed or not.
    pub(crate) fn drain_bytes(&mut self) {
        limit_reads(&self.stream, LINGER);
        let mut sink = Vec::new();
        let _ = self.stream.read_to_end(&mut sink);
        if !sink.is_empty() {
            self.received.lock().unwrap().push(sink);
        }
    }

    /// Hold the connection open, never replying, until the double is dropped —
    /// the only way to exercise the client's read timeout.
    pub(crate) fn hold(&self) {
        self.pause(WAIT);
    }

    /// Wait `wait`, or less when the double is dropped first.
    pub(crate) fn pause(&self, wait: Duration) {
        let _ = self.stopped.recv_timeout(wait);
    }
}
