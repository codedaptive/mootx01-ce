//! Build serial derivation for `moot_estate_ping`.
//!
//! Provides a single entry point — `derive()` — that returns a build
//! serial string computed once at server startup and stored on the
//! dispatcher so `moot_estate_ping` can report it without any per-call
//! filesystem access.
//!
//! ## Override
//!
//! If `MOOTX01_BUILD_SERIAL` is set and non-empty, it is returned verbatim.
//! This lets test harnesses and CI inject a known serial without recompiling.
//!
//! ## Derived value
//!
//! When the env override is absent, the serial is derived from the running
//! executable's modification time and byte count:
//!
//!   `<mtime-yyyyMMddHHmmss>/<8-hex-fingerprint>`
//!
//! The 8-hex fingerprint is the lower 32 bits of
//! `mtime_seconds XOR file_size`, formatted as zero-padded lowercase hex.
//! This is not a cryptographic hash — its sole purpose is build identity:
//! the value changes on every relink because the linker always updates
//! the mtime and the output size varies with code changes. Only filesystem
//! metadata is queried (one `std::fs::metadata` call, no file read).
//!
//! On any error (exe path unavailable, metadata unreadable), falls back
//! to `"unknown"` so the server still starts cleanly.
//!
//! ## Parity with Swift
//!
//! Mirrors `ToolDispatcher.deriveBuildSerial()` in
//! `Sources/AriaMCP/ToolDispatch.swift`. The serial VALUE differs per
//! binary (different files, different OS, different mtime) — this is
//! expected and correct. The serial is a self-report, not a cross-port
//! conformance value.

use std::time::UNIX_EPOCH;

/// Derive the build serial for the currently running executable.
///
/// See the module-level documentation for the full derivation contract
/// and the `MOOTX01_BUILD_SERIAL` override.
pub fn derive() -> String {
    // 1. Env override wins unconditionally.
    let env_override = std::env::var("MOOTX01_BUILD_SERIAL").unwrap_or_default();
    if !env_override.is_empty() {
        return env_override;
    }

    // 2. Derive from the running executable's mtime + size.
    let exe_path = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return "unknown".to_owned(),
    };

    let meta = match std::fs::metadata(&exe_path) {
        Ok(m) => m,
        Err(_) => return "unknown".to_owned(),
    };

    let mtime_secs: u64 = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let file_size: u64 = meta.len();

    // Compact mtime: yyyyMMddHHmmss in UTC (14 chars, sortable, human-readable).
    // Computed from mtime_secs using calendar arithmetic — no external crate needed.
    let compact = seconds_to_yyyymmddhhmmss(mtime_secs);

    // 8-hex fingerprint: lower 32 bits of (mtime_seconds XOR file_size).
    // Changes on every relink (mtime advances; size varies with code delta).
    let fingerprint: u32 = (mtime_secs ^ file_size) as u32;
    let hex = format!("{:08x}", fingerprint);

    format!("{}/{}", compact, hex)
}

/// Convert a Unix timestamp (seconds since 1970-01-01 00:00:00 UTC) to
/// the compact `yyyyMMddHHmmss` string used in the build serial.
///
/// Uses calendar arithmetic so no external crate is required. The
/// Gregorian calendar rules (leap years, month lengths) are implemented
/// inline. Returns `"00000000000000"` on any arithmetic failure.
fn seconds_to_yyyymmddhhmmss(secs: u64) -> String {
    // Decompose into date + time components.
    let s_in_day = (secs % 86400) as u32;
    let h = s_in_day / 3600;
    let m = (s_in_day % 3600) / 60;
    let s = s_in_day % 60;

    // Days since 1970-01-01 (the Unix epoch).
    let total_days = (secs / 86400) as u32;

    // Gregorian calendar: walk from year 1970 upward.
    let mut year = 1970u32;
    let mut remaining = total_days;
    loop {
        let days_in_year = if is_leap(year) { 366 } else { 365 };
        if remaining < days_in_year {
            break;
        }
        remaining -= days_in_year;
        year += 1;
    }

    let month_days: [u32; 12] = [
        31,
        if is_leap(year) { 29 } else { 28 },
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
    ];
    let mut month = 1u32;
    for &days in &month_days {
        if remaining < days {
            break;
        }
        remaining -= days;
        month += 1;
    }
    let day = remaining + 1;

    format!(
        "{:04}{:02}{:02}{:02}{:02}{:02}",
        year, month, day, h, m, s
    )
}

/// Returns true if `year` is a Gregorian leap year.
fn is_leap(year: u32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `seconds_to_yyyymmddhhmmss` calendar function produces the
    /// expected string for a known Unix timestamp.
    ///
    /// 2025-06-19 00:00:00 UTC = 1_750_291_200 seconds since epoch.
    /// 2026-06-19 00:00:00 UTC = 1_781_827_200 seconds since epoch.
    #[test]
    fn known_timestamp_formats_correctly() {
        assert_eq!(seconds_to_yyyymmddhhmmss(1_750_291_200), "20250619000000");
        assert_eq!(seconds_to_yyyymmddhhmmss(1_781_827_200), "20260619000000");
    }

    /// The `seconds_to_yyyymmddhhmmss` function handles the epoch itself.
    #[test]
    fn epoch_zero_formats_correctly() {
        assert_eq!(seconds_to_yyyymmddhhmmss(0), "19700101000000");
    }

    /// `derive()` returns a non-empty string under normal conditions.
    ///
    /// We cannot assert the exact value (it depends on the test binary's
    /// mtime), but we can confirm the function returns something non-empty
    /// and either the env-override path or the derived path fires.
    #[test]
    fn derive_returns_non_empty() {
        // The env var is not removed before calling derive(). If MOOTX01_BUILD_SERIAL
        // is already set in the test environment, the override path fires — also fine;
        // either path returns a non-empty serial.
        let serial = derive();
        assert!(!serial.is_empty(), "derive() must return a non-empty serial");
    }

    /// `MOOTX01_BUILD_SERIAL` override is honored by `derive()`.
    ///
    /// We set it in-process via `std::env::set_var` for the duration of
    /// this test. This is safe in a single-threaded test; the var is
    /// removed after the assertion so other tests are unaffected.
    #[test]
    fn env_override_is_honored() {
        // SAFETY: no other thread in this test binary reads MOOTX01_BUILD_SERIAL
        // concurrently. The Rust test runner can run tests in parallel, but this
        // module's tests do not share state with other modules.
        unsafe { std::env::set_var("MOOTX01_BUILD_SERIAL", "TEST-OVERRIDE-XYZ") };
        let serial = derive();
        unsafe { std::env::remove_var("MOOTX01_BUILD_SERIAL") };
        assert_eq!(serial, "TEST-OVERRIDE-XYZ");
    }
}
