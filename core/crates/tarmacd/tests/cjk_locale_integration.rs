// CJK/IME regression: a daemon launched without a UTF-8 locale (the
// Finder/launchd case, where it inherits no LANG/LC_*) must still give the
// shells it spawns a UTF-8 character locale. Otherwise zsh's line editor decodes
// the UTF-8 bytes SwiftTerm sends on a candidate commit against the C/POSIX
// locale, mbrtowc returns WEOF, and the terminal shows `<ffffffff>` then `??`.
//
// These tests drive the real daemon over the wire, spawn a shell, and read back
// its effective `locale charmap` + `$LC_CTYPE` from the pty output.

mod common;

use std::time::Instant;

use common::{LONG, TestDaemon, contains};
use tarmac_protocol::Msg;

// `lang == None` strips every locale var (the launchd case); `Some(l)` sets LANG
// to `l`. Either way LC_ALL/LC_CTYPE are cleared so `lang` is the only signal.
fn start_daemon(lang: Option<&str>) -> TestDaemon {
    TestDaemon::start_with(|cmd| {
        cmd.env("RUST_LOG", "warn").env_remove("LC_ALL").env_remove("LC_CTYPE");
        match lang {
            Some(l) => {
                cmd.env("LANG", l);
            }
            None => {
                cmd.env_remove("LANG");
            }
        }
    })
}

// Spawn a shell that reports its effective charmap + LC_CTYPE, and return the
// single "RESULT ..." line the daemon forwards from the pty.
fn shell_locale_result(daemon: &TestDaemon, term_id: &str) -> String {
    let mut app = daemon.connect_app_drained();

    // `$(locale charmap)` is "UTF-8" under a UTF-8 ctype, "US-ASCII" under C.
    // `${LC_CTYPE-unset}` distinguishes an injected value from an unset one.
    app.spawn_term(
        term_id,
        &[
            "/bin/sh",
            "-c",
            "printf 'RESULT charmap=%s ctype=%s\\n' \"$(locale charmap)\" \"${LC_CTYPE-unset}\"",
        ],
    );

    let deadline = Instant::now() + LONG;
    let mut out: Vec<u8> = Vec::new();
    loop {
        match app.recv(deadline, "output") {
            Msg::Output { term_id: tid, bytes } if tid == term_id => {
                out.extend_from_slice(&bytes);
                if contains(&out, b"RESULT ") && contains(&out, b"\n") {
                    break;
                }
            }
            Msg::Exit { term_id: tid, .. } if tid == term_id => break,
            _ => {}
        }
    }

    let text = String::from_utf8_lossy(&out);
    text.lines()
        .find(|l| l.contains("RESULT "))
        .map(|l| l.trim().to_string())
        .unwrap_or_else(|| panic!("no RESULT line in pty output; got:\n{text}"))
}

#[test]
fn no_locale_daemon_forces_utf8_ctype_on_spawned_shell() {
    let daemon = start_daemon(None);
    let result = shell_locale_result(&daemon, "cjk-no-locale");
    assert!(
        result.contains("charmap=UTF-8"),
        "a shell spawned by a no-locale daemon must run in a UTF-8 charmap; got: {result}"
    );
    assert!(
        result.contains("ctype=en_US.UTF-8"),
        "the daemon must inject LC_CTYPE=en_US.UTF-8 when it has no UTF-8 locale; got: {result}"
    );
}

#[test]
fn existing_utf8_lang_is_respected_not_overridden() {
    let daemon = start_daemon(Some("en_US.UTF-8"));
    let result = shell_locale_result(&daemon, "cjk-utf8-lang");
    // The shell is already UTF-8 via the inherited LANG…
    assert!(
        result.contains("charmap=UTF-8"),
        "an inherited UTF-8 LANG must keep the shell UTF-8; got: {result}"
    );
    // …so the daemon must NOT force LC_CTYPE (leave the user's locale choice).
    assert!(
        result.contains("ctype=unset"),
        "an existing UTF-8 locale must not be overridden with LC_CTYPE; got: {result}"
    );
}
