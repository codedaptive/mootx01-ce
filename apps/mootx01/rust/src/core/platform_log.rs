//! Native daemon diagnostics: Windows Application Event Log and Linux syslog.
//! The manager compiles this same source; neither app depends on the other.
//! Delivery is best effort. Callers retain stderr for interactive diagnostics.

/// Native event severity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    /// An operation cannot complete.
    Error,
    /// An operation completed with a degraded capability.
    Warning,
    /// An informational event.
    Information,
}

/// Submit fatal text after removing path-shaped private metadata. Callers keep
/// the complete diagnostic on stderr.
pub fn report_fatal(message: &str) {
    report_event(Level::Error, &redact_private_metadata(message));
}

/// Submit a path-free fatal diagnostic for an estate operation.
pub fn report_estate_fatal(kind: &str, estate_name: Option<&str>) {
    let message = match estate_name {
        Some(name) => format!("mootx01 serve fatal: {kind}; estate '{}'", sanitize_field(name)),
        None => format!("mootx01 serve fatal: {kind}"),
    };
    report_event(Level::Error, &message);
}

/// Submit an event to the platform sink; unsupported platforms do nothing.
pub fn report_event(level: Level, message: &str) {
    platform::report(level, message);
}

fn sanitize_field(field: &str) -> String {
    field.rsplit(['/', '\\']).find(|part| !part.is_empty()).unwrap_or("unknown")
        .chars().map(|ch| if ch.is_control() { '_' } else { ch }).collect()
}

fn redact_private_metadata(message: &str) -> String {
    message.split_whitespace().map(|word| {
        let path_shaped = word.contains('/') || word.contains('\\')
            || word.eq_ignore_ascii_case("db.key")
            || (word.as_bytes().get(1) == Some(&b':')
                && word.as_bytes().first().is_some_and(u8::is_ascii_alphabetic));
        if path_shaped { "[private-path]".to_string() } else { sanitize_field(word) }
    }).collect::<Vec<_>>().join(" ")
}

#[cfg(any(target_os = "windows", target_os = "linux", test))]
fn event_text(message: &str) -> String {
    // Native strings terminate at NUL. Preserve its position visibly instead
    // of losing the remainder of a diagnostic supplied by an error value.
    message.replace('\0', "\\0")
}

#[cfg(any(target_os = "windows", test))]
fn event_source() -> String {
    // The Windows source uses the brand's uppercase word and lowercase hex
    // suffix. Derive it from the canonical identity, without adding an Apple
    // logging identity or duplicating the product name at a call site.
    let name = moot_product_identity::storage::UNIX_DATA_FOLDER;
    match name.split_once('x') {
        Some((word, suffix)) => format!("{}x{suffix}", word.to_ascii_uppercase()),
        None => name.to_ascii_uppercase(),
    }
}

#[cfg(any(target_os = "windows", test))]
fn event_chunks(text: &str) -> Vec<Vec<u16>> {
    let mut chunks = Vec::new();
    let mut chunk = Vec::new();
    for ch in text.chars() {
        if chunk.len() + ch.len_utf16() > 30_000 {
            chunk.push(0);
            chunks.push(std::mem::take(&mut chunk));
        }
        chunk.extend(ch.encode_utf16(&mut [0; 2]).iter().copied());
    }
    chunk.push(0);
    chunks.push(chunk);
    chunks
}

#[cfg(target_os = "windows")]
mod platform {
    use super::{event_chunks, event_source, event_text, Level};
    use std::{ptr, sync::Once};
    use windows_sys::Win32::System::{EventLog::*, Registry::*};

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    fn register_source(source: &str) {
        static REGISTER: Once = Once::new();
        REGISTER.call_once(|| {
            let key_name = wide(&format!(
                "SYSTEM\\CurrentControlSet\\Services\\EventLog\\Application\\{source}"
            ));
            let types_name = wide("TypesSupported");
            let types =
                u32::from(EVENTLOG_ERROR_TYPE | EVENTLOG_WARNING_TYPE | EVENTLOG_INFORMATION_TYPE);
            let mut key = ptr::null_mut();
            // SAFETY: all UTF-16 buffers are terminated and live for the call;
            // key is an out-parameter, closed only after a successful open.
            unsafe {
                if RegCreateKeyExW(
                    HKEY_LOCAL_MACHINE,
                    key_name.as_ptr(),
                    0,
                    ptr::null(),
                    REG_OPTION_NON_VOLATILE,
                    KEY_SET_VALUE,
                    ptr::null(),
                    &mut key,
                    ptr::null_mut(),
                ) == 0
                {
                    let _ = RegSetValueExW(
                        key,
                        types_name.as_ptr(),
                        0,
                        REG_DWORD,
                        (&types as *const u32).cast(),
                        std::mem::size_of_val(&types) as u32,
                    );
                    let _ = RegCloseKey(key);
                }
            }
            // A per-user process usually cannot create this HKLM key.
            // RegisterEventSourceW explicitly routes unknown sources to the
            // Application log. No elevation or file sink is needed. Without
            // a message resource, Event Viewer Details / event Properties
            // still contain the diagnostic insertion string verbatim.
        });
    }

    pub(super) fn report(level: Level, message: &str) {
        let source = event_source();
        register_source(&source);
        let source = wide(&source);
        let text = event_text(message);
        let kind = match level {
            Level::Error => EVENTLOG_ERROR_TYPE,
            Level::Warning => EVENTLOG_WARNING_TYPE,
            Level::Information => EVENTLOG_INFORMATION_TYPE,
        };
        // SAFETY: source is terminated and retained until registration returns.
        let handle = unsafe { RegisterEventSourceW(ptr::null(), source.as_ptr()) };
        if handle.is_null() {
            return;
        }
        // ReportEventW limits each insertion string to 31,839 UTF-16 units.
        // Split long diagnostics at Unicode scalar boundaries rather than
        // silently dropping the whole event or cutting a surrogate pair.
        for chunk in event_chunks(&text) {
            let pointers = [chunk.as_ptr()];
            // SAFETY: one terminated string, one pointer, no SID or raw data;
            // all buffers and the registered handle remain live for the call.
            unsafe {
                let _ = ReportEventW(
                    handle,
                    kind,
                    0,
                    1,
                    ptr::null_mut(),
                    1,
                    0,
                    pointers.as_ptr(),
                    ptr::null(),
                );
            }
        }
        // SAFETY: handle came from successful RegisterEventSourceW, once closed.
        unsafe {
            let _ = DeregisterEventSource(handle);
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{event_text, Level};
    use std::{ffi::CString, sync::OnceLock};

    pub(super) fn report(level: Level, message: &str) {
        static IDENT: OnceLock<CString> = OnceLock::new();
        IDENT.get_or_init(|| {
            let ident = CString::new(moot_product_identity::storage::UNIX_DATA_FOLDER)
                .expect("product identity contains no NUL");
            // SAFETY: openlog retains the pointer; the CString's allocation
            // lives in IDENT for the process lifetime. No closelog is needed.
            unsafe {
                libc::openlog(ident.as_ptr(), libc::LOG_PID, libc::LOG_USER);
            }
            ident
        });
        let priority = match level {
            Level::Error => libc::LOG_ERR,
            Level::Warning => libc::LOG_WARNING,
            Level::Information => libc::LOG_INFO,
        };
        let text = CString::new(event_text(message)).expect("NULs were escaped");
        // SAFETY: the format is fixed, and text is a terminated C string.
        // A diagnostic containing percent signs is data, never a format string.
        unsafe {
            libc::syslog(
                libc::LOG_USER | priority,
                b"%s\0".as_ptr().cast(),
                text.as_ptr(),
            );
        }
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
mod platform {
    use super::Level;

    pub(super) fn report(_level: Level, _message: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_log_long_unicode_text_is_preserved() {
        let text = format!("{}🦀end", "x".repeat(29_999));
        let chunks = event_chunks(&text);
        assert_eq!(chunks.len(), 2);
        let joined: String = chunks
            .iter()
            .map(|c| {
                assert_eq!(c.last(), Some(&0));
                assert!(c.len() <= 30_001);
                String::from_utf16(&c[..c.len() - 1]).unwrap()
            })
            .collect();
        assert_eq!(joined, text);
    }

    #[test]
    fn platform_log_preserves_sink_safe_text() {
        let text = "mootx01 serve fatal: path café 🦀 is 100% unavailable\nsecond line";
        assert_eq!(event_text(text), text);
        assert_eq!(event_text("before\0after"), "before\\0after");
        assert_eq!(event_text(""), "");
        assert_eq!(event_source(), "MOOTx01");
    }

    #[test]
    fn platform_log_redacts_paths_and_sanitizes_estate_fields() {
        let redacted = redact_private_metadata(
            "catalog failed at /Users/alice/Private/estate and C:\\Users\\alice\\db.key",
        );
        assert_eq!(redacted, "catalog failed at [private-path] and [private-path]");
        assert_eq!(sanitize_field("/Users/alice/estate\nname"), "estate_name");
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    #[test]
    fn platform_log_unsupported_target_is_noop() {
        const CHILD: &str = "MOOT_PLATFORM_LOG_NOOP_CHILD";
        if std::env::var_os(CHILD).is_some() {
            report_fatal("mootx01 serve fatal: noop sentinel");
            for level in [Level::Error, Level::Warning, Level::Information] {
                report_event(level, "noop sentinel\0🦀%s");
            }
            return;
        }
        let module = module_path!().split_once("::").unwrap().1;
        let name = format!("{module}::platform_log_unsupported_target_is_noop");
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", &name, "--nocapture"])
            .env(CHILD, "1")
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(output.stderr.is_empty(), "no-op must not write stderr");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("1 passed"),
            "child test must actually run: {stdout}"
        );
        assert!(
            !stdout.contains("noop sentinel"),
            "no-op must not write stdout"
        );
    }
}
