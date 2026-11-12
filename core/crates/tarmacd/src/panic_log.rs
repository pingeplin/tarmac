//! A panic also goes through `tracing`, so its line in `tarmacd.log` carries a
//! timestamp that matches it to the crash report an abort leaves behind.

use std::any::Any;
use std::panic::Location;

/// Chains onto the hook already installed, which still prints the panic as
/// before. The record goes to the subscriber set when the panic happens.
pub fn install() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        tracing::error!("{}", record(std::thread::current().name(), info.location(), info.payload()));
        previous(info);
    }));
}

fn record(thread: Option<&str>, location: Option<&Location>, payload: &(dyn Any + Send)) -> String {
    let message = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("Box<dyn Any>");
    let at = location.map_or_else(|| "<unknown>".to_string(), ToString::to_string);
    format!("thread '{}' panicked at {at}: {message}", thread.unwrap_or("<unnamed>"))
}

#[cfg(test)]
mod tests {
    use super::{install, record};
    use std::io::Write;
    use std::panic::{self, Location};
    use std::sync::{Arc, Mutex};

    #[test]
    fn a_record_names_the_thread_the_location_and_a_str_message() {
        let here = Location::caller();
        assert_eq!(
            record(Some("tokio-runtime-worker"), Some(here), &"boom"),
            format!("thread 'tokio-runtime-worker' panicked at {here}: boom")
        );
    }

    #[test]
    fn a_record_reads_a_formatted_message() {
        let here = Location::caller();
        assert_eq!(
            record(Some("main"), Some(here), &String::from("boom 7")),
            format!("thread 'main' panicked at {here}: boom 7")
        );
    }

    #[test]
    fn a_record_survives_an_unnamed_thread_no_location_and_an_opaque_payload() {
        assert_eq!(
            record(None, None, &7_i32),
            "thread '<unnamed>' panicked at <unknown>: Box<dyn Any>"
        );
    }

    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl Write for Captured {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    // The hook is process-wide: it is swapped and restored around one panic,
    // and the tracing subscriber is scoped to this thread. Other tests here
    // panic on purpose, so the stub hook is checked for this test's payload.
    #[test]
    fn a_panic_is_logged_as_an_error_and_the_previous_hook_still_runs() {
        let original = panic::take_hook();
        let chained = Arc::new(Mutex::new(Vec::new()));
        let seen = chained.clone();
        panic::set_hook(Box::new(move |info| {
            seen.lock().unwrap().push(info.payload_as_str().unwrap_or_default().to_string());
        }));
        install();

        let out = Captured::default();
        let writer = out.clone();
        let subscriber = tracing_subscriber::fmt().with_writer(move || writer.clone()).with_ansi(false).finish();
        let caught = tracing::subscriber::with_default(subscriber, || panic::catch_unwind(|| panic!("boom {}", 7)));
        panic::set_hook(original);

        assert!(caught.is_err());
        let text = String::from_utf8(out.0.lock().unwrap().clone()).unwrap();
        assert!(text.contains("ERROR"), "{text}");
        assert!(text.contains(&format!("panicked at {}:", file!())), "{text}");
        assert!(text.contains("boom 7"), "{text}");
        assert!(chained.lock().unwrap().iter().any(|p| p == "boom 7"));
    }
}
