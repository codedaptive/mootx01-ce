import Foundation

// LongMemEvalRunner.swift — LongMemEval session-recall harness (Part 4).
//
// This runner OWNS the test-estate lifecycle: for each question it provisions
// a fresh scratch estate under /tmp/lme-bench-XXXXXX, launches mootx01 with
// MOOTX01_DATA_DIR pointing at it, ingests haystack sessions via live MCP write,
// queries via live MCP query, records the manifest, and tears down the estate.
//
// Safety guarantees:
//   - lmeScratchDir(posture:) names the dir with /tmp/lme-bench- so the teardown guard
//     can distinguish LME scratch dirs from arbitrary /tmp directories.
//   - lmeGuardedTeardown() refuses any path that does not carry the
//     /tmp/lme-bench- prefix; a non-scratch path cannot be passed by mistake.
//   - The built EndpointConfig always carries MOOTX01_DATA_DIR=/tmp/lme-bench-...
//     so assertScratchBackend (GauntletCLI.swift) independently verifies the
//     scratch constraint before any write begins.
//
// Estate strategies:
//   - --fresh-per-question (default): each question gets its own scratch estate.
//     Correct isolation, but slower: O(N) estate provisions.
//   - --shared-estate: all questions share one estate provisioned before the run.
//     Faster, but haystack contamination across questions is methodology-affecting
//     (prior sessions' content can influence recall for later questions).

// MARK: - Recall arm

/// Which recall arm(s) the LME token-efficiency benchmark exercises.
enum LMEArm: String, Sendable, Codable {
    /// Only the exact-recall arm — `moot_memory_search` with full content payload.
    case exact
    /// Only the dense-recall arm — `moot_recall_distilled` with distilled factoid payload.
    case dense
    /// Both arms per question, same estate, same ingest (default).
    case both
}

// MARK: - Verbmap for mootx01 in LME mode

/// Standard mootx01 VerbMap used for LME ingestion + exact recall queries.
/// Matches the live E2E test's mootEndpoint verbMap convention.
///
/// write:         moot_file_memory
/// query:         moot_memory_search
/// constantArgs:  { "location": "benchmark/longmemeval" }
/// resultFormat:  .mootText
let lmeMootVerbMap = EndpointConfig.VerbMap(
    write: "moot_file_memory",
    query: "moot_memory_search",
    list: nil,
    constantArgs: ["location": "benchmark/longmemeval"],
    resultFormat: .mootText
)

/// Dense recall VerbMap for the token-efficiency benchmark.
/// Uses `moot_recall_distilled`, which:
///   - Returns ~10-token distilled factoid prose per hit (capped at ~300 chars)
///   - Requires `moot_consolidate` to be called BEFORE the first dense query
///   - Does NOT use a location constant arg (queries the estate-default wing)
///
/// write:         moot_file_memory  (same ingest tool as lmeMootVerbMap)
/// query:         moot_recall_distilled
/// constantArgs:  {} (no location needed)
/// resultFormat:  .mootText
let lmeDenseMootVerbMap = EndpointConfig.VerbMap(
    write: "moot_file_memory",
    query: "moot_recall_distilled",
    list: nil,
    constantArgs: [:],
    resultFormat: .mootText
)

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin in the haystack, enabling the
/// scorer to correlate retrieved UUIDs → session IDs for recall scoring.
struct LMEManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The haystack session this turn belongs to.
    let sessionID: String
    /// Zero-based index of this turn within its session.
    let turnIndex: Int
    /// Zero-based index of the session within the question's haystack.
    let sessionIndex: Int
    /// The turn's role: "user" or "assistant".
    let role: String
}

// MARK: - Per-question result

/// The result of running the LME harness against one question.
/// Optional dense-arm fields are nil when arm = .exact (dense was not run).
/// Optional exact-arm payload text is nil when arm = .dense (exact was not run).
struct LMEQuestionResult: Sendable {
    /// The question's unique identifier.
    let questionID: String
    /// The question type (non-abstention: not *_abs).
    let questionType: String
    /// Time taken for the exact-arm moot_memory_search call, in seconds.
    /// nil when arm = .dense.
    let queryLatencySeconds: Double?
    /// UUIDs returned by moot_memory_search, in ranked order. Empty when arm = .dense.
    let retrievedUUIDs: [String]
    /// Manifest: filed UUID → haystack position for every ingested turn.
    let manifest: [LMEManifestEntry]
    /// Ground truth session IDs that contain evidence for this question.
    let answerSessionIDs: [String]
    /// True when the DegeneracyGuard ran and found the backend healthy.
    /// False means guard refusal — this question's result is excluded from
    /// aggregate scoring.
    let guardHealthy: Bool
    /// If the guard was unhealthy, the diagnostic message.
    let guardDiagnostic: String?
    /// Total number of turns ingested for this question's haystack.
    let turnsIngested: Int
    /// Mean write latency (seconds) across all ingested turns.
    let writeMeanLatencySeconds: Double
    /// Raw payload text from the exact-arm moot_memory_search call.
    /// The joined textBlocks from the MCPToolResult — used by Part 2's token
    /// estimator and evidence scorer. nil when arm = .dense.
    let exactPayloadText: String?
    /// Raw payload text from the dense-arm moot_recall_distilled call.
    /// Contains distilled factoid prose (~300 chars/factoid cap).
    /// nil when arm = .exact.
    let densePayloadText: String?
    /// Time taken for the dense-arm moot_recall_distilled call, in seconds.
    /// nil when arm = .exact.
    let denseQueryLatencySeconds: Double?
    // MARK: Judge mode fields (Part 4, LME-03)
    /// Judge subprocess answer for the exact arm. nil when judgeCmd was not set
    /// or the exact arm was not run.
    let exactJudgeAnswer: String?
    /// True when exactJudgeAnswer contains the normalized gold answer as a substring.
    /// nil when exactJudgeAnswer is nil.
    let exactJudgeCorrect: Bool?
    /// Judge subprocess answer for the dense arm. nil when judgeCmd was not set
    /// or the dense arm was not run.
    let denseJudgeAnswer: String?
    /// True when denseJudgeAnswer contains the normalized gold answer as a substring.
    /// nil when denseJudgeAnswer is nil.
    let denseJudgeCorrect: Bool?
    /// Whether this question's estate was served from the snapshot cache.
    /// true = cache hit (ingest skipped), false = cache miss (ingest ran + snapshot saved).
    /// nil = --estate-cache off (cache not in use for this run).
    let cacheHit: Bool?
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// (Shape B response) before accepting idle. false = the barrier converged
    /// via the no-lanes grace window without ever seeing the lane — ambiguous
    /// evidence (tiny corpus finished early, or lane never wired). nil = the
    /// drain barrier did not run for this question (barrier != drain, or the
    /// estate was restored from cache and ingest was skipped).
    let drainLaneObserved: Bool?
}

// MARK: - Run config

/// Configuration for one LME run. Built from CLI arguments in `runLongMemEval`.
struct LMERunConfig: Sendable {
    /// Path to the mootx01 binary. The runner launches it as a stdio MCP server
    /// with MOOTX01_DATA_DIR set to the provisioned scratch estate.
    let mootBinaryPath: String
    /// Path to the LongMemEval variant JSON file (e.g. longmemeval_s_cleaned.json).
    let datasetPath: URL
    /// Variant name for report labelling ("s", "m", or "oracle").
    let variant: String
    /// Maximum number of questions to run. nil = all non-abstention questions.
    let limit: Int?
    /// Skip this many questions from the (seeded-shuffled) question list.
    let offset: Int
    /// Seed for deterministic question shuffling and run reproducibility.
    let seed: UInt64
    /// When true (default), each question gets its own fresh scratch estate.
    /// When false, a single shared estate is used for all questions in the run.
    let freshPerQuestion: Bool
    /// Directory to write the results report. nil = current directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
    /// Which recall arm(s) to benchmark. Default .both runs exact + dense per question.
    let arm: LMEArm
    /// Optional judge command for LLM-judged QA mode. When set, the harness runs
    /// the command subprocess per arm per question (prompt on stdin, answer on stdout)
    /// and grades deterministically against the gold `answer`. Off by default.
    let judgeCmd: String?
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
    /// At-rest posture for scratch estates. Default plaintextOptOut: the runner
    /// writes mootx01's `no-encrypt` marker into each scratch data dir before
    /// serve launch so the estate is created plaintext (no keychain contact).
    /// --no-plaintext-scratch selects encryptedDefault. Recorded in the report
    /// JSON as "estate_encryption".
    let scratchPosture: ScratchEstatePosture
    /// Exact-arm retrieval strategy (--exact-strategy). Follows the program's
    /// documented client protocol; see the strategy comment at the query site.
    let exactStrategy: ExactRecallStrategy
}

/// How the exact arm drives the estate's recall surface.
/// The program's tool descriptions are the client contract:
/// - .search    — bare moot_memory_search (LEGACY harness behavior; the tool
///                self-describes as broad/time-ordered retrieval).
/// - .relevance — moot_memory_search with ordering:byRelevanceDesc (the
///                documented setting "for relevance-ranked results").
/// - .precise   — moot_recall_precise (the documented precision-retrieval mode).
/// - .auto      — DEFAULT: relevance-ordered search, escalating to
///                moot_recall_precise when the response reports
///                "discrimination: low" — exactly the escalation the tool
///                descriptions instruct clients to perform.
enum ExactRecallStrategy: String, Sendable, Codable {
    case search
    case relevance
    case precise
    case auto
}

// MARK: - Scratch estate management

/// Creates a fresh scratch directory under /tmp/lme-bench-<UUID> for LME use.
/// The /tmp/lme-bench- prefix is the contract with `lmeGuardedTeardown`.
///
/// The UUID suffix guarantees uniqueness across concurrent runs without needing
/// mkdtemp(3) or a subprocess call.
///
/// - Parameter posture: At-rest posture for the estate this dir will hold.
///   `plaintextOptOut` writes mootx01's `no-encrypt` marker into the dir
///   BEFORE any serve launch (see ScratchPosture.swift). No default value on
///   purpose: every call site decides posture explicitly.
/// - Returns: The URL of the created directory.
/// - Throws: `MCPError` when directory or marker creation fails.
func lmeScratchDir(posture: ScratchEstatePosture) throws -> URL {
    // Build a unique path with the /tmp/lme-bench- prefix.
    // The 8-character UUID prefix gives 32-bit entropy (4B combinations) —
    // more than sufficient for sequential benchmark runs on one machine.
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/lme-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description: "lmeScratchDir: could not create \(path): \(error)")
    }
    try applyScratchPosture(posture, to: url)
    return url
}

/// Deletes a scratch directory created by `lmeScratchDir`. Refuses any path
/// that does not carry the `/tmp/lme-bench-` prefix — a contamination guard
/// that mirrors commit 253cebf1's fixture-cleanup guard.
///
/// - Parameter url: The scratch directory to remove.
/// - Throws: `MCPError` when the prefix guard fires. Does NOT throw on
///   FileManager errors (missing dir is a no-op; actual I/O failures are
///   swallowed and logged to stderr).
func lmeGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/lme-bench-") else {
        throw MCPError(description:
            "SAFETY: lmeGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/lme-bench- prefix. "
            + "Only directories created by lmeScratchDir(posture:) may be torn down by this guard.")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        // Log but do not propagate: a missing or already-deleted scratch dir is
        // not a correctness failure, and a teardown error should not mask the
        // benchmark result.
        FileHandle.standardError.write(Data(
            "[lme] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a scratch estate.
/// The command form is `MOOTX01_DATA_DIR=<scratchDir> <mootBinaryPath>` which:
///   1. Passes assertScratchBackend (scratchDir is always /tmp/lme-bench-*).
///   2. Tells the MCPClient how to launch the server (stdio transport).
///
/// - Parameters:
///   - scratchDir: A directory created by `lmeScratchDir(posture:)`.
///   - mootBinaryPath: Path to the mootx01 binary.
/// - Returns: A validated EndpointConfig for this estate.
/// - Throws: `MCPError` via assertScratchBackend when the config does not meet
///   the scratch safety constraint (should not happen for lmeScratchDir output).
func lmeEndpointConfig(scratchDir: URL, mootBinaryPath: String) throws -> EndpointConfig {
    let command = "MOOTX01_DATA_DIR=\(scratchDir.path) \(mootBinaryPath)"
    let endpoint = EndpointConfig(
        name: "mootx01-lme",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmeMootVerbMap,
        role: .target
    )
    // Validate scratch constraint before returning — belt-and-suspenders.
    try assertScratchBackend(endpoint)
    return endpoint
}

// MARK: - Runner

/// Runs the LongMemEval harness against a loaded corpus. Returns per-question
/// results with manifest, latency, and guard verdict for each question.
///
/// This function is the implementation of the `longmemeval` subcommand's inner
/// loop. The CLI dispatch in main.swift wraps it with argument parsing and report
/// writing.
func runLMEQuestions(
    questions: [LMEQuestion],
    config: LMERunConfig
) async throws -> [LMEQuestionResult] {
    // Apply offset + limit to the (seeded-shuffled) question list.
    // SplitMix64 is the fleet-standard seeded PRNG (GauntletRNG.swift).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = questions
    // Fisher-Yates shuffle using SplitMix64 for determinism.
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let sliced: [LMEQuestion]
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    var results: [LMEQuestionResult] = []
    results.reserveCapacity(sliced.count)

    // Cache-mode setup (reuse only; zero cost when estateCache == .off).
    // Binary fingerprint is computed once per run so all questions share it.
    let binaryFingerprint: String = config.estateCache == .reuse
        ? mootBinaryFingerprint(config.mootBinaryPath) : ""
    let resolvedCacheDir: URL = config.cacheDir ?? defaultCacheDir(outDir: config.outDir)

    // Shared-estate path: provision once and reuse for all questions.
    var sharedScratch: URL?
    var sharedClient: MCPClient?
    if !config.freshPerQuestion {
        let scratch = try lmeScratchDir(posture: config.scratchPosture)
        sharedScratch = scratch
        let endpoint = try lmeEndpointConfig(scratchDir: scratch, mootBinaryPath: config.mootBinaryPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        sharedClient = client
    }
    defer {
        if !config.freshPerQuestion {
            if let client = sharedClient {
                Task { await client.disconnect() }
            }
            if let scratch = sharedScratch {
                try? lmeGuardedTeardown(scratch)
            }
        }
    }

    for question in sliced {
        // --- Cache-aware estate provisioning ---
        // For fresh-per-question runs in reuse mode, attempt a cache restore before
        // provisioning a new estate. On hit: the restored scratch dir is ready for
        // querying without re-ingest. On miss: normal fresh ingest + snapshot after drain.
        var manifest: [LMEManifestEntry] = []
        var writeTimes: [Double] = []
        var questionCacheHit: Bool? = nil  // nil when cache is off
        var cacheEntryForSnapshot: URL? = nil  // set on miss; used for snapshot after drain

        let (client, scratch): (MCPClient, URL?)
        if config.freshPerQuestion {
            var freshScratch: URL

            if config.estateCache == .reuse {
                let cacheEntry = estateCacheEntryURL(
                    cacheDir: resolvedCacheDir,
                    benchmark: "lme",
                    variant: config.variant,
                    seed: config.seed,
                    encodeBarrier: config.encodeBarrier,
                    binaryFingerprint: binaryFingerprint,
                    posture: config.scratchPosture,
                    unitID: question.questionID
                )
                if let (restored, hit): (URL, [LMEManifestEntry]) =
                    restoreEstateCacheEntry(
                        from: cacheEntry,
                        expectedPosture: config.scratchPosture,
                        scratchDirFactory: { try lmeScratchDir(posture: config.scratchPosture) }) {
                    // Cache hit: restored scratch dir contains the post-ingest estate
                    // (including the posture marker, which travels with the snapshot).
                    freshScratch = restored
                    manifest = hit  // pre-populate manifest from snapshot
                    questionCacheHit = true
                } else {
                    // Cache miss: fresh estate; snapshot to cache after ingest + drain.
                    freshScratch = try lmeScratchDir(posture: config.scratchPosture)
                    questionCacheHit = false
                    cacheEntryForSnapshot = cacheEntry
                }
            } else {
                freshScratch = try lmeScratchDir(posture: config.scratchPosture)
            }

            let endpoint = try lmeEndpointConfig(scratchDir: freshScratch,
                                                  mootBinaryPath: config.mootBinaryPath)
            let freshClient = MCPClient(endpoint: endpoint)
            try await freshClient.connect()
            client = freshClient
            scratch = freshScratch
        } else {
            client = sharedClient!
            scratch = nil
        }
        // Defer teardown for this question's estate.
        defer {
            if config.freshPerQuestion {
                Task { await client.disconnect() }
                if let s = scratch { try? lmeGuardedTeardown(s) }
            }
        }

        // Ingest haystack sessions: write each turn via live moot_file_memory.
        // Skipped on cache hit (manifest and estate already restored from snapshot).
        let skipIngest = (questionCacheHit == true)
        // Drain-barrier lane evidence for this question. nil when the barrier
        // did not run (barrier != drain, or ingest skipped on cache hit).
        var drainLaneObserved: Bool? = nil
        if !skipIngest {
        for (sessionIndex, session) in question.haystackSessions.enumerated() {
            let sessionID = question.haystackSessionIDs[sessionIndex]
            for (turnIndex, turn) in session.enumerated() {
                // Compose the turn content as "role: content" to preserve speaker context.
                let content = "\(turn.role): \(turn.content)"
                var writeArgs: [String: JSONValue] = [
                    lmeMootVerbMap.contentArg: .string(content),
                ]
                for (k, v) in lmeMootVerbMap.constantArgs {
                    writeArgs[k] = .string(v)
                }
                // Encode barrier: impatient mode sends impatient:true so the backend
                // encodes inline before each write returns. For drain mode (default),
                // writes proceed without the flag and a single drain barrier is applied
                // after the full ingest loop. For none, no barrier — documents the race.
                // Previously this code sent "n":true, which was silently ignored by the
                // product because the correct key is "impatient".
                if config.encodeBarrier == .impatient {
                    writeArgs["impatient"] = .bool(true)
                }
                let writeStart = Date()
                let writeResult = try await client.callTool(
                    lmeMootVerbMap.write,
                    arguments: writeArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                let writeDuration = Date().timeIntervalSince(writeStart)
                writeTimes.append(writeDuration)

                if let uuid = writeResult.writeAssignedID {
                    manifest.append(LMEManifestEntry(
                        uuid: uuid,
                        sessionID: sessionID,
                        turnIndex: turnIndex,
                        sessionIndex: sessionIndex,
                        role: turn.role
                    ))
                }
            }
        }

        // Encode barrier (drain mode): after all haystack turns are ingested, poll
        // moot_drain_status until the encode queue is idle before issuing any recall
        // query. This serializes ingest → encode → query without per-write latency.
        // The drain poll is a no-op for impatient and none modes.
        if config.encodeBarrier == .drain {
            let outcome = await waitForEncodeDrain(
                client: client,
                label: "lme \(question.questionID)"
            )
            drainLaneObserved = outcome.laneObserved
        }
        } // end if !skipIngest

        // Snapshot to cache on cache miss: after ingest + encode barrier, the estate
        // is in a fully-committed state. Copy it to the cache entry so future runs
        // with the same key skip ingest entirely.
        if let ce = cacheEntryForSnapshot, let s = scratch {
            saveEstateCacheEntry(estateScratchDir: s, manifest: manifest, to: ce)
        }

        // DegeneracyGuard probe: issue ≥3 distinct probes before scoring.
        // Uses the same probe queries and classification as the gauntlet path.
        // Always probes via the exact verbMap (moot_memory_search) regardless of arm —
        // the guard verifies estate health, not arm-specific retrieval quality.
        let guard_ = DegeneracyGuard()
        let probeVerbMap = lmeMootVerbMap
        let probeRankings = await probeMCPClient(client, verbMap: probeVerbMap, name: "mootx01-lme")
        let verdict = guard_.classify(probeRankings: probeRankings)
        // Use pattern matching: Verdict has associated values so `==` is unavailable.
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

        let writeMean = writeTimes.isEmpty ? 0.0 : writeTimes.reduce(0, +) / Double(writeTimes.count)

        // Exact arm query: moot_memory_search.
        // ORDER IS LOAD-BEARING: the exact-arm query MUST run before any
        // moot_consolidate. Consolidation is not read-only — it subsumes source
        // drawers into distilled factoids, after which the originals no longer
        // surface in default search (proven 2026-07-27: LME q1 answer at rank 2
        // pre-consolidate, absent from top-20 post-consolidate, 330 factoids).
        // Consolidating first contaminates the exact-arm measurement; it
        // depressed 1.1.x any@5 from ~0.85-shape to ~0.6 across two full grids.
        var exactPayloadText: String? = nil
        var exactQueryLatency: Double? = nil
        var retrievedUUIDs: [String] = []
        if config.arm == .exact || config.arm == .both {
            // Exact-arm strategy follows the PROGRAM'S OWN client protocol
            // (the tool descriptions are the client contract):
            //   - moot_memory_search self-describes as "best for broad or
            //     time-ordered retrieval; use ordering:byRelevanceDesc for
            //     relevance-ranked results" — so relevance ordering is the
            //     correct default for a recall benchmark, not the bare call.
            //   - every response carries a discrimination signal; the docs say
            //     low discrimination on small estates is expected and clients
            //     should "prefer moot_recall_precise for precision retrieval".
            // .auto implements exactly that documented escalation. .search
            // preserves the old bare call for comparison runs.
            let queryStart = Date()
            var queryArgs: [String: JSONValue] = [
                lmeMootVerbMap.queryArg: .string(question.question),
            ]
            for (k, v) in lmeMootVerbMap.constantArgs { queryArgs[k] = .string(v) }
            if config.exactStrategy == .relevance || config.exactStrategy == .auto {
                queryArgs["ordering"] = .string("byRelevanceDesc")
            }
            if config.exactStrategy == .precise {
                let preciseResult = try await client.callTool(
                    "moot_recall_precise",
                    arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = preciseResult.orderedIDs
                exactPayloadText = preciseResult.textBlocks.joined(separator: "\n")
            } else {
                let queryResult = try await client.callTool(
                    lmeMootVerbMap.query,
                    arguments: queryArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = queryResult.orderedIDs
                exactPayloadText = queryResult.textBlocks.joined(separator: "\n")
                // Documented escalation: low discrimination → recall_precise.
                if config.exactStrategy == .auto,
                   exactPayloadText?.contains("discrimination: low") == true {
                    let preciseResult = try await client.callTool(
                        "moot_recall_precise",
                        arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                        format: lmeMootVerbMap.resultFormat
                    )
                    if !preciseResult.orderedIDs.isEmpty {
                        retrievedUUIDs = preciseResult.orderedIDs
                        exactPayloadText = preciseResult.textBlocks.joined(separator: "\n")
                    }
                }
            }
            exactQueryLatency = Date().timeIntervalSince(queryStart)
        }

        // Dense arm: build distilled representations via moot_distill, then query
        // moot_recall_distilled. Runs strictly AFTER the exact arm (see the
        // ordering note above) because distillation mutates what default
        // search returns.
        var densePayloadText: String? = nil
        var denseQueryLatency: Double? = nil
        if config.arm == .dense || config.arm == .both {
            let _ = try await client.callTool(
                "moot_distill",
                arguments: [:],
                format: .mootText
            )
            var denseArgs: [String: JSONValue] = [
                lmeDenseMootVerbMap.queryArg: .string(question.question),
            ]
            for (k, v) in lmeDenseMootVerbMap.constantArgs { denseArgs[k] = .string(v) }
            let denseStart = Date()
            let denseResult = try await client.callTool(
                lmeDenseMootVerbMap.query,
                arguments: denseArgs,
                format: lmeDenseMootVerbMap.resultFormat
            )
            denseQueryLatency = Date().timeIntervalSince(denseStart)
            // Capture raw payload text for Part 2 token counting and evidence scoring.
            densePayloadText = denseResult.textBlocks.joined(separator: "\n")
        }

        // Judge mode (Part 4): optional LLM-judged QA per arm.
        // Soft errors (failed subprocess, non-zero exit) are logged and skipped —
        // a judge failure does not fail the question; the answer fields stay nil.
        var exactJudgeAnswer: String? = nil
        var exactJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = exactPayloadText,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                exactJudgeAnswer = answer
                exactJudgeCorrect = lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (exact) for \(question.questionID): \(error)\n".utf8))
            }
        }

        var denseJudgeAnswer: String? = nil
        var denseJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = densePayloadText,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                denseJudgeAnswer = answer
                denseJudgeCorrect = lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (dense) for \(question.questionID): \(error)\n".utf8))
            }
        }

        results.append(LMEQuestionResult(
            questionID: question.questionID,
            questionType: question.questionType,
            queryLatencySeconds: exactQueryLatency,
            retrievedUUIDs: retrievedUUIDs,
            manifest: manifest,
            answerSessionIDs: question.answerSessionIDs,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            turnsIngested: manifest.count,
            writeMeanLatencySeconds: writeMean,
            exactPayloadText: exactPayloadText,
            densePayloadText: densePayloadText,
            denseQueryLatencySeconds: denseQueryLatency,
            exactJudgeAnswer: exactJudgeAnswer,
            exactJudgeCorrect: exactJudgeCorrect,
            denseJudgeAnswer: denseJudgeAnswer,
            denseJudgeCorrect: denseJudgeCorrect,
            cacheHit: questionCacheHit,
            drainLaneObserved: drainLaneObserved
        ))
    }

    return results
}

// MARK: - Default mootx01 binary discovery

/// Probes candidate binary paths in order and returns the first executable one.
/// Falls back to `~/.mootx01/bin/mootx01` (installed binary) then to the CE
/// debug build (relative to the current working directory at invocation time).
///
/// The caller may override with `--mootx01-binary` to short-circuit this search.
func discoverMootBinary() -> String? {
    let candidates = [
        "\(NSHomeDirectory())/.mootx01/bin/mootx01",
        // CE debug build path (swift build --package-path apps/mootx01).
        // The debug path varies by build system; try both Xcode-style and SPM-style.
        ".build/out/Products/Debug/mootx01",
        ".build/debug/mootx01",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
