//! estate_cache.rs — snapshot-based estate reuse for benchmark runners.
//!
//! Rust twin of `EstateCache.swift`. See that file for the full design rationale,
//! cache key components, deletion discipline, and METHODOLOGY note on cross-twin
//! sharing.
//!
//! ## How it works (--estate-cache reuse)
//!
//!   FIRST run of a question:  normal ingest → encode barrier → snapshot to cache
//!   SUBSEQUENT runs:          copy snapshot → skip ingest → guard probe → query
//!
//! The copy queried is always a FRESH COPY of the snapshot. The cache original
//! is NEVER queried — a corrupt run cannot contaminate future cache reads.
//!
//! ## Cache key
//!
//! `(benchmark, variant, seed, encode_barrier, binary_fingerprint, unit_id)`
//!
//! Binary fingerprint (mtime + size) invalidates automatically on rebuild.
//!
//! ## Cache entry layout
//!
//! ```text
//! <cacheDir>/
//!   <run-key>/           benchmark[-variant]-seed<N>-barrier_<mode>-bin_<fp>
//!     <safe-unit-id>/    question_id / conv_id / query_id (filesystem-safe)
//!       estate/          copy of MOOTX01_DATA_DIR after ingest+encode
//!       manifest.json    serialized manifest entries (UUID -> origin mapping)
//! ```

use crate::encode_barrier::EncodeBarrier;
use serde::{Serialize, de::DeserializeOwned};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// ─────────────────────────────────────────────────────────────────────────────
// Cache mode
// ─────────────────────────────────────────────────────────────────────────────

/// The estate snapshot reuse mode passed via --estate-cache.
///
/// `off` (default): each question gets a freshly ingested estate — the default behavior.
/// `reuse`: after ingest + encode, snapshot the estate to a keyed cache; on subsequent
/// runs with the same key, copy the snapshot and skip ingest entirely.
///
/// Twin of Swift `EstateCacheMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateCacheMode {
    /// Fresh ingest every run. Default. No cache is read or written.
    Off,
    /// Snapshot after ingest; copy snapshot on subsequent runs.
    Reuse,
}

impl EstateCacheMode {
    /// Parse from a CLI string. Returns an error string on unknown value.
    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "off"   => Ok(EstateCacheMode::Off),
            "reuse" => Ok(EstateCacheMode::Reuse),
            other   => Err(format!(
                "--estate-cache must be 'off' or 'reuse'; got '{other}'"
            )),
        }
    }

    /// The raw string value as written to report JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            EstateCacheMode::Off   => "off",
            EstateCacheMode::Reuse => "reuse",
        }
    }
}

impl Default for EstateCacheMode {
    fn default() -> Self {
        EstateCacheMode::Off
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Binary fingerprint
// ─────────────────────────────────────────────────────────────────────────────

/// Computes a short fingerprint of the mootx01 binary using mtime + file size.
///
/// Fast (one stat call), reliable (any `swift build` changes the binary's mtime),
/// and zero-dependency. Returns "unknown" when the binary is inaccessible.
///
/// Format: "<mtime_secs_hex>_<size_hex>". Matches the Swift `mootBinaryFingerprint(_:)` format.
/// Uses integer seconds (sub-second precision dropped) for a stable key.
///
/// Cross-twin sharing: when the Swift and Rust runners point at the SAME mootx01
/// binary, their fingerprints match → same cache entries are shared across both twins.
///
/// Twin of Swift `mootBinaryFingerprint(_:)`.
pub fn moot_binary_fingerprint(binary_path: &str) -> String {
    let path = Path::new(binary_path);
    // Resolve symlinks so the fingerprint reflects the final binary target, not
    // an intermediate symlink that may have a different mtime. Fall back to the
    // original path if canonicalize fails (e.g., path does not exist yet).
    let resolved = match std::fs::canonicalize(path) {
        Ok(p) => p,
        Err(_) => path.to_path_buf(),
    };
    match std::fs::metadata(&resolved) {
        Ok(meta) => {
            let size = meta.len();
            // Use integer seconds (drop sub-second precision) for a stable key —
            // same as Swift's `Int64(attrs[.modificationDate]?.timeIntervalSince1970 ?? 0)`.
            let mtime_secs = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            format!("{mtime_secs:x}_{size:x}")
        }
        Err(_) => "unknown".to_string(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cache entry path
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the path of the cache entry directory for one benchmark unit
/// (a question, conversation, or query), keyed by the full run configuration.
///
/// Cache hierarchy:
/// ```text
/// <cacheDir>/
///   <benchmark>[-<variant>]-seed<seed>-barrier_<mode>-bin_<fingerprint>/
///     <safe-unit-id>/
///       estate/        <- MOOTX01_DATA_DIR snapshot
///       manifest.json  <- serialized manifest entries
/// ```
///
/// - `variant`: LME variant ("s", "m", "oracle"). Empty string for locomo/lmeb.
/// - `unit_id`: The question_id / conversation sampleID / query_id. Sanitized
///   for filesystem safety (illegal characters replaced with underscores,
///   truncated to 200 chars).
///
/// Twin of Swift `estateCacheEntryURL(...)`.
pub fn estate_cache_entry_path(
    cache_dir: &Path,
    benchmark: &str,
    variant: &str,
    seed: u64,
    encode_barrier: EncodeBarrier,
    binary_fingerprint: &str,
    unit_id: &str,
) -> PathBuf {
    // Run-config key: a single directory name encoding all parameters that
    // affect estate content. Components separated by dashes for readability.
    let variant_suffix = if variant.is_empty() {
        String::new()
    } else {
        format!("-{variant}")
    };
    let run_key = format!(
        "{benchmark}{variant_suffix}-seed{seed}-barrier_{}-bin_{binary_fingerprint}",
        encode_barrier.as_str()
    );

    // Sanitize unit ID: only alphanumerics, dash, dot, underscore are safe on
    // all relevant filesystems (macOS HFS+, Linux ext4). Everything else → '_'.
    let safe_unit_id: String = unit_id
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '.' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    // Guard against empty or over-long IDs (256-char path component limit on HFS+).
    let safe_unit_id: String = if safe_unit_id.is_empty() {
        "unknown".to_string()
    } else {
        safe_unit_id.chars().take(200).collect()
    };

    cache_dir.join(run_key).join(safe_unit_id)
}

// ─────────────────────────────────────────────────────────────────────────────
// Default cache directory
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the default cache directory for a run.
///
/// When `--cache-dir` is absent, the cache lives under `<out-dir>/estate-cache/`
/// (or `<cwd>/estate-cache/` when `--out` is also absent).
///
/// The `estate-cache` directory is created on first write. Its presence is
/// inert during `--estate-cache off` runs — the runner never reads or writes it.
///
/// Expected cache sizes (inform disk planning):
///   - LME: ~80–150 MB per cached estate × number of unique questions.
///   - LoCoMo: ~30–80 MB per cached conversation × 10 conversations ≈ ≤ 800 MB.
///   - LMEB: ~5–50 MB per cached query estate × number of queries.
///
/// Twin of Swift `defaultCacheDir(outDir:)`.
pub fn default_cache_dir(out_dir: Option<&Path>) -> PathBuf {
    let base = out_dir
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    base.join("estate-cache")
}

// ─────────────────────────────────────────────────────────────────────────────
// Directory copy helper
// ─────────────────────────────────────────────────────────────────────────────

/// Recursively copies a directory tree from `src` to `dst`.
///
/// `dst` must NOT exist — mirrors macOS `FileManager.copyItem(at:to:)` semantics
/// used in the Swift twin. Creates `dst` and all parent directories.
///
/// Returns an error string on failure. Non-fatal callers log and continue.
pub fn copy_dir_all(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dst).map_err(|e| {
        format!("copy_dir_all: create_dir_all {} failed: {e}", dst.display())
    })?;

    for entry in std::fs::read_dir(src).map_err(|e| {
        format!("copy_dir_all: read_dir {} failed: {e}", src.display())
    })? {
        let entry = entry.map_err(|e| {
            format!("copy_dir_all: read entry in {} failed: {e}", src.display())
        })?;
        let src_child = entry.path();
        let dst_child = dst.join(entry.file_name());

        if src_child.is_dir() {
            copy_dir_all(&src_child, &dst_child)?;
        } else {
            std::fs::copy(&src_child, &dst_child).map_err(|e| {
                format!(
                    "copy_dir_all: copy {} -> {} failed: {e}",
                    src_child.display(),
                    dst_child.display()
                )
            })?;
        }
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Snapshot + restore
// ─────────────────────────────────────────────────────────────────────────────

/// Saves an estate snapshot to a cache entry directory.
///
/// Creates the entry directory (and any parent run-key directory), copies the
/// estate data dir to `<entry>/estate/`, and writes the manifest to
/// `<entry>/manifest.json`. Non-fatal on failure: a snapshot error is logged
/// and the run continues without caching (the question result is still valid).
///
/// - `estate_scratch_dir`: The benchmark scratch dir after ingest + encode barrier.
///   The directory MUST exist and contain a valid mootx01 estate.
/// - `manifest`: Per-question manifest entries (UUID → origin). Must be Serialize
///   so they can round-trip through `manifest.json`.
/// - `cache_entry`: The directory where the snapshot will be written. Caller
///   provides the path from `estate_cache_entry_path(...)`.
///
/// Twin of Swift `saveEstateCacheEntry(estateScratchDir:manifest:to:)`.
pub fn save_estate_cache_entry<M: Serialize>(
    estate_scratch_dir: &Path,
    manifest: &[M],
    cache_entry: &Path,
) {
    // Inner closure so we can use ? for error propagation and log at one site.
    let result = (|| -> Result<(), String> {
        // Ensure the entry directory (and run-key parent) exist.
        std::fs::create_dir_all(cache_entry).map_err(|e| {
            format!("create_dir_all {} failed: {e}", cache_entry.display())
        })?;

        let estate_target = cache_entry.join("estate");
        let manifest_path = cache_entry.join("manifest.json");

        // Remove any stale estate from a partial previous write.
        if estate_target.exists() {
            std::fs::remove_dir_all(&estate_target).map_err(|e| {
                format!("remove_dir_all stale estate {} failed: {e}", estate_target.display())
            })?;
        }

        // Copy estate data dir into the cache entry.
        copy_dir_all(estate_scratch_dir, &estate_target)?;

        // Write the manifest JSON alongside the estate (pretty-printed, sorted by serde default).
        let manifest_json = serde_json::to_string_pretty(manifest)
            .map_err(|e| format!("manifest encode failed: {e}"))?;
        std::fs::write(&manifest_path, manifest_json.as_bytes())
            .map_err(|e| format!("manifest write failed: {e}"))?;

        eprintln!(
            "[cache] snapshot saved: {}/{}",
            cache_entry
                .parent()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            cache_entry
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
        );
        Ok(())
    })();

    if let Err(e) = result {
        eprintln!(
            "[cache] snapshot WARNING: could not save {}: {e}",
            cache_entry.display()
        );
    }
}

/// Restores an estate cache entry to a fresh scratch directory.
///
/// Checks whether `cache_entry` has both an `estate/` subdirectory and a
/// `manifest.json` file. On a hit: creates a fresh scratch directory via
/// `scratch_dir_factory`, copies the cached estate into it, and decodes the
/// manifest. On a miss or any error: returns `None` (non-fatal, caller falls
/// back to normal ingest).
///
/// ISOLATION GUARANTEE: The returned scratch directory is a fresh COPY of the
/// cache entry. The cache original is never queried, so a query run cannot
/// contaminate subsequent cache reads regardless of mootx01's writes to the estate.
///
/// - `cache_entry`: Cache entry path from `estate_cache_entry_path(...)`.
/// - `scratch_dir_factory`: A `FnOnce` that creates the empty scratch directory.
///   The factory produces the empty dir; this function removes it and replaces
///   its path with the cached estate copy. The resulting path retains the correct
///   prefix for guarded teardown.
/// - Returns `Some((scratch_dir, manifest))` on cache hit, `None` on miss or error.
///
/// Twin of Swift `restoreEstateCacheEntry(from:scratchDirFactory:)`.
pub fn restore_estate_cache_entry<M: DeserializeOwned>(
    cache_entry: &Path,
    scratch_dir_factory: impl FnOnce() -> Result<PathBuf, String>,
) -> Option<(PathBuf, Vec<M>)> {
    let estate_source = cache_entry.join("estate");
    let manifest_path = cache_entry.join("manifest.json");

    // Cache miss: required files absent.
    if !estate_source.exists() || !manifest_path.exists() {
        return None;
    }

    let result = (|| -> Result<(PathBuf, Vec<M>), String> {
        // Create a fresh scratch directory with the correct prefix.
        let scratch = scratch_dir_factory()?;
        // Remove the empty scratch dir so copy_dir_all can write to its path
        // (mirrors Swift: removeItem at the empty scratch before copyItem).
        std::fs::remove_dir_all(&scratch).map_err(|e| {
            format!("remove empty scratch {} failed: {e}", scratch.display())
        })?;
        // Copy the cached estate into the scratch path (cache original untouched).
        copy_dir_all(&estate_source, &scratch)?;
        // Decode the manifest.
        let manifest_data = std::fs::read_to_string(&manifest_path)
            .map_err(|e| format!("manifest read failed: {e}"))?;
        let manifest: Vec<M> = serde_json::from_str(&manifest_data)
            .map_err(|e| format!("manifest decode failed: {e}"))?;
        eprintln!(
            "[cache] hit: {}",
            cache_entry
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
        );
        Ok((scratch, manifest))
    })();

    match result {
        Ok(pair) => Some(pair),
        Err(e) => {
            eprintln!(
                "[cache] restore WARNING: could not restore {}: {e}",
                cache_entry.display()
            );
            None
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    // ── EstateCacheMode tests ─────────────────────────────────────────────────

    #[test]
    fn cache_mode_round_trips() {
        assert_eq!(EstateCacheMode::from_str("off").unwrap(),   EstateCacheMode::Off);
        assert_eq!(EstateCacheMode::from_str("reuse").unwrap(), EstateCacheMode::Reuse);
    }

    #[test]
    fn cache_mode_rejects_unknown() {
        assert!(EstateCacheMode::from_str("on").is_err());
        assert!(EstateCacheMode::from_str("").is_err());
    }

    #[test]
    fn cache_mode_as_str() {
        assert_eq!(EstateCacheMode::Off.as_str(),   "off");
        assert_eq!(EstateCacheMode::Reuse.as_str(), "reuse");
    }

    #[test]
    fn default_is_off() {
        assert_eq!(EstateCacheMode::default(), EstateCacheMode::Off);
    }

    // ── Cache entry path tests ────────────────────────────────────────────────

    #[test]
    fn cache_entry_path_no_variant() {
        let base = Path::new("/tmp/ec-test-cache");
        let p = estate_cache_entry_path(
            base, "lme", "", 42, EncodeBarrier::Drain, "abc_def", "question_001",
        );
        let s = p.to_string_lossy();
        assert!(s.contains("lme-seed42-barrier_drain-bin_abc_def"), "run key not found in {s}");
        assert!(s.ends_with("question_001"), "unit id not at end of {s}");
    }

    #[test]
    fn cache_entry_path_with_variant() {
        let base = Path::new("/tmp/ec-test-cache");
        let p = estate_cache_entry_path(
            base, "lme", "s", 0, EncodeBarrier::Impatient, "fp123", "q1",
        );
        assert!(p.to_string_lossy().contains("lme-s-seed0-barrier_impatient-bin_fp123"));
    }

    #[test]
    fn cache_entry_path_sanitizes_unit_id() {
        let base = Path::new("/tmp/ec-test-cache");
        let p = estate_cache_entry_path(
            base, "lmeb", "", 1, EncodeBarrier::None, "fp", "query/with/slashes and spaces",
        );
        let last = p.file_name().unwrap().to_string_lossy();
        assert!(!last.contains('/'), "slash not sanitized in {last}");
        assert!(!last.contains(' '), "space not sanitized in {last}");
    }

    #[test]
    fn different_fingerprint_produces_different_key() {
        let base = Path::new("/tmp/ec-test-cache");
        let p1 = estate_cache_entry_path(base, "lme", "", 1, EncodeBarrier::Drain, "fp1", "q1");
        let p2 = estate_cache_entry_path(base, "lme", "", 1, EncodeBarrier::Drain, "fp2", "q1");
        assert_ne!(p1, p2, "fingerprints fp1 and fp2 must produce different paths");
    }

    #[test]
    fn different_seed_produces_different_key() {
        let base = Path::new("/tmp/ec-test-cache");
        let p1 = estate_cache_entry_path(base, "lme", "", 1, EncodeBarrier::Drain, "fp", "q1");
        let p2 = estate_cache_entry_path(base, "lme", "", 2, EncodeBarrier::Drain, "fp", "q1");
        assert_ne!(p1, p2);
    }

    // ── Default cache dir tests ───────────────────────────────────────────────

    #[test]
    fn default_cache_dir_under_cwd() {
        let dir = default_cache_dir(None);
        assert!(dir.ends_with("estate-cache"), "expected estate-cache suffix in {}", dir.display());
    }

    #[test]
    fn default_cache_dir_under_out_dir() {
        let out = Path::new("/tmp/lme-out");
        let dir = default_cache_dir(Some(out));
        assert_eq!(dir, PathBuf::from("/tmp/lme-out/estate-cache"));
    }

    // ── copy_dir_all tests ────────────────────────────────────────────────────

    #[test]
    fn copy_dir_all_round_trip() {
        let src = PathBuf::from("/tmp/ec-copy-src");
        let dst = PathBuf::from("/tmp/ec-copy-dst");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&dst);

        std::fs::create_dir_all(src.join("subdir")).unwrap();
        std::fs::write(src.join("a.txt"), b"hello").unwrap();
        std::fs::write(src.join("subdir/b.txt"), b"world").unwrap();

        copy_dir_all(&src, &dst).unwrap();

        assert_eq!(std::fs::read(dst.join("a.txt")).unwrap(), b"hello");
        assert_eq!(std::fs::read(dst.join("subdir/b.txt")).unwrap(), b"world");

        // Cleanup.
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&dst);
    }

    // ── save + restore round-trip tests ──────────────────────────────────────

    #[test]
    fn save_and_restore_round_trip() {
        let src        = PathBuf::from("/tmp/ec-save-src");
        let cache_dir  = PathBuf::from("/tmp/ec-save-entry");
        let scratch    = PathBuf::from("/tmp/ec-save-scratch");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);

        // Fake estate with one file.
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("estate.db"), b"fake estate data").unwrap();

        // Manifest as Vec<HashMap<String, String>> — matches LMEB serialization pattern.
        let manifest: Vec<HashMap<String, String>> = vec![{
            let mut m = HashMap::new();
            m.insert("uuid".to_string(),   "u1".to_string());
            m.insert("doc_id".to_string(), "d1".to_string());
            m
        }];

        save_estate_cache_entry(&src, &manifest, &cache_dir);
        assert!(cache_dir.join("estate").exists(), "estate/ not saved");
        assert!(cache_dir.join("manifest.json").exists(), "manifest.json not saved");

        // Restore.
        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&cache_dir, move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            });

        let (restored_scratch, restored_manifest) = result.expect("cache hit expected");
        assert_eq!(
            std::fs::read(restored_scratch.join("estate.db")).unwrap(),
            b"fake estate data",
            "estate content mismatch after restore"
        );
        assert_eq!(restored_manifest.len(), 1);
        assert_eq!(restored_manifest[0]["doc_id"], "d1");

        // Cleanup.
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&restored_scratch);
    }

    #[test]
    fn restore_returns_none_on_miss() {
        let missing = PathBuf::from("/tmp/ec-missing-entry-lme07-xxx");
        let _ = std::fs::remove_dir_all(&missing);

        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&missing, || {
                Ok(PathBuf::from("/tmp/ec-factory-never-called"))
            });
        assert!(result.is_none(), "expected None on cache miss");
    }

    #[test]
    fn snapshot_copy_is_isolated_from_original() {
        // Verify that mutating the restored copy leaves the cache original intact.
        let src        = PathBuf::from("/tmp/ec-iso-src");
        let cache_dir  = PathBuf::from("/tmp/ec-iso-entry");
        let scratch    = PathBuf::from("/tmp/ec-iso-scratch");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);

        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("data.db"), b"original").unwrap();

        let empty_manifest: Vec<HashMap<String, String>> = vec![];
        save_estate_cache_entry(&src, &empty_manifest, &cache_dir);

        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&cache_dir, move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            });
        let (restored, _) = result.expect("cache hit expected");

        // Mutate the restored copy.
        std::fs::write(restored.join("data.db"), b"mutated").unwrap();

        // Cache original is unchanged.
        let original_bytes = std::fs::read(cache_dir.join("estate").join("data.db"))
            .expect("cache original estate.db missing");
        assert_eq!(original_bytes, b"original", "cache original was mutated");

        // Cleanup.
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&restored);
    }

    #[test]
    fn guard_on_deletion_path_is_preserved() {
        // The scratch factory returns a path with the correct prefix —
        // the restored scratch has the same prefix, enabling guarded teardown.
        let src        = PathBuf::from("/tmp/ec-guard-src");
        let cache_dir  = PathBuf::from("/tmp/ec-guard-entry");
        let scratch    = PathBuf::from("/tmp/lme-bench-ec-guard-scratch");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);

        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("x.db"), b"x").unwrap();
        let em: Vec<HashMap<String, String>> = vec![];
        save_estate_cache_entry(&src, &em, &cache_dir);

        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&cache_dir, move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            });
        let (restored, _) = result.expect("hit expected");
        // Verify the restored path has the expected LME prefix for guarded teardown.
        assert!(
            restored.to_string_lossy().starts_with("/tmp/lme-bench-"),
            "restored path {} does not have expected prefix", restored.display()
        );

        // Cleanup.
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&restored);
    }
}
