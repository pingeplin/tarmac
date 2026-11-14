//! The daemon's soft `RLIMIT_NOFILE` (#360). launchd starts a process at 256,
//! and every subscriber, doc watch and PTY holds descriptors.

/// `OPEN_MAX` in macOS `<sys/syslimits.h>`; the `libc` crate does not export it.
const OPEN_MAX: u64 = 10240;

/// The soft limit to set: `OPEN_MAX` clamped to the hard limit and to
/// `kern.maxfilesperproc`. `None` when that is not above `soft`: the limit is
/// never lowered.
fn target(soft: u64, hard: u64, per_proc: Option<u64>) -> Option<u64> {
    let want = OPEN_MAX.min(hard).min(per_proc.unwrap_or(u64::MAX));
    (want > soft).then_some(want)
}

#[cfg(target_os = "macos")]
fn max_files_per_proc() -> Option<u64> {
    let mut value = [0u8; 4];
    crate::proc::sysctl(&mut [libc::CTL_KERN, libc::KERN_MAXFILESPERPROC], &mut value).filter(|&n| n == 4)?;
    u64::try_from(i32::from_ne_bytes(value)).ok()
}

#[cfg(not(target_os = "macos"))]
fn max_files_per_proc() -> Option<u64> {
    None
}

/// Raises the soft limit; called before the socket, the watcher and any terminal.
pub fn raise() {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is a valid rlimit for getrlimit to fill.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        tracing::warn!("cannot read RLIMIT_NOFILE: {}", std::io::Error::last_os_error());
        return;
    }
    let Some(soft) = target(limit.rlim_cur, limit.rlim_max, max_files_per_proc()) else {
        tracing::info!("open file limit stays at {}", limit.rlim_cur);
        return;
    };
    let raised = libc::rlimit { rlim_cur: soft, rlim_max: limit.rlim_max };
    // SAFETY: `raised` is a valid rlimit.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } == 0 {
        tracing::info!("open file limit raised from {} to {soft}", limit.rlim_cur);
    } else {
        tracing::warn!("cannot raise the open file limit to {soft}: {}", std::io::Error::last_os_error());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launchd_s_256_is_raised_to_open_max() {
        assert_eq!(target(256, u64::MAX, Some(61440)), Some(10240));
    }

    #[test]
    fn the_target_is_clamped_to_the_hard_limit_and_maxfilesperproc() {
        assert_eq!(target(256, 4096, Some(61440)), Some(4096));
        assert_eq!(target(256, u64::MAX, Some(2048)), Some(2048));
        assert_eq!(target(256, u64::MAX, None), Some(10240));
    }

    #[test]
    fn a_limit_is_never_lowered() {
        assert_eq!(target(1_048_576, u64::MAX, Some(61440)), None);
        assert_eq!(target(10240, u64::MAX, Some(61440)), None);
        assert_eq!(target(256, 128, Some(61440)), None);
    }
}
