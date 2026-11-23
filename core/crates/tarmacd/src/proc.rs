//! Facts about a pid, read from the OS. Every failure (dead pid, permission)
//! is `None`, except in `proc_facts`, whose `Facts` tells a gone pid from a
//! failed read; the daemon ships on macOS and the other targets only keep the
//! crate buildable.

pub type Pid = libc::pid_t;

/// argv[0] in a `KERN_PROCARGS2` buffer: a native-endian argc, the exec path
/// and its NUL padding, then argv. `None` for no argument or a cut buffer.
fn argv0(procargs: &[u8]) -> Option<&[u8]> {
    let argc = i32::from_ne_bytes(procargs.get(..4)?.try_into().ok()?);
    if argc < 1 {
        return None;
    }
    let rest = &procargs[4..];
    let path_end = rest.iter().position(|&b| b == 0)?;
    let rest = &rest[path_end..];
    let rest = &rest[rest.iter().position(|&b| b != 0)?..];
    Some(&rest[..rest.iter().position(|&b| b == 0)?])
}

/// The basename of argv[0], less a login shell's leading `-`.
fn name_of_argv0(argv0: &[u8]) -> Option<String> {
    basename(argv0.strip_prefix(b"-").unwrap_or(argv0))
}

fn basename(path: &[u8]) -> Option<String> {
    let base = path.rsplit(|&b| b == b'/').next()?;
    (!base.is_empty()).then(|| String::from_utf8_lossy(base).into_owned())
}

/// The basename of argv[0] (`sysctl(KERN_PROCARGS2)`), as `ps -o comm` shows
/// it: not resolved through a symlink, a login shell's `-` dropped. When argv
/// is unreadable (`EINVAL` on another user's process), the executable's basename.
#[cfg(target_os = "macos")]
pub fn process_name(pid: libc::pid_t) -> Option<String> {
    argv0_name(pid).or_else(|| path_name(pid))
}

/// One `sysctl` read into `buf`: the count written, or `None` on error.
#[cfg(target_os = "macos")]
fn sysctl(mib: &mut [libc::c_int], buf: &mut [u8]) -> Option<usize> {
    let mut size = buf.len();
    #[expect(clippy::cast_possible_truncation, reason = "predates the lint; decided in #470")]
    // SAFETY: `mib` names `mib.len()` ints; `buf` is `size` bytes, and sysctl
    // writes at most `size` bytes and sets `size` to the count written.
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
    (ret == 0).then_some(size)
}

/// One `sysctl` read of a native-endian 4-byte int; `None` on error or on
/// any other size.
#[cfg(target_os = "macos")]
pub(crate) fn sysctl_i32(mib: &mut [libc::c_int]) -> Option<i32> {
    let mut value = [0u8; 4];
    sysctl(mib, &mut value).filter(|&n| n == 4)?;
    Some(i32::from_ne_bytes(value))
}

/// The argument area is at most `KERN_ARGMAX` bytes (1 MiB). A shorter buffer
/// is no error: it came back as argc and zeros (measured, Darwin 25.6). The
/// buffer is kept per thread, so a poll does not allocate it again.
#[cfg(target_os = "macos")]
fn argv0_name(pid: Pid) -> Option<String> {
    thread_local!(static PROCARGS: std::cell::RefCell<Vec<u8>> = const { std::cell::RefCell::new(Vec::new()) });
    PROCARGS.with_borrow_mut(|buf| {
        if buf.is_empty() {
            buf.resize(procargs_len(sysctl_i32(&mut [libc::CTL_KERN, libc::KERN_ARGMAX])?)?, 0);
        }
        let size = sysctl(&mut [libc::CTL_KERN, libc::KERN_PROCARGS2, pid], buf)?;
        argv0(&buf[..size]).and_then(name_of_argv0)
    })
}

/// The argument buffer's length for a `KERN_ARGMAX` of `argmax`: `None` for
/// one that is not positive, which no read could fill.
#[cfg(target_os = "macos")]
fn procargs_len(argmax: i32) -> Option<usize> {
    usize::try_from(argmax).ok().filter(|&n| n > 0)
}

#[cfg(target_os = "macos")]
fn path_name(pid: Pid) -> Option<String> {
    let mut buf = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf is a valid, sized buffer; proc_pidpath writes at most
    // `buffersize` bytes and returns the number written (<= buffersize) or <= 0
    // on error. We never read past `len`.
    #[expect(clippy::cast_possible_truncation, reason = "buf is a PROC_PIDPATHINFO_MAXSIZE array")]
    let len = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_void, buf.len() as u32) };
    if len <= 0 {
        return None;
    }
    #[expect(clippy::cast_sign_loss, reason = "a len <= 0 returned above")]
    let len = len as usize;
    basename(&buf[..len])
}

#[cfg(not(target_os = "macos"))]
pub fn process_name(_pid: libc::pid_t) -> Option<String> {
    None
}

/// The CURRENT working directory, via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` —
/// the same fact `lsof -p <pid> -d cwd` reports.
#[cfg(target_os = "macos")]
pub fn pid_cwd(pid: libc::pid_t) -> Option<String> {
    // SAFETY: proc_vnodepathinfo holds only integers and integer arrays (libc),
    // for which all-zero bytes is a valid value.
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        reason = "predates the lint; decided in #470"
    )]
    let size = size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    // SAFETY: `info` is a valid, zeroed, exactly-sized buffer; proc_pidinfo
    // writes at most `size` bytes and returns <=0 on error.
    let ret =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, &raw mut info as *mut libc::c_void, size) };
    if ret <= 0 {
        return None;
    }
    // vip_path is a NUL-terminated cwd string packed as [[c_char; 32]; 32]
    // (MAXPATHLEN split across a fixed 2D array for an old-rustc const-generic
    // limit in libc) — read it as one flat byte buffer.
    let vip_path = &info.pvi_cdir.vip_path;
    // SAFETY: vip_path is a field of `info`, alive for this call; the length is
    // its exact byte size (path is c_char == u8-sized on this target).
    let bytes = unsafe { std::slice::from_raw_parts(vip_path.as_ptr() as *const u8, size_of_val(vip_path)) };
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
    Live { ppid: Pid, started: u64 },
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
pub fn proc_facts(pid: Pid) -> Facts {
    let mut buf = [0u8; KINFO_PROC_SIZE];
    let Some(size) = sysctl(&mut [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid], &mut buf) else {
        return Facts::Unread;
    };
    match size {
        0 => Facts::Gone,
        #[expect(clippy::cast_possible_wrap, reason = "predates the lint; decided in #470")]
        KINFO_PROC_SIZE if buf[P_STAT] as i8 == SZOMB => Facts::Gone,
        KINFO_PROC_SIZE => {
            let tv_sec = i64::from_ne_bytes(buf[0..8].try_into().expect("8 bytes"));
            let tv_usec = i32::from_ne_bytes(buf[8..12].try_into().expect("4 bytes"));
            let ppid = i32::from_ne_bytes(buf[E_PPID..E_PPID + 4].try_into().expect("4 bytes"));
            start_micros(tv_sec, tv_usec).map_or(Facts::Unread, |started| Facts::Live { ppid, started })
        }
        _ => Facts::Unread,
    }
}

/// A `timeval` as microseconds since the epoch, or `None` for one that is
/// negative or does not fit. The value is half of a process's identity, so a
/// time that cannot be right is "unread", never a wrapped number (#485).
fn start_micros(tv_sec: i64, tv_usec: i32) -> Option<u64> {
    let seconds = u64::try_from(tv_sec).ok()?;
    let micros = u64::try_from(tv_usec).ok()?;
    seconds.checked_mul(1_000_000)?.checked_add(micros)
}

#[cfg(not(target_os = "macos"))]
pub fn proc_facts(_pid: Pid) -> Facts {
    Facts::Unread
}

#[cfg(test)]
mod parse_tests {
    use super::{argv0, name_of_argv0};

    fn procargs(argc: i32, rest: &[u8]) -> Vec<u8> {
        let mut buf = argc.to_ne_bytes().to_vec();
        buf.extend_from_slice(rest);
        buf
    }

    #[test]
    fn argv0_follows_the_exec_path_and_its_padding() {
        let buf = procargs(2, b"/real/2.1.325\0\0\0\0claude\0--resume\0PATH=/bin\0");
        assert_eq!(argv0(&buf), Some(&b"claude"[..]));
    }

    #[test]
    fn argv0_with_no_padding_after_the_exec_path() {
        assert_eq!(argv0(&procargs(1, b"/bin/sleep\0sleep\0")), Some(&b"sleep"[..]));
    }

    #[test]
    fn no_argv0_without_an_argument() {
        assert_eq!(argv0(&procargs(0, b"/bin/sleep\0\0PATH=/bin\0")), None);
        assert_eq!(argv0(&procargs(-1, b"/bin/sleep\0sleep\0")), None);
    }

    #[test]
    fn no_argv0_from_a_short_or_cut_buffer() {
        assert_eq!(argv0(b""), None);
        assert_eq!(argv0(&[1, 0, 0]), None);
        assert_eq!(argv0(&procargs(1, b"")), None);
        assert_eq!(argv0(&procargs(1, b"/bin/sleep")), None);
        assert_eq!(argv0(&procargs(1, b"/bin/sleep\0\0\0")), None);
        assert_eq!(argv0(&procargs(1, b"/bin/sleep\0sle")), None);
    }

    #[test]
    fn argv0_of_garbage_is_bytes_or_none_never_a_panic() {
        for buf in [&[0xffu8; 3][..], &[0xff; 4], &[0xff; 9], &[1, 0, 0, 0, 0xff, 0, 0xfe, 0]] {
            let _ = argv0(buf);
        }
    }

    #[test]
    fn the_name_is_the_basename_of_argv0() {
        assert_eq!(name_of_argv0(b"claude").as_deref(), Some("claude"));
        assert_eq!(name_of_argv0(b"/Users/x/.local/bin/claude").as_deref(), Some("claude"));
        assert_eq!(name_of_argv0(b"./run.sh").as_deref(), Some("run.sh"));
    }

    #[test]
    fn a_login_shell_loses_its_leading_dash() {
        assert_eq!(name_of_argv0(b"-zsh").as_deref(), Some("zsh"));
        assert_eq!(name_of_argv0(b"-/bin/zsh").as_deref(), Some("zsh"));
    }

    #[test]
    fn an_empty_name_is_none() {
        assert_eq!(name_of_argv0(b""), None);
        assert_eq!(name_of_argv0(b"-"), None);
        assert_eq!(name_of_argv0(b"/usr/bin/"), None);
    }

    #[test]
    fn a_name_that_is_not_utf8_is_read_lossily() {
        assert_eq!(name_of_argv0(b"a\xffb").as_deref(), Some("a\u{fffd}b"));
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::{Facts, pid_cwd, proc_facts, procargs_len, process_name, start_micros};
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    fn name_of(command: &mut Command) -> Option<String> {
        #[expect(
            clippy::unwrap_used,
            reason = "a test helper; allow-unwrap-in-tests does not cover a cfg(all(test, …)) module"
        )]
        let mut child: Child = command.arg("5").spawn().unwrap();
        #[expect(clippy::cast_possible_wrap, reason = "predates the lint; decided in #470")]
        let name = process_name(child.id() as libc::pid_t);
        #[expect(
            clippy::unwrap_used,
            reason = "a test helper; allow-unwrap-in-tests does not cover a cfg(all(test, …)) module"
        )]
        child.kill().unwrap();
        #[expect(
            clippy::unwrap_used,
            reason = "a test helper; allow-unwrap-in-tests does not cover a cfg(all(test, …)) module"
        )]
        child.wait().unwrap();
        name
    }

    // Claude Code's native install runs `claude` as a symlink to a versioned
    // binary; proc_pidpath resolves it to the version (#349).
    #[test]
    fn a_process_run_through_a_symlink_is_named_by_the_link() {
        let link = crate::fixtures::tmp_dir("argv0").join("claude");
        std::os::unix::fs::symlink("/bin/sleep", &link).unwrap();
        assert_eq!(name_of(&mut Command::new(&link)).as_deref(), Some("claude"));
    }

    #[test]
    fn a_login_shell_argv0_loses_its_dash() {
        assert_eq!(name_of(Command::new("/bin/sleep").arg0("-zsh")).as_deref(), Some("zsh"));
    }

    // launchd is root-owned: its argv is unreadable to us, its path is not.
    #[test]
    fn a_process_with_unreadable_argv_is_named_by_its_path() {
        assert_eq!(process_name(1).as_deref(), Some("launchd"));
    }

    #[test]
    fn an_argument_area_of_no_bytes_gives_no_buffer() {
        assert_eq!(procargs_len(1_048_576), Some(1_048_576));
        assert_eq!(procargs_len(1), Some(1));
        assert_eq!(procargs_len(0), None);
        assert_eq!(procargs_len(-1), None);
    }

    #[test]
    fn a_plain_process_keeps_its_name() {
        assert_eq!(name_of(&mut Command::new("/bin/sleep")).as_deref(), Some("sleep"));
    }

    #[test]
    fn a_start_time_is_microseconds_or_nothing() {
        assert_eq!(start_micros(1_700_000_000, 5), Some(1_700_000_000_000_005));
        assert_eq!(start_micros(0, 0), Some(0));
        assert_eq!(start_micros(0, 999_999), Some(999_999));
        assert_eq!(start_micros(-1, 0), None, "a negative second is not a wrapped number");
        assert_eq!(start_micros(1, -1), None, "a negative microsecond is not a wrapped number");
        // u64::MAX / 1_000_000: the last second whose microseconds fit.
        let most = 18_446_744_073_709;
        assert_eq!(start_micros(most, 0), Some(18_446_744_073_709_000_000));
        assert_eq!(start_micros(most, i32::MAX), None, "the sum does not fit");
        assert_eq!(start_micros(most + 1, 0), None, "the product does not fit");
    }

    #[test]
    fn own_pid_is_live_with_its_parent_and_a_start_time() {
        #[expect(clippy::cast_possible_wrap, reason = "predates the lint; decided in #470")]
        let Facts::Live { ppid, started } = proc_facts(std::process::id() as libc::pid_t) else {
            panic!("own pid is not live")
        };
        // SAFETY: getppid takes no arguments and is always successful (getppid(2)).
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
        #[expect(clippy::cast_possible_wrap, reason = "predates the lint; decided in #470")]
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
        #[expect(clippy::cast_possible_wrap, reason = "predates the lint; decided in #470")]
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
