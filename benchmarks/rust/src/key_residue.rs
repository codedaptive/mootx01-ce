// key_residue.rs — zero-residual-key verification for scratch estate
// retirement (P1.1b, the 2026-07-30 requirement: when a test estate is
// retired, its key material goes with it — no orphaned keys ever).
//
// The Rust leg targets Linux/Windows as well as macOS, so it verifies the
// ON-DISK residue kind only: the Rust product keys its estates from a
// `db.key` file INSIDE the estate's own directory (PersistenceKit rust
// encryption.rs, INSTALL_KEY_FILE) — under a scratch dir, teardown of the
// dir removes it, and this module proves that it did. The Swift product's
// Keychain residue kind is verified by the Swift leg (KeyResidue.swift);
// there is no Keychain on the Rust leg's target platforms.
//
// The harness's run modes are designed to leave NOTHING: unencrypted opens a
// plaintext transient record (no key exists), encrypted uses the temporal-key
// posture (Swift product: key lives only in the serve process's memory;
// Rust product: scratch-local db.key torn down with the dir). This verifier
// is the enforcement — every retirement probes for residue and reports
// loudly, because a residue hit means the posture contract was violated
// upstream.

use std::path::{Path, PathBuf};

use crate::mcp_client::MCPError;

/// What a scratch dir could leave behind, collected BEFORE teardown (the
/// files must still exist to enumerate them).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyResidueProbes {
    /// On-disk `db.key` files found under the scratch dir.
    pub key_file_paths: Vec<PathBuf>,
    /// The scratch dir itself.
    pub scratch_dir: PathBuf,
}

/// Walks a scratch dir and records every on-disk key file (`db.key`). Call
/// BEFORE tearing the dir down. A missing dir yields empty probes (nothing
/// was created, nothing can linger).
pub fn collect_key_residue_probes(scratch_dir: &Path) -> KeyResidueProbes {
    let mut key_files = Vec::new();
    collect_db_keys(scratch_dir, &mut key_files, 0);
    key_files.sort();
    KeyResidueProbes {
        key_file_paths: key_files,
        scratch_dir: scratch_dir.to_path_buf(),
    }
}

/// Maximum depth this walk will descend below the scratch dir.
///
/// A scratch estate is shallow — `<scratch>/db.key` sits at depth 0 below
/// the scratch root — so this bound is never reached in practice. It is
/// defence in depth: teardown runs on every retirement and must not become an
/// unbounded walk over a pathological tree. Hitting the bound stops the
/// descent; it is not an error, because a residue walk that refuses to finish
/// is worse than one that stops looking.
const MAX_RESIDUE_WALK_DEPTH: usize = 16;

fn collect_db_keys(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth >= MAX_RESIDUE_WALK_DEPTH {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        // `DirEntry::file_type()` describes the ENTRY (an lstat), so a symlink
        // reports `is_symlink()` and never `is_dir()`. `Path::is_dir()` stats
        // the TARGET and therefore follows symlinks — using it here let a
        // symlinked directory inside the scratch dir send this walk outside
        // the scratch estate. That matters because scratch paths are
        // deterministic under a shared /tmp and are accepted via
        // `create_dir_all()` when already present, so a same-user process can
        // pre-create one containing a symlink to a large tree or to `/`, and
        // every teardown would then walk it.
        //
        // A symlink is still eligible to be RECORDED as residue below when it
        // is named `db.key` — a link left in the scratch dir is residue — it
        // is only never DESCENDED into.
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        if file_type.is_dir() {
            collect_db_keys(&path, out, depth + 1);
        } else if path.file_name().and_then(|n| n.to_str()) == Some("db.key") {
            out.push(path);
        }
    }
}

/// The outcome of a zero-residual verification.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyResidueReport {
    /// On-disk key files still present after teardown.
    pub key_files_remaining: Vec<PathBuf>,
    /// True when the scratch dir itself survived teardown.
    pub scratch_dir_remaining: bool,
}

impl KeyResidueReport {
    /// Zero residual key material: nothing left behind.
    pub fn is_clean(&self) -> bool {
        self.key_files_remaining.is_empty() && !self.scratch_dir_remaining
    }
}

/// Verifies zero residual key material AFTER a scratch dir teardown. Pure
/// inspection — the caller decides how loud to be from the report.
pub fn verify_zero_key_residue(probes: &KeyResidueProbes) -> KeyResidueReport {
    KeyResidueReport {
        key_files_remaining: probes
            .key_file_paths
            .iter()
            .filter(|p| p.exists())
            .cloned()
            .collect(),
        scratch_dir_remaining: probes.scratch_dir.exists(),
    }
}

/// Retires one scratch estate: collect residue probes, run the guarded
/// teardown the caller supplies, then verify. A dirty report is shouted to
/// stderr with every finding named — silence would let a run claim
/// cleanliness it does not have. Twin of Swift `retireScratchEstate`.
pub fn retire_scratch_estate<F>(scratch_dir: &Path, teardown: F) -> Result<(), MCPError>
where
    F: FnOnce(&Path) -> Result<(), MCPError>,
{
    let probes = collect_key_residue_probes(scratch_dir);
    let teardown_result = teardown(scratch_dir);
    let report = verify_zero_key_residue(&probes);
    if !report.is_clean() {
        let mut lines = vec![format!(
            "[key-residue] RESIDUAL KEY MATERIAL at retirement of {}:",
            scratch_dir.display()
        )];
        for f in &report.key_files_remaining {
            lines.push(format!("  key file still on disk: {}", f.display()));
        }
        if report.scratch_dir_remaining {
            lines.push(format!(
                "  scratch dir still present: {}",
                probes.scratch_dir.display()
            ));
        }
        lines.push(
            "  zero-residue contract violated — investigate the run's estate mode plumbing."
                .to_string(),
        );
        eprintln!("{}", lines.join("\n"));
    }
    teardown_result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("key-residue-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("estates").join("default")).unwrap();
        dir
    }

    #[test]
    fn probes_find_nested_db_key() {
        let dir = scratch("probe");
        std::fs::write(dir.join("estates/default/db.key"), b"0123456789abcdef0123456789abcdef")
            .unwrap();
        let probes = collect_key_residue_probes(&dir);
        assert_eq!(probes.key_file_paths.len(), 1);
        assert!(probes.key_file_paths[0].ends_with("estates/default/db.key"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn retirement_removes_key_with_estate_and_reports_clean() {
        let dir = scratch("clean");
        std::fs::write(dir.join("estates/default/db.key"), b"0123456789abcdef0123456789abcdef")
            .unwrap();
        std::fs::write(dir.join("estates/default/estate.sqlite"), b"data").unwrap();
        let probes = collect_key_residue_probes(&dir);
        assert_eq!(probes.key_file_paths.len(), 1);
        // Teardown = whole-dir removal, exactly what the runners do.
        std::fs::remove_dir_all(&dir).unwrap();
        let report = verify_zero_key_residue(&probes);
        assert!(report.is_clean(), "expected zero residue, got {report:?}");
    }

    #[test]
    fn residual_key_after_failed_teardown_is_detected() {
        let dir = scratch("dirty");
        std::fs::write(dir.join("estates/default/db.key"), b"0123456789abcdef0123456789abcdef")
            .unwrap();
        let probes = collect_key_residue_probes(&dir);
        // Simulate a teardown that failed to remove anything.
        let report = verify_zero_key_residue(&probes);
        assert!(!report.is_clean());
        assert_eq!(report.key_files_remaining.len(), 1);
        assert!(report.scratch_dir_remaining);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// REGRESSION (MXE-BK defect 3). A symlinked directory inside the scratch
    /// dir must NOT be descended into. `Path::is_dir()` stats the target and
    /// so followed the link, taking every teardown walk outside the scratch
    /// estate; `DirEntry::file_type()` describes the entry and does not.
    ///
    /// The outside tree here holds a `db.key`. Pre-fix the walk followed the
    /// link and collected it; post-fix it is never reached — the walk finds
    /// only the estate's own key.
    #[test]
    fn walk_does_not_follow_symlinked_directory_out_of_scratch() {
        let dir = scratch("symlink");
        std::fs::write(dir.join("estates/default/db.key"), b"inside").unwrap();

        // A tree OUTSIDE the scratch dir, holding a key the walk must not see.
        let outside = std::env::temp_dir()
            .join(format!("key-residue-outside-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&outside);
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("db.key"), b"outside").unwrap();

        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, dir.join("escape")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir(&outside, dir.join("escape")).unwrap();

        let probes = collect_key_residue_probes(&dir);

        assert_eq!(
            probes.key_file_paths.len(),
            1,
            "walk escaped the scratch estate through a symlink: {:?}",
            probes.key_file_paths
        );
        assert!(probes.key_file_paths[0].ends_with("estates/default/db.key"));
        assert!(
            !probes.key_file_paths.iter().any(|p| p.starts_with(&outside)),
            "walk collected a key from outside the scratch dir"
        );

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&outside);
    }

    /// A symlink named `db.key` is still RECORDED as residue — it is a link
    /// left inside the scratch dir. Only descent is refused, not detection.
    #[test]
    fn symlinked_key_file_is_still_recorded_as_residue() {
        let dir = scratch("symlink-key");
        let target = dir.join("real.key");
        std::fs::write(&target, b"k").unwrap();

        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, dir.join("estates/default/db.key")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&target, dir.join("estates/default/db.key")).unwrap();

        let probes = collect_key_residue_probes(&dir);
        assert_eq!(probes.key_file_paths.len(), 1);
        assert!(probes.key_file_paths[0].ends_with("estates/default/db.key"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_dir_probes_empty_and_clean() {
        let dir = std::env::temp_dir().join("key-residue-test-never-created");
        let probes = collect_key_residue_probes(&dir);
        assert!(probes.key_file_paths.is_empty());
        assert!(verify_zero_key_residue(&probes).is_clean());
    }

    #[test]
    fn retire_runs_teardown_and_propagates_result() {
        let dir = scratch("retire");
        std::fs::write(dir.join("estates/default/db.key"), b"k").unwrap();
        let result = retire_scratch_estate(&dir, |d| {
            std::fs::remove_dir_all(d).map_err(|e| MCPError {
                description: format!("teardown: {e}"),
            })
        });
        assert!(result.is_ok());
        assert!(!dir.exists());
    }
}
