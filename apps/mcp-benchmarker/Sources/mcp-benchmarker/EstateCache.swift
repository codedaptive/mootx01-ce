import Foundation

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
// Cache key components: (benchmark, variant, question_id, seed, encode_barrier, binary_fingerprint)
// Binary fingerprint (mtime + size of the mootx01 binary) invalidates automatically
// on rebuild — a new swift build changes mtime, so the cache misses.
//
// Cache entry layout:
//   <cacheDir>/
//     <run-key>/            benchmark-variant-seed-barrier-binhash
//       <safe-unit-id>/     question_id/conv_id/query_id (filesystem-safe)
//         estate/           copy of the MOOTX01_DATA_DIR after ingest+encode
//         manifest.json     serialized manifest entries (UUID → origin mapping)
//
// Deletion discipline: cache entries are NEVER deleted by the runner. Only the
// per-question scratch copies (under /tmp/lme-bench-*, /tmp/locomo-bench-*,
// /tmp/lmeb-bench-*) are subject to guarded teardown — those functions already
// require the correct prefix. Cache entry paths are outside /tmp/ (typically
// under the results dir) and are NEVER passed to guarded teardown functions.
//
// METHODOLOGY note (cross-twin sharing):
//   When the Swift and Rust runners point at the SAME mootx01 binary, they share
//   cache entries (same binary fingerprint → same cache key → same snapshots).
//   This improves twin comparison consistency: both legs query IDENTICAL estates.
//   Cross-twin sharing is allowed and recommended. When they point at different
//   builds, different fingerprints → different cache entries → no sharing.
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
    /// Snapshot after ingest; copy snapshot on subsequent runs.
    case reuse
}

// MARK: - Binary fingerprint

/// Computes a short fingerprint of the mootx01 binary using mtime + file size.
///
/// Fast (one stat call), reliable (any `swift build` changes the binary's mtime),
/// and zero-dependency. Returns "unknown" when the binary is inaccessible.
///
/// The fingerprint is included in the cache key so a rebuilt mootx01 automatically
/// produces a cache miss — stale snapshots from an old binary are never reused
/// against a new binary.
///
/// Format: "<mtime_hex>_<size_hex>" (both values are positive integers).
func mootBinaryFingerprint(_ binaryPath: String) -> String {
    // Resolve symlinks so the fingerprint reflects the final binary target,
    // not an intermediate symlink that may have a different mtime.
    // resolvingSymlinksInPath() is non-throwing; no try? needed.
    let resolvedPath = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else {
        return "unknown"
    }
    let size = (attrs[.size] as? Int) ?? 0
    // Use integer seconds (drop sub-second precision) for a stable key.
    let mtimeSecs = Int64((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    return String(format: "%llx_%llx", mtimeSecs, Int64(size))
}

// MARK: - Cache entry URL

/// Returns the URL of the cache entry directory for one benchmark unit
/// (a question, conversation, or query), keyed by the full run configuration.
///
/// Cache hierarchy:
/// ```
/// <cacheDir>/
///   <benchmark>[-<variant>]-seed<seed>-barrier_<mode>-bin_<fingerprint>-estate_<posture>/
///     <safe-unit-id>/
///       estate/        ← MOOTX01_DATA_DIR snapshot
///       manifest.json  ← serialized manifest entries
/// ```
///
/// - Parameters:
///   - cacheDir: Root cache directory (--cache-dir, or default under out/cwd).
///   - benchmark: "lme", "locomo", or "lmeb".
///   - variant: LME variant ("s", "m", "oracle"). Empty string for locomo/lmeb.
///   - seed: Question shuffle seed.
///   - encodeBarrier: The barrier mode used during ingest.
///   - binaryFingerprint: From `mootBinaryFingerprint(_:)`.
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
    binaryFingerprint: String,
    posture: ScratchEstatePosture,
    unitID: String
) -> URL {
    // Run-config key: a single directory name encoding all parameters that
    // affect estate content. Each component is separated by a dash for readability.
    let variantSuffix = variant.isEmpty ? "" : "-\(variant)"
    let runKey = "\(benchmark)\(variantSuffix)-seed\(seed)-barrier_\(encodeBarrier.rawValue)-bin_\(binaryFingerprint)-estate_\(posture.rawValue)"

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
func saveEstateCacheEntry<M: Codable & Sendable>(
    estateScratchDir: URL,
    manifest: [M],
    to cacheEntry: URL
) {
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
        try fm.copyItem(at: estateScratchDir, to: estateTarget)
        // Write the manifest JSON alongside the estate.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
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
/// - Parameters:
///   - cacheEntry: Cache entry URL from `estateCacheEntryURL(...)`.
///   - expectedPosture: The run's scratch-estate posture. The snapshot copied
///     the whole data dir, so a plaintext snapshot carries the `no-encrypt`
///     marker and an encrypted one does not. After restore, the marker's
///     presence must MATCH the expected posture; a mismatch means the cache
///     entry does not belong to this run's key (should be impossible now that
///     posture is a key component) and is treated as a miss with a warning —
///     never as a silently wrong-posture estate.
///   - scratchDirFactory: A throwing closure that creates the empty scratch
///     directory (e.g. `{ try lmeScratchDir(posture: p) }`). The factory
///     produces the empty dir; the function replaces its contents with the
///     cache snapshot (the posture marker therefore comes FROM the snapshot,
///     not from the factory). The resulting dir keeps the correct prefix for
///     guarded teardown.
/// - Returns: `(scratchDir, manifest)` on cache hit, nil on miss or error.
func restoreEstateCacheEntry<M: Codable>(
    from cacheEntry: URL,
    expectedPosture: ScratchEstatePosture,
    scratchDirFactory: () throws -> URL
) -> (URL, [M])? {
    let fm = FileManager.default
    let estateSource = cacheEntry.appendingPathComponent("estate")
    let manifestURL  = cacheEntry.appendingPathComponent("manifest.json")

    // Cache miss: required files absent.
    guard fm.fileExists(atPath: estateSource.path),
          fm.fileExists(atPath: manifestURL.path) else { return nil }

    do {
        // Create a fresh scratch directory with the correct prefix.
        let scratch = try scratchDirFactory()
        // Remove the empty scratch dir so copyItem can write to its path.
        try fm.removeItem(at: scratch)
        // Copy the cached estate into the scratch path.
        try fm.copyItem(at: estateSource, to: scratch)
        // Posture assert: the restored data dir's marker presence must match
        // the posture this run expects. The marker travels with the snapshot;
        // a mismatch is a foreign or corrupted cache entry.
        let markerPresent = scratchHasOptOutMarker(in: scratch)
        let markerExpected = (expectedPosture == .plaintextOptOut)
        guard markerPresent == markerExpected else {
            FileHandle.standardError.write(Data(
                ("[cache] restore WARNING: posture mismatch for \(cacheEntry.path) — "
                + "expected \(expectedPosture.rawValue), marker "
                + "\(markerPresent ? "present" : "absent"). Treating as cache miss.\n").utf8))
            try? fm.removeItem(at: scratch)
            return nil
        }
        // Decode the manifest.
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode([M].self, from: manifestData)
        FileHandle.standardError.write(Data(
            "[cache] hit: \(cacheEntry.lastPathComponent)\n".utf8))
        return (scratch, manifest)
    } catch {
        FileHandle.standardError.write(Data(
            "[cache] restore WARNING: could not restore \(cacheEntry.path): \(error)\n".utf8))
        return nil
    }
}
