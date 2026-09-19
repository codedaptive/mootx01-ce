//! Record naming and no-clobber record writes. Twin of Swift `RecordWriter.swift`.
//!
//! Two mandates live here, both from 2026-08-17, both paid for in lost
//! measurement time.
//!
//! NAMING. Every record is `<test>-<arm>-<serial>.<ext>`, and a report and its
//! params sidecar share one serial. The arm and the serial belong in the NAME,
//! not only in the payload: on 2026-08-17 the four matrix arms all resolved to
//! `matrix-report-seed20260816.json`, and the field that distinguished them
//! lived inside the file being replaced. A collision that overwrites its own
//! evidence cannot be detected by reading the survivor. Cost: 4h19m of matrix
//! measurement.
//!
//! NO OVERWRITE. A record write refuses to replace an existing file, via
//! `create_new(true)` (the `O_EXCL` the Swift leg opens with). A benchmark
//! record is measurement, not cache: the only correct response to "this path
//! is taken" is to stop and be told.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Resolves the run serial that ties a report to its params sidecar.
///
/// The Makefile passes `--run-id <serial>` so every record of one pass carries
/// the pass's serial, matching the output directory name. A hand invocation
/// with no flag gets a UTC timestamp in the same `yyyyMMddTHHmmssZ` shape the
/// Swift leg produces, so a record is never written without a serial.
pub fn resolve_run_serial(args: &[String]) -> String {
    if let Some(pos) = args.iter().position(|a| a == "--run-id") {
        if let Some(v) = args.get(pos + 1) {
            if !v.is_empty() {
                return v.clone();
            }
        }
    }
    utc_stamp(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
    )
}

/// Formats Unix seconds as `yyyyMMddTHHmmssZ`.
///
/// Hand-rolled rather than pulled from a date crate: the harness holds a
/// zero-extra-dependency line (std + serde + serde_json only), and the Swift
/// leg's `DateFormatter` output shape is the contract to match. The civil-date
/// conversion is Howard Hinnant's `civil_from_days`, shifting the epoch to
/// 0000-03-01 so leap days land at the end of the cycle.
fn utc_stamp(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11], March = 0
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };

    format!("{y:04}{m:02}{d:02}T{hh:02}{mm:02}{ss:02}Z")
}

/// Builds a record filename in the mandated `<test>-<arm>-<serial>` shape.
///
/// The arm is the value that distinguishes two runs of the same lane inside one
/// pass — the matrix set, the MemBench agent, the LongMemEval variant. A lane
/// with a single arm still names it (LoCoMo's `all10`, LMEB's `all6`) so a
/// record's scope is readable without opening the file, and so narrowing the
/// scope later cannot silently reuse a wider scope's name.
///
/// Path separators in `arm` are flattened: matrix arms carry set names that may
/// contain `/`, which would otherwise write into a directory that does not exist.
pub fn record_filename(test: &str, arm: &str, serial: &str, suffix: &str, ext: &str) -> String {
    let safe_arm = arm.replace('/', "_");
    let mut name = format!("{test}-{safe_arm}-{serial}");
    if !suffix.is_empty() {
        name.push('-');
        name.push_str(suffix);
    }
    format!("{name}.{ext}")
}

/// Writes a record, refusing to replace an existing file.
///
/// `create_new(true)` makes the create-or-fail decision the kernel's rather
/// than a check-then-write race. On collision the error names the path, so the
/// operator learns which record was about to be destroyed rather than
/// discovering later that it was.
pub fn write_record_never_overwrite(data: &[u8], path: &Path) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    // Create the parent directory tree before attempting the create_new open.
    // Separating parent creation from file creation preserves the never-overwrite
    // guarantee: create_new(true) still fails if the file is already there.
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            format!("cannot create parent directory for {}: {e}", path.display())
        })?;
    }
    // Mode 0o600: benchmark records are private evidence; world-readable scores
    // cross the OS-user boundary on a shared development host.
    let mut file = match OpenOptions::new().write(true).create_new(true).mode(0o600).open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(format!(
                "record already exists and records are never overwritten: {} \
                 — a second run of this arm in one pass must carry its own serial",
                path.display()
            ))
        }
        Err(e) => return Err(format!("cannot create record {}: {e}", path.display())),
    };
    file.write_all(data)
        .map_err(|e| format!("write failed for {}: {e}", path.display()))
}

/// Appends one line to a run-scoped ledger, creating it when absent.
///
/// The append path is separate from the report path on purpose. A report is
/// written once and never replaced; a ledger accumulates one line per record so
/// a pass leaves a readable index of what it produced, which is what makes a
/// smoke pass checkable in one read rather than a directory listing.
pub fn append_to_ledger(line: &str, path: &Path) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)
        .map_err(|e| format!("cannot open ledger {}: {e}", path.display()))?;
    let payload = if line.ends_with('\n') {
        line.to_string()
    } else {
        format!("{line}\n")
    };
    file.write_all(payload.as_bytes())
        .map_err(|e| format!("ledger append failed for {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pinned literals, not shape assertions: a golden stamp in both ports is
    // the only thing that catches a twin whose date math is quietly different.
    #[test]
    fn utc_stamp_matches_known_instants() {
        assert_eq!(utc_stamp(0), "19700101T000000Z");
        assert_eq!(utc_stamp(1_771_305_182), "20260217T051302Z");
        // 2024-02-29, a leap day, at 23:59:59 — the case the era shift exists for.
        assert_eq!(utc_stamp(1_709_251_199), "20240229T235959Z");
    }

    #[test]
    fn record_filename_carries_test_arm_serial() {
        assert_eq!(
            record_filename("matrix", "lmeb", "20260817T055302Z", "", "json"),
            "matrix-lmeb-20260817T055302Z.json"
        );
        assert_eq!(
            record_filename("matrix", "lmeb", "20260817T055302Z", "params", "json"),
            "matrix-lmeb-20260817T055302Z-params.json"
        );
    }

    #[test]
    fn arm_path_separators_are_flattened() {
        let n = record_filename("matrix", "set/one", "S", "", "json");
        assert_eq!(n, "matrix-set_one-S.json");
        assert!(!n.contains('/'));
    }

    // item (b) gate: write_record_never_overwrite must create the parent directory
    // tree before the create_new open. Without the create_dir_all call the open
    // fails with NotFound rather than producing a successful write.
    // Removing the create_dir_all block makes this test fail (gate is red).
    #[test]
    fn parent_dir_is_created_when_absent() {
        let root = std::env::temp_dir().join(format!(
            "record-writer-parent-create-{}", std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        // root is NOT created; the function must create root and sub.
        let path = root.join("sub").join("record.json");
        write_record_never_overwrite(b"payload", &path)
            .expect("write_record_never_overwrite must create parent dirs");
        assert_eq!(std::fs::read(&path).unwrap(), b"payload");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn second_write_to_one_path_is_refused() {
        let dir = std::env::temp_dir().join("record-writer-noclobber-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("r.json");
        write_record_never_overwrite(b"first", &p).unwrap();
        let err = write_record_never_overwrite(b"second", &p).unwrap_err();
        assert!(err.contains("never overwritten"), "{err}");
        // The first record is intact — a refused write must not truncate.
        assert_eq!(std::fs::read(&p).unwrap(), b"first");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
