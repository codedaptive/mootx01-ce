import Foundation

// LoCoMoRunner.swift — LoCoMo turn-recall harness (Part 2).
//
// This lane is MEASURE-ONLY and differs from LongMemEvalRunner in one key
// architectural way: LoCoMo uses PER-CONVERSATION estates (not per-question),
// because each conversation has ~154 questions that all share the same 700+
// turns as their evidence base. Each conversation's pre-built estate artifact
// is restored from the cache; a miss is a hard failure
// (ArtifactRequiredError), never a fresh build. Artifacts are built by the
// seeding pipeline (benchmarks/seeding/seed_locomo.py, BENCHMARK_ESTATES.md).
//
// Safety guarantees (parallel to LME):
//   - loCoMoScratchDir(posture:) uses the /tmp/locomo-bench- prefix.
//   - loCoMoGuardedTeardown() refuses any path without that prefix.
//   - The EndpointConfig carries --db /tmp/locomo-bench-... so
//     assertScratchBackend independently verifies the scratch constraint.
//
// Manifest correlation:
//   - The restored artifact's manifest maps UUID → dia_id (e.g. "D1:3").
//   - The scorer uses lmeRankedSessions (math is string-agnostic) to map
//     retrieved UUIDs → ranked dia_ids for recall scoring against evidence sets.

// MARK: - Verbmap for mootx01 in LoCoMo mode

/// Standard mootx01 VerbMap for LoCoMo ingestion + recall queries.
/// Mirrors the LME verbMap with a LoCoMo-specific location.
///
/// write:         moot_file_memory
/// query:         moot_memory_search
/// constantArgs:  { "location": "benchmarks/locomo" }
/// resultFormat:  .mootV2
let loCoMoMootVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: ["location": "benchmarks/locomo"],
    resultFormat: .mootV2
)

// MARK: - Estate shape

/// Backend persistence shape for LoCoMo benchmark estates.
///
/// Selects the mootx01 backend via the `--in-memory` serve flag
/// injected into the serve command. The two shapes produce identical recall
/// semantics but differ in disk footprint and estate-cache compatibility:
///
/// - `.disk` (default): SQLite-backed estate. Compatible with `--estate-cache reuse|require`.
/// - `.ram`: In-memory estate (`--in-memory`). No disk writes; no
///   keychain contact. Incompatible with `--estate-cache reuse|require` because an
///   ephemeral estate cannot be snapshotted.
///
/// The shape is recorded in the report JSON as the `"shape"` field.
enum LoCoMoEstateShape: String, Sendable {
    /// Disk-backed SQLite estate (default). Compatible with estate cache.
    case disk
    /// In-memory estate. Injects `--in-memory` into the serve
    /// command. Zero disk I/O; incompatible with `--estate-cache reuse|require`.
    case ram
}

// MARK: - Recall strategy

/// Which MCP verb is used for LoCoMo recall queries.
///
/// `.search` (default) uses bare `moot_memory_search` with the `location:benchmarks/locomo`
/// constant arg — byte-stable, byte-identical to all prior LoCoMo runs. Existing
/// invocations that omit `--strategy` always land here.
///
/// `.shaped` calls `moot_recall_shaped`, which steers the signed-weight fusion
/// engine. No location constant arg — shaped recall operates globally on the
/// estate's index. An optional named preset is selected with `--recall-shape`.
///
/// `.precise` calls `moot_recall_precise`, the precision-retrieval mode. No
/// location constant arg.
///
/// Every emitted cell label embeds the strategy name so search/shaped/precise
/// results are distinguishable in the published report.
enum LoCoMoRecallStrategy: String, Sendable {
    case search
    case shaped
    case precise
    /// Two-pass conversational multi-hop (item 12): decompose → pools →
    /// RRF-intersect, with a bridge re-query when the pools are disjoint.
    /// See LoCoMoMultiHop.swift for the design and determinism notes.
    case multihop
    /// Graph-diffusion multi-hop (item 12, iteration 2): one
    /// moot_recall_connected call — the product's scored anchor + walk
    /// over tunnels ∪ dream associations. The recipe owns the math; the
    /// harness just asks.
    case connected
}

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin turn, enabling the scorer to
/// correlate retrieved UUIDs → dia_ids for turn-level recall scoring.
struct LoCoMoManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The dia_id of the turn (e.g. "D1:3" = session 1, 3rd dialog turn).
    let diaID: String
    /// 1-based session number this turn belongs to.
    let sessionNumber: Int
    /// 0-based index of this turn within its session.
    let turnIndex: Int
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    let speaker: String
}

// MARK: - Per-question result

/// The result of querying the harness with one LoCoMo question.
struct LoCoMoQuestionResult: Sendable {
    /// Synthetic question identifier (e.g. "conv-26_q3").
    let questionID: String
    /// Conversation this question came from. Carried so the run summary counts
    /// the conversations ACTUALLY sampled — the summary previously derived
    /// this from the unshuffled corpus prefix, which always reported 1.
    let conversationIndex: Int
    /// Category label: "single_hop" | "temporal" | "multi_hop" | "open_domain".
    let categoryLabel: String
    /// Raw integer category (1-4).
    let category: Int
    /// Time taken for the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double
    /// UUIDs returned by moot_memory_search, in ranked order.
    let retrievedUUIDs: [String]
    /// Manifest mapping UUID → dia_id for every ingested turn in this conversation's estate.
    /// Shared across all questions for the same conversation.
    let manifest: [LoCoMoManifestEntry]
    /// Ground-truth dia_ids that contain evidence for this question.
    let evidenceDiaIDs: [String]
    /// True when the DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// If the guard was unhealthy, the diagnostic message.
    let guardDiagnostic: String?
    /// Guard sampling policy active during this leg.
    let guardSamplingMode: GuardSamplingPolicy
    /// Total turns ingested into this conversation's estate.
    let turnsIngested: Int
    /// Mean write latency across all turns for this conversation's estate.
    let writeMeanLatencySeconds: Double
    /// Raw payload text (joined textBlocks) from the moot_memory_search response.
    /// Used by the report builder to compute tokens_per_result and provenance_summary.
    /// Nil when the MCP response carried no textBlocks.
    let payloadText: String?
    /// Whether this question's estate was served from the artifact cache.
    /// Always true in this measure-only lane: a run either restores every
    /// conversation's artifact or hard-fails before producing a result.
    /// One conversation estate is shared by all questions.
    let cacheHit: Bool?
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// (Shape B response) before accepting idle. false = converged via the
    /// no-lanes grace window (ambiguous evidence). nil = barrier did not run
    /// (barrier != drain, or estate restored from cache). Shared per
    /// conversation, like cacheHit.
    let drainLaneObserved: Bool?
}

// MARK: - Run config

/// Configuration for one LoCoMo run.
struct LoCoMoRunConfig: Sendable {
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Path to the LoCoMo dataset JSON file (locomo10.json).
    let datasetPath: URL
    /// Maximum number of questions to run. nil = all scoreable questions.
    let limit: Int?
    /// Skip this many questions from the (seeded-shuffled) question list.
    let offset: Int
    /// --ids: pinned debug-subset unit IDs (nil = whole corpus).
    var unitIDs: Set<String>? = nil
    /// Optional retrieval-call override (environment seam; see
    /// RetrievalCallSpec.swift). When set it replaces the .search
    /// strategy's query call; named strategies are explicit paths.
    var retrievalCall: RetrievalCallSpec? = nil
    /// Payload-economics shape-variant arm (--payload-arm /
    /// MOOT_BENCH_PAYLOAD_ARM; see PayloadArm.swift). Applied by
    /// retrieveThroughSeam to the seam result's textBlocks so judged-output
    /// row text carries the arm's field subset. nil = full ruled payload.
    var payloadArm: PayloadArm? = nil
    /// Seed for deterministic question shuffling.
    let seed: UInt64
    /// Directory to write the results report. nil = current directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
    /// Encode-queue synchronization strategy. Controls whether ingest uses inline
    /// encoding (impatient), a post-ingest drain barrier (drain, default), or no
    /// barrier (none). Recorded in the report JSON as "encode_barrier".
    let encodeBarrier: EncodeBarrier
    /// Estate snapshot reuse mode (--estate-cache). Defaults to .off (fresh ingest
    /// every run). .reuse snapshots after ingest+encode and copies on cache hits.
    let estateCache: EstateCacheMode
    /// Root directory for estate snapshots (--cache-dir). nil = <outDir>/estate-cache
    /// (or <cwd>/estate-cache when outDir is also nil).
    let cacheDir: URL?
    /// At-rest posture for scratch estates. Default plaintextTransient: writes
    /// each scratch dir as a transient catalog record (plaintext by rule) before serve
    /// launch (no keychain contact). --estate-mode encrypted selects
    /// encryptedEphemeral (temporal in-process key). Recorded in the report
    /// JSON as "estate_encryption".
    let scratchPosture: ScratchEstatePosture
    // MARK: Recall strategy (additive — PR-08)
    /// MCP verb used for queries. Default `.search` is byte-stable with all prior
    /// LoCoMo runs. `.shaped` and `.precise` add STRATEGY CELLS beside the
    /// default; all three are distinguishable via the run label and report field.
    let strategy: LoCoMoRecallStrategy
    /// Optional category filter (--category): "single_hop" | "temporal" |
    /// "multi_hop" | "open_domain". Applied BEFORE offset/limit so a limit
    /// counts questions of the requested category — the multi-hop cell would
    /// otherwise be unmeasurable at quick-run sizes (the first 50 shuffled
    /// questions carry only 2 multi-hop members). nil = all categories.
    /// A filtered run is its own cell: the report's category breakdown makes
    /// the composition explicit.
    let categoryFilter: String?
    /// Named preset for `strategy == .shaped`. nil uses the product's default
    /// (balanced, unsteered). Validated against `lmeRecallShapePresets` at parse.
    let recallShape: String?
    // MARK: Rerank (additive — W2-rerank)
    /// Optional command for post-retrieval reranking. When set, the top
    /// `rerankWindowSize` hits from the query are handed to this command before
    /// scoring. The command reads a numbered candidate prompt on stdin and writes
    /// a permutation of candidate numbers on stdout (exit 0).
    ///
    /// The command is recorded as PRESENCE ONLY in the report (`rerank_cmd_set`).
    /// It may carry API keys; never log, hash, or derive any value from it.
    let rerankCmd: String?
    /// Seed-file loading mode (--seed-path). `.batch` (default) emits a
    /// schema-v1 JSON file and loads with one `moot_json_import` — zero
    /// per-turn network calls. `.live` retains the original per-turn
    /// `moot_file_memory` path for periodic equivalence re-proving.
    let seedPath: SeedPathMode
    /// Guard sampling policy for this leg. Default `.oncePerLeg` probes on the
    /// first question only; use `.perUnit` to restore per-question behavior for
    /// debugging.
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
    /// SHA-256 of the corpus fixture file (B2 provenance). Computed once at
    /// CLI load time; "unknown" when unreadable (never validates).
    var corpusDigest: String = "unknown"
    // MARK: C1/C6 additions (benchmark reset 2026-08-13)
    /// Backend persistence shape (--shape disk|ram). `.disk` (default) uses the
    /// normal SQLite backend. `.ram` injects `--in-memory` into the
    /// serve command and is incompatible with `--estate-cache reuse|require`.
    /// Recorded in the report JSON as `"shape"`.
    var shape: LoCoMoEstateShape = .disk
    /// Maximum number of conversations to process concurrently (--parallel N).
    /// Default = max(1, 80% of logical cores). 1 = today's serial behaviour.
    /// Each concurrent conversation runs its own estate + client; the
    /// per-question inner loop stays serial within a conversation.
    /// Recorded in the report JSON as `"parallel_units"`.
    var parallelConversations: Int = max(1, ProcessInfo.processInfo.activeProcessorCount * 4 / 5)
}

// MARK: - Scratch estate management

/// Creates a fresh, hardened scratch directory under /tmp/locomo-bench-<UUID>
/// for LoCoMo use. The /tmp/locomo-bench- prefix is the contract with
/// `loCoMoGuardedTeardown`.
///
/// Hardening added in E3 (mirrors memBenchScratchDir):
/// - Symlink check after creation: a symlink at the target path is rejected so
///   an attacker cannot redirect scratch writes to real data.
/// - `resolvingSymlinksInPath()` canonicalizes `..` components; the canonical
///   URL is returned and re-checked against the expected prefix.
///
/// - Parameter posture: At-rest posture for the estate this dir will hold
///   (see ScratchPosture.swift). No default value on purpose: every call
///   site decides posture explicitly.
/// - Returns: The canonical URL of the created directory.
/// - Throws: `MCPError` when directory creation or the symlink guard fails.
func loCoMoScratchDir(posture: ScratchEstatePosture) throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/locomo-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description: "loCoMoScratchDir: could not create \(path): \(error)")
    }

    // Reject symlinks placed at the target path before or during creation.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "loCoMoScratchDir: SAFETY: '\(path)' is a symlink — "
            + "refusing to use as scratch estate")
    }

    // Canonicalize and verify the resolved path stays within the expected prefix.
    let canonical = url.resolvingSymlinksInPath()
    let canonicalPath = canonical.path
    guard canonicalPath.hasPrefix("/tmp/locomo-bench-") else {
        throw MCPError(description:
            "loCoMoScratchDir: SAFETY: canonicalized path '\(canonicalPath)' "
            + "escapes /tmp/locomo-bench-")
    }

    return canonical
}

/// Deletes a scratch directory created by `loCoMoScratchDir`. Refuses any path
/// without the `/tmp/locomo-bench-` prefix and refuses symlinks — belt and
/// suspenders on top of the creation-time guards.
///
/// - Parameter url: The canonical scratch directory URL from `loCoMoScratchDir`.
/// - Throws: `MCPError` when the prefix guard or symlink guard fires.
func loCoMoGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/locomo-bench-") else {
        throw MCPError(description:
            "SAFETY: loCoMoGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/locomo-bench- prefix. "
            + "Only directories created by loCoMoScratchDir(posture:) may be torn down by this guard.")
    }
    // Belt-and-suspenders symlink check (matches memBenchGuardedTeardown).
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "SAFETY: loCoMoGuardedTeardown refused symlink '\(path)' — "
            + "only real directories may be torn down")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data(
            "[locomo] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a LoCoMo scratch estate.
///
/// - Parameters:
///   - shape: Estate backend shape. `.ram` injects `--in-memory`
///     into the command env so mootx01 selects the InMemory PersistenceKit backend.
///     `.disk` (default) produces the normal SQLite-backed estate.
func loCoMoEndpointConfig(scratchDir: URL, mootBinaryPath: String,
                          posture: ScratchEstatePosture,
                          shape: LoCoMoEstateShape = .disk) throws -> EndpointConfig {
    // `--in-memory` routes mootx01 to PersistenceKit's InMemory backend
    // when shape is `.ram`. Placed after the posture prefix and before MOOTX01_VAULT
    // so mootx01 sees it at startup before vault decisions are made.
    // The env-prefix token (empty for plaintext) declares the temporal-key
    // posture to serve; the stdio launcher runs the command through `env`.
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: scratchDir, inMemory: shape == .ram, environment: scratchServeEnvironment)
    let endpoint = EndpointConfig(
        name: "mootx01-locomo",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: loCoMoMootVerbMap,
        role: .target
    )
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
    return endpoint
}

// MARK: - Runner

/// Runs the LoCoMo harness against a loaded corpus. Returns per-question
/// results with manifest, latency, and guard verdict for each question.
///
/// Per-conversation estate strategy:
///   1. Select and shuffle the question list.
///   2. For each conversation that has ≥1 selected question:
///      a. Restore the conversation's pre-built estate artifact (hard-fail on miss).
///      b. Run the DegeneracyGuard probe via LegGuardSampler (real call on the first conversation of the leg only; cached verdict after).
///      c. For each selected question in this conversation, issue a query.
///      d. Tear down the estate.
///
/// Questions are processed in conversation order (deterministic given the shuffle),
/// not the shuffled order — the shuffle only selects which questions to include.
func runLoCoMoQuestions(
    questions: [LoCoMoQuestion],
    conversations: [LoCoMoConversation],
    config: LoCoMoRunConfig
) async throws -> (results: [LoCoMoQuestionResult], rerankFailures: Int, timingReport: String?) {
    // --ids pinned subset (before shuffle: same file → same units always).
    let questions = try filterUnits(
        questions, ids: config.unitIDs, id: { $0.questionID }, lane: "locomo")
    // Category filter runs BEFORE the shuffle/offset/limit so a limit counts
    // questions of the requested category (see LoCoMoRunConfig.categoryFilter).
    let filtered: [LoCoMoQuestion]
    if let category = config.categoryFilter {
        filtered = questions.filter { $0.categoryLabel == category }
    } else {
        filtered = questions
    }

    // Apply offset + limit to the seeded-shuffled question list.
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filtered
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [LoCoMoQuestion]
    if let limit = config.limit {
        selected = Array(afterOffset.prefix(limit))
    } else {
        selected = afterOffset
    }

    // Group selected questions by conversation index. Use a dict of [Int: [LoCoMoQuestion]]
    // preserving insertion order (each group retains the shuffled order of its members).
    var questionsByConversation: [Int: [LoCoMoQuestion]] = [:]
    for q in selected {
        questionsByConversation[q.conversationIndex, default: []].append(q)
    }


    // Cache-mode setup (reuse only; zero cost when estateCache == .off).
    // B2: one provenance per run (see makeArtifactProvenance).
    let runProvenance = makeArtifactProvenance(
        benchmark: "locomo",
        variant: "",
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

    // Conversation indices in ascending order. Results are collected per-conversation
    // and re-assembled in this order after parallel processing, producing
    // byte-deterministic output regardless of task completion order (C6).
    let convIndices = questionsByConversation.keys.sorted()

    // One sampler shared across all concurrent conversations. LegGuardSampler is
    // an actor — all concurrent `await guardSampler.probe { ... }` calls are
    // automatically serialized by the Swift runtime. The first conversation to
    // run a real probe caches the verdict; all subsequent ones pay zero MCP cost.
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    // C4: one timing sampler for the leg — captures the audit-derived timing
    // report from the first freshly-settled estate (INGEST samples + four CYCLE
    // tiers). Shared across concurrent conversations via actor serialisation;
    // the first conversation to reach the settled estate issues the fetch, all
    // others return the cached text at zero MCP cost.
    let timingSampler = LegTimingSampler()

    // Bounded parallel execution (C6): process up to config.parallelConversations
    // conversations concurrently. Each conversation owns its own estate and MCP
    // client; the per-question inner loop stays serial within a conversation.
    // Results are keyed by conversation index and re-assembled in ascending
    // convIndex order after the group completes.
    //
    // Error semantics (cross-port asymmetry, intentional): a per-conversation
    // error propagates through withThrowingTaskGroup and ABORTS the run —
    // Swift is the measurement instrument and refuses a report with holes.
    // The Rust twin records a stub result (guard_healthy=false) and continues,
    // localizing a parity diff to the failing item.
    var resultsByConvIndex: [Int: [LoCoMoQuestionResult]] = [:]
    resultsByConvIndex.reserveCapacity(convIndices.count)
    var totalRerankFailures = 0

    try await withThrowingTaskGroup(of: (Int, [LoCoMoQuestionResult], Int).self) { group in
        // Seed the initial wave: up to parallelConversations tasks at once.
        var remaining = convIndices[...]
        let initialBatch = min(config.parallelConversations, remaining.count)
        for _ in 0..<initialBatch {
            let ci = remaining.removeFirst()
            let convQuestions = questionsByConversation[ci]!
            let conversation = conversations[ci]
            group.addTask {
                try await loCoMoConversationTask(
                    convIndex: ci, convQuestions: convQuestions,
                    conversation: conversation, config: config,
                    resolvedCacheDir: resolvedCacheDir, runProvenance: runProvenance,
                    guardSampler: guardSampler, timingSampler: timingSampler)
            }
        }
        // As each task finishes, store its results and launch the next conversation.
        for try await (ci, convResults, convRerankFailures) in group {
            resultsByConvIndex[ci] = convResults
            totalRerankFailures += convRerankFailures
            if !remaining.isEmpty {
                let ci2 = remaining.removeFirst()
                let convQuestions2 = questionsByConversation[ci2]!
                let conversation2 = conversations[ci2]
                group.addTask {
                    try await loCoMoConversationTask(
                        convIndex: ci2, convQuestions: convQuestions2,
                        conversation: conversation2, config: config,
                        resolvedCacheDir: resolvedCacheDir, runProvenance: runProvenance,
                        guardSampler: guardSampler, timingSampler: timingSampler)
                }
            }
        }
    }

    // Reassemble in ascending convIndex order (byte-deterministic output).
    let allResults = convIndices.flatMap { resultsByConvIndex[$0] ?? [] }
    return (allResults, totalRerankFailures, await timingSampler.text())
}

// MARK: - Per-conversation task body

/// Executes one conversation's estate lifecycle: provision, ingest, settle, probe,
/// query, teardown. Returns `(convIndex, results, rerankFailures)`.
///
/// Extracted from `runLoCoMoQuestions` so `withThrowingTaskGroup` can dispatch
/// multiple conversations concurrently while keeping the per-question inner loop
/// serial within each conversation. The signature is `async throws` so errors
/// surface through the task group without swallowing context.
///
/// - Parameters:
///   - convIndex: The conversation's index in the corpus (key for result assembly).
///   - convQuestions: Selected questions for this conversation.
///   - conversation: The full `LoCoMoConversation` value.
///   - config: Run-level configuration (shared, read-only across all tasks).
///   - resolvedCacheDir: Resolved cache root, pre-computed once in the caller.
///   - runProvenance: Artifact provenance token, pre-computed once in the caller.
///   - guardSampler: Shared leg-level guard sampler (actor — safe across tasks).
///   - timingSampler: Shared leg-level timing sampler (actor — safe across tasks). C4.
private func loCoMoConversationTask(
    convIndex: Int,
    convQuestions: [LoCoMoQuestion],
    conversation: LoCoMoConversation,
    config: LoCoMoRunConfig,
    resolvedCacheDir: URL,
    runProvenance: ArtifactProvenance,
    guardSampler: LegGuardSampler,
    timingSampler: LegTimingSampler
) async throws -> (Int, [LoCoMoQuestionResult], Int) {
    var convResults: [LoCoMoQuestionResult] = []
    var rerankFailures = 0

    // Measure-only provisioning: restore this conversation's pre-built estate
    // artifact, or hard-fail. LoCoMo uses one estate per conversation; all
    // questions in a conversation share it, so cache granularity is
    // per-conversation (keyed by sampleID). Estate building is owned by the
    // seeding pipeline (benchmarks/seeding/); a miss — under any --estate-cache
    // mode, including off — is ArtifactRequiredError, never a fresh build.
    let manifest: [LoCoMoManifestEntry]

    let cacheEntry = estateCacheEntryURL(
        cacheDir: resolvedCacheDir,
        benchmark: "locomo",
        variant: "",
        seed: config.seed,
        encodeBarrier: config.encodeBarrier,
        posture: config.scratchPosture,
        seedPath: config.seedPath,
        unitID: conversation.sampleID
    )
    guard config.estateCache.readsCache,
          let (activeScratchDir, hit): (URL, [LoCoMoManifestEntry]) =
              try restoreEstateCacheEntry(
                  from: cacheEntry,
                  expectedProvenance: runProvenance,
                  scratchDirFactory: { try loCoMoScratchDir(posture: config.scratchPosture) })
    else {
        throw ArtifactRequiredError(entryPath: cacheEntry.path)
    }
    manifest = hit

    let endpoint = try loCoMoEndpointConfig(
        scratchDir: activeScratchDir, mootBinaryPath: config.mootBinaryPath,
        posture: config.scratchPosture,
        shape: config.shape)
    // Embedding-provider seam on restored estates is verified by
    // verifyEmbeddingProviderSeam inside restoreEstateCacheEntry.
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    // Retire the estate only when this conversation finished. A throw leaves
    // it on disk under a loud notice (see keepScratchEstateOnFailure).
    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            // Retirement = teardown + zero-residual-key verification.
            try? retireScratchEstate(activeScratchDir, expectPlaintext: config.scratchPosture == .plaintextTransient, teardown: loCoMoGuardedTeardown)
        } else {
            keepScratchEstateOnFailure(activeScratchDir, lane: "locomo")
        }
    }

        let convLabel = "[locomo] conv=\(conversation.sampleID) (\(convQuestions.count) questions, "
            + "\(conversation.allTurns.count) turns, restored)"
        FileHandle.standardError.write(Data((convLabel + "\n").utf8))

        // The restored artifact is settled by construction (the seeding
        // pipeline builds import → drain → dream → reindex → drain); this
        // lane never ingests, settles, or snapshots. drainLaneObserved is
        // nil because the drain barrier does not run on a restored estate.
        let drainLaneObserved: Bool? = nil
        // No writes happen on a restored estate; write latency is a
        // build-time property of the artifact, not of this run.
        let writeMean = 0.0
        // The restored manifest names every record the seeding pipeline
        // imported for this conversation, so its count is the ingested count.
        let ingestCount = manifest.count

        // DegeneracyGuard probe — delegated to the leg sampler.
        // Probes on the first conversation; caches the verdict for all subsequent
        // conversations. The guard validates the binary under test — a frozen-ranking
        // binary would be frozen on every estate, so caching across conversations is valid.
        let (verdict, _) = await guardSampler.probe {
            await probeMCPClient(client, verbMap: loCoMoMootVerbMap, name: "mootx01-locomo")
        }
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic


        // Issue a query for each question in this conversation.
        for question in convQuestions {
            // Strategy dispatch: which MCP verb is called for this run's queries.
            //
            // .search (default): moot_memory_search with location:benchmarks/locomo — the
            //   byte-stable path used by all prior LoCoMo runs. Existing invocations
            //   are unchanged and produce identical output to pre-PR-08 builds.
            //
            // .shaped: moot_recall_shaped — steers the signed-weight fusion engine.
            //   Operates globally on the estate index (no location constant arg).
            //   An optional preset is passed when recallShape is non-nil.
            //
            // .precise: moot_recall_precise — precision-retrieval mode. No location arg.
            //
            // The strategy name is embedded in the run label and the report so every
            // cell is unambiguously identified in the published output.
            let queryStart = Date()
            var retrievedIDs: [String] = []
            // Individual text blocks parallel to retrievedIDs — used as rerank
            // previews. Multihop fuses multiple search passes; individual blocks
            // are not available from the fusion output so we leave this empty
            // for that strategy (reranker receives empty previews, IDs still provided).
            var rawTextBlocks: [String] = []
            let rawPayload: String?
            switch config.strategy {
            case .search:
                // Environment seam: an override spec replaces the standard
                // query call; nil is byte-identical to the verb-map path.
                // D-2026-08-20-A: seam failure hard-fails the unit with a
                // named error that identifies the conversation and seam args.
                do {
                    let queryResult = try await retrieveThroughSeam(
                        question.question, client: client,
                        verbMap: loCoMoMootVerbMap, spec: config.retrievalCall,
                        arm: config.payloadArm)
                    retrievedIDs = queryResult.orderedIDs
                    rawTextBlocks = queryResult.textBlocks
                    rawPayload = queryResult.textBlocks.isEmpty ? nil
                        : queryResult.textBlocks.joined(separator: "\n")
                } catch {
                    if let spec = config.retrievalCall {
                        throw MCPError(description:
                            "[locomo \(conversation.sampleID) q=\(question.questionID)] "
                            + "seam call failed (tool=\(spec.tool), "
                            + "extraArgs=\(spec.extraArgs)): \(error)")
                    }
                    throw error
                }
            case .shaped:
                var shapedArgs: [String: JSONValue] = [
                    loCoMoMootVerbMap.queryArg: .string(question.question),
                ]
                if let preset = config.recallShape { shapedArgs["preset"] = .string(preset) }
                let queryResult = try await client.callTool(
                    AriaV2Surface.recallShaped,
                    arguments: shapedArgs,
                    format: loCoMoMootVerbMap.resultFormat
                )
                retrievedIDs = queryResult.orderedIDs
                rawTextBlocks = queryResult.textBlocks
                rawPayload = queryResult.textBlocks.isEmpty ? nil
                    : queryResult.textBlocks.joined(separator: "\n")
            case .precise:
                let preciseArgs: [String: JSONValue] = [
                    loCoMoMootVerbMap.queryArg: .string(question.question),
                ]
                let queryResult = try await client.callTool(
                    AriaV2Surface.recallPrecise,
                    arguments: preciseArgs,
                    format: loCoMoMootVerbMap.resultFormat
                )
                retrievedIDs = queryResult.orderedIDs
                rawTextBlocks = queryResult.textBlocks
                rawPayload = queryResult.textBlocks.isEmpty ? nil
                    : queryResult.textBlocks.joined(separator: "\n")
            case .multihop:
                // Two-pass multi-hop (LoCoMoMultiHop.swift): the driver owns
                // decomposition/fusion/bridging; the closures own the wire.
                // Ranked ids come from the FUSION, not any single call, so
                // retrieval metrics score the strategy's actual output.
                let outcome = try await runMultiHopStrategy(
                    question: question.question,
                    search: { query in
                        let queryArgs = AriaV2Surface.memorySearchArgs(verbMap: loCoMoMootVerbMap, query: query)
                        let result = try await client.callTool(
                            loCoMoMootVerbMap.query,
                            arguments: queryArgs,
                            format: loCoMoMootVerbMap.resultFormat
                        )
                        return result.orderedIDs
                    },
                    hydrate: { id in
                        let full = try await client.callTool(
                            AriaV2Surface.memoryGet,
                            arguments: AriaV2Surface.memoryGetArgs(memoryId: id),
                            format: loCoMoMootVerbMap.resultFormat
                        )
                        return full.textBlocks.joined(separator: "\n")
                    }
                )
                retrievedIDs = outcome.ids
                // rawTextBlocks intentionally left empty: multihop fuses multiple
                // search passes; individual per-ID blocks are not available from
                // the fusion outcome. The reranker receives IDs but empty previews.
                rawPayload = outcome.payload
            case .connected:
                // The product's graph-diffusion recall. Wing "benchmark" is
                // the ingest location's wing ("benchmarks/locomo" = wing/room),
                // so the walk sees this corpus's dream-built associations.
                let result = try await client.callTool(
                    AriaV2Surface.recallConnected,
                    arguments: [
                        loCoMoMootVerbMap.queryArg: .string(question.question),
                        "wing": .string("benchmark"),
                    ],
                    format: loCoMoMootVerbMap.resultFormat
                )
                retrievedIDs = result.orderedIDs
                rawTextBlocks = result.textBlocks
                rawPayload = result.textBlocks.isEmpty ? nil
                    : result.textBlocks.joined(separator: "\n")
            }
            let queryLatency = Date().timeIntervalSince(queryStart)

            // Post-retrieval reranking — inserts between retrieval and scoring.
            // Operates on retrievedIDs; rawPayload is kept unchanged for diagnostics.
            if let rerankCmd = config.rerankCmd {
                let (reranked, failed) = applyRerank(
                    cmd: rerankCmd,
                    question: question.question,
                    ids: retrievedIDs,
                    previews: rawTextBlocks
                )
                retrievedIDs = reranked
                if failed { rerankFailures += 1 }
            }

            convResults.append(LoCoMoQuestionResult(
                questionID: question.questionID,
                conversationIndex: question.conversationIndex,
                categoryLabel: question.categoryLabel,
                category: question.category,
                queryLatencySeconds: queryLatency,
                retrievedUUIDs: retrievedIDs,
                manifest: manifest,
                evidenceDiaIDs: question.evidence,
                guardHealthy: guardHealthy,
                guardDiagnostic: guardDiagnostic,
                guardSamplingMode: config.guardSamplingPolicy,
                turnsIngested: ingestCount,
                writeMeanLatencySeconds: writeMean,
                payloadText: rawPayload,
                cacheHit: true,
                drainLaneObserved: drainLaneObserved
            ))
        }
    // Teardown happens via defer above; return this conversation's results.
    unitCompleted = true
    return (convIndex, convResults, rerankFailures)
}
