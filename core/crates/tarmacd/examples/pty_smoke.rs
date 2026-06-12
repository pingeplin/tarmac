// Smoke test for the sandbox pty-exit-hang hazard: spawn /bin/echo on a pty,
// read until EOF, wait for exit. Hanging here means pty children cannot exit
// in this environment and the integration test will hang too.
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use std::io::Read;

fn main() {
    let pty = native_pty_system()
        .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
        .unwrap();
    let mut cmd = CommandBuilder::new("/bin/echo");
    cmd.args(["pty-smoke-ok"]);
    cmd.env("TERM", "xterm-256color");
    let mut child = pty.slave.spawn_command(cmd).unwrap();
    drop(pty.slave);
    let mut reader = pty.master.try_clone_reader().unwrap();
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match reader.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => out.extend_from_slice(&buf[..n]),
        }
    }
    let status = child.wait().unwrap();
    println!(
        "output={:?} exit_code={} signal={:?}",
        String::from_utf8_lossy(&out),
        status.exit_code(),
        status.signal()
    );
}
