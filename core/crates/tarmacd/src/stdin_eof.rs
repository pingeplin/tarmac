//! A test daemon outlives no test (#531): the harness holds the write end of
//! the daemon's stdin, and a test process that dies in any way, even with no
//! `Drop` run, closes it. Opt-in, because the app's daemon has `/dev/null` for
//! stdin and must outlive the app.

use crate::Env;

/// Set to `1` by the launcher that holds the daemon's stdin.
const ASK: &str = "TARMAC_EXIT_ON_STDIN_EOF";

/// Resolves at EOF on stdin when the launcher asked; never otherwise. A read
/// error counts as EOF.
pub(crate) fn reached(env: Env) -> impl Future<Output = ()> + use<> {
    let asked = asked(env);
    async move {
        if !asked {
            return std::future::pending().await;
        }
        let (eof, at_eof) = tokio::sync::oneshot::channel();
        // A thread rather than a blocking task: a runtime that shuts down waits
        // on its blocking tasks, and this read may never end.
        std::thread::spawn(move || {
            let _ = std::io::copy(&mut std::io::stdin().lock(), &mut std::io::sink());
            let _ = eof.send(());
        });
        let _ = at_eof.await;
    }
}

fn asked(env: Env) -> bool {
    env(ASK).is_some_and(|v| v == "1")
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::{ASK, asked};

    #[test]
    fn only_a_launcher_that_sets_the_variable_to_1_asks() {
        for (value, want) in [(None, false), (Some(""), false), (Some("0"), false), (Some("1"), true)] {
            let env = |name: &str| if name == ASK { value.map(OsString::from) } else { None };
            assert_eq!(asked(&env), want, "{value:?}");
        }
    }
}
