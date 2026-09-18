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
//! `(benchmark, variant, seed, encode_barrier, posture, seed_path)` — then
//! `unit_id` as the leaf directory.
//! The authoritative list is the enumeration above `estate_cache_entry_path`;
//! this header is the summary of it.
//!
//! Staleness is DETECTED, not keyed: every entry carries `artifact.json`
//! (artifact_manifest.rs) validated hard on restore.
//!
//! ## Cache entry layout
//!
//! ```text
//! <cacheDir>/
//!   <run-key>/           see estate_cache_entry_path for the component order
//!     <safe-unit-id>/    question_id / conv_id / query_id (filesystem-safe)
//!       estate/          copy of the scratch estate dir after ingest+encode
//!       manifest.json    serialized manifest entries (UUID -> origin mapping)
//! ```

use crate::encode_barrier::EncodeBarrier;
use crate::scratch_posture::ScratchEstatePosture;
use serde::{Serialize, de::DeserializeOwned};
use std::path::{Path, PathBuf};

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
    /// Snapshot after settle; restore snapshot on subsequent runs; build
    /// fresh on a miss.
    Reuse,
    /// Measure-only (B7): restore like `Reuse`, but a cache MISS is a HARD
    /// ERROR instead of a fresh build — a leg can never silently mix
    /// built-fresh and restored units. Build artifacts first, then measure.
    Require,
}

impl EstateCacheMode {
    /// Parse from a CLI string. Returns an error string on unknown value.
    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "off"     => Ok(EstateCacheMode::Off),
            "reuse"   => Ok(EstateCacheMode::Reuse),
            "require" => Ok(EstateCacheMode::Require),
            other   => Err(format!(
                "--estate-cache must be 'off', 'reuse', or 'require'; got '{other}'"
            )),
        }
    }

    /// The raw string value as written to report JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            EstateCacheMode::Off     => "off",
            EstateCacheMode::Reuse   => "reuse",
            EstateCacheMode::Require => "require",
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


// ─────────────────────────────────────────────────────────────────────────────
// Cache entry path
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the path of the cache entry directory for one benchmark unit
/// (a question, conversation, or query), keyed by the full run configuration.
///
/// Cache hierarchy:
/// ```text
/// <cacheDir>/
///   <benchmark>[-<variant>]-seed<seed>-barrier_<mode>-estate_<posture>-seedpath_<mode>/
///     <safe-unit-id>/
///       estate/        <- scratch estate dir snapshot
///       manifest.json  <- serialized manifest entries
/// ```
///
/// - `variant`: LME variant ("s", "m", "oracle"). Empty string for locomo/lmeb.
/// - `posture`: At-rest posture of the scratch estate. In the key because a
///   plaintext estate and an encrypted estate are different bytes on disk —
///   a snapshot of one must never be restored for a run expecting the other.
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
    posture: ScratchEstatePosture,
    seed_path: crate::seed_export::SeedPathMode,
    unit_id: &str,
) -> PathBuf {
    // Run-config key: a single directory name whose components are, in order —
    // benchmark, variant (omitted when empty), seed, encode barrier, at-rest
    // posture, and seed path. This IS the key: the retired build axes
    // (granularity, preference extraction, event-time scheme, enrichment,
    // filing arm) each collapsed to a single surviving value, so their
    // segments carried no information — the seeding pipeline
    // (BENCHMARK_ESTATES.md) owns artifact building, and every artifact
    // predating this key format was deleted.
    // B3 (benchmark reset 2026-08-13): the binary fingerprint is RETIRED from
    // this key — a product rebuild must not invalidate artifacts. Staleness is
    // DETECTED instead: every entry carries artifact.json (artifact_manifest.rs)
    // validated hard on restore.
    //
    // This is an enumeration, not a claim of completeness. An enumeration goes
    // stale visibly — the list sits directly above the format string that
    // builds it.
    let variant_suffix = if variant.is_empty() {
        String::new()
    } else {
        format!("-{variant}")
    };
    // The seed-path segment exists because a live-built and a batch-built
    // estate are DIFFERENT estate shapes (subjects present vs subject debt,
    // per-record capture times vs one collapsed import instant — deferral
    // ledger L-3/L-4). Restoring one for a run expecting the other would
    // silently mix the two populations Gate G exists to compare.
    let seed_path_segment = match seed_path {
        crate::seed_export::SeedPathMode::Live => "live",
        crate::seed_export::SeedPathMode::Batch => "batch",
    };
    let run_key = format!(
        "{benchmark}{variant_suffix}-seed{seed}-barrier_{}-estate_{}-seedpath_{seed_path_segment}",
        encode_barrier.as_str(),
        posture.as_str()
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
/// B7 hard-failure message: `--estate-cache require` met a cache miss.
/// The run must stop — never silently build fresh — so a leg's provenance
/// stays uniform. Twin of Swift `ArtifactRequiredError`.
pub fn artifact_required_error(entry: &Path) -> String {
    format!(
        "artifact required but missing: {}\n--estate-cache require is \
         measure-only; it never builds. Build the artifact first (run the \
         same configuration with --estate-cache reuse, or `make artifacts`), \
         then re-run.",
        entry.display()
    )
}

/// Clones `src` to `dst` — instant, copy-on-write — falling back to a full
/// byte copy when cloning is unavailable (non-APFS/reflink volume, or the
/// platform tool is absent). B5: the clone IS isolation (writes to either
/// side never reach the other), and it removes the full-byte-copy tax from
/// every snapshot and restore.
///
/// PORT ASYMMETRY, deliberate: the Swift twin calls clonefile(2) directly
/// (Darwin is a system framework); this crate holds the std+serde-only
/// dependency line, so the clone goes through the platform's cp
/// (`cp -RcP` uses clonefile on macOS; `cp -RP --reflink=auto` on Linux).
/// A subprocess spawn is noise against the multi-second copy it replaces.
///
/// ## Symlink semantics — `-P` pins an otherwise unspecified default
///
/// `-P` is POSIX and makes cp copy a symlink AS a symlink rather than
/// indirecting through it. It is specified here on both platform arms
/// because POSIX leaves the default UNSPECIFIED: for `-R` with none of
/// `-H`, `-L` or `-P` given, "it is unspecified which of -H, -L, or -P will
/// be used as a default". Both platforms this harness targets happen to
/// preserve symlinks already — macOS cp(1) `-R` documents "symbolic links
/// to be copied, rather than indirected through" (verified empirically on
/// this harness's macOS target), and GNU cp `-R` likewise does not
/// dereference by default. `-P` therefore changes no observed behaviour;
/// it removes the dependence on an unspecified default so a different cp
/// implementation cannot silently start following links.
///
/// Result: symlinks are COPIED AS SYMLINKS. This differs from
/// `copy_dir_all`'s stricter discipline, which SKIPS symlinks entirely. The
/// difference is deliberate: `copy_dir_all` is the correctness reference;
/// the cp path is the performance path, and copying a symlink as a symlink
/// (rather than dereferencing it) is the closest semantics that
/// clonefile(2) / reflink can provide. A future reader must not "unify"
/// these two behaviours by removing `-P`.
pub fn clone_or_copy_dir(src: &Path, dst: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let status = std::process::Command::new("cp")
        .args(["-RcP"]) // -c: clonefile(2) APFS clone; -P: copy symlinks as symlinks (not followed)
        .arg(src)
        .arg(dst)
        .status();
    #[cfg(not(target_os = "macos"))]
    let status = std::process::Command::new("cp")
        .args(["-RP", "--reflink=auto"]) // -P: copy symlinks as symlinks, not indirected through
        .arg(src)
        .arg(dst)
        .status();
    match status {
        Ok(st) if st.success() => return Ok(()),
        Ok(st) => eprintln!(
            "[cache] clone cp exited {st} — falling back to full copy for {}",
            dst.display()
        ),
        Err(e) => eprintln!(
            "[cache] clone cp unavailable ({e}) — falling back to full copy for {}",
            dst.display()
        ),
    }
    // Fallback: the pre-B5 behavior. Clean any partial clone first.
    let _ = std::fs::remove_dir_all(dst);
    copy_dir_all(src, dst)
}

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

        // `DirEntry::file_type()` describes the ENTRY (an lstat), so a symlink
        // reports `is_symlink()` and never `is_dir()`. `Path::is_dir()` stats
        // the TARGET and follows symlinks, so a symlinked directory inside the
        // estate would have been descended into and its contents copied INTO
        // the snapshot — pulling a tree from outside the estate into the cache.
        //
        // Symlinks are skipped outright rather than resolved: a snapshot is a
        // copy of the estate's own bytes, and a link's target is by definition
        // outside the tree being snapshotted. Estates contain no symlinks, so
        // this changes nothing in practice; it removes the escape hatch.
        // Same defect and same fix as the residue walk in key_residue.rs.
        let file_type = entry.file_type().map_err(|e| {
            format!(
                "copy_dir_all: file_type {} failed: {e}",
                src_child.display()
            )
        })?;
        if file_type.is_symlink() {
            continue;
        }

        if file_type.is_dir() {
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
    provenance: &crate::artifact_manifest::ArtifactProvenance,
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
        // B5: clone (instant, COW) with byte-copy fallback.
        clone_or_copy_dir(estate_scratch_dir, &estate_target)?;

        // Write the manifest JSON alongside the estate (pretty-printed, sorted by serde default).
        let manifest_json = serde_json::to_string_pretty(manifest)
            .map_err(|e| format!("manifest encode failed: {e}"))?;
        std::fs::write(&manifest_path, manifest_json.as_bytes())
            .map_err(|e| format!("manifest write failed: {e}"))?;

        // B2: seal the artifact's declared dependency set beside the manifest.
        crate::artifact_manifest::write_artifact_provenance(provenance, cache_entry);

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
///   its path with the cached estate copy. The resulting path retains the
///   correct prefix for guarded teardown.
/// - Returns `Some((scratch_dir, manifest))` on cache hit, `None` on miss or error.
///
/// Twin of Swift `restoreEstateCacheEntry(from:expectedProvenance:scratchDirFactory:)`.
pub fn restore_estate_cache_entry<M: DeserializeOwned>(
    cache_entry: &Path,
    expected_provenance: &crate::artifact_manifest::ArtifactProvenance,
    scratch_dir_factory: impl FnOnce() -> Result<PathBuf, String>,
) -> Result<Option<(PathBuf, Vec<M>)>, String> {
    let estate_source = cache_entry.join("estate");
    let manifest_path = cache_entry.join("manifest.json");

    // Cache miss: required files absent.
    if !estate_source.exists() || !manifest_path.exists() {
        return Ok(None);
    }

    // B2: validate the artifact's declared provenance BEFORE any bytes move.
    // HARD FAIL (Err) on mismatch or an unverifiable manifest — a mismatched
    // artifact silently rebuilt would mix provenances within one leg (the
    // failure B7 exists to prevent). Twin of Swift ArtifactProvenanceError.
    let Some(on_disk) = crate::artifact_manifest::load_artifact_provenance(cache_entry) else {
        return Err(format!(
            "artifact provenance mismatch at {}: artifact.json absent or undecodable — \
             pre-B2 entry or torn write. Rebuild it (make rebuild) or fix the run \
             configuration; refusing to silently mix provenances in one leg.",
            cache_entry.display()
        ));
    };
    let mismatches = on_disk.mismatches(expected_provenance);
    if !mismatches.is_empty() {
        return Err(format!(
            "artifact provenance mismatch at {}:\n  {}\nThe artifact was built under \
             different declared inputs. Rebuild it (make rebuild) or fix the run \
             configuration; refusing to silently mix provenances in one leg.",
            cache_entry.display(),
            mismatches.join("\n  ")
        ));
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
        // B5: clone preserves the isolation guarantee (copy-on-write).
        clone_or_copy_dir(&estate_source, &scratch)?;


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
        Ok(pair) => Ok(Some(pair)),
        Err(e) => {
            // Restore-mechanics failures (I/O, decode) stay soft misses with
            // a warning — only PROVENANCE failures (validated above, before
            // this closure) hard-fail the run.
            eprintln!(
                "[cache] restore WARNING: could not restore {}: {e}",
                cache_entry.display()
            );
            Ok(None)
        }
    }
}


/// Resolves the estate database inside an estate directory. Swift-built
/// estates keep `estate.sqlite` at the root; Rust-built estates keep it at
/// `databases/default/estate.sqlite`. The root wins when both exist. None
/// when neither exists (fixture snapshots, non-estate payloads). Twin of
/// Swift `estateDatabasePath(in:)`.
pub fn estate_database_path(estate_dir: &Path) -> Option<PathBuf> {
    let root = estate_dir.join("estate.sqlite");
    if root.is_file() {
        return Some(root);
    }
    let nested = estate_dir.join("databases/default/estate.sqlite");
    if nested.is_file() {
        return Some(nested);
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    /// Shared provenance fixture for cache round-trip tests (B2).
    fn test_provenance() -> crate::artifact_manifest::ArtifactProvenance {
        crate::artifact_manifest::make_artifact_provenance(
            "lme", "s", 7, "drain", "plaintext-optout", "batch", "deadbeef",
        )
    }

    use super::*;
    use std::collections::HashMap;

    // ── EstateCacheMode tests ─────────────────────────────────────────────────

    /// REGRESSION (MXE-BK defect 3, sibling walk). `copy_dir_all` used
    /// `Path::is_dir()`, which follows symlinks, so a symlinked directory
    /// inside an estate was descended into and a tree from OUTSIDE the estate
    /// was copied into the snapshot cache. Same defect as the residue walk.
    #[test]
    fn copy_dir_all_does_not_follow_symlinked_directory() {
        let base = std::env::temp_dir()
            .join(format!("estate-cache-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let src = base.join("src");
        let dst = base.join("dst");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("estate.sqlite"), b"real data").unwrap();

        // A tree outside the estate that must not be pulled into the snapshot.
        let outside = base.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("foreign.txt"), b"must not be copied").unwrap();

        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, src.join("escape")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir(&outside, src.join("escape")).unwrap();

        copy_dir_all(&src, &dst).unwrap();

        assert!(dst.join("estate.sqlite").exists(), "real file was not copied");
        assert!(
            !dst.join("escape").exists(),
            "snapshot followed a symlink out of the estate"
        );
        assert!(
            !dst.join("escape/foreign.txt").exists(),
            "snapshot copied a file from outside the estate"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

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

    /// B7: require parses, stringifies, and its miss error names the entry
    /// and the remedy. Twin of Swift ArtifactRequiredTests.
    #[test]
    fn require_mode_semantics() {
        assert_eq!(
            EstateCacheMode::from_str("require").unwrap(),
            EstateCacheMode::Require
        );
        assert_eq!(EstateCacheMode::Require.as_str(), "require");
        let msg = artifact_required_error(Path::new("/tmp/x/entry"));
        assert!(msg.contains("/tmp/x/entry"));
        assert!(msg.contains("never builds"));
        assert!(msg.contains("--estate-cache reuse"));
    }

    #[test]
    fn cache_entry_path_no_variant() {
        let base = Path::new("/tmp/ec-test-cache");
        let p = estate_cache_entry_path(
            base, "lme", "", 42, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "question_001",
        );
        let s = p.to_string_lossy();
        assert!(s.contains("lme-seed42-barrier_drain-estate_plaintext-optout"),
            "run key not found in {s}");
        assert!(s.ends_with("question_001"), "unit id not at end of {s}");
    }

    #[test]
    fn cache_entry_path_with_variant() {
        let base = Path::new("/tmp/ec-test-cache");
        let p = estate_cache_entry_path(
            base, "lme", "s", 0, EncodeBarrier::Impatient,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "q1",
        );
        assert!(p.to_string_lossy()
            .contains("lme-s-seed0-barrier_impatient-estate_plaintext-optout"));
    }

    #[test]
    fn cache_entry_path_sanitizes_unit_id() {
        let base = Path::new("/tmp/ec-test-cache");
        let p = estate_cache_entry_path(
            base, "lmeb", "", 1, EncodeBarrier::None,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "query/with/slashes and spaces",
        );
        let last = p.file_name().unwrap().to_string_lossy();
        assert!(!last.contains('/'), "slash not sanitized in {last}");
        assert!(!last.contains(' '), "space not sanitized in {last}");
    }

    #[test]
    fn different_seed_path_produces_different_key() {
        // A live-built and a batch-built estate are different estate shapes
        // (subject debt, collapsed capture times — ledger L-3/L-4); the cache
        // key must never let one restore into a run expecting the other.
        let base = Path::new("/tmp/ec-test-cache");
        let live = estate_cache_entry_path(base, "lme", "", 1, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient,
            crate::seed_export::SeedPathMode::Live, "q1",
        );
        let batch = estate_cache_entry_path(base, "lme", "", 1, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient,
            crate::seed_export::SeedPathMode::Batch, "q1",
        );
        assert_ne!(live, batch);
        assert!(batch.to_string_lossy().contains("seedpath_batch"));
    }


    #[test]
    fn different_seed_produces_different_key() {
        let base = Path::new("/tmp/ec-test-cache");
        let p1 = estate_cache_entry_path(base, "lme", "", 1, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "q1",
        );
        let p2 = estate_cache_entry_path(base, "lme", "", 2, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "q1",
        );
        assert_ne!(p1, p2);
    }

    // ── Run-key format pins ──────────────────────────────────────────────────

    /// Golden pins of the full run-key format: every segment named, in order,
    /// with no blank segments a future axis could collide with.
    #[test]
    fn run_key_format_golden_pins() {
        let base = Path::new("/tmp/ec-runkey-format");
        let locomo = estate_cache_entry_path(base, "locomo", "", 7, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "conv-1",
        );
        let lmeb = estate_cache_entry_path(base, "lmeb", "", 7, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "query-1",
        );
        let locomo_key = locomo.parent().unwrap().file_name().unwrap().to_string_lossy().to_string();
        let lmeb_key = lmeb.parent().unwrap().file_name().unwrap().to_string_lossy().to_string();
        assert_eq!(locomo_key,
            "locomo-seed7-barrier_drain-estate_plaintext-optout-seedpath_batch");
        assert_eq!(lmeb_key,
            "lmeb-seed7-barrier_drain-estate_plaintext-optout-seedpath_batch");
        assert!(!locomo_key.ends_with('-'), "every segment is named, never a trailing blank");
        assert!(!lmeb_key.ends_with('-'), "every segment is named, never a trailing blank");
    }

    /// Swift and Rust must name identically-shaped estates identically or the two
    /// legs cannot share a cache directory. Asserts the full key, not a prefix —
    /// the sibling Swift run-key format test (EstateCacheTests.swift) asserts
    /// the same string.
    #[test]
    fn run_key_matches_swift_leg_verbatim() {
        let base = Path::new("/tmp/ec-runkey-format");
        let p = estate_cache_entry_path(base, "lmeb", "", 42, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "query-001",
        );
        let run_key = p.parent().unwrap().file_name().unwrap().to_string_lossy().to_string();
        assert_eq!(run_key,
            "lmeb-seed42-barrier_drain-estate_plaintext-optout-seedpath_batch");
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

        save_estate_cache_entry(&src, &manifest, &test_provenance(), &cache_dir);
        assert!(cache_dir.join("estate").exists(), "estate/ not saved");
        assert!(cache_dir.join("manifest.json").exists(), "manifest.json not saved");

        // Restore.
        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&cache_dir, &test_provenance(), move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            })
            .unwrap();

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
            restore_estate_cache_entry(&missing, &test_provenance(), || {
                Ok(PathBuf::from("/tmp/ec-factory-never-called"))
            }).unwrap();
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
        save_estate_cache_entry(&src, &empty_manifest, &test_provenance(), &cache_dir);

        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&cache_dir, &test_provenance(), move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            })
            .unwrap();
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
        save_estate_cache_entry(&src, &em, &test_provenance(), &cache_dir);

        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(&cache_dir, &test_provenance(), move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            })
            .unwrap();
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

    // ── Provenance mismatch and corrupt manifest (B2 gate) ───────────────────

    /// d. A provenance mismatch returns Err and the message names the entry path.
    ///
    /// The Rust port guards B2 before any bytes move: mismatched declared
    /// inputs hard-fail with `Err`, never a silent miss. The error string must
    /// name the entry path so operators can locate the stale artifact.
    #[test]
    fn provenance_mismatch_returns_err_naming_entry_path() {
        let src       = PathBuf::from("/tmp/ec-prov-mismatch-src");
        let cache_dir = PathBuf::from("/tmp/ec-prov-mismatch-entry");
        let scratch   = PathBuf::from("/tmp/ec-prov-mismatch-scratch");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);

        // Save with the canonical test provenance.
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("estate.db"), b"data").unwrap();
        let em: Vec<HashMap<String, String>> = vec![];
        save_estate_cache_entry(&src, &em, &test_provenance(), &cache_dir);

        // Restore with a mismatched corpus digest — forces the B2 mismatch path.
        let mismatched = crate::artifact_manifest::make_artifact_provenance(
            "lme", "s", 7, "drain", "plaintext-optout", "batch",
            "000000000000", // different corpusDigest
        );
        let scratch_clone = scratch.clone();
        let result: Result<Option<(PathBuf, Vec<HashMap<String, String>>)>, _> =
            restore_estate_cache_entry(&cache_dir, &mismatched, move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            });

        // Must be Err.
        assert!(result.is_err(),
            "provenance mismatch must return Err, not Ok; got: {:?}", result);
        // Error message must name the entry path so operators can locate the artifact.
        let err = result.unwrap_err();
        let entry_path_str = cache_dir.to_string_lossy().to_string();
        assert!(err.contains(&entry_path_str),
            "error must name the entry path '{}'; got: {}", entry_path_str, err);

        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);
    }

    /// e. A corrupt manifest.json returns Ok(None).
    ///
    /// A restore-mechanics failure (I/O, decode) stays a soft miss: the caller
    /// will build a fresh estate. Only B2 provenance failures are hard errors.
    #[test]
    fn corrupt_manifest_json_returns_ok_none() {
        let src       = PathBuf::from("/tmp/ec-corrupt-manifest-src");
        let cache_dir = PathBuf::from("/tmp/ec-corrupt-manifest-entry");
        let scratch   = PathBuf::from("/tmp/ec-corrupt-manifest-scratch");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);

        // Save a valid entry, then overwrite manifest.json with invalid JSON.
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("estate.db"), b"data").unwrap();
        let em: Vec<HashMap<String, String>> = vec![];
        save_estate_cache_entry(&src, &em, &test_provenance(), &cache_dir);
        std::fs::write(cache_dir.join("manifest.json"), b"THIS IS NOT JSON").unwrap();

        let scratch_clone = scratch.clone();
        let result: Result<Option<(PathBuf, Vec<HashMap<String, String>>)>, String> =
            restore_estate_cache_entry(&cache_dir, &test_provenance(), move || {
                std::fs::create_dir_all(&scratch_clone).unwrap();
                Ok(scratch_clone)
            });

        // Must be Ok(None) — not Err and not Ok(Some).
        assert!(result.is_ok(),
            "corrupt manifest.json must not return Err; got: {:?}", result);
        assert!(result.unwrap().is_none(),
            "corrupt manifest.json must return Ok(None) (soft miss)");

        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);
    }

    // ── Posture in cache key + restore assert (FIX-HARNESS-20260727) ─────────

    #[test]
    fn posture_partitions_cache_key() {
        let base = Path::new("/tmp/ec-posture-key");
        let plain = estate_cache_entry_path(base, "lme", "s", 1, EncodeBarrier::Drain,
            ScratchEstatePosture::PlaintextTransient, crate::seed_export::SeedPathMode::Batch, "q1",
        );
        let enc = estate_cache_entry_path(base, "lme", "s", 1, EncodeBarrier::Drain,
            ScratchEstatePosture::EncryptedEphemeral, crate::seed_export::SeedPathMode::Batch, "q1",
        );
        assert_ne!(plain, enc,
            "plaintext and encrypted estates are different bytes; keys must differ");
    }

    /// A matching cache entry restores: the copied bytes are handed back with
    /// their manifest.
    #[test]
    fn matching_entry_restores_as_a_hit() {
        let src       = PathBuf::from("/tmp/ec-postcopy-src");
        let cache_dir = PathBuf::from("/tmp/ec-postcopy-entry");
        let scratch   = PathBuf::from("/tmp/ec-postcopy-scratch");
        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        let _ = std::fs::remove_dir_all(&scratch);

        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("estate.db"), b"data").unwrap();
        let em: Vec<HashMap<String, String>> = vec![];
        save_estate_cache_entry(&src, &em, &test_provenance(), &cache_dir);

        let scratch_clone = scratch.clone();
        let result: Option<(PathBuf, Vec<HashMap<String, String>>)> =
            restore_estate_cache_entry(
                &cache_dir,
                &test_provenance(),
                move || {
                    std::fs::create_dir_all(&scratch_clone).unwrap();
                    Ok(scratch_clone)
                },
            )
            .unwrap();
        assert!(result.is_some(), "a matching cache entry must restore as a hit");

        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&cache_dir);
        if let Some((p, _)) = result { let _ = std::fs::remove_dir_all(&p); }
    }

    /// GUARD (not a fix gate) — `clone_or_copy_dir` must not follow symlinks.
    ///
    /// BH-02 investigated finding #9, which alleged that the `cp`-based
    /// primary path followed symlinks and so pulled content from outside the
    /// estate into the cache entry. It does not: the finding does not
    /// reproduce on either target. macOS `cp -Rc` was measured copying a
    /// symlink as a symlink, and GNU `cp -R` does not dereference by default
    /// either. This test PASSES both before and after the `-P` flag was
    /// pinned onto the cp invocations, so it gates nothing — labelling it a
    /// fix gate would misrepresent what it demonstrates.
    ///
    /// Its job is coverage that was genuinely missing: `copy_dir_all` (the
    /// FALLBACK path) had `copy_dir_all_does_not_follow_symlinked_directory`,
    /// but the `cp`-based PRIMARY path — the one every APFS dev machine
    /// actually takes — had no symlink test at all. This closes that gap and
    /// will fail if a future edit drops `-P` on a platform whose cp follows
    /// links, or switches the primary path to a dereferencing copy.
    ///
    /// Asserts via `symlink_metadata`, which does NOT traverse the link, so a
    /// real directory at `dst/escape` (the failure this guards against) is
    /// distinguishable from a preserved symlink.
    #[test]
    fn clone_or_copy_dir_does_not_follow_symlinked_directory() {
        let base = std::env::temp_dir()
            .join(format!("estate-cache-clone-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let src = base.join("src");
        let dst = base.join("dst");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("estate.sqlite"), b"real data").unwrap();

        // A tree OUTSIDE the estate that must not be materialised as real files in dst.
        let outside = base.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("foreign.txt"), b"must not be copied").unwrap();

        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, src.join("escape")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir(&outside, src.join("escape")).unwrap();

        clone_or_copy_dir(&src, &dst).unwrap();

        // Real estate file must be present.
        assert!(dst.join("estate.sqlite").exists(), "real file was not copied");

        // The escape symlink must NOT have been followed to create a real directory
        // in dst containing foreign content. Two acceptable outcomes:
        //   (a) cp -RcP path: escape is a symlink in dst (not a real dir).
        //   (b) copy_dir_all fallback: escape is skipped entirely (does not exist).
        // The forbidden outcome: escape is a real directory (cp followed the symlink
        // and materialised foreign bytes as real files inside the cache entry).
        let escape_path = dst.join("escape");
        let is_real_dir = std::fs::symlink_metadata(&escape_path)
            .map(|m| m.file_type().is_dir())
            .unwrap_or(false); // absent (fallback path) → false → assertion passes
        assert!(
            !is_real_dir,
            "clone_or_copy_dir followed a symlink and created a real directory \
             from it — foreign content was pulled into the cache entry"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

}

/// Resolves the cache directory for a run AND refuses to proceed when the drift
/// gate's evidence does not cover the binary this run will drive.
///
/// Every lane resolves its cache directory through this one function so the
/// refusal cannot be present in three lanes and absent in the fourth. A gate is
/// only as strong as its least-covered entry point.
///
/// Enforced ONLY when the cache is in use. An `--estate-cache off` run builds
/// every estate fresh and reuses no artifact, so demanding a receipt there
/// would refuse the one mode that cannot carry stale state forward.
///
/// Rust twin of Swift's `resolvedCacheDirEnforcingDriftGate`.
pub fn resolved_cache_dir_enforcing_drift_gate(
    cache_dir: Option<&Path>,
    out_dir: Option<&Path>,
    moot_binary_path: Option<&str>,
    estate_cache: EstateCacheMode,
) -> Result<PathBuf, crate::drift_gate_receipt::DriftGateRefusal> {
    let resolved = cache_dir
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| default_cache_dir(out_dir));
    if estate_cache == EstateCacheMode::Off {
        return Ok(resolved);
    }
    crate::drift_gate_receipt::preflight(&resolved, moot_binary_path)?;
    Ok(resolved)

}
