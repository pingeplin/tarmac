//! Facts about a pid, read from the OS. Every failure (dead pid, permission)
//! is `None`; the daemon ships on macOS and the other targets only keep the
//! crate buildable.

pub type Pid = libc::pid_t;

/// The executable's basename, via `proc_pidpath`.
#[cfg(target_os = "macos")]
pub fn process_name(pid: libc::pid_t) -> Option<String> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf is a valid, sized allocation; proc_pidpath writes at most
    // `buffersize` bytes and returns the number written (<= buffersize) or <= 0
    // on error. We never read past `len`.
    let len = unsafe {
        libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_void, buf.len() as u32)
    };
    if len <= 0 {
        return None;
    }
    buf.truncate(len as usize);
    let path = String::from_utf8_lossy(&buf);
    let base = std::path::Path::new(path.as_ref()).file_name()?.to_string_lossy().into_owned();
    if base.is_empty() { None } else { Some(base) }
}

#[cfg(not(target_os = "macos"))]
pub fn process_name(_pid: libc::pid_t) -> Option<String> {
    None
}

/// The CURRENT working directory, via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` —
/// the same fact `lsof -p <pid> -d cwd` reports.
#[cfg(target_os = "macos")]
pub fn pid_cwd(pid: libc::pid_t) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    // SAFETY: `info` is a valid, zeroed, exactly-sized buffer; proc_pidinfo
    // writes at most `size` bytes and returns <=0 on error.
    let ret = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    if ret <= 0 {
        return None;
    }
    // vip_path is a NUL-terminated cwd string packed as [[c_char; 32]; 32]
    // (MAXPATHLEN split across a fixed 2D array for an old-rustc const-generic
    // limit in libc) — read it as one flat byte buffer.
    let vip_path = &info.pvi_cdir.vip_path;
    // SAFETY: vip_path is a field of `info`, alive for this call; the length is
    // its exact byte size (path is c_char == u8-sized on this target).
    let bytes = unsafe {
        std::slice::from_raw_parts(vip_path.as_ptr() as *const u8, std::mem::size_of_val(vip_path))
    };
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let cwd = String::from_utf8_lossy(&bytes[..end]).into_owned();
    (!cwd.is_empty()).then_some(cwd)
}

#[cfg(not(target_os = "macos"))]
pub fn pid_cwd(_pid: libc::pid_t) -> Option<String> {
    None
}

/// What `sysctl(KERN_PROC_PID)` says of a pid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Facts {
    /// `started` is the start time in microseconds since the epoch: with the
    /// pid it names one process, since a pid can be reused.
    Live { ppid: libc::pid_t, started: u64 },
    /// No such process, or a zombie: it has exited, reaped or not.
    Gone,
    /// The read failed, or gave a size this build does not know.
    Unread,
}

// The pinned libc has no Apple `kinfo_proc`, so the fields are read at their
// offsets in it (measured on Darwin 25.6 arm64). Any other size is `Unread`, so
// a layout change in a later macOS degrades to "unread", never to a wrong pid.
#[cfg(target_os = "macos")]
const KINFO_PROC_SIZE: usize = 648;
#[cfg(target_os = "macos")]
const P_STAT: usize = 36;
#[cfg(target_os = "macos")]
const E_PPID: usize = 560;
#[cfg(target_os = "macos")]
const SZOMB: i8 = 5;

/// One `sysctl` read; never `proc_pidinfo`, which fails on pid 1, on
/// root-owned pids and on zombies.
#[cfg(target_os = "macos")]
pub fn proc_facts(pid: libc::pid_t) -> Facts {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid];
    let mut buf = [0u8; KINFO_PROC_SIZE];
    let mut size = buf.len();
    // SAFETY: `mib` names four ints; `buf` is `size` bytes, and sysctl writes at
    // most `size` bytes and sets `size` to the count written.
    let ret = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buf.as_mut_ptr() as *mut libc::c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ret != 0 {
        return Facts::Unread;
    }
    match size {
        0 => Facts::Gone,
        KINFO_PROC_SIZE if buf[P_STAT] as i8 == SZOMB => Facts::Gone,
        KINFO_PROC_SIZE => {
            let tv_sec = i64::from_ne_bytes(buf[0..8].try_into().expect("8 bytes"));
            let tv_usec = i32::from_ne_bytes(buf[8..12].try_into().expect("4 bytes"));
            let ppid = i32::from_ne_bytes(buf[E_PPID..E_PPID + 4].try_into().expect("4 bytes"));
            Facts::Live { ppid, started: (tv_sec as u64) * 1_000_000 + tv_usec as u64 }
        }
        _ => Facts::Unread,
    }
}

#[cfg(not(target_os = "macos"))]
pub fn proc_facts(_pid: libc::pid_t) -> Facts {
    Facts::Unread
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::{Facts, pid_cwd, proc_facts};
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    #[test]
    fn own_pid_is_live_with_its_parent_and_a_start_time() {
        let Facts::Live { ppid, started } = proc_facts(std::process::id() as libc::pid_t) else {
            panic!("own pid is not live")
        };
        assert_eq!(ppid, unsafe { libc::getppid() });
        assert_ne!(started, 0);
    }

    // proc_pidinfo fails on a root-owned pid; sysctl reads it (D9).
    #[test]
    fn launchd_is_live_with_no_parent() {
        assert!(matches!(proc_facts(1), Facts::Live { ppid: 0, .. }), "{:?}", proc_facts(1));
    }

    #[test]
    fn an_exited_child_is_gone_before_and_after_it_is_reaped() {
        let mut child = Command::new("/bin/cat").stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap();
        let pid = child.id() as libc::pid_t;
        assert!(matches!(proc_facts(pid), Facts::Live { .. }), "a running child is live");

        drop(child.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(10);
        while proc_facts(pid) != Facts::Gone {
            assert!(Instant::now() < deadline, "the zombie stayed {:?}", proc_facts(pid));
            std::thread::sleep(Duration::from_millis(10));
        }
        child.wait().unwrap();
        assert_eq!(proc_facts(pid), Facts::Gone);
    }

    #[test]
    fn an_invalid_pid_is_not_live() {
        assert!(!matches!(proc_facts(-1), Facts::Live { .. }));
    }

    // Proven on our own test process, which cargo always launches with a real cwd.
    #[test]
    fn pid_cwd_resolves_own_process_cwd() {
        let pid = std::process::id() as libc::pid_t;
        let cwd = pid_cwd(pid).expect("cwd resolves for our own live pid");
        let expected = std::env::current_dir().unwrap().canonicalize().unwrap();
        assert_eq!(std::path::Path::new(&cwd).canonicalize().unwrap(), expected);
    }

    #[test]
    fn pid_cwd_returns_none_for_an_invalid_pid() {
        assert_eq!(pid_cwd(-1), None);
    }
}
