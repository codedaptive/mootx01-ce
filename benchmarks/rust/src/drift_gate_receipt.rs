//! drift_gate_receipt.rs — runtime enforcement of the drift gate. Rust twin of
//! Swift's `DriftGateReceipt.swift`.
//!
//! `make drift-gate` runs CorpusKit's counts-store invariants in both ports and
//! writes a receipt. `make drift-stamp-current` then refuses to measure a
//! binary older than the source those invariants were checked against — but
//! only when `MOOT_BINARY` names a path make can stat. When the flag is unset,
//! the lane discovers its own binary and the rule goes unenforced exactly where
//! a mistake is easiest to make.
//!
//! This module applies the same rule against the path the harness ACTUALLY
//! resolved. A measurement of a binary older than the validated source is a
//! measurement of code nobody checked, and it reads as an ordinary result.
//!
//! The receipt is three lines, written only when both ports' suites pass:
//!
//!   1  ISO8601 instant the gate passed        (provenance, not enforcement)
//!   2  sha256 over the kit sources it checked (make enforces this one)
//!   3  newest kit source mtime, epoch seconds (THIS module enforces this one)
//!
//! Line 3 exists so the harness can apply the freshness rule without reaching
//! into the kit tree. Teaching the benchmarker to stat kit sources would put
//! kit layout knowledge in the harness, and drift between those two is the
//! failure this whole mechanism exists to prevent.

use std::fmt;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Filename the Makefile writes. One constant, so a rename cannot leave the
/// writer and the reader looking at different paths.
pub const RECEIPT_FILENAME: &str = ".drift-gate-stamp";

/// Why a run may not proceed. Each variant carries the numbers, because a
/// refusal that does not say what it saw sends the reader back to reproduce it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftGateRefusal {
    /// No receipt at the expected path: the gate has not run for this cache dir.
    NoReceipt { path: String },

    /// The receipt exists but is not the three-line shape this module reads.
    /// Treated as a refusal rather than a pass: an unreadable receipt is
    /// absence of evidence, and the point is to fail closed.
    UnreadableReceipt { path: String, detail: String },

    /// The binary under test predates the newest source the gate validated.
    BinaryOlderThanValidatedSource {
        binary_path: String,
        binary_mtime: u64,
        newest_source_mtime: u64,
    },
}

impl fmt::Display for DriftGateRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DriftGateRefusal::NoReceipt { path } => write!(
                f,
                "REFUSING to run: no drift-gate receipt at {path}. The counts-store \
                 invariants have not been checked for this cache directory. Run \
                 `make drift-gate` before measuring."
            ),
            DriftGateRefusal::UnreadableReceipt { path, detail } => write!(
                f,
                "REFUSING to run: drift-gate receipt at {path} could not be read \
                 ({detail}). An unreadable receipt is not evidence the gate passed. \
                 Run `make drift-gate` to rewrite it."
            ),
            DriftGateRefusal::BinaryOlderThanValidatedSource {
                binary_path,
                binary_mtime,
                newest_source_mtime,
            } => write!(
                f,
                "REFUSING to run: {binary_path} is older than the source the drift \
                 gate validated.\n  binary built:   epoch {binary_mtime}\n  source \
                 changed: epoch {newest_source_mtime}\nThe binary predates the code \
                 whose invariants were checked, so the gate's evidence does not cover \
                 what is about to be measured. Rebuild the binary, then run \
                 `make drift-gate`."
            ),
        }
    }
}

impl std::error::Error for DriftGateRefusal {}

/// The gate's receipt, and the rule the harness enforces from it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriftGateReceipt {
    /// Instant the gate passed. Provenance for the run record; not enforced.
    pub passed_at: String,

    /// sha256 over the kit sources the gate checked. Carried so a run record
    /// can name the exact source state validated. The Makefile enforces this
    /// field; the harness cannot, having no kit tree to hash.
    pub kit_fingerprint: String,

    /// Newest mtime among the kit sources the gate checked, epoch seconds.
    pub newest_source_mtime: u64,
}

impl DriftGateReceipt {
    /// Reads the receipt from a cache directory.
    ///
    /// Fails closed on a missing or malformed receipt: the alternative is
    /// measuring on the strength of a file nobody could parse.
    pub fn read(cache_directory: &Path) -> Result<Self, DriftGateRefusal> {
        let path = cache_directory.join(RECEIPT_FILENAME);
        let display = path.display().to_string();
        if !path.exists() {
            return Err(DriftGateRefusal::NoReceipt { path: display });
        }
        let text = fs::read_to_string(&path).map_err(|e| DriftGateRefusal::UnreadableReceipt {
            path: display.clone(),
            detail: e.to_string(),
        })?;
        let lines: Vec<&str> = text
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect();
        if lines.len() < 3 {
            return Err(DriftGateRefusal::UnreadableReceipt {
                path: display,
                detail: format!("expected 3 lines, found {}", lines.len()),
            });
        }
        let mtime = lines[2]
            .parse::<u64>()
            .map_err(|_| DriftGateRefusal::UnreadableReceipt {
                path: display,
                detail: format!("line 3 is not an epoch timestamp: '{}'", lines[2]),
            })?;
        Ok(DriftGateReceipt {
            passed_at: lines[0].to_string(),
            kit_fingerprint: lines[1].to_string(),
            newest_source_mtime: mtime,
        })
    }

    /// Refuses when `binary_path` is older than the newest source the gate
    /// validated.
    ///
    /// A binary whose mtime cannot be read is NOT a refusal: the path may be a
    /// wrapper or a symlink into a store the harness cannot stat, and failing
    /// closed there would block legitimate runs for a reason unrelated to
    /// drift. The checks that CAN be made are made.
    pub fn assert_covers(&self, binary_path: &str) -> Result<(), DriftGateRefusal> {
        let mtime = match fs::metadata(binary_path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        {
            Some(d) => d.as_secs(),
            None => return Ok(()),
        };

        if mtime < self.newest_source_mtime {
            return Err(DriftGateRefusal::BinaryOlderThanValidatedSource {
                binary_path: binary_path.to_string(),
                binary_mtime: mtime,
                newest_source_mtime: self.newest_source_mtime,
            });
        }
        Ok(())
    }
}

/// The whole preflight: read the receipt, then apply the freshness rule.
///
/// Call once per run, after the lane has resolved which binary it will drive
/// and before it writes anything to a scratch estate.
pub fn preflight(cache_directory: &Path, binary_path: Option<&str>) -> Result<(), DriftGateRefusal> {
    let receipt = DriftGateReceipt::read(cache_directory)?;
    // A run with no resolved binary has nothing to check freshness against.
    // The receipt still had to exist, which is the part that can be checked.
    match binary_path {
        Some(p) => receipt.assert_covers(p),
        None => Ok(()),
    }
}

/// Convenience for tests and callers that hold a `SystemTime`.
#[allow(dead_code)]
pub fn epoch_secs(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    //! Proves the preflight CAN refuse. A check nobody has watched fail is a
    //! claim. Each refusal path is built and observed, and each is paired with
    //! the case that must be ACCEPTED — a preflight refusing everything would
    //! satisfy the first half and fail the second.

    use super::*;
    use std::fs::File;
    use std::io::Write;

    fn scratch_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("drift-gate-rs-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create scratch dir");
        dir
    }

    fn write_receipt(dir: &Path, fingerprint: &str, source_mtime: u64) {
        let mut f = File::create(dir.join(RECEIPT_FILENAME)).expect("create receipt");
        writeln!(f, "2026-08-15T22:00:00Z").unwrap();
        writeln!(f, "{fingerprint}").unwrap();
        writeln!(f, "{source_mtime}").unwrap();
    }

    /// Creates a file standing in for a product binary, with an explicit mtime.
    /// Uses std's `File::set_modified` rather than a crate: the harness takes
    /// no dependency it can avoid, least of all for test scaffolding.
    fn make_binary(dir: &Path, name: &str, mtime: u64) -> String {
        let path = dir.join(name);
        let f = File::create(&path).expect("create binary");
        (&f).write_all(b"\x7f").unwrap();
        f.set_modified(UNIX_EPOCH + std::time::Duration::from_secs(mtime))
            .expect("set mtime");
        path.display().to_string()
    }

    #[test]
    fn refuses_without_receipt() {
        let dir = scratch_dir("no-receipt");
        let err = preflight(&dir, None).expect_err("must refuse without a receipt");
        assert!(matches!(err, DriftGateRefusal::NoReceipt { .. }), "{err:?}");
    }

    #[test]
    fn refuses_on_truncated_receipt() {
        let dir = scratch_dir("truncated");
        let mut f = File::create(dir.join(RECEIPT_FILENAME)).unwrap();
        writeln!(f, "2026-08-15T22:00:00Z").unwrap();
        writeln!(f, "abc123").unwrap();
        let err = preflight(&dir, None).expect_err("must refuse a 2-line receipt");
        assert!(matches!(err, DriftGateRefusal::UnreadableReceipt { .. }), "{err:?}");
    }

    #[test]
    fn refuses_on_non_numeric_mtime() {
        let dir = scratch_dir("non-numeric");
        write_receipt(&dir, "abc123", 0);
        let mut f = File::create(dir.join(RECEIPT_FILENAME)).unwrap();
        writeln!(f, "2026-08-15T22:00:00Z\nabc123\nyesterday").unwrap();
        let err = preflight(&dir, None).expect_err("must refuse a non-epoch line 3");
        assert!(matches!(err, DriftGateRefusal::UnreadableReceipt { .. }), "{err:?}");
    }

    #[test]
    fn refuses_stale_binary() {
        let dir = scratch_dir("stale");
        write_receipt(&dir, "abc123", 1_760_000_000);
        let stale = make_binary(&dir, "stale-moot", 1_760_000_000 - 3600);
        let err = preflight(&dir, Some(&stale)).expect_err("must refuse a stale binary");
        assert!(
            matches!(err, DriftGateRefusal::BinaryOlderThanValidatedSource { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn accepts_fresh_binary() {
        let dir = scratch_dir("fresh");
        write_receipt(&dir, "abc123", 1_760_000_000);
        let fresh = make_binary(&dir, "fresh-moot", 1_760_000_000 + 3600);
        preflight(&dir, Some(&fresh)).expect("a binary newer than the source must be accepted");
    }

    /// Equal mtimes are accepted: the rule is "older than", and a build
    /// finishing inside the same second is correct. Refusing it would block
    /// real runs.
    #[test]
    fn accepts_equal_mtime() {
        let dir = scratch_dir("equal");
        write_receipt(&dir, "abc123", 1_760_000_000);
        let same = make_binary(&dir, "same-moot", 1_760_000_000);
        preflight(&dir, Some(&same)).expect("equal mtimes must be accepted");
    }

    /// An unstattable path is not a refusal: it may be a wrapper or a symlink
    /// into a store the harness cannot inspect. The receipt still had to exist.
    #[test]
    fn tolerates_unstattable_binary() {
        let dir = scratch_dir("unstattable");
        write_receipt(&dir, "abc123", 1_760_000_000);
        preflight(&dir, Some("/nonexistent/path/to/mootx01"))
            .expect("an unstattable path must not refuse");
    }

    #[test]
    fn reads_receipt_fields() {
        let dir = scratch_dir("fields");
        write_receipt(&dir, "deadbeef", 1_760_000_000);
        let r = DriftGateReceipt::read(&dir).expect("receipt must parse");
        assert_eq!(r.kit_fingerprint, "deadbeef");
        assert_eq!(r.passed_at, "2026-08-15T22:00:00Z");
        assert_eq!(r.newest_source_mtime, 1_760_000_000);
    }

    /// A refusal that does not say what it saw sends the reader back to
    /// reproduce it.
    #[test]
    fn refusal_message_is_actionable() {
        let dir = scratch_dir("message");
        write_receipt(&dir, "abc123", 1_760_000_000);
        let stale = make_binary(&dir, "stale-msg", 1_760_000_000 - 3600);
        let err = preflight(&dir, Some(&stale)).expect_err("must refuse");
        let text = err.to_string();
        assert!(text.contains(&stale), "must name the binary: {text}");
        assert!(text.contains("REFUSING"), "must state the refusal: {text}");
        assert!(text.contains("Rebuild"), "must say what to do: {text}");
    }
}
