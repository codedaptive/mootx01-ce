//! artifact_manifest.rs — B2 (benchmark reset 2026-08-13): the artifact
//! provenance manifest. Rust twin of `ArtifactManifest.swift`; JSON field
//! names must match exactly (snake_case) so the two ports read each other's
//! artifacts.
//!
//! Test estates are BUILD ARTIFACTS, not a cache (BENCHMARK_BUILD_ARCHITECTURE
//! §1). Every cache entry carries a manifest of its declared inputs
//! (`artifact.json`, beside `manifest.json`), and the runner VALIDATES it on
//! open — hard-failing on mismatch. This is what makes B3's narrow
//! invalidation key safe: staleness is DETECTED by declaration, not assumed
//! away by hashing the binary.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Version of the artifact container format itself. Twin of Swift
/// `artifactFormatVersion`; the two constants MUST match or cross-port artifact
/// sharing breaks (this file's header states the ports read each other's
/// artifacts).
///
/// Version history:
///   1 — pre-B4 format: estate snapshot taken immediately after corpus ingest,
///       before the dream cycle. Pre-settle artifacts carry format_version = 1
///       and are REFUSED by `mismatches` because their estate bytes do not
///       reflect the full settled state.
///   2 — B4 settled-estate protocol: import → drain → dream → reindex → drain
///       → snapshot. Every artifact built at version 2 is a fully settled
///       estate; the benchmark's timing and quality measurements are valid.
///   3 — retired build axes removed from the manifest (granularity,
///       preference_extraction, event_time_scheme, enrichment, filing_arm):
///       each collapsed to a single surviving value, so recording them
///       validated nothing. Version-2 artifacts predate the seeding-pipeline
///       artifact regime and are refused.
///
/// Bump this constant when the manifest gains/renames fields, the entry layout
/// changes, or the snapshot protocol changes in a way that makes old artifacts
/// semantically incompatible — so old entries hard-fail with a clear message
/// instead of decoding garbage or silently returning stale data.
pub const ARTIFACT_FORMAT_VERSION: i32 = 3;

/// The estate manifest `schema_version` value written by
/// `DrawerStore::populate_v1_manifest_defaults` on first open — the semantic
/// version of the estate FORMAT (not the PersistenceKit storage migration
/// version). Per BENCHMARK_PROTOCOL §9 artifacts KEY on this value and REFUSE
/// a mismatch; update here when the estate format version changes. Twin of
/// Swift `currentEstateSchemaVersion`.
pub const CURRENT_ESTATE_SCHEMA_VERSION: &str = "1.1";

/// The declared dependency set of one estate artifact.
/// Twin of Swift `ArtifactProvenance`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ArtifactProvenance {
    pub format_version: i32,
    pub benchmark: String,
    pub variant: String,
    pub seed: u64,
    pub encode_barrier: String,
    pub estate_posture: String,
    pub seed_path: String,
    /// SHA-256 of the corpus fixture (lowercase hex); "unknown" never
    /// validates — unverifiable provenance is a hard fail.
    pub corpus_digest: String,
    pub embedding_models: Vec<String>,
    /// ADVISORY — exempt from validation (a retrieval-logic rebuild does not
    /// alter estate bytes; that exemption is B3's entire point).
    pub mootx01_version: String,
    pub protocol_version: String,
    /// A2/A3 marker recording state at build time. A build input: an
    /// artifact without markers cannot yield INGEST/CYCLE timings.
    pub markers_present: bool,
    /// The estate manifest `schema_version` at build time
    /// (`CURRENT_ESTATE_SCHEMA_VERSION`). NOT advisory — a different schema
    /// version means a different estate layout; incompatible artifacts are
    /// hard-refused on restore. Per BENCHMARK_PROTOCOL §9. Twin of Swift
    /// `estateSchemaVersion`.
    pub estate_schema_version: String,
}

impl ArtifactProvenance {
    /// Compare this manifest (loaded from disk) against the run's expected
    /// provenance. Empty result = valid. Every field participates EXCEPT
    /// `mootx01_version` (advisory). Twin of Swift `mismatches(against:)`.
    pub fn mismatches(&self, expected: &ArtifactProvenance) -> Vec<String> {
        let mut out = Vec::new();
        macro_rules! check {
            ($label:expr, $a:expr, $b:expr) => {
                if $a != $b {
                    out.push(format!("{}: artifact={:?} run={:?}", $label, $a, $b));
                }
            };
        }
        check!("format_version", self.format_version, expected.format_version);
        check!("benchmark", self.benchmark, expected.benchmark);
        check!("variant", self.variant, expected.variant);
        check!("seed", self.seed, expected.seed);
        check!("encode_barrier", self.encode_barrier, expected.encode_barrier);
        check!("estate_posture", self.estate_posture, expected.estate_posture);
        check!("seed_path", self.seed_path, expected.seed_path);
        check!("corpus_digest", self.corpus_digest, expected.corpus_digest);
        check!("embedding_models", self.embedding_models, expected.embedding_models);
        check!("protocol_version", self.protocol_version, expected.protocol_version);
        check!("markers_present", self.markers_present, expected.markers_present);
        // NOT advisory: a different schema version means a different estate
        // layout; such artifacts are incompatible and must not be restored.
        check!(
            "estate_schema_version",
            self.estate_schema_version,
            expected.estate_schema_version
        );
        // There is no adornment/minter field: the adornment-generation system
        // was removed, and the arm is a per-restore activation state, never
        // part of entry provenance.
        // Old artifact.json files with a gold_minter key deserialize fine —
        // serde ignores unknown fields here.
        // Unverifiable provenance never validates: "unknown" on either side
        // means the corpus fixture could not be digested, and equality of two
        // unknowns proves nothing about the bytes.
        if self.corpus_digest == "unknown" || expected.corpus_digest == "unknown" {
            out.push("corpus_digest: unverifiable (\"unknown\" never validates)".to_string());
        }
        out
    }
}

/// Builds the run's expected/save provenance from a lane's configuration.
/// One call per run: every unit of a leg shares the declared dependency set.
/// `mootx01_version` is "unknown" until the B1 artifact builder owns
/// provisioning (advisory — exempt from validation). `embedding_models`
/// records "binary-default": the harness drives the shipped binary's
/// provisioning defaults and declares that fact rather than guessing ids.
/// Twin of Swift `makeArtifactProvenance`.
#[allow(clippy::too_many_arguments)]
pub fn make_artifact_provenance(
    benchmark: &str,
    variant: &str,
    seed: u64,
    encode_barrier: &str,
    estate_posture: &str,
    seed_path: &str,
    corpus_digest: &str,
) -> ArtifactProvenance {
    ArtifactProvenance {
        format_version: ARTIFACT_FORMAT_VERSION,
        benchmark: benchmark.to_string(),
        variant: variant.to_string(),
        seed,
        encode_barrier: encode_barrier.to_string(),
        estate_posture: estate_posture.to_string(),
        seed_path: seed_path.to_string(),
        corpus_digest: corpus_digest.to_string(),
        embedding_models: vec!["binary-default".to_string()],
        mootx01_version: "unknown".to_string(),
        protocol_version: crate::run_environment::BENCHMARK_PROTOCOL_VERSION.to_string(),
        markers_present: std::env::var("MOOTX01_ENCODE_MARKERS")
            .map(|v| v != "off")
            .unwrap_or(true),
        estate_schema_version: CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
    }
}


/// Writes `artifact.json` into a cache entry directory. Best-effort like the
/// snapshot save itself. Twin of Swift `writeArtifactProvenance`.
pub fn write_artifact_provenance(provenance: &ArtifactProvenance, cache_entry: &Path) {
    let path = cache_entry.join("artifact.json");
    match serde_json::to_string_pretty(provenance) {
        Ok(json) => {
            if let Err(e) = std::fs::write(&path, json) {
                eprintln!("[artifact] WARNING: could not write provenance {}: {e}", path.display());
            }
        }
        Err(e) => eprintln!("[artifact] WARNING: could not encode provenance: {e}"),
    }
}

/// Loads `artifact.json` from a cache entry. None = absent or undecodable
/// (pre-B2 entry or torn write) — under strict validation that is a hard
/// fail with a rebuild instruction. Twin of Swift `loadArtifactProvenance`.
pub fn load_artifact_provenance(cache_entry: &Path) -> Option<ArtifactProvenance> {
    let path = cache_entry.join("artifact.json");
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prov() -> ArtifactProvenance {
        make_artifact_provenance(
            "lme", "s", 7, "drain", "plaintext-optout", "batch", "deadbeef",
        )
    }

    /// Round-trip + advisory exemption: a different mootx01_version must NOT
    /// mismatch (a retrieval-logic rebuild does not alter estate bytes).
    #[test]
    fn version_is_advisory() {
        let a = prov();
        let mut b = prov();
        b.mootx01_version = "9.9".to_string();
        assert!(a.mismatches(&b).is_empty());
    }

    /// Every validated field mismatch is reported by name.
    #[test]
    fn corpus_digest_mismatch_reported() {
        let a = prov();
        let mut b = prov();
        b.corpus_digest = "0000".to_string();
        let m = a.mismatches(&b);
        assert_eq!(m.len(), 1);
        assert!(m[0].starts_with("corpus_digest:"));
    }

    /// `estate_schema_version` is NOT advisory — a mismatch is reported.
    /// An artifact from a different schema era has incompatible layout.
    #[test]
    fn estate_schema_version_mismatch_reported() {
        let a = prov();
        let mut b = prov();
        b.estate_schema_version = "2.0".to_string();
        let m = a.mismatches(&b);
        // Exactly one mismatch for this field (no other fields differ).
        assert_eq!(m.len(), 1, "expected exactly one mismatch: {m:?}");
        assert!(
            m[0].starts_with("estate_schema_version:"),
            "mismatch entry should name the field: {m:?}"
        );
    }

    /// FIX_GATE — artifacts from an older format era are REFUSED.
    ///
    /// Pre-axis-collapse artifacts (format_version ≤ 2) must not be handed
    /// back as cache hits. `mismatches` must report a `format_version` entry
    /// when the on-disk manifest carries an older version and the run expects
    /// the current version (3, axis-collapsed manifest).
    #[test]
    fn older_format_versions_refused() {
        let expected = prov(); // stamps ARTIFACT_FORMAT_VERSION
        for old in [1, 2] {
            let mut on_disk = prov();
            on_disk.format_version = old; // simulate a pre-collapse artifact
            let m = on_disk.mismatches(&expected);
            assert!(
                !m.is_empty(),
                "a format_version={old} artifact must be refused; got no mismatches"
            );
            assert!(
                m.iter().any(|s| s.starts_with("format_version:")),
                "mismatch must name 'format_version' so the user knows why the cache was invalidated: {m:?}"
            );
        }
    }

    /// GUARD — `make_artifact_provenance` stamps format version 3.
    ///
    /// The factory must write the current format version (3) into the provenance
    /// struct. `prov()` reaches the factory correctly, so a stale literal
    /// hard-coded inside `make_artifact_provenance` is detectable here.
    ///
    /// The expectation is the independent literal 3, not `ARTIFACT_FORMAT_VERSION`.
    /// If the symbol and the factory both carry the same value, asserting
    /// `p.format_version == ARTIFACT_FORMAT_VERSION` proves nothing: a factory
    /// that hard-codes 3 and a constant that also equals 3 both pass. Writing
    /// the expected value as a literal means the test fails the moment the factory
    /// drifts, regardless of what the constant says.
    ///
    /// When you intentionally bump `ARTIFACT_FORMAT_VERSION`, update this literal
    /// in BOTH ports (here and in ArtifactManifestTests.swift:makeArtifactProvenanceStampsConstant)
    /// as a deliberate, coordinated act — that synchronisation is the point of the guard.
    #[test]
    fn make_artifact_provenance_stamps_constant() {
        let p = prov();
        assert_eq!(
            p.format_version, 3,
            "make_artifact_provenance must stamp version 3; if you bumped ARTIFACT_FORMAT_VERSION, update this literal in both ports"
        );
    }

    /// Disk round-trip preserves equality and the snake_case JSON contract
    /// the Swift twin reads.
    #[test]
    fn disk_round_trip() {
        let dir = std::env::temp_dir().join(format!("b2-prov-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = prov();
        write_artifact_provenance(&p, &dir);
        let json = std::fs::read_to_string(dir.join("artifact.json")).unwrap();
        assert!(json.contains("\"corpus_digest\""));
        assert!(json.contains("\"markers_present\""));
        assert!(json.contains("\"estate_schema_version\""));
        let loaded = load_artifact_provenance(&dir).unwrap();
        assert_eq!(loaded, p);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
