//! Facts about a pid, read from the OS. Every failure (dead pid, permission)
//! is `None`; the daemon ships on macOS and the other targets only keep the
//! crate buildable.

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

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::pid_cwd;

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
