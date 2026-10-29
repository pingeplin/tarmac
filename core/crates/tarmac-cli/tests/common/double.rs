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

pub struct Double {
    pub dir: PathBuf,
    pub sock: PathBuf,
    /// Raw payloads received, in order. Raw (not decoded) so a test can assert
    /// which keys were on the wire, not just what they decoded to.
    pub received: Arc<Mutex<Vec<Vec<u8>>>>,
    server: Mutex<Option<JoinHandle<()>>>,
    stop: Option<Sender<()>>,
}

impl Double {
    pub fn start(name: &str, handler: impl FnOnce(&mut Peer) + Send + 'static) -> Self {
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
    pub fn frames(&self) -> Vec<Vec<u8>> {
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
                stream.set_read_timeout(Some(WAIT)).unwrap();
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

/// The accepted connection, as a handler sees it.
pub struct Peer {
    stream: UnixStream,
    received: Arc<Mutex<Vec<Vec<u8>>>>,
    stopped: Receiver<()>,
}

impl Peer {
    /// One frame, recorded.
    pub fn read(&mut self) -> Option<Vec<u8>> {
        let payload = frame::read_sync(&mut self.stream).ok()?;
        self.received.lock().unwrap().push(payload.clone());
        Some(payload)
    }

    pub fn write(&mut self, payload: &[u8]) -> bool {
        frame::write_sync(&mut self.stream, payload).is_ok()
    }

    /// Keep reading so the test can observe whether the client sends anything
    /// after its request. EOF (the client exiting) ends it.
    pub fn drain(&mut self) {
        self.stream.set_read_timeout(Some(LINGER)).unwrap();
        while self.read().is_some() {}
    }

    /// `drain`, but whatever bytes arrive are recorded as one entry, framed or not.
    pub fn drain_bytes(&mut self) {
        self.stream.set_read_timeout(Some(LINGER)).unwrap();
        let mut sink = Vec::new();
        let _ = self.stream.read_to_end(&mut sink);
        if !sink.is_empty() {
            self.received.lock().unwrap().push(sink);
        }
    }

    /// Hold the connection open, never replying, until the double is dropped —
    /// the only way to exercise the client's read timeout.
    pub fn hold(&self) {
        let _ = self.stopped.recv_timeout(WAIT);
    }
}
