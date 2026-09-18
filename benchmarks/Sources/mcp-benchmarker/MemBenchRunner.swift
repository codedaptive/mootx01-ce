import Foundation

// MemBenchRunner.swift — MemBench per-item turn-recall harness.
//
// Estate model: PER-ITEM scratch estates (parallel to the LME per-question model),
// because MemBench items are independent conversation threads — each has its own
// set of sessions and a single QA pair. LoCoMo's per-conversation batching model
// does not apply here: items do not share sessions, so sharing an estate across
// items would introduce cross-item contamination.
//
//   LME model:     1 question → 1 scratch estate → ingest haystack → 1 query
//   MemBench model: 1 item    → 1 scratch estate → ingest all sessions → 1 query
//
// Safety guarantees (parallel to LME and LoCoMo):
//   - memBenchScratchDir(posture:) uses the /tmp/membench-bench- prefix.
//   - memBenchGuardedTeardown() refuses any path without that prefix.
//   - The EndpointConfig carries --db /tmp/membench-bench-... so
//     assertScratchBackend independently verifies the scratch constraint.
//
// Manifest correlation:
//   - Live path: each ingested turn produces a UUID from moot_file_memory.
//     Batch path: moot_json_import returns the drawer id for every record.
//   - MemBenchManifestEntry maps UUID → String(sid). A sid is NOT unique within
//     an item: a turn that restates an earlier step repeats it, so two entries
//     can share one sid and either earns the evidence credit.
//   - EVERY turn is manifested, not only the evidence ones. The scorer walks
//     retrieved UUIDs in rank order, so an unmapped hit distorts the rank of
//     everything behind it.
//   - The scorer uses lmeRankedSessions to map retrieved UUIDs → ranked sids for
//     recall scoring against evidenceSids (target_step_id[*].globalSid).
//
// Inline encoding (impatient barrier):
//   - Required when barrier == .impatient. The drain barrier (default) polls
//     moot_drain_status after the full item ingest. The none mode documents the race.
//   - Origin: LME-01 finding — without barrier enforcement, recall queries
//     issued immediately after ingest can precede encoding completion.

// MARK: - Verbmap for mootx01 in MemBench mode

/// Standard mootx01 VerbMap for MemBench ingestion + recall queries.
/// Mirrors the LoCoMo verbMap with a MemBench-specific location.
///
/// write:         moot_file_memory
/// query:         moot_memory_search
/// constantArgs:  { "location": "benchmarks/membench" }
/// resultFormat:  .mootV2
let memBenchMootVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: ["location": "benchmarks/membench"],
    resultFormat: .mootV2
)

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin turn, enabling the scorer to
/// correlate retrieved UUIDs → global sids for turn-level recall scoring.
struct MemBenchManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The sid of the turn as it appears in the corpus. Not unique within an
    /// item — a restated step repeats its sid, so two entries may share one.
    let sid: String
    /// The 0-based session index this turn belongs to.
    let sessionIndex: Int
}

// MARK: - Per-item result

/// The result of ingesting one MemBench item and querying its QA question.
struct MemBenchItemResult: Sendable {
    /// Synthetic item identifier (e.g. "FirstAgent/simple/roles/0").
    let itemID: String
    /// Category label (e.g. "simple", "noisy").
    let category: String
    /// The question text that was queried.
    let question: String
    /// Time taken for the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double
    /// UUIDs returned by moot_memory_search, in ranked order.
    let retrievedUUIDs: [String]
    /// Manifest mapping UUID → sid for every ingested turn in this item's estate.
    let manifest: [MemBenchManifestEntry]
    /// Ground-truth global sids that contain evidence for this item's question.
    /// Derived from target_step_id[*].globalSid.
    let evidenceSids: [String]
    /// True when the DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// If the guard was unhealthy, the diagnostic message.
    let guardDiagnostic: String?
    /// Sampling policy that determined whether this item issued its own probe
    /// or used the cached verdict from the first item of the leg.
    let guardSamplingMode: GuardSamplingPolicy
    /// Total turns ingested into this item's estate.
    let turnsIngested: Int
    /// Mean write latency across all turns for this item.
    let writeMeanLatencySeconds: Double
    /// Raw payload text (joined textBlocks) from the moot_memory_search response.
    /// Nil when the MCP response carried no textBlocks.
    let payloadText: String?
    // MARK: C9 — multiple-choice arm
    /// The item's four answer options from the dataset (keys A/B/C/D).
    /// Passed through from MemBenchItem.qa.choices so the scorer can apply
    /// selectMultipleChoicePrediction without a corpus lookup at score time.
    let choices: [String: String]
    /// The correct answer letter (A/B/C/D) from the dataset.
    let groundTruth: String
}

// MARK: - Backend shape

/// Controls the storage backend for per-item scratch estates.
///
/// Recorded in the report JSON as the "shape" field beside "encode_barrier".
///
/// - `disk` (default): standard SQLite-backed estate, same as all prior runs.
/// - `ram`: --in-memory selects PersistenceKit's InMemory backend —
///   no SQLite file is written, no keychain contact. Incompatible with
///   --estate-cache reuse|require (a RAM estate is not an artifact; nothing
///   is written to disk to snapshot).
public enum BenchShape: String, Sendable {
    case disk = "disk"
    case ram  = "ram"

    /// Parses a `--shape` CLI value. `nil` input → default (`.disk`).
    /// Fails closed on unknown values.
    static func parse(_ raw: String?) throws -> BenchShape {
        guard let raw else { return .disk }
        guard let shape = BenchShape(rawValue: raw) else {
            throw MCPError(description: "--shape must be 'disk' or 'ram'; got '\(raw)'")
        }
        return shape
    }
}

// MARK: - Capacity tier (C11)

/// Token-volume capacity tier for a MemBench run.
///
/// Controls how many tokens each measured item's estate is grown to before the
/// recall query is issued. Capacity tiers are a Shape-3 derivative: every report
/// produced with a non-baseline tier carries `protocol_deviation: true` and a
/// descriptive `estate_shape` label.
///
/// - `baseline`: no filler — each item's estate contains only that item's own
///   sessions. This is the standard per-item MemBench protocol.
/// - `tenK`: grow each item's estate to approximately 10,000 tokens by adding
///   conflict-free filler items drawn from the same C10 conflict-key group.
/// - `hundredK`: grow each item's estate to approximately 100,000 tokens.
///   If the conflict-free pool is exhausted before the target is reached, the run
///   reports the achieved count plus a shortfall — never pads with invalid data.
///
/// Twin of Rust `CapacityTier`.
public enum CapacityTier: String, Sendable {
    case baseline = "baseline"
    case tenK     = "10k"
    case hundredK = "100k"

    /// The token target for this tier. Nil for `.baseline` (no fill).
    var targetTokens: Int? {
        switch self {
        case .baseline:  return nil
        case .tenK:      return 10_000
        case .hundredK:  return 100_000
        }
    }

    /// Parses an optional `--capacity-tier` CLI value.
    /// Nil input → `.baseline`. Fails closed on unknown values.
    static func parse(_ raw: String?) throws -> CapacityTier {
        guard let raw else { return .baseline }
        guard let tier = CapacityTier(rawValue: raw) else {
            throw MCPError(description:
                "--capacity-tier must be 'baseline', '10k', or '100k'; got '\(raw)'")
        }
        return tier
    }

    /// Report JSON `capacity_tier` value.
    var reportLabel: String { rawValue }

    /// Report JSON `estate_shape` value for capacity-tier runs.
    /// Nil for baseline (estate_shape is set by estateGrouping instead).
    var estateShapeLabel: String? {
        switch self {
        case .baseline:  return nil
        case .tenK:      return "per-item-capacity-10k"
        case .hundredK:  return "per-item-capacity-100k"
        }
    }
}

// MARK: - Estate grouping mode (C10)

/// Controls the estate topology for a MemBench run.
///
/// - `perItem` (default): one scratch estate per item — the published MemBench protocol.
/// - `consolidatedShape3`: items grouped by conflict key (question text), one estate per
///   group. Departs from the published protocol; every figure carries deviation labels
///   in the report JSON (`"estate_shape": "consolidated-shape3"`,
///   `"protocol_deviation": true`).
///
/// Twin of Rust `GroupingMode`.
public enum EstateGroupingMode: String, Sendable {
    /// One estate per item. Published MemBench protocol (default).
    case perItem = "per-item"
    /// Shape 3: non-overlapping groups by conflict key (question text), one estate per
    /// group. Greedy round-robin ensures no group contains two items with the same
    /// question. Deviates from the published per-item protocol.
    case consolidatedShape3 = "consolidated"

    /// Parses an optional CLI flag value. `nil` or `"per-item"` → `.perItem`;
    /// `"consolidated"` → `.consolidatedShape3`. Fails closed on unknown values.
    static func parse(_ raw: String?) throws -> EstateGroupingMode {
        guard let raw else { return .perItem }
        guard let mode = EstateGroupingMode(rawValue: raw) else {
            throw MCPError(description:
                "--estate-grouping must be 'per-item' or 'consolidated'; got '\(raw)'")
        }
        return mode
    }
}

// MARK: - Run config

/// Configuration for one MemBench run.

struct MemBenchRunConfig: Sendable {
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Root MemData directory (contains FirstAgent/ and ThirdAgent/).
    let dataDir: URL
    /// Agent perspective to load. Default: "FirstAgent".
    let agent: String
    /// Category names to include. nil = all 7 LowLevel categories.
    let categories: [String]?
    /// Maximum number of items to run. nil = all loaded items.
    let limit: Int?
    /// Skip this many items from the (seeded-shuffled) item list.
    let offset: Int
    /// --ids: pinned debug-subset unit IDs (nil = whole corpus).
    var unitIDs: Set<String>? = nil
    /// Optional retrieval-call override (environment seam; see
    /// RetrievalCallSpec.swift). nil = the verb map's standard query.
    var retrievalCall: RetrievalCallSpec? = nil
    /// Payload-economics shape-variant arm (--payload-arm /
    /// MOOT_BENCH_PAYLOAD_ARM; see PayloadArm.swift). Applied by
    /// retrieveThroughSeam to the seam result's textBlocks so judged-output
    /// row text carries the arm's field subset. nil = full ruled payload.
    var payloadArm: PayloadArm? = nil
    /// Seed for deterministic item shuffling.
    let seed: UInt64
    /// Directory to write the results report. nil = current directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
    /// Encode-queue synchronisation strategy. Controls whether ingest uses
    /// inline encoding (impatient), a post-ingest drain barrier (drain, default),
    /// or no barrier (none). Recorded in the report JSON as "encode_barrier".
    let encodeBarrier: EncodeBarrier
    /// At-rest posture for scratch estates. Default plaintextTransient: writes
    /// each scratch dir as a transient catalog record (plaintext by rule).
    let scratchPosture: ScratchEstatePosture
    /// Optional category filter. Applied BEFORE offset/limit so a limit counts
    /// items of the requested category. nil = all categories.
    let categoryFilter: String?
    /// Seed-file loading mode (--seed-path). `.batch` (default) emits a
    /// schema-v1 JSON file and loads with one `moot_json_import` — zero
    /// per-turn network calls. `.live` retains the original per-turn
    /// `moot_file_memory` path for periodic equivalence re-proving.
    let seedPath: SeedPathMode
    /// Guard probe sampling policy for this leg.
    ///
    /// Default `.oncePerLeg`: the guard probes the first item only and caches
    /// the verdict for the rest of the leg. Use `.perUnit` only for debugging.
    let guardSamplingPolicy: GuardSamplingPolicy
    /// Estate snapshot reuse mode (B6 — membench was the one lane with no
    /// artifact reuse at all; every run rebuilt 7,000 estates from scratch).
    let estateCache: EstateCacheMode
    /// Cache root directory. nil = <outDir>/estate-cache (or <cwd>/estate-cache).
    let cacheDir: URL?
    /// SHA-256 of the corpus fixture inputs (B2 provenance). "unknown" never
    /// validates.
    let corpusDigest: String
    /// Storage backend shape for scratch estates (C1).
    /// `.ram` selects the InMemory backend (--in-memory); `.disk` (default)
    /// uses the standard SQLite backend. Recorded in the report JSON as "shape".
    let shape: BenchShape
    /// Number of items to process concurrently (C6). 1 = serial (previous behavior).
    /// Default: max(1, floor(logical_core_count × 0.8)). Recorded as "parallel_units".
    let parallelUnits: Int
    /// C10: Estate grouping topology. `.perItem` (default) runs one scratch estate per
    /// item — the published MemBench protocol. `.consolidatedShape3` groups items by
    /// question text and runs one estate per group (Shape 3 deviation).
    let estateGrouping: EstateGroupingMode
    /// C11: Capacity tier. `.baseline` (default) = no filler, standard per-item run.
    /// `.tenK` / `.hundredK` grow each item's estate to ~10k / ~100k tokens with
    /// conflict-free filler drawn from the C10 conflict-key group.
    let capacityTier: CapacityTier
}

// MARK: - Scratch estate management

/// Creates a fresh, hardened scratch directory under /tmp/membench-bench-<UUID>.
/// The /tmp/membench-bench- prefix is the contract with `memBenchGuardedTeardown`.
///
/// Hardening added in E3 (mirrors Rust membench_scratch_dir):
/// - After creation, `FileManager.destinationOfSymbolicLink(atPath:)` verifies
///   the entry is not a symlink an attacker raced to place.
/// - `URL.resolvingSymlinksInPath()` canonicalizes the path (resolves any `..`
///   segments); the canonical URL is what callers store and pass to teardown.
/// - The canonical path is re-checked against the expected prefix.
///
/// - Parameter posture: At-rest posture for the estate.
/// - Returns: The canonical URL of the created directory.
/// - Throws: `MCPError` when directory creation or the symlink guard fails.
func memBenchScratchDir(posture: ScratchEstatePosture) throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/membench-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description: "memBenchScratchDir: could not create \(path): \(error)")
    }

    // Reject symlinks: an attacker could race to replace the just-created
    // directory with a symlink pointing at real data. FileManager.attributesOfItem
    // follows symlinks, so we use FileManager.destinationOfSymbolicLink which
    // only succeeds when the path IS a symlink — success means we must refuse.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "memBenchScratchDir: SAFETY: '\(path)' is a symlink — "
            + "refusing to use as scratch estate")
    }

    // Canonicalize to resolve any `..` components; verify the resolved path
    // stays within the expected prefix before handing it to the caller.
    let canonical = url.resolvingSymlinksInPath()
    let canonicalPath = canonical.path
    guard canonicalPath.hasPrefix("/tmp/membench-bench-") else {
        throw MCPError(description:
            "memBenchScratchDir: SAFETY: canonicalized path '\(canonicalPath)' "
            + "escapes /tmp/membench-bench-")
    }

    return canonical
}

/// Deletes a scratch directory created by `memBenchScratchDir`. Refuses any path
/// without the `/tmp/membench-bench-` prefix, and refuses symlinks — belt and
/// suspenders on top of the creation-time guards.
///
/// - Parameter url: The canonical scratch directory URL from `memBenchScratchDir`.
/// - Throws: `MCPError` when the prefix guard or symlink guard fires.
func memBenchGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/membench-bench-") else {
        throw MCPError(description:
            "SAFETY: memBenchGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/membench-bench- prefix. "
            + "Only directories created by memBenchScratchDir(posture:) may be torn down by this guard.")
    }
    // Belt-and-suspenders symlink check: a canonical path should never be a
    // symlink itself, but if it somehow is, refuse rather than following it.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "SAFETY: memBenchGuardedTeardown refused symlink '\(path)' — "
            + "only real directories may be torn down")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data(
            "[membench] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a MemBench scratch estate.
///
/// When `shape` is `.ram`, injects `--in-memory` into the serve
/// command so mootx01 selects PersistenceKit's InMemory backend — no SQLite file
/// is written and there is no keychain contact. The env var is placed after the
/// posture prefix and before the VAULT/DATA_DIR vars, matching the convention
/// in other lanes that inject backend-selection vars.
func memBenchEndpointConfig(scratchDir: URL, mootBinaryPath: String,
                             posture: ScratchEstatePosture,
                             shape: BenchShape) throws -> EndpointConfig {
    // RAM shape: no persistent file, no keychain. --in-memory is
    // read by mootx01 serve before storage initialization.
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: scratchDir, inMemory: shape == .ram, environment: scratchServeEnvironment)
    let endpoint = EndpointConfig(
        name: "mootx01-membench",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: memBenchMootVerbMap,
        role: .target
    )
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
    return endpoint
}

// MARK: - Runner

/// Runs the MemBench harness against a loaded corpus. Returns per-item results
/// with manifest, latency, and guard verdict for each item.
///
/// Per-item estate strategy (mirrors the LME per-question model):
///   1. Select and shuffle the item list.
///   2. For each selected item:
///      a. Provision a fresh scratch estate.
///      b. Ingest all turns from all sessions per the EncodeBarrier mode.
///      c. Trigger moot_dream for dream-built associations.
///      d. Run the DegeneracyGuard probe.
///      e. Issue the item's QA question as a recall query.
///      f. Tear down the estate.


func runMemBenchItems(
    items: [MemBenchItem],
    config: MemBenchRunConfig
) async throws -> (results: [MemBenchItemResult], timingReport: String?) {
    // --ids pinned subset (before shuffle: same file → same units always).
    let items = try filterUnits(
        items, ids: config.unitIDs, id: { $0.itemID }, lane: "membench")
    // Category filter runs BEFORE the shuffle/offset/limit so a limit counts
    // items of the requested category.
    let filtered: [MemBenchItem]
    if let category = config.categoryFilter {
        filtered = items.filter { $0.category == category }
    } else {
        filtered = items
    }

    // Apply seeded shuffle then offset + limit.
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filtered
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [MemBenchItem]
    if let limit = config.limit {
        selected = Array(afterOffset.prefix(limit))
    } else {
        selected = afterOffset
    }

    // One sampler per leg: probes on the first item; caches for subsequent items.
    // LegGuardSampler is an actor — safe for concurrent callers without additional
    // synchronisation.
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    // C4: one timing sampler for the leg — captures the audit-derived timing
    // report from the first freshly-settled estate (INGEST samples + four CYCLE
    // tiers). Actor serialisation ensures exactly one MCP call is issued.
    let timingSampler = LegTimingSampler()

    // B6: cache setup — one provenance per run (B2), key without a binary
    // fingerprint (B3), snapshot after settle (B4), clone restore (B5).
    let runProvenance = makeArtifactProvenance(
        benchmark: "membench",
        variant: config.agent,   // ThirdAgent estates must not share a key with FirstAgent
        seed: config.seed,
        encodeBarrier: config.encodeBarrier,
        posture: config.scratchPosture,
        seedPath: config.seedPath,
        corpusDigest: config.corpusDigest,
        mootx01Version: mootBinaryVersion(binaryPath: config.mootBinaryPath))
    // Drift gate: refuse before any scratch estate is written when the gate's
    // evidence does not cover the binary this lane resolved. Routed through the
    // shared resolver so no lane can be the one that skips it.
    let resolvedCacheDir: URL = try resolvedCacheDirEnforcingDriftGate(
        cacheDir: config.cacheDir,
        outDir: config.outDir,
        mootBinaryPath: config.mootBinaryPath,
        estateCache: config.estateCache)

    // Parallel execution with bounded concurrency (C6). parallelUnits == 1 gives
    // the same completion order as the previous sequential loop (one outstanding task
    // at a time). Results are collected with their original index and sorted before
    // return so the report ordering is byte-deterministic regardless of task
    // completion order.
    var indexedResults: [(Int, MemBenchItemResult)] = []
    indexedResults.reserveCapacity(selected.count)
    try await withThrowingTaskGroup(of: (Int, MemBenchItemResult).self) { group in
        var nextToSubmit = 0
        // Seed the initial wave of concurrent tasks up to the concurrency limit.
        while nextToSubmit < config.parallelUnits, nextToSubmit < selected.count {
            let idx = nextToSubmit
            group.addTask {
                let result = try await runOneMemBenchItem(
                    item: selected[idx], itemIdx: idx, totalCount: selected.count,
                    config: config, guardSampler: guardSampler, timingSampler: timingSampler,
                    runProvenance: runProvenance, resolvedCacheDir: resolvedCacheDir)
                return (idx, result)
            }
            nextToSubmit += 1
        }
        // Sliding window: for each completed task, submit the next pending item.
        for try await (completedIdx, result) in group {
            indexedResults.append((completedIdx, result))
            if nextToSubmit < selected.count {
                let idx = nextToSubmit
                group.addTask {
                    let result = try await runOneMemBenchItem(
                        item: selected[idx], itemIdx: idx, totalCount: selected.count,
                        config: config, guardSampler: guardSampler, timingSampler: timingSampler,
                        runProvenance: runProvenance, resolvedCacheDir: resolvedCacheDir)
                    return (idx, result)
                }
                nextToSubmit += 1
            }
        }
    }
    // Sort by original index for byte-deterministic report ordering.
    return (indexedResults.sorted { $0.0 < $1.0 }.map(\.1), await timingSampler.text())
}

// MARK: - Per-item runner (task body)

/// Ingests one MemBench item into a fresh scratch estate and issues its QA query.
///
/// This is the body extracted from the per-item loop in `runMemBenchItems` and run
/// as each task in the bounded-concurrency TaskGroup (C6). Every invocation owns
/// its own scratch directory, MCP client, and process — there is no shared mutable
/// state except `guardSampler` (an actor) and the read-only `runProvenance` /
/// `resolvedCacheDir` values.
///
/// - Parameters:
///   - item: The MemBench item to process.
///   - itemIdx: 0-based position in the selected item list (for progress logging).
///   - totalCount: Total selected items for the leg (for progress logging).
///   - config: Immutable run configuration for this leg.
///   - guardSampler: Shared leg-level guard sampler (actor — safe for concurrent callers).
///   - timingSampler: Shared leg-level timing sampler (actor — safe for concurrent callers). C4.
///   - runProvenance: B2 provenance key shared across all items in the leg (read-only).
///   - resolvedCacheDir: Cache root directory for this leg (read-only).
/// - Returns: The scored `MemBenchItemResult` for this item.
/// - Throws: `MCPError` on connection, ingest, or cache errors.
func runOneMemBenchItem(
    item: MemBenchItem,
    itemIdx: Int,
    totalCount: Int,
    config: MemBenchRunConfig,
    guardSampler: LegGuardSampler,
    timingSampler: LegTimingSampler,
    runProvenance: ArtifactProvenance,
    resolvedCacheDir: URL
) async throws -> MemBenchItemResult {
    let itemLabel = "[membench] item=\(item.itemID) (#\(itemIdx + 1)/\(totalCount))"
    FileHandle.standardError.write(Data((itemLabel + "\n").utf8))

    // Measure-only provisioning: restore this item's pre-built estate
    // artifact, or hard-fail. The restored estate is SETTLED (built import →
    // drain → dream → retrain by the seeding pipeline) and the manifest comes
    // from the snapshot. A miss — under any --estate-cache mode, including
    // off — is ArtifactRequiredError, never a fresh build.
    let cacheEntry = estateCacheEntryURL(
        cacheDir: resolvedCacheDir,
        benchmark: "membench",
        variant: config.agent,   // ThirdAgent estates must not share a key with FirstAgent
        seed: config.seed,
        encodeBarrier: config.encodeBarrier,
        posture: config.scratchPosture,
        seedPath: config.seedPath,
        unitID: item.itemID
    )
    guard config.estateCache.readsCache,
          let (scratchDir, restoredManifest): (URL, [MemBenchManifestEntry]) =
              try restoreEstateCacheEntry(
                  from: cacheEntry,
                  expectedProvenance: runProvenance,
                  scratchDirFactory: { try memBenchScratchDir(posture: config.scratchPosture) })
    else {
        throw ArtifactRequiredError(entryPath: cacheEntry.path)
    }
    let endpoint = try memBenchEndpointConfig(
        scratchDir: scratchDir, mootBinaryPath: config.mootBinaryPath,
        posture: config.scratchPosture, shape: config.shape)
    // Embedding-provider seam on restored estates is verified by
    // verifyEmbeddingProviderSeam inside restoreEstateCacheEntry.
    let client = MCPClient(endpoint: endpoint, responseDeadline: 600)
    try await client.connect()
    // Retire the estate only when this item finished. A throw leaves it on
    // disk under a loud notice (see keepScratchEstateOnFailure).
    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            try? retireScratchEstate(scratchDir, expectPlaintext: config.scratchPosture == .plaintextTransient, teardown: memBenchGuardedTeardown)
        } else {
            keepScratchEstateOnFailure(scratchDir, lane: "membench")
        }
    }

    // The restored artifact is settled by construction (the seeding
    // pipeline builds import → drain → dream → reindex → drain); this
    // lane never ingests, settles, or snapshots. The restored manifest
    // names every record the seeding pipeline imported for this item.
    let manifest: [MemBenchManifestEntry] = restoredManifest
    let ingestCount = manifest.count

    // No writes happen on a restored estate; write latency is a build-time
    // property of the artifact, not of this run.
    let writeMean = 0.0

    // DegeneracyGuard probe — delegated to the leg sampler.
    // On the first item the sampler issues 3 MCP probe queries and caches
    // the verdict; subsequent items reuse the cached verdict at zero cost.
    let (verdict, _) = await guardSampler.probe {
        await probeMCPClient(client, verbMap: memBenchMootVerbMap, name: "mootx01-membench")
    }
    let guardHealthy: Bool
    if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
    let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic


    // Issue the QA question through the configured retrieval door.
    // D-2026-08-20-A: seam failure hard-fails the unit. The error names the
    // unit (itemID) and seam args so the run log is unambiguous.
    let queryStart = Date()
    let queryResult: MCPToolResult
    do {
        queryResult = try await retrieveThroughSeam(
            item.qa.question, client: client,
            verbMap: memBenchMootVerbMap, spec: config.retrievalCall,
            arm: config.payloadArm)
    } catch {
        if let spec = config.retrievalCall {
            throw MCPError(description:
                "[membench \(item.itemID)] seam call failed "
                + "(tool=\(spec.tool), extraArgs=\(spec.extraArgs)): \(error)")
        }
        throw error
    }
    let queryLatency = Date().timeIntervalSince(queryStart)
    let rawPayload: String? = queryResult.textBlocks.isEmpty ? nil
        : queryResult.textBlocks.joined(separator: "\n")

    unitCompleted = true
    return MemBenchItemResult(
        itemID: item.itemID,
        category: item.category,
        question: item.qa.question,
        queryLatencySeconds: queryLatency,
        retrievedUUIDs: queryResult.orderedIDs,
        manifest: manifest,
        evidenceSids: item.evidenceSids,
        guardHealthy: guardHealthy,
        guardDiagnostic: guardDiagnostic,
        guardSamplingMode: config.guardSamplingPolicy,
        turnsIngested: ingestCount,
        writeMeanLatencySeconds: writeMean,
        payloadText: rawPayload,
        // C9: carry choices and groundTruth through so the scorer can apply
        // selectMultipleChoicePrediction without a corpus lookup at score time.
        choices: item.qa.choices,
        groundTruth: item.qa.groundTruth
    )
}

// MARK: - Batch seed builder

// MARK: - C11 — Token count helper

/// Estimates the total token count of a MemBench item's session corpus.
///
/// Content format mirrors the live-path ingest string ("user: …\nassistant: …")
/// so the estimator accounts for exactly the bytes that reach the estate on
/// both the live and batch paths.
///
/// Uses `lmeEstimateTokens` (UTF-8 ceiling-4), the same estimator used by
/// LME-03 token efficiency and conformance-vectored in token_efficiency_vectors.json.
///
/// Twin of Rust `membench_item_token_count`.
func memBenchItemTokenCount(_ item: MemBenchItem) -> Int {
    var total = 0
    for session in item.sessions {
        for turn in session.turns {
            // Content format is identical to runOneMemBenchItem live-path ingest.
            let content = "user: \(turn.userMessage)\nassistant: \(turn.assistantMessage)"
            total += lmeEstimateTokens(content)
        }
    }
    return total
}

// MARK: - C11 — Capacity tier runner

/// Runs the MemBench harness in capacity-tier mode, growing each item's estate
/// to approximately `targetTokens` with conflict-free filler before the query.
///
/// Strategy:
///   1. Filter, shuffle, and offset/limit the corpus (same as the per-item runner).
///   2. Group ALL filtered items by conflict key using `memBenchGroupItemsByConflictKey`
///      (the C10 grouper — not duplicated here).
///   3. For each selected item X, greedily fill from X's group (excluding X) until
///      the estate reaches `targetTokens` or the pool is exhausted.
///   4. Ingest X's sessions + filler sessions into a fresh per-item estate.
///      Only X's UUID→sid manifest is tracked; filler UUIDs are absent from the
///      manifest and silently skipped by `lmeRankedSessions` during scoring.
///   5. Settle (dream + reindex + drain), guard probe, and query X's QA question.
///
/// The estate cache is intentionally NOT used: a capacity-tier estate's provenance
/// depends on which fillers were selected, which varies with the full corpus and
/// grouping — no single item_id key can represent it.
///
/// - Parameters:
///   - items: Full loaded corpus slice (all items used for conflict-key grouping;
///     only the selected subset actually run through MCP).
///   - config: Immutable run configuration.
///   - targetTokens: Non-zero token target from `config.capacityTier.targetTokens`.
/// - Returns: `(results, timingReport, achievedTokensPerItem, itemsPerEstate)` in
///   original-index order. `achievedTokensPerItem[i]` is the actual estate token
///   count for `results[i]`; `itemsPerEstate[i]` is how many items (1 for X plus
///   any fillers) contributed sessions to that estate.
///
/// Twin of Rust `run_membench_items_capacity_tier`.
///
/// Length note: the body deliberately mirrors the per-item runner's parallel
/// task-group protocol (throttle setup → split-phase dispatch → indexed
/// collection) so the two dispatch paths stay diffable side by side;
/// fragmenting it into sub-functions would break that protocol boundary.
func runMemBenchItemsCapacityTier(
    items: [MemBenchItem],
    config: MemBenchRunConfig,
    targetTokens: Int
) async throws -> (results: [MemBenchItemResult],
                   timingReport: String?,
                   achievedTokensPerItem: [Int],
                   itemsPerEstate: [Int]) {
    // Category filter then shuffle + offset/limit — same discipline as per-item runner.
    let filtered: [MemBenchItem]
    if let category = config.categoryFilter {
        filtered = items.filter { $0.category == category }
    } else {
        filtered = items
    }
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filtered
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [MemBenchItem] = config.limit.map { Array(afterOffset.prefix($0)) } ?? afterOffset

    // Group ALL filtered items so the filler pool reflects the full corpus.
    // Items not in `selected` can still appear as fillers.
    let allGroups = memBenchGroupItemsByConflictKey(filtered)

    // Build an itemID → group-index map for O(1) filler-pool lookup.
    // `let` after full population: Swift 6 region isolation requires the captured
    // dict to be immutable so it is safe to read concurrently inside addTask closures.
    var itemGroupIndexMut: [String: Int] = [:]
    for (gi, g) in allGroups.enumerated() {
        for item in g { itemGroupIndexMut[item.itemID] = gi }
    }
    let itemGroupIndex: [String: Int] = itemGroupIndexMut

    // Pre-compute token counts for every item in the filtered set.
    var tokenCountsMut: [String: Int] = [:]
    for item in filtered { tokenCountsMut[item.itemID] = memBenchItemTokenCount(item) }
    let tokenCounts: [String: Int] = tokenCountsMut

    // Shared leg-level samplers (actors — safe for concurrent callers).
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    let timingSampler = LegTimingSampler()

    // Parallel execution with bounded concurrency (mirrors per-item runner C6).
    var indexedResults: [(Int, MemBenchItemResult, Int, Int)] = []
    indexedResults.reserveCapacity(selected.count)
    try await withThrowingTaskGroup(
        of: (Int, MemBenchItemResult, Int, Int).self
    ) { group in
        var nextToSubmit = 0
        while nextToSubmit < config.parallelUnits, nextToSubmit < selected.count {
            let idx = nextToSubmit
            group.addTask {
                let (r, tokens, cnt) = try await runOneMemBenchItemCapacityTier(
                    item: selected[idx], itemIdx: idx, totalCount: selected.count,
                    config: config, targetTokens: targetTokens,
                    allGroups: allGroups, itemGroupIndex: itemGroupIndex,
                    tokenCounts: tokenCounts,
                    guardSampler: guardSampler, timingSampler: timingSampler)
                return (idx, r, tokens, cnt)
            }
            nextToSubmit += 1
        }
        for try await (completedIdx, result, tokens, cnt) in group {
            indexedResults.append((completedIdx, result, tokens, cnt))
            if nextToSubmit < selected.count {
                let idx = nextToSubmit
                group.addTask {
                    let (r, tokens, cnt) = try await runOneMemBenchItemCapacityTier(
                        item: selected[idx], itemIdx: idx, totalCount: selected.count,
                        config: config, targetTokens: targetTokens,
                        allGroups: allGroups, itemGroupIndex: itemGroupIndex,
                        tokenCounts: tokenCounts,
                        guardSampler: guardSampler, timingSampler: timingSampler)
                    return (idx, r, tokens, cnt)
                }
                nextToSubmit += 1
            }
        }
    }
    let sorted = indexedResults.sorted { $0.0 < $1.0 }
    return (sorted.map(\.1), await timingSampler.text(), sorted.map(\.2), sorted.map(\.3))
}

/// Runs one MemBench item in capacity-tier mode: greedily fills an estate with
/// X's own sessions plus conflict-free filler sessions from X's C10 group.
///
/// Returns `(result, achievedTokens, itemsInEstate)`.
///
/// Length note: this is the full end-to-end per-item measurement protocol —
/// filler-pool build → estate provisioning → ingest (target + fillers) →
/// settle → guard probe → query → collection — and the sequence IS the
/// measurement contract. Sub-functions would scatter the protocol across
/// the file without shortening the contract itself.
private func runOneMemBenchItemCapacityTier(
    item: MemBenchItem,
    itemIdx: Int,
    totalCount: Int,
    config: MemBenchRunConfig,
    targetTokens: Int,
    allGroups: [[MemBenchItem]],
    itemGroupIndex: [String: Int],
    tokenCounts: [String: Int],
    guardSampler: LegGuardSampler,
    timingSampler: LegTimingSampler
) async throws -> (MemBenchItemResult, Int, Int) {
    let tierLabel = config.capacityTier.reportLabel
    FileHandle.standardError.write(Data(
        "[membench-cap\(tierLabel)] item=\(item.itemID) (#\(itemIdx + 1)/\(totalCount))\n".utf8))

    // Filler pool: all items in X's conflict-key group, excluding X itself.
    // The C10 grouper guarantees every pool member has a different conflict key
    // (question text) from X, so no competing answer enters the estate.
    let groupIdx = itemGroupIndex[item.itemID] ?? 0
    let group = allGroups[groupIdx]
    let fillerPool = group.filter { $0.itemID != item.itemID }

    // Greedy fill: accumulate X's token count, then add fillers until the target
    // is reached or the pool is exhausted. Never pad beyond the pool.
    var achievedTokens = tokenCounts[item.itemID] ?? memBenchItemTokenCount(item)
    var selectedFillers: [MemBenchItem] = []
    for filler in fillerPool {
        let ft = tokenCounts[filler.itemID] ?? memBenchItemTokenCount(filler)
        selectedFillers.append(filler)
        achievedTokens += ft
        if achievedTokens >= targetTokens { break }
    }
    let itemsInEstate = 1 + selectedFillers.count

    // Fresh per-item estate: capacity-tier estates are never cached (the filler
    // composition depends on the full corpus and grouping, not a single item_id).
    let scratchDir = try memBenchScratchDir(posture: config.scratchPosture)
    let endpoint = try memBenchEndpointConfig(
        scratchDir: scratchDir, mootBinaryPath: config.mootBinaryPath,
        posture: config.scratchPosture, shape: config.shape)
    // Build-path embedding pre-provisioning: capacity-tier estates are never
    // cached, so the two-session dance always applies when
    // MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set.
    try await preprovisionEmbeddingSlot(scratchDir: scratchDir, endpoint: endpoint)
    let client = MCPClient(endpoint: endpoint, responseDeadline: 600)
    try await client.connect()
    // Retire the estate only when this unit finished. A throw leaves it
    // on disk under a loud notice (see keepScratchEstateOnFailure).
    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            try? retireScratchEstate(
                scratchDir,
                expectPlaintext: config.scratchPosture == .plaintextTransient,
                teardown: memBenchGuardedTeardown)
        } else {
            keepScratchEstateOnFailure(scratchDir, lane: "membench")
        }
    }

    // Ingest: X's turns first (manifest tracked), then filler turns (no manifest).
    // Filler UUIDs are absent from X's manifest; lmeRankedSessions silently skips
    // them, degrading X's retrieval rank — which is exactly what we measure.
    var manifest: [MemBenchManifestEntry] = []
    var writeTimes: [Double] = []

    // Helper: ingest one item's sessions, optionally building the manifest.
    func ingestSessions(of target: MemBenchItem, trackManifest: Bool) async throws {
        for session in target.sessions {
            for turn in session.turns {
                let content = "user: \(turn.userMessage)\nassistant: \(turn.assistantMessage)"
                var writeArgs: [String: JSONValue] = [
                    memBenchMootVerbMap.contentArg: .string(content),
                    "subject": .string(deterministicSubject(content)),
                ]
                for (k, v) in memBenchMootVerbMap.constantArgs {
                    writeArgs[k] = .string(v)
                }
                if config.encodeBarrier == .impatient {
                    writeArgs["impatient"] = .bool(true)
                }
                let writeStart = Date()
                let writeResult = try await client.callTool(
                    memBenchMootVerbMap.write,
                    arguments: writeArgs,
                    format: memBenchMootVerbMap.resultFormat)
                writeTimes.append(Date().timeIntervalSince(writeStart))
                if trackManifest, let uuid = writeResult.writeAssignedID {
                    manifest.append(MemBenchManifestEntry(
                        uuid: uuid,
                        sid: String(turn.sid),
                        sessionIndex: session.sessionIndex))
                }
            }
        }
    }

    try await ingestSessions(of: item, trackManifest: true)
    for filler in selectedFillers {
        try await ingestSessions(of: filler, trackManifest: false)
    }

    // Encode barrier (drain or impatient — mirrors per-item runner).
    if config.encodeBarrier == .drain {
        _ = await waitForEncodeDrain(
            client: client,
            label: "membench-cap\(tierLabel) item=\(item.itemID)")
    }

    // Settle: dream + reindex + drain (mirrors per-item runner B4).
    _ = try await client.callTool(
        AriaV2Surface.dream,
        arguments: ["associates": JSONValue.string("all")],
        format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk)
    _ = try await client.callTool(
        AriaV2Surface.reindex,
        arguments: [:],
        format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk)
    _ = await waitForEncodeDrain(
        client: client,
        label: "membench-cap\(tierLabel) settle item=\(item.itemID)")

    // Timing capture: once per leg (sampler caches the first result).
    _ = await timingSampler.capture { await fetchTimingReport(client: client) }

    // DegeneracyGuard: once per leg (sampler caches the first verdict).
    let (verdict, _) = await guardSampler.probe {
        await probeMCPClient(client, verbMap: memBenchMootVerbMap, name: "mootx01-membench")
    }
    let guardHealthy: Bool
    if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
    let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

    // Query X's QA question against the filled estate.
    // D-2026-08-20-A: seam failure hard-fails the unit with a named error.
    let queryStart = Date()
    let queryResult: MCPToolResult
    do {
        queryResult = try await retrieveThroughSeam(
            item.qa.question, client: client,
            verbMap: memBenchMootVerbMap, spec: config.retrievalCall,
            arm: config.payloadArm)
    } catch {
        if let spec = config.retrievalCall {
            throw MCPError(description:
                "[membench-cap \(item.itemID)] seam call failed "
                + "(tool=\(spec.tool), extraArgs=\(spec.extraArgs)): \(error)")
        }
        throw error
    }
    let queryLatency = Date().timeIntervalSince(queryStart)
    let rawPayload: String? = queryResult.textBlocks.isEmpty ? nil
        : queryResult.textBlocks.joined(separator: "\n")

    let writeMean = writeTimes.isEmpty ? 0.0
        : writeTimes.reduce(0, +) / Double(writeTimes.count)

    let result = MemBenchItemResult(
        itemID: item.itemID,
        category: item.category,
        question: item.qa.question,
        queryLatencySeconds: queryLatency,
        retrievedUUIDs: queryResult.orderedIDs,
        manifest: manifest,
        evidenceSids: item.evidenceSids,
        guardHealthy: guardHealthy,
        guardDiagnostic: guardDiagnostic,
        guardSamplingMode: config.guardSamplingPolicy,
        // turnsIngested counts only X's turns (manifest entries), not fillers.
        // This matches per-item convention and lets the report show how much
        // of X's own content was ingested, independent of filler volume.
        turnsIngested: manifest.count,
        writeMeanLatencySeconds: writeMean,
        payloadText: rawPayload,
        choices: item.qa.choices,
        groundTruth: item.qa.groundTruth)

    unitCompleted = true
    return (result, achievedTokens, itemsInEstate)
}

// MARK: - C10 — Conflict key and group assignment

/// Returns the conflict key for a MemBench item used by Shape 3 group assignment.
///
/// The conflict key is the QA question text. Two items "conflict" — would produce
/// competing answers if queried against the same estate — when they share the same
/// question text. Using question text as the key captures both (rel, attr) pairs for
/// the roles corpus and event_name for the events corpus without regex parsing.
///
/// Twin of Rust `membench_conflict_key`.
func memBenchConflictKey(_ item: MemBenchItem) -> String {
    item.qa.question
}

/// Assigns items to non-overlapping groups using greedy round-robin on conflict key.
///
/// Algorithm: for each item in order, look up how many times its conflict key has
/// appeared so far. Assign the item to that group index (0-based). Increment the
/// key's count. Result: no group contains two items with the same conflict key.
/// The number of groups equals the maximum frequency of any single key value.
///
/// Assignment order is deterministic when `items` is in a deterministic order.
/// Callers should shuffle before grouping when randomisation is wanted.
///
/// Twin of Rust `membench_group_items_by_conflict_key`.
func memBenchGroupItemsByConflictKey(_ items: [MemBenchItem]) -> [[MemBenchItem]] {
    var keyCount: [String: Int] = [:]
    var groups: [[MemBenchItem]] = []
    for item in items {
        let key = memBenchConflictKey(item)
        let groupIndex = keyCount[key, default: 0]
        keyCount[key] = groupIndex + 1
        while groups.count <= groupIndex {
            groups.append([])
        }
        groups[groupIndex].append(item)
    }
    return groups
}

// MARK: - C10 — Consolidated runner (Shape 3)

/// Runs the MemBench harness using the consolidated-estate topology (Shape 3).
///
/// Topology: items are grouped by conflict key (question text) using greedy round-robin
/// so no group contains two items asking the same question. Each group gets ONE shared
/// scratch estate. All items' sessions are ingested into the group estate; the estate
/// is settled once; then each item's question is queried against the shared estate and
/// scored using only THAT item's manifest entries.
///
/// Cross-item UUID noise: when a retrieval query returns UUIDs that belong to another
/// item's sessions, those UUIDs are absent from the querying item's manifest and are
/// silently skipped by `lmeRankedSessions`. The resulting rank degradation is the
/// measurement Shape 3 captures.
///
/// Differences from the per-item runner:
///   - One estate per GROUP (not per item).
///   - Live-path ingest only — direct UUID attribution per write.
///   - Estate cache not supported — group estates span multiple item identities.
///
/// Returns per-item results in group/item order, the timing report, and the groups
/// built (passed to `buildMemBenchReport` for Shape 3 stats).
///
/// Twin of Rust `run_membench_items_consolidated`.
func runMemBenchItemsConsolidated(
    items: [MemBenchItem],
    config: MemBenchRunConfig
) async throws -> (results: [MemBenchItemResult], timingReport: String?, groups: [[MemBenchItem]]) {
    // Category filter: runs BEFORE shuffle/offset/limit (same rule as per-item runner).
    let filtered: [MemBenchItem]
    if let category = config.categoryFilter {
        filtered = items.filter { $0.category == category }
    } else {
        filtered = items
    }

    // Seeded shuffle (same SplitMix64 algorithm as per-item runner).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filtered
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }

    // Apply offset + limit.
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [MemBenchItem] = config.limit.map { Array(afterOffset.prefix($0)) } ?? afterOffset

    // Group by conflict key (question text), greedy round-robin.
    let groups = memBenchGroupItemsByConflictKey(selected)

    // Shared samplers for the leg (actors — safe for concurrent callers).
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    let timingSampler = LegTimingSampler()

    // Compute the absolute ordinal base for each group's results so the final sort
    // reproduces the original group/item assignment order byte-deterministically.
    var groupOrdinalBases: [Int] = []
    var runningBase = 0
    for g in groups {
        groupOrdinalBases.append(runningBase)
        runningBase += g.count
    }

    // Parallel group execution: same sliding-window TaskGroup as the per-item runner
    // but groups replace items as the unit of concurrency.
    var indexedResults: [(Int, MemBenchItemResult)] = []
    indexedResults.reserveCapacity(selected.count)

    try await withThrowingTaskGroup(of: [(Int, MemBenchItemResult)].self) { tg in
        var nextToSubmit = 0
        // Seed the initial wave up to the concurrency cap.
        while nextToSubmit < config.parallelUnits, nextToSubmit < groups.count {
            let gi = nextToSubmit
            let ordinalBase = groupOrdinalBases[gi]
            tg.addTask {
                try await runOneMemBenchGroup(
                    group: groups[gi],
                    groupIndex: gi,
                    totalGroups: groups.count,
                    ordinalBase: ordinalBase,
                    config: config,
                    guardSampler: guardSampler,
                    timingSampler: timingSampler
                )
            }
            nextToSubmit += 1
        }
        // Sliding window: submit the next group each time one completes.
        for try await groupResults in tg {
            indexedResults.append(contentsOf: groupResults)
            if nextToSubmit < groups.count {
                let gi = nextToSubmit
                let ordinalBase = groupOrdinalBases[gi]
                tg.addTask {
                    try await runOneMemBenchGroup(
                        group: groups[gi],
                        groupIndex: gi,
                        totalGroups: groups.count,
                        ordinalBase: ordinalBase,
                        config: config,
                        guardSampler: guardSampler,
                        timingSampler: timingSampler
                    )
                }
                nextToSubmit += 1
            }
        }
    }

    let sortedResults = indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
    return (sortedResults, await timingSampler.text(), groups)
}

/// Provisions one shared scratch estate for a group of items, ingests all sessions,
/// settles the estate, then queries each item individually.
///
/// Each item uses only its OWN manifest (the UUID→sid entries built from that item's
/// ingest turns). Cross-item UUIDs in the retrieval list are absent from the querying
/// item's manifest and are skipped by `lmeRankedSessions`, degrading that item's rank.
///
/// C10 constraints:
///   - Live-path ingest only (no batch path; no per-item record ID disambiguation).
///   - No estate cache (group estates are not identifiable by a single item_id key).
///
/// - Parameters:
///   - group: Items sharing this estate. No two items in the group share a conflict key.
///   - groupIndex: 0-based group position for logging.
///   - totalGroups: Total group count for logging.
///   - ordinalBase: Offset added to each item's in-group index to produce its absolute
///     position in the full result set (for deterministic sort by the consolidated runner).
///   - config: Immutable run configuration.
///   - guardSampler: Shared leg-level guard sampler (actor — safe for concurrent callers).
///   - timingSampler: Shared leg-level timing sampler (actor — safe for concurrent callers).
/// - Returns: Per-item results paired with absolute ordinals, in item order within the group.
private func runOneMemBenchGroup(
    group: [MemBenchItem],
    groupIndex: Int,
    totalGroups: Int,
    ordinalBase: Int,
    config: MemBenchRunConfig,
    guardSampler: LegGuardSampler,
    timingSampler: LegTimingSampler
) async throws -> [(Int, MemBenchItemResult)] {
    let groupLabel =
        "[membench-s3] group=\(groupIndex + 1)/\(totalGroups) items=\(group.count)"
    FileHandle.standardError.write(Data((groupLabel + "\n").utf8))

    // Fresh estate per group — no cache support for Shape 3.
    let scratchDir = try memBenchScratchDir(posture: config.scratchPosture)
    let endpoint = try memBenchEndpointConfig(
        scratchDir: scratchDir, mootBinaryPath: config.mootBinaryPath,
        posture: config.scratchPosture, shape: config.shape)
    // Build-path embedding pre-provisioning: Shape-3 estates are never cached,
    // so the two-session dance always applies when
    // MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set.
    try await preprovisionEmbeddingSlot(scratchDir: scratchDir, endpoint: endpoint)
    let client = MCPClient(endpoint: endpoint, responseDeadline: 600)
    try await client.connect()
    // Retire the estate only when this unit finished. A throw leaves it
    // on disk under a loud notice (see keepScratchEstateOnFailure).
    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            try? retireScratchEstate(
                scratchDir,
                expectPlaintext: config.scratchPosture == .plaintextTransient,
                teardown: memBenchGuardedTeardown
            )
        } else {
            keepScratchEstateOnFailure(scratchDir, lane: "membench")
        }
    }

    // Per-item accumulation: manifests and per-turn write latencies, indexed by
    // position in `group`. Live path gives direct UUID attribution per write.
    var perItemManifests: [[MemBenchManifestEntry]] = Array(repeating: [], count: group.count)
    var perItemWriteTimes: [[Double]] = Array(repeating: [], count: group.count)

    // Ingest all sessions from ALL items into the shared estate.
    for (itemIdx, item) in group.enumerated() {
        for session in item.sessions {
            for turn in session.turns {
                let content = "user: \(turn.userMessage)\nassistant: \(turn.assistantMessage)"
                var writeArgs: [String: JSONValue] = [
                    memBenchMootVerbMap.contentArg: .string(content),
                    "subject": .string(deterministicSubject(content)),
                ]
                for (k, v) in memBenchMootVerbMap.constantArgs {
                    writeArgs[k] = .string(v)
                }
                if config.encodeBarrier == .impatient {
                    writeArgs["impatient"] = .bool(true)
                }
                let writeStart = Date()
                let writeResult = try await client.callTool(
                    memBenchMootVerbMap.write,
                    arguments: writeArgs,
                    format: memBenchMootVerbMap.resultFormat
                )
                perItemWriteTimes[itemIdx].append(Date().timeIntervalSince(writeStart))
                if let uuid = writeResult.writeAssignedID {
                    perItemManifests[itemIdx].append(MemBenchManifestEntry(
                        uuid: uuid,
                        sid: String(turn.sid),
                        sessionIndex: session.sessionIndex
                    ))
                }
            }
        }
    }

    // Encode barrier: wait after all group ingest completes.
    if config.encodeBarrier == .drain {
        _ = await waitForEncodeDrain(
            client: client, label: "membench-s3 group=\(groupIndex)")
    }

    // Settle: dream + reindex + drain. Mirrors per-item runner settle (B4).
    _ = try await client.callTool(
        AriaV2Surface.dream,
        arguments: ["associates": JSONValue.string("all")],
        format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk)
    _ = try await client.callTool(
        AriaV2Surface.reindex,
        arguments: [:],
        format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk)
    _ = await waitForEncodeDrain(
        client: client, label: "membench-s3 settle group=\(groupIndex)")

    // Timing capture: once per leg, sampler caches the first result.
    _ = await timingSampler.capture { await fetchTimingReport(client: client) }

    // DegeneracyGuard probe: once per leg, sampler caches the first verdict.
    let (verdict, _) = await guardSampler.probe {
        await probeMCPClient(client, verbMap: memBenchMootVerbMap, name: "mootx01-membench")
    }
    let guardHealthy: Bool
    if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
    let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

    // Query each item individually, using only its own per-item manifest.
    var results: [(Int, MemBenchItemResult)] = []
    for (itemIdx, item) in group.enumerated() {
        let queryArgs = AriaV2Surface.memorySearchArgs(verbMap: memBenchMootVerbMap, query: item.qa.question)
        let queryStart = Date()
        let queryResult = try await client.callTool(
            memBenchMootVerbMap.query,
            arguments: queryArgs,
            format: memBenchMootVerbMap.resultFormat
        )
        let queryLatency = Date().timeIntervalSince(queryStart)
        let rawPayload: String? = queryResult.textBlocks.isEmpty
            ? nil : queryResult.textBlocks.joined(separator: "\n")

        let itemWriteTimes = perItemWriteTimes[itemIdx]
        let writeMean = itemWriteTimes.isEmpty ? 0.0
            : itemWriteTimes.reduce(0, +) / Double(itemWriteTimes.count)

        let result = MemBenchItemResult(
            itemID: item.itemID,
            category: item.category,
            question: item.qa.question,
            queryLatencySeconds: queryLatency,
            retrievedUUIDs: queryResult.orderedIDs,
            manifest: perItemManifests[itemIdx],
            evidenceSids: item.evidenceSids,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            guardSamplingMode: config.guardSamplingPolicy,
            turnsIngested: perItemManifests[itemIdx].count,
            writeMeanLatencySeconds: writeMean,
            payloadText: rawPayload,
            choices: item.qa.choices,
            groundTruth: item.qa.groundTruth
        )
        results.append((ordinalBase + itemIdx, result))
    }
    unitCompleted = true
    return results
}

