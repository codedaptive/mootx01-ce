// ArtifactManifest.swift
//
// B2 (benchmark reset 2026-08-13): the artifact provenance manifest.
//
// Test estates are BUILD ARTIFACTS, not a cache (BENCHMARK_BUILD_ARCHITECTURE
// §1). An artifact is a deterministic function of its declared inputs, so
// every entry carries a manifest of those inputs — and the runner VALIDATES it on
// open, hard-failing on mismatch. This is what makes the narrow invalidation
// key (B3) safe: staleness is DETECTED by declaration, not assumed away by
// hashing the binary (the old `bin_<mtime_size>` key component invalidated
// every artifact on every product build even when the change could not alter
// one byte of estate content — a retrieval-logic change does not re-encode a
// corpus).
//
// Dependency matrix (BENCHMARK_BUILD_ARCHITECTURE §2): the declared inputs
// are the things whose change ACTUALLY invalidates estate bytes — corpus
// fixture, ingest configuration, embedding models, storage schema semantics
// (protocol version), and the marker-recording flag (an artifact built with
// markers off cannot yield INGEST/CYCLE timings and must fail loudly at
// measurement, never report nothing).

import Foundation

/// Version of the artifact container format itself. Twin of Rust
/// `ARTIFACT_FORMAT_VERSION`; the two constants MUST match or cross-port
/// artifact sharing breaks (both ports read each other's `artifact.json`).
///
/// Version history:
///   1 — pre-B4 format: estate snapshot taken immediately after corpus ingest,
///       before the dream cycle. Pre-settle artifacts carry formatVersion = 1
///       and are REFUSED by `mismatches(against:)` because their estate bytes
///       do not reflect the full settled state.
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
let artifactFormatVersion = 3

/// The estate manifest `schema_version` value written by
/// `DrawerStore.populateV1ManifestDefaults` on first open — the semantic
/// version of the estate FORMAT (not the PersistenceKit storage migration
/// version, which is a separate integer in `_storagekit_n`). Per
/// BENCHMARK_PROTOCOL §9 artifacts KEY on this value and REFUSE a mismatch;
/// update here when the estate format version changes.
let currentEstateSchemaVersion = "1.1"

/// The declared dependency set of one estate artifact. Written as
/// `artifact.json` beside the entry's `manifest.json`; validated on open.
struct ArtifactProvenance: Codable, Sendable, Equatable {
    /// Artifact container format version (`artifactFormatVersion`).
    let formatVersion: Int
    /// Benchmark lane ("membench", "lme", "locomo", "lmeb").
    let benchmark: String
    /// Lane variant ("s"/"m"/"oracle" for LME; "" when the lane has none).
    let variant: String
    /// Question/item shuffle seed.
    let seed: UInt64
    /// Encode-queue synchronization strategy used during ingest.
    let encodeBarrier: String
    /// At-rest posture of the estate ("plaintext-optout" | "encrypted-ephemeral").
    let estatePosture: String
    /// Seed-file loading strategy ("batch" | "live").
    let seedPath: String
    /// SHA-256 of the corpus fixture the unit was built from (lowercase hex).
    /// "unknown" when the fixture could not be read — a mismatch against
    /// "unknown" is still a mismatch: unverifiable provenance never validates.
    let corpusDigest: String
    /// Embedding model identifiers the estate was provisioned with.
    let embeddingModels: [String]
    /// `mootx01 --version` major.minor of the binary that BUILT the artifact.
    /// Advisory (estate bytes are schema-governed, not binary-governed);
    /// recorded so a schema-era mismatch is explainable after the fact.
    let mootx01Version: String
    /// BENCHMARK_PROTOCOL.md version governing the build.
    let protocolVersion: String
    /// Whether encode-completion / dream-cycle audit markers were recorded
    /// during the build (A2/A3, `MOOTX01_ENCODE_MARKERS`). A build input:
    /// an artifact without markers cannot yield INGEST/CYCLE timings.
    let markersPresent: Bool
    /// The estate manifest `schema_version` at build time (`currentEstateSchemaVersion`).
    /// NOT advisory — artifacts from a different schema era have incompatible
    /// layout. Per BENCHMARK_PROTOCOL §9 this field is keyed and refuses a
    /// mismatch on restore. Twin of Rust `estate_schema_version`.
    let estateSchemaVersion: String
    enum CodingKeys: String, CodingKey {
        case formatVersion        = "format_version"
        case benchmark
        case variant
        case seed
        case encodeBarrier        = "encode_barrier"
        case estatePosture        = "estate_posture"
        case seedPath             = "seed_path"
        case corpusDigest         = "corpus_digest"
        case embeddingModels      = "embedding_models"
        case mootx01Version       = "mootx01_version"
        case protocolVersion      = "protocol_version"
        case markersPresent       = "markers_present"
        case estateSchemaVersion  = "estate_schema_version"
    }

    /// Compare this manifest (loaded from an artifact on disk) against the
    /// run's expected provenance. Returns the list of human-readable
    /// mismatches — empty means the artifact is valid for this run.
    ///
    /// Every field participates EXCEPT `mootx01Version` (advisory — a
    /// retrieval-logic rebuild does not alter estate bytes; that exemption
    /// is the entire point of B3's narrow key). `formatVersion` mismatch is
    /// reported first since it makes the remaining comparison unreliable.
    func mismatches(against expected: ArtifactProvenance) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ label: String, _ a: T, _ b: T) {
            if a != b { out.append("\(label): artifact=\(a) run=\(b)") }
        }
        check("format_version", formatVersion, expected.formatVersion)
        check("benchmark", benchmark, expected.benchmark)
        check("variant", variant, expected.variant)
        check("seed", seed, expected.seed)
        check("encode_barrier", encodeBarrier, expected.encodeBarrier)
        check("estate_posture", estatePosture, expected.estatePosture)
        check("seed_path", seedPath, expected.seedPath)
        check("corpus_digest", corpusDigest, expected.corpusDigest)
        check("embedding_models", embeddingModels, expected.embeddingModels)
        check("protocol_version", protocolVersion, expected.protocolVersion)
        check("markers_present", markersPresent, expected.markersPresent)
        // NOT advisory: a different schema version means a different estate
        // layout; such artifacts are incompatible and must not be restored.
        check("estate_schema_version", estateSchemaVersion, expected.estateSchemaVersion)
        // There is no adornment/minter field: the adornment-generation system
        // was removed, and the arm is a per-restore activation state, never
        // part of entry provenance.
        // Old artifact.json files with a gold_minter key decode fine —
        // Codable ignores unknown keys.
        // Unverifiable provenance never validates: "unknown" on either side
        // means the corpus fixture could not be digested, and equality of two
        // unknowns proves nothing about the bytes. Twin of the Rust rule.
        if corpusDigest == "unknown" || expected.corpusDigest == "unknown" {
            out.append("corpus_digest: unverifiable (\"unknown\" never validates)")
        }
        return out
    }
}

/// A provenance mismatch on artifact open. HARD FAIL by design: a mismatched
/// artifact silently rebuilt (the old behavior for every cache anomaly) mixes
/// built-fresh and restored units in one leg, which B7 exists to prevent.
struct ArtifactProvenanceError: Error, CustomStringConvertible {
    let entryPath: String
    let mismatches: [String]
    var description: String {
        "artifact provenance mismatch at \(entryPath):\n  "
            + mismatches.joined(separator: "\n  ")
            + "\nThe artifact was built under different declared inputs. "
            + "Rebuild it (make rebuild) or fix the run configuration; refusing "
            + "to silently mix provenances in one leg."
    }
}

/// Writes `artifact.json` into a cache entry directory. Best-effort like the
/// snapshot save itself (a failed write leaves an entry with NO manifest,
/// which `loadArtifactProvenance` treats as pre-B2/unverifiable).
func writeArtifactProvenance(_ provenance: ArtifactProvenance, to cacheEntry: URL) {
    let url = cacheEntry.appendingPathComponent("artifact.json")
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(provenance).write(to: url, options: .atomic)
    } catch {
        FileHandle.standardError.write(Data(
            "[artifact] WARNING: could not write provenance \(url.path): \(error)\n".utf8))
    }
}

/// Loads `artifact.json` from a cache entry. nil = absent or undecodable
/// (a pre-B2 entry or a torn write) — callers treat nil as "unverifiable",
/// which under strict validation is a hard fail with a rebuild instruction.
func loadArtifactProvenance(from cacheEntry: URL) -> ArtifactProvenance? {
    let url = cacheEntry.appendingPathComponent("artifact.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ArtifactProvenance.self, from: data)
}

/// Builds the run's expected/save provenance from the lane's configuration.
/// One call per run (not per unit): every unit of a leg shares the declared
/// dependency set; only the unit id varies, and that lives in the entry PATH,
/// not the manifest.
///
/// `mootx01Version` records the binary that produced the artifact. It stays
/// ADVISORY — exempt from validation — precisely so a retrieval-logic rebuild
/// does not invalidate artifacts; it exists so a stale-binary build is
/// explainable after the fact rather than invisible. `embeddingModels`
/// records "binary-default": the harness drives the shipped binary's
/// provisioning defaults and declares that fact rather than guessing ids.
func makeArtifactProvenance(
    benchmark: String,
    variant: String,
    seed: UInt64,
    encodeBarrier: EncodeBarrier,
    posture: ScratchEstatePosture,
    seedPath: SeedPathMode,
    corpusDigest: String,
    mootx01Version: String
) -> ArtifactProvenance {
    ArtifactProvenance(
        formatVersion: artifactFormatVersion,
        benchmark: benchmark,
        variant: variant,
        seed: seed,
        encodeBarrier: encodeBarrier.rawValue,
        estatePosture: posture.rawValue,
        seedPath: seedPath.rawValue,
        corpusDigest: corpusDigest,
        embeddingModels: ["binary-default"],
        mootx01Version: mootx01Version,
        protocolVersion: benchmarkProtocolVersion,
        markersPresent: ProcessInfo.processInfo.environment["MOOTX01_ENCODE_MARKERS"] != "off",
        estateSchemaVersion: currentEstateSchemaVersion
    )
}
