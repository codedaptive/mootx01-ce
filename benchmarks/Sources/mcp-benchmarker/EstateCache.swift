import Foundation
import Darwin  // clonefile(2) — B5 APFS clone

// EstateCache.swift — snapshot-based estate reuse for benchmark runners.
//
// Background: provisioning a fresh mootx01 estate for each benchmark question
// requires ingest + background encoding — typically ~90% of run wall-clock.
// For N-run statistical means, questions 2..N re-ingest byte-identical content
// into byte-identical estates. This module lets runs 2..N skip that work.
//
// How it works (--estate-cache reuse):
//   FIRST run of a question:  normal ingest → encode barrier → snapshot to cache
//   SUBSEQUENT runs:          copy snapshot → skip ingest → guard probe → query
//
// The copy queried is always a FRESH COPY of the snapshot. The cache original
// is NEVER queried. A corrupt query run cannot contaminate future cache reads.
//
// Cache key components, in key order: benchmark, variant, seed, encode_barrier,
// posture, seed_path — then unit_id as the leaf directory. The authoritative
// list is the enumeration above `estateCacheEntryURL(...)`; this header is the
// summary of it.
// Staleness is DETECTED, not keyed (B3): every entry carries an artifact.json
// provenance manifest (ArtifactManifest.swift) validated hard on open — a
// mismatch is a hard error, never a silent rebuild. A product rebuild does
// not invalidate artifacts.
//
// Cache entry layout:
//   <cacheDir>/
//     <run-key>/            see estateCacheEntryURL for the component order
//       <safe-unit-id>/     question_id/conv_id/query_id (filesystem-safe)
//         estate/           copy of the --db after ingest+encode
//         manifest.json     serialized manifest entries (UUID → origin mapping)
//
// Deletion discipline: cache entries are NEVER deleted by the runner. Only the
// per-question scratch copies (under /tmp/lme-bench-*, /tmp/locomo-bench-*,
// /tmp/lmeb-bench-*) are subject to guarded teardown — those functions already
// require the correct prefix. Cache entry paths are outside /tmp/ (typically
// under the results dir) and are NEVER passed to guarded teardown functions.
//
// METHODOLOGY note (cross-twin sharing):
//   The Swift and Rust runners produce IDENTICAL run keys for
//   identically-shaped estates (both ports pin the key format verbatim in
//   their run-key golden-pin tests), so pointing both legs at the same cache
//   directory shares entries. Validity is guarded by artifact.json: on open,
//   each port validates the entry's declared provenance against its own run
//   configuration and hard-fails on mismatch, so a shared entry can never be
//   silently wrong for either leg. Cross-twin sharing is allowed and
//   recommended — both legs query IDENTICAL estates.
//
//   Recommended N-run pattern for means:
//     Run 1: --estate-cache off (cold, full ingest)  ← gold standard, samples ingest variance
//     Runs 2..N: --estate-cache reuse (warm)         ← identical estates, query-only variance
//   Full-fresh (all N runs with --estate-cache off) remains the gold standard.

// MARK: - Cache mode

/// The estate snapshot reuse mode passed via --estate-cache.
///
/// `off` (default): each question gets a freshly ingested estate — current behavior.
/// `reuse`: after ingest + encode, snapshot the estate to a keyed cache; on subsequent
/// runs with the same key, copy the snapshot and skip ingest entirely.
enum EstateCacheMode: String, Sendable, Codable {
    /// Fresh ingest every run. Default. No cache is read or written.
    case off
    /// Snapshot after settle; restore snapshot on subsequent runs; build
    /// fresh on a miss.
    case reuse
    /// Measure-only (B7): restore like `reuse`, but a cache MISS is a HARD
    /// ERROR instead of a fresh build. A leg run under `require` can never
    /// silently mix built-fresh and restored units — the failure mode that
    /// makes a published figure unreproducible. Build artifacts first
    /// (`make artifacts`), then measure under `require`.
    case require

    /// Whether this mode reads the cache at all.
    var readsCache: Bool { self != .off }
}

/// B7 hard failure: `--estate-cache require` met a cache miss. The run must
/// stop — never silently build fresh — so a leg's provenance stays uniform.
struct ArtifactRequiredError: Error, CustomStringConvertible {
    let entryPath: String
    var description: String {
        "artifact required but missing: \(entryPath)\n"
            + "--estate-cache require is measure-only; it never builds. "
            + "Build the artifact first (run the same configuration with "
            + "--estate-cache reuse, or `make artifacts`), then re-run."
    }
}


// MARK: - Cache entry URL

/// Returns the URL of the cache entry directory for one benchmark unit
/// (a question, conversation, or query), keyed by the full run configuration.
///
/// Cache hierarchy:
/// ```
/// <cacheDir>/
///   <benchmark>[-<variant>]-seed<seed>-barrier_<mode>-estate_<posture>-seedpath_<mode>/
///     <safe-unit-id>/
///       estate/        ← --db snapshot
///       manifest.json  ← serialized manifest entries
/// ```
///
/// - Parameters:
///   - cacheDir: Root cache directory (--cache-dir, or default under out/cwd).
///   - benchmark: "lme", "locomo", "lmeb", or "membench" (spec/agentic lanes
///     carry their own provenance-scoped names).
///   - variant: LME variant ("s", "m", "oracle"). Empty string for locomo/lmeb.
///   - seed: Question shuffle seed.
///   - encodeBarrier: The barrier mode used during ingest.
///   - posture: At-rest posture of the scratch estate. In the key because a
///     plaintext estate and an encrypted estate are different bytes on disk —
///     a snapshot of one must never be restored for a run expecting the other.
///   - unitID: The question_id / conversation sampleID / query_id.
func estateCacheEntryURL(
    cacheDir: URL,
    benchmark: String,
    variant: String,
    seed: UInt64,
    encodeBarrier: EncodeBarrier,
    posture: ScratchEstatePosture,
    seedPath: SeedPathMode,
    unitID: String
) -> URL {
    // Run-config key: a single directory name whose components are, in order —
    // benchmark, variant (omitted when empty), seed, encode barrier, at-rest
    // posture, and seed path. Each component is separated by a dash for
    // readability. This IS the key now: the retired build axes (granularity,
    // preference extraction, event-time scheme, enrichment, filing arm) each
    // collapsed to a single surviving value, so their segments carry no
    // information — the seeding pipeline (BENCHMARK_ESTATES.md) owns artifact
    // building, and every artifact predating this key format was deleted.
    //
    // This is an enumeration, not a claim of completeness. An enumeration goes
    // stale visibly — the list sits directly above the format string that
    // builds it.
    //
    // The seed-path segment exists because a live-built and a batch-built
    // estate are DIFFERENT estate shapes (subjects present vs subject debt,
    // per-record capture times vs one collapsed import instant — deferral
    // ledger L-3/L-4). Restoring one for a run expecting the other would
    // silently mix the two populations Gate G exists to compare.
    let variantSuffix = variant.isEmpty ? "" : "-\(variant)"
    // B3 (benchmark reset 2026-08-13): the binary fingerprint is RETIRED from
    // this key. It invalidated every artifact on every product build even when
    // the change could not alter estate bytes (a retrieval-logic change does
    // not re-encode a corpus). Staleness is now DETECTED, not assumed: every
    // entry carries an artifact.json provenance manifest (ArtifactManifest.swift)
    // validated on open — a mismatch is a hard error, never a silent rebuild.
    // There is NO adornment/minter segment: one entry per unit, and the
    // arm is a runtime activation state applied to the scratch copy at
    // restore — never a separate estate namespace.
    let runKey = "\(benchmark)\(variantSuffix)-seed\(seed)-barrier_\(encodeBarrier.rawValue)-estate_\(posture.rawValue)-seedpath_\(seedPath.rawValue)"

    // Sanitize the unit ID for safe filesystem use: replace characters that are
    // illegal on macOS (and on most POSIX filesystems) with underscores.
    // The legal set here is: alphanumerics, dash, dot, underscore.
    let safeUnitID = unitID.unicodeScalars.map { scalar in
        let c = Character(scalar)
        if c.isLetter || c.isNumber || c == "-" || c == "." || c == "_" {
            return String(c)
        }
        return "_"
    }.joined()
    // Guard against empty or over-long IDs (256-char path component limit on HFS+).
    let trimmedID = safeUnitID.isEmpty ? "unknown" : String(safeUnitID.prefix(200))

    return cacheDir
        .appendingPathComponent(runKey)
        .appendingPathComponent(trimmedID)
}

// MARK: - Default cache directory

/// Returns the default cache directory for a run. When `--cache-dir` is absent,
/// the cache lives under `<out-dir>/estate-cache/` (or `<cwd>/estate-cache/`
/// when `--out` is also absent).
///
/// The `estate-cache` directory is created on first write. Its presence is
/// inert during `--estate-cache off` runs — the runner never reads or writes it.
///
/// Expected cache sizes (inform disk planning):
///   - LME: ~80–150 MB per cached estate × number of unique questions.
///     A full LME-s run (500 questions) could cache up to ~60 GB. Use
///     `--limit N` or a dedicated `--cache-dir` on large runs.
///   - LoCoMo: ~30–80 MB per cached conversation × 10 conversations ≈ ≤ 800 MB.
///   - LMEB: ~5–50 MB per cached query estate × number of queries.
func defaultCacheDir(outDir: URL?) -> URL {
    let base = outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return base.appendingPathComponent("estate-cache")
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
/// would refuse the one mode that cannot carry stale state forward. The
/// Makefile applies the same rule to `make measure-*`, which always runs under
/// `--estate-cache require`.
///
/// - Throws: `DriftGateRefusal` when the receipt is missing, unreadable, or
///   older than the binary under test.
func resolvedCacheDirEnforcingDriftGate(
    cacheDir: URL?,
    outDir: URL?,
    mootBinaryPath: String?,
    estateCache: EstateCacheMode
) throws -> URL {
    let resolved = cacheDir ?? defaultCacheDir(outDir: outDir)
    guard estateCache != .off else { return resolved }
    try DriftGateReceipt.preflight(
        cacheDirectory: resolved.path, binaryPath: mootBinaryPath)
    // Cache isolation: when the embedding-provider seam is set, the cache dir
    // path must contain the model-id string so provisioned and default estates
    // never share a namespace. A mixed cache poisons cross-arm comparisons.
    try assertEmbeddingProviderCacheDirIsolation(cacheDir: resolved)
    return resolved
}

// MARK: - Clone-or-copy (B5)

/// Clones `src` to `dst` via clonefile(2) — instant, copy-on-write, no space
/// until written — falling back to a full byte copy when cloning is
/// unavailable (non-APFS volume, cross-volume, or older estate layouts).
/// clonefile on a directory clones the whole hierarchy in one call, and the
/// clone IS isolation: writes to either side never reach the other (B5).
///
/// The fallback is silent by design at the call sites' semantics (both were
/// full copies before B5); it logs the reason so a persistently-copying
/// cache is visible to the operator.
func cloneOrCopyItem(at src: URL, to dst: URL) throws {
    if clonefile(src.path, dst.path, 0) == 0 {
        return
    }
    let err = errno
    FileHandle.standardError.write(Data(
        "[cache] clonefile unavailable (errno \(err)) — falling back to full copy for \(dst.lastPathComponent)\n".utf8))
    try FileManager.default.copyItem(at: src, to: dst)
}

// MARK: - Snapshot + restore

/// Saves an estate snapshot to a cache entry directory.
///
/// Creates the entry directory (and any parent run-key directory), copies the
/// estate data dir to `<entry>/estate/`, and writes the manifest to
/// `<entry>/manifest.json`. Non-fatal on failure: a snapshot error is logged
/// and the run continues without caching (the question result is still valid).
///
/// - Parameters:
///   - estateScratchDir: The benchmark scratch dir after ingest + encode barrier.
///     The directory MUST exist and contain a valid mootx01 estate.
///   - manifest: The per-question manifest entries (UUID → origin). Must be
///     Codable so it can round-trip through `manifest.json`.
///   - cacheEntry: The directory where the snapshot will be written. Caller
///     provides the URL from `estateCacheEntryURL(...)`.

// MARK: - Artifact-store disk headroom

/// Free bytes on the volume holding `url`.
///
/// Walks up to the nearest EXISTING ancestor before asking. The obvious version
/// of this function queries `url` directly and returns nil for a path that has
/// not been created yet — which is every artifact entry, since the headroom
/// check necessarily runs before the directory is made. That version compiles,
/// reads correctly, and silently never fires. It was written that way first and
/// caught only because the falsification run exited 0.
///
/// Volume identity is a property of the mount, so any existing ancestor answers
/// the same question as the leaf would.
func freeBytesOnVolume(containing url: URL) -> Int64? {
    let fm = FileManager.default
    var probe = url.standardizedFileURL
    while !fm.fileExists(atPath: probe.path) {
        let parent = probe.deletingLastPathComponent().standardizedFileURL
        // Root reached without finding anything that exists: give up rather
        // than loop. "/" always exists in practice, so this is belt-and-braces.
        if parent.path == probe.path { return nil }
        probe = parent
    }
    // volumeAvailableCapacityForImportantUsage, which is Apple's documented
    // answer to "can I write important data here".
    //
    // On an APFS volume carrying Time Machine local snapshots the three figures
    // diverge widely. Measured on this machine: strict (the df number) 97 GB,
    // opportunistic 163 GB, important 326 GB. The ~229 GB gap is 18 local
    // snapshots that macOS purges under write pressure.
    //
    // An earlier version took min(strict, important) on the reasoning that the
    // least generous definition is the safest. That is wrong here: it would
    // halt a legitimate run at the 25 GB floor while 200+ GB sat reclaimable,
    // which is a guard that stops correct work. The purgeable space is real
    // space — it is the number Finder reports and the number the system will
    // actually free.
    //
    // Strict is still read so the diagnostic can name which definition it
    // used; see the STOPPING message.
    let keys: Set<URLResourceKey> = [
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]
    guard let values = try? probe.resourceValues(forKeys: keys) else { return nil }
    // importantUsage answers 0 (not nil) on some EXTERNAL volumes — the API is
    // quota-oriented and meaningful on the boot container; taken literally it
    // halted a run against a 659 GB-free external artifact volume claiming
    // "0.0 GB available". A zero from importantUsage on a volume whose plain
    // capacity is nonzero is an API artifact, not a full disk — fall through
    // to the plain figure in that case.
    if let important = values.volumeAvailableCapacityForImportantUsage,
       important > 0 { return important }
    return values.volumeAvailableCapacity.map(Int64.init)
}

/// Minimum free space, in gigabytes, below which artifact writes stop the run.
///
/// A single cached estate is not small — measured at ~342 MB for LongMemEval
/// and ~46 MB for MemBench — and a full fleet is thousands of them. The floor
/// has to leave room for the in-flight scratch estate plus the OS, not merely
/// for the next artifact.
///
/// Override with MOOTX01_BENCH_MIN_FREE_GB when a run is deliberately taken
/// closer to the edge on a volume that is not the boot disk.
var artifactMinimumFreeGigabytes: Int64 {
    if let raw = ProcessInfo.processInfo.environment["MOOTX01_BENCH_MIN_FREE_GB"],
       let parsed = Int64(raw), parsed >= 0 {
        return parsed
    }
    return 25
}

/// Stops the run when the artifact volume is close to full.
///
/// This is a HARD stop, and deliberately so. Artifact writes are otherwise
/// best-effort: `saveEstateCacheEntry` logs a warning and lets the run
/// continue, which is right when one snapshot fails for its own reasons. It is
/// wrong when the cause is a full disk, because then every subsequent snapshot
/// fails too and the run keeps going — filling the volume with scratch estates
/// and producing a fleet that is silently incomplete. A later measurement pass
/// under `--estate-cache require` then hard-fails on the missing entries,
/// hours after the actual problem.
///
/// Worse, the volume here is usually the boot disk. A benchmark that fills it
/// is not a failed benchmark, it is a broken machine.
///
/// Measured 2026-08-16: a MemBench fleet at 7,000 items needs roughly 322 GB,
/// and the Makefile's per-estate size guidance understated LongMemEval by about
/// 2.8x. Estimating the total up front is therefore not reliable; checking the
/// remaining headroom before each write is.
func assertArtifactDiskHeadroom(cacheDir: URL, unitLabel: String) {
    guard let free = freeBytesOnVolume(containing: cacheDir) else { return }
    let floor = artifactMinimumFreeGigabytes * 1_073_741_824
    guard free < floor else { return }

    let freeGB = Double(free) / 1_073_741_824
    FileHandle.standardError.write(Data("""

        [cache] STOPPING: only \(String(format: "%.1f", freeGB)) GB available for important \
        usage on the artifact volume (floor is \(artifactMinimumFreeGigabytes) GB). This figure \
        includes purgeable space such as Time Machine local snapshots, so it is larger than df.

        The run stopped at unit '\(unitLabel)' rather than continue. Artifact writes are
        best-effort individually, so without this stop the run would have kept going,
        failed every remaining snapshot, and produced a fleet that looks complete in the
        log but hard-fails a later --estate-cache require pass. On a boot volume it would
        also have filled the disk.

        Artifacts already written are intact and reusable. To continue:
          - free space, or point --cache-dir at another volume, then re-run; completed
            units are restored from cache rather than rebuilt, or
          - lower the floor with MOOTX01_BENCH_MIN_FREE_GB=<gb> if this volume is not
            the boot disk.

        """.utf8))
    exit(1)
}

func saveEstateCacheEntry<M: Codable & Sendable>(
    estateScratchDir: URL,
    manifest: [M],
    provenance: ArtifactProvenance,
    to cacheEntry: URL
) {
    // Headroom check before the copy, not after: cloneOrCopyItem falls back to
    // a full byte copy on a non-APFS volume, and a byte copy that runs out of
    // space mid-write leaves a half-written entry behind.
    assertArtifactDiskHeadroom(
        cacheDir: cacheEntry.deletingLastPathComponent(),
        unitLabel: cacheEntry.lastPathComponent)

    let fm = FileManager.default
    let estateTarget = cacheEntry.appendingPathComponent("estate")
    let manifestURL  = cacheEntry.appendingPathComponent("manifest.json")
    do {
        // Ensure the entry directory exists (creates the run-key parent too).
        try fm.createDirectory(at: cacheEntry, withIntermediateDirectories: true)
        // Remove any stale entry from a partial previous write.
        if fm.fileExists(atPath: estateTarget.path) {
            try fm.removeItem(at: estateTarget)
        }
        // Copy estate data dir into the cache entry.
        // B5: APFS clone (instant, COW) with byte-copy fallback.
        try cloneOrCopyItem(at: estateScratchDir, to: estateTarget)
        // Write the manifest JSON alongside the estate.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        // B2: seal the artifact's declared dependency set beside the manifest.
        writeArtifactProvenance(provenance, to: cacheEntry)
        FileHandle.standardError.write(Data(
            "[cache] snapshot saved: \(cacheEntry.lastPathComponent)/\(cacheEntry.deletingLastPathComponent().lastPathComponent)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data(
            "[cache] snapshot WARNING: could not save \(cacheEntry.path): \(error)\n".utf8))
    }
}

/// Restores an estate cache entry to a fresh scratch directory.
///
/// Checks whether `cacheEntry` has both an `estate/` subdirectory and a
/// `manifest.json` file. On a hit: creates a fresh scratch directory (via
/// `scratchDirFactory`), copies the cached estate into it, and decodes the
/// manifest. On a miss or any error: returns nil (non-fatal, caller falls back
/// to normal ingest).
///
/// ISOLATION GUARANTEE: The returned scratch directory is a fresh COPY of the
/// cache entry. The cache original is never queried, so a query run cannot
/// contaminate subsequent cache reads regardless of mootx01's writes to the estate.
///
/// ## Posture
///
/// A scratch estate's posture is not a file in the directory. The product
/// attaches the restored directory as a transient catalog record (`--db`),
/// which is plaintext by rule, or ciphertext under the harness key file beside
/// it; the snapshot's bytes therefore ARE its posture. Posture is a component
/// of the cache key, so an entry never belongs to another posture's run.
///
/// Twin of Rust `restore_estate_cache_entry`.
///
/// - Parameters:
///   - cacheEntry: Cache entry URL from `estateCacheEntryURL(...)`.
///   - scratchDirFactory: A throwing closure that creates the empty scratch
///     directory (e.g. `{ try lmeScratchDir(posture: p) }`). The factory
///     produces the empty dir; the function replaces its contents with the
///     cache snapshot. The resulting dir keeps the correct prefix for guarded
///     teardown.
///   - verifyEmbeddingProvider: Runs the environment-driven embedding-provider
///     verification seam. Production callers use the default. Cache-mechanics
///     tests disable it so process-global environment mutation in seam tests
///     cannot change an unrelated restore assertion.
/// - Returns: `(scratchDir, manifest)` on cache hit, nil on miss or error.
func restoreEstateCacheEntry<M: Codable>(
    from cacheEntry: URL,
    expectedProvenance: ArtifactProvenance,
    verifyEmbeddingProvider: Bool = true,
    scratchDirFactory: () throws -> URL
) throws -> (URL, [M])? {
    let fm = FileManager.default
    let estateSource = cacheEntry.appendingPathComponent("estate")
    let manifestURL  = cacheEntry.appendingPathComponent("manifest.json")

    // Cache miss: required files absent.
    guard fm.fileExists(atPath: estateSource.path),
          fm.fileExists(atPath: manifestURL.path) else { return nil }

    // B2: validate the artifact's declared provenance BEFORE any bytes move.
    // HARD FAIL on mismatch or on an unverifiable (absent/undecodable)
    // manifest — a mismatched artifact silently rebuilt would mix
    // provenances within one leg (the failure B7 exists to prevent).
    guard let onDisk = loadArtifactProvenance(from: cacheEntry) else {
        throw ArtifactProvenanceError(
            entryPath: cacheEntry.path,
            mismatches: ["artifact.json absent or undecodable — pre-B2 entry or torn write"])
    }
    let mismatches = onDisk.mismatches(against: expectedProvenance)
    guard mismatches.isEmpty else {
        throw ArtifactProvenanceError(entryPath: cacheEntry.path, mismatches: mismatches)
    }

    // The posture travels with the record kind, not with the directory: a
    // scratch estate is a transient catalog record and is plaintext by the
    // product's rule (or ciphertext under the harness key file beside it), so
    // a restored snapshot carries its posture in its bytes and there is no
    // marker to validate here.

    // Stage 1: restore mechanics (soft miss on failure).
    // A mechanics failure is indistinguishable from a corrupted or transient
    // cache entry — the caller will build fresh. Seam failures are distinct
    // and handled in Stage 2 below.
    //
    // copiedScratch tracks whether the estate copy landed on disk. A manifest
    // read or decode failure after a successful copy triggers cleanup: the
    // stranded copy carries key material in encrypted modes and sits outside
    // guarded teardown while the caller proceeds on a different scratch.
    let scratch: URL
    let manifest: [M]
    var copiedScratch: URL? = nil
    do {
        // Create a fresh scratch directory with the correct prefix.
        let s = try scratchDirFactory()
        // Remove the empty scratch dir so copyItem can write to its path.
        try fm.removeItem(at: s)
        // Copy the cached estate into the scratch path.
        // B5: APFS clone (instant, COW) with byte-copy fallback. The clone
        // preserves the isolation guarantee: copy-on-write means the run's
        // writes never reach the cache original.
        try cloneOrCopyItem(at: estateSource, to: s)
        copiedScratch = s  // set after copy — marks the estate as on-disk
        // Decode the manifest.
        let manifestData = try Data(contentsOf: manifestURL)
        manifest = try JSONDecoder().decode([M].self, from: manifestData)
        scratch = s
    } catch {
        if let s = copiedScratch {
            FileHandle.standardError.write(Data(
                "[cache] restore cleanup: removed partial scratch \(s.path)\n".utf8))
            try? fm.removeItem(at: s)
        }
        FileHandle.standardError.write(Data(
            "[cache] restore WARNING: could not restore \(cacheEntry.path): \(error)\n".utf8))
        return nil
    }

    // Stage 2: provisioning seams (hard error — a silently unprovisioned cell
    // would measure defaults while labeled as the provisioned arm). If a seam
    // throws, remove the copied scratch before propagating to prevent a
    // key-material leak in encrypted modes, then rethrow.
    do {
        // Instrument seam (W2.5 Track R(c)): provision lane_weights into the
        // SCRATCH COPY when MOOT_BENCH_PROVISION_LANE_WEIGHTS is set. Runs
        // after the copy so only a validated copy is ever
        // provisioned; the cache original is never touched. Hard-throws on
        // failure (a silently unprovisioned cell would measure defaults
        // while labeled as the provisioned arm).
        try provisionLaneWeightsSeam(into: scratch)
        // Provision recall_tuning into the scratch copy when
        // MOOT_BENCH_PROVISION_RECALL_TUNING is set — exact mirror of the
        // lane_weights seam above; both run before any probe query so the
        // correct tuning is in effect for all measurements in the unit.
        try provisionRecallTuningSeam(into: scratch)
        // Provision door_config into the scratch copy when
        // MOOT_BENCH_PROVISION_DOOR_CONFIG is set — exact mirror of the
        // lane_weights and recall_tuning seams above; runs before any probe
        // query so the correct front-door A1 config is in effect for all
        // measurements in the unit. When `door="guess"` is used in the run,
        // the RecallDirector reads this key instead of defaulting to
        // matrixAware. Hard-throws on failure (a silently unprovisioned cell
        // would measure the default arm while labeled as the provisioned arm).
        try provisionDoorConfigSeam(into: scratch)
        // Embedding-provider restore-path verification: when
        // MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set, the restored estate
        // MUST already carry the matching key — it was built with the slot
        // wired (via preprovisionEmbeddingSlot in the build path). A write
        // here would produce no vectors for the slot (reindexMissing skips
        // already-indexed drawers), mislabeling the arm. Read-and-compare
        // instead: absent or mismatched key is a HARD ERROR; match is a no-op.
        if verifyEmbeddingProvider {
            try verifyEmbeddingProviderSeam(in: scratch)
        }
    } catch {
        // Seam failure: remove the copied scratch before propagating. A full
        // estate copy (with key material in encrypted modes) left on disk sits
        // outside guarded teardown while the caller proceeds on a different
        // scratch.
        FileHandle.standardError.write(Data(
            "[cache] seam failure on \(cacheEntry.path): \(error)\n".utf8))
        try? fm.removeItem(at: scratch)
        FileHandle.standardError.write(Data(
            "[cache] restore cleanup: removed partial scratch \(scratch.path)\n".utf8))
        throw error
    }

    FileHandle.standardError.write(Data(
        "[cache] hit: \(cacheEntry.lastPathComponent)\n".utf8))
    return (scratch, manifest)
}
