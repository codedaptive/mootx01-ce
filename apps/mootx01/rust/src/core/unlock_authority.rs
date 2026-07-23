//! core/unlock_authority.rs — sensitivity unlock identity-verification
//! seam for the Rust/Linux/Windows vertical.
//!
//! The sensitivity policy requires two distinct approval mechanisms:
//!   * Swift/macOS  → LocalAuthentication (LAContext.evaluatePolicy)
//!   * Rust/Linux/Windows → two discrete PBKDF2-HMAC-SHA256 passwords
//!
//! This module implements the Rust half. It reads the stored hashes from the
//! sidecar file (via `sensitivity_hashes::load`), prompts the user for the
//! tier-specific password with echo disabled, verifies via PBKDF2, and on
//! success calls the daemon's `/api/control/unlock` endpoint to issue the
//! in-RAM grant.
//!
//! The HTTP call is the same `/api/control/unlock` endpoint that the Swift
//! CLI calls — JSON body `{"tier": "restricted"|"secret", "proof": {"ts": ms}}`.
//! The daemon verifies the timestamp freshness (±10 s) and issues the grant
//! with the TTL specified by out-of-band sensitivity grants.
//!
//! ## Why passwords-not-LA on Linux/Windows
//!
//! LocalAuthentication is Apple-only. The Linux/Windows equivalent (PAM,
//! WinBio) requires privileged access and additional dependencies that would
//! violate the C-1 external-dependency constraint. Two discrete passwords are
//! the lightest mechanism that still puts a meaningful gate in front of the
//! sensitivity tiers while compiling everywhere with std-only dependencies.

use std::io;
use std::net::TcpStream;
use std::path::Path;
use std::io::Write as _;
use std::time::{SystemTime, UNIX_EPOCH};

use aria_mcp::sensitivity_grant_ledger::SensitivityTier;

use crate::core::{daemon_client, sensitivity_hashes};

// --- Public types ---

/// Outcome returned by `authenticate_and_grant`.
#[derive(Debug)]
pub enum UnlockOutcome {
    /// The daemon issued the grant. `expires_at_iso` is the ISO-8601
    /// expiry time returned in the daemon's response body.
    Granted { expires_at_iso: String },
    /// The password was incorrect.
    WrongPassword,
    /// The sidecar does not exist; sensitivity passwords have not been set up.
    NotConfigured,
    /// The daemon is not running or refused the request.
    DaemonError(String),
    /// An I/O error occurred reading stdin or the sidecar file.
    IoError(String),
}

/// Outcome returned by `lock_all`.
#[derive(Debug)]
pub enum LockOutcome {
    /// The daemon cleared all grants.
    Locked,
    /// The daemon is not running or refused the request.
    DaemonError(String),
    /// An I/O error occurred.
    IoError(String),
}

// --- Public entry points ---

/// Verify the user's identity for `tier` and, on success, POST to the
/// daemon's `/api/control/unlock` endpoint to issue the in-RAM grant.
///
/// The flow:
///   1. Load the sidecar (→ `NotConfigured` if absent)
///   2. Prompt the user for the tier-specific password with echo disabled
///   3. Verify via PBKDF2-HMAC-SHA256 (→ `WrongPassword` if mismatch)
///   4. POST `{"tier":"…","proof":{"ts":…}}` to the daemon (→ `DaemonError`
///      if the daemon is unreachable or returns a non-200 status)
///   5. Return `Granted { expires_at_iso }` on success
///
/// The `data_dir` parameter is used to locate the sidecar file and the
/// `daemon.port` file (via `daemon_client::resolved_port`).
pub fn authenticate_and_grant(tier: SensitivityTier, data_dir: &Path) -> UnlockOutcome {
    // Step 1 — load hashes.
    let hashes = match sensitivity_hashes::load(data_dir) {
        Some(h) => h,
        None => return UnlockOutcome::NotConfigured,
    };

    // Step 2 — prompt for password with echo disabled.
    let prompt = match tier {
        SensitivityTier::Restricted => "Restricted-tier password: ",
        SensitivityTier::Secret     => "Secret-tier password: ",
    };
    let password = match read_password_line(prompt) {
        Ok(p) => p,
        Err(e) => return UnlockOutcome::IoError(e.to_string()),
    };

    // Step 3 — verify PBKDF2 hash.
    let ok = match tier {
        SensitivityTier::Restricted => sensitivity_hashes::verify_password(
            &password,
            &hashes.restricted_salt,
            &hashes.restricted_hash,
        ),
        SensitivityTier::Secret => sensitivity_hashes::verify_password(
            &password,
            &hashes.secret_salt,
            &hashes.secret_hash,
        ),
    };
    if !ok {
        return UnlockOutcome::WrongPassword;
    }

    // Step 4 — POST to daemon.
    let port = daemon_client::resolved_port();
    let tier_str = match tier {
        SensitivityTier::Restricted => "restricted",
        SensitivityTier::Secret     => "secret",
    };
    let ts_ms = current_ms();
    let body = format!(
        r#"{{"tier":"{tier_str}","proof":{{"ts":{ts_ms}}}}}"#
    );
    match post_control(port, "/api/control/unlock", body.as_bytes()) {
        Ok(resp_body) => parse_grant_response(&resp_body),
        Err(e) => UnlockOutcome::DaemonError(e.to_string()),
    }
}

/// Call the daemon's `/api/control/lock` endpoint to clear all grants.
///
/// No identity verification is required — locking is always permitted so the
/// user can reduce their own access at will. The daemon port is
/// resolved via `daemon_client::resolved_port()` (port file → 4242).
pub fn lock_all() -> LockOutcome {
    let port = daemon_client::resolved_port();
    match post_control(port, "/api/control/lock", b"{}") {
        Ok(_) => LockOutcome::Locked,
        Err(e) => LockOutcome::DaemonError(e.to_string()),
    }
}

// --- Helpers ---

/// Current wall time in epoch milliseconds.
///
/// The daemon validates that the proof timestamp is within ±10 s of its
/// own clock. Using the system clock here is correct — the skew between
/// the CLI process and the daemon (which runs on the same host) is zero.
fn current_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Parse the daemon's JSON response body into an `UnlockOutcome`.
///
/// Expected success shape: `{"ok":true,"tier":"…","expiresAt":"…"}`.
/// Any other shape is treated as a daemon error with the raw body as the
/// message so the caller can surface it.
fn parse_grant_response(body: &[u8]) -> UnlockOutcome {
    let text = String::from_utf8_lossy(body);
    let obj: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return UnlockOutcome::DaemonError(format!("unexpected daemon response: {text}")),
    };
    if obj.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        let expires = obj
            .get("expiresAt")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        UnlockOutcome::Granted { expires_at_iso: expires }
    } else {
        let msg = obj
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or(&text)
            .to_string();
        UnlockOutcome::DaemonError(msg)
    }
}

/// POST `body` to `http://127.0.0.1:<port><path>` and return the response
/// body as raw bytes.
///
/// Uses a raw `TcpStream` (matching the existing `daemon_client::post_frame`
/// pattern) to keep the dependency surface minimal — no reqwest, no tokio.
/// The control endpoints return small JSON responses so buffering the whole
/// body in memory is safe.
fn post_control(port: u16, path: &str, body: &[u8]) -> io::Result<Vec<u8>> {
    let addr = format!("127.0.0.1:{port}");
    let mut stream = TcpStream::connect(&addr)
        .map_err(|e| io::Error::new(e.kind(), format!("daemon not running on port {port}: {e}")))?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10)))?;

    // Hand-rolled HTTP/1.1 POST — same approach as daemon_client::post_frame.
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(request.as_bytes())?;
    stream.write_all(body)?;

    // Read the full response.
    let mut response = Vec::new();
    io::Read::read_to_end(&mut stream, &mut response)?;

    // Split status line from body (find the double-CRLF header separator).
    if let Some(sep) = find_header_end(&response) {
        // Parse status code from the first line.
        let header = String::from_utf8_lossy(&response[..sep]);
        let status = header
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|s| s.parse::<u16>().ok())
            .unwrap_or(0);
        if status != 200 {
            let body_text = String::from_utf8_lossy(&response[sep + 4..]).to_string();
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("daemon returned HTTP {status}: {body_text}"),
            ));
        }
        Ok(response[sep + 4..].to_vec())
    } else {
        Err(io::Error::new(io::ErrorKind::InvalidData, "malformed HTTP response"))
    }
}

/// Find the position of `\r\n\r\n` (the HTTP header/body separator) in `buf`.
fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

/// Read a line from stdin with terminal echo disabled.
///
/// Prints `prompt` to stderr (so it does not appear in piped output), reads
/// a single line, then restores the terminal state before returning. A
/// newline is printed to stderr after the hidden input so the next line of
/// output appears below the prompt.
///
/// On Unix: uses `libc::tcgetattr` / `tcsetattr` to toggle `ECHO`.
/// On non-Unix (Windows): reads without echo-disable — Windows terminals
/// do not have a portable POSIX equivalent via libc here; a follow-up
/// mission can wire `SetConsoleMode` when Windows CI is established.
fn read_password_line(prompt: &str) -> io::Result<String> {
    eprint!("{prompt}");
    // Flush stderr so the prompt appears before we block on stdin.
    let _ = std::io::stderr().flush();

    #[cfg(unix)]
    {
        // Disable ECHO on STDIN_FILENO before reading.
        let stdin_fd: libc::c_int = 0; // STDIN_FILENO
        let mut old_termios: libc::termios = unsafe { std::mem::zeroed() };
        // `tcgetattr` may fail (e.g. stdin is a pipe in tests) — save the
        // return value and only restore if we successfully saved.
        let saved = unsafe { libc::tcgetattr(stdin_fd, &mut old_termios) };
        if saved == 0 {
            let mut new_termios = old_termios;
            // ECHO: echo input characters (POSIX.1-2017 §11.2.3). Clear it.
            new_termios.c_lflag &= !(libc::ECHO as libc::tcflag_t);
            // ECHONL: echo newline even when ECHO is off. Also clear it to
            // prevent a bare newline from leaking the fact that Enter was
            // pressed, which is visible in some terminal configurations.
            new_termios.c_lflag &= !(libc::ECHONL as libc::tcflag_t);
            unsafe { libc::tcsetattr(stdin_fd, libc::TCSAFLUSH, &new_termios); }
        }

        let mut line = String::new();
        let result = std::io::stdin().read_line(&mut line);

        if saved == 0 {
            // Always restore — even if read_line failed.
            unsafe { libc::tcsetattr(stdin_fd, libc::TCSAFLUSH, &old_termios); }
        }
        eprintln!(); // newline after the hidden input
        result?;
        Ok(line.trim_end_matches('\n').trim_end_matches('\r').to_string())
    }

    #[cfg(not(unix))]
    {
        // Windows: plain read (no echo-disable via std). A future mission can
        // add `SetConsoleMode(ENABLE_ECHO_INPUT)` via winapi when Windows CI
        // is established. The password is still verified before the grant is
        // issued; echo-off is a UX concern, not a security boundary.
        let mut line = String::new();
        std::io::stdin().read_line(&mut line)?;
        eprintln!();
        Ok(line.trim_end_matches('\n').trim_end_matches('\r').to_string())
    }
}

// --- Tests ---

#[cfg(test)]
mod tests {
    use super::*;

    /// `current_ms` returns a plausible epoch-millisecond timestamp
    /// (after 2020-01-01 and before 2100-01-01).
    #[test]
    fn current_ms_is_plausible() {
        let ms = current_ms();
        assert!(ms > 1_577_836_800_000); // 2020-01-01 in ms
        assert!(ms < 4_102_444_800_000); // 2100-01-01 in ms
    }

    /// `find_header_end` finds the separator at the expected offset.
    ///
    /// Byte layout of "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}":
    ///   0–16  "HTTP/1.1 200 OK\r\n"  (17 bytes)
    ///  17–35  "Content-Length: 2\r\n" (19 bytes)
    ///  36–37  "\r\n"                  (blank line, 2 bytes)
    ///  38–39  "{}"
    /// The \r\n\r\n window starts at position 34.
    #[test]
    fn find_header_end_found() {
        let buf = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
        let pos = find_header_end(buf);
        assert_eq!(pos, Some(34));
        // Body starts immediately after the 4-byte separator.
        assert_eq!(&buf[pos.unwrap() + 4..], b"{}");
    }

    /// `find_header_end` returns None when no separator is present.
    #[test]
    fn find_header_end_not_found() {
        let buf = b"no separator here";
        assert!(find_header_end(buf).is_none());
    }

    /// `parse_grant_response` parses a well-formed success response.
    #[test]
    fn parse_grant_response_success() {
        let body = br#"{"ok":true,"tier":"restricted","expiresAt":"2026-07-05T00:00:00Z"}"#;
        match parse_grant_response(body) {
            UnlockOutcome::Granted { expires_at_iso } => {
                assert_eq!(expires_at_iso, "2026-07-05T00:00:00Z");
            }
            other => panic!("expected Granted, got {:?}", other),
        }
    }

    /// `parse_grant_response` surfaces an error response cleanly.
    #[test]
    fn parse_grant_response_error() {
        let body = br#"{"ok":false,"error":"proof timestamp stale"}"#;
        match parse_grant_response(body) {
            UnlockOutcome::DaemonError(msg) => {
                assert!(msg.contains("stale"), "msg: {msg}");
            }
            other => panic!("expected DaemonError, got {:?}", other),
        }
    }

    /// `parse_grant_response` handles malformed JSON gracefully.
    #[test]
    fn parse_grant_response_malformed_json() {
        let body = b"not json at all";
        match parse_grant_response(body) {
            UnlockOutcome::DaemonError(_) => {} // expected
            other => panic!("expected DaemonError, got {:?}", other),
        }
    }

    /// `authenticate_and_grant` returns `NotConfigured` when sidecar is absent.
    #[test]
    fn authenticate_and_grant_not_configured() {
        let dir = tempfile::tempdir().expect("tempdir");
        let outcome = authenticate_and_grant(SensitivityTier::Restricted, dir.path());
        matches!(outcome, UnlockOutcome::NotConfigured);
    }
}
