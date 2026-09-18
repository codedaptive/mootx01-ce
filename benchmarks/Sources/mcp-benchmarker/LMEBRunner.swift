import Foundation

// LMEBRunner.swift — LMEB/ConvoMem retrieval harness.
//
// This runner OWNS the test-estate lifecycle: for each query it provisions a
// fresh scratch estate under /tmp/lmeb-bench-XXXXXX, launches mootx01 with
// --db pointing at it, ingests candidate documents via live MCP
// write, queries via live MCP query, records the UUID→docID manifest, scores,
// and tears down the estate.
//
// Key differences from LongMemEvalRunner.swift:
//   - Ground truth is a SET OF DOCUMENT IDs (not session IDs). The retrieval
//     scope per query is the scene's candidate pool (10–168 docs), not all 500k.
//   - Scratch dir prefix is /tmp/lmeb-bench- (distinct from /tmp/lme-bench-).
//   - VerbMap location is "benchmarks/lmeb" (distinct from "benchmarks/longmemeval").
//   - Each corpus doc is ingested as a single moot_file_memory call; there is
//     no session/turn structure.
//
// Safety guarantees:
//   - lmebScratchDir(posture:) names the dir with /tmp/lmeb-bench- so the teardown
//     guard can distinguish LMEB scratch dirs from arbitrary /tmp directories.
//   - lmebGuardedTeardown() refuses any path without the /tmp/lmeb-bench- prefix.
//   - The built EndpointConfig always carries --db /tmp/lmeb-bench-...
//     so assertScratchBackend (GauntletCLI.swift) independently verifies the
//     scratch constraint before any write begins.

// MARK: - VerbMap

/// Standard mootx01 VerbMap used for LMEB ingestion + recall queries.
///
/// location: "benchmarks/lmeb" scopes all writes to the LMEB namespace —
/// distinct from the longmemeval namespace so the two benchmarks never share
/// content when run on the same estate.
let lmebMootVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: ["location": "benchmarks/lmeb"],
    resultFormat: .mootV2
)

// MARK: - Run shape

/// Whether the LMEB run uses an in-RAM estate or a normal on-disk estate.
///
/// .disk (default): standard mootx01 SQLite-backed estate — same as all prior
/// published LMEB numbers. .ram: injects --in-memory into the
/// serve environment so mootx01 selects PersistenceKit's InMemory backend;
/// no keychain contact, no SQLite I/O. Incompatible with --estate-cache
/// reuse|require (a RAM estate is not a snapshottable artifact).
enum BenchRunShape: String, Sendable {
    /// Normal on-disk SQLite estate (default). Compatible with estate cache.
    case disk
    /// In-RAM estate via --in-memory. No cache permitted.
    case ram
}

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin doc in the candidate pool.
/// Codable so it can round-trip through estate cache manifest.json.
struct LMEBManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The corpus document ID this ingestion represents.
    let docID: String
}

// MARK: - Per-query result

/// The raw result of running the LMEB harness against one query.
struct LMEBQueryResult: Sendable {
    /// Query identifier, e.g. "scene_42_q_0".
    let queryID: String
    /// Time taken for the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double
    /// Doc IDs retrieved by moot_memory_search, in ranked order (UUID→docID mapped).
    /// Unmapped UUIDs occupy their rank slot as NUL-prefixed placeholders so rank
    /// positions of mapped hits are preserved. With a complete manifest (batch path
    /// using return_id_map), no placeholder is ever emitted.
    let retrievedDocIDs: [String]
    /// Ground-truth relevant document IDs for this query.
    let relevantDocIDs: Set<String>
    /// True when the DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// Diagnostic message when the guard was not healthy.
    let guardDiagnostic: String?
    /// Sampling policy that determined whether this unit issued its own probe or
    /// used the cached verdict from the first unit of the leg.
    let guardSamplingMode: GuardSamplingPolicy
    /// Total number of candidate docs ingested for this query.
    let docsIngested: Int
    /// Mean write latency (seconds) across all ingested docs.
    let writeMeanLatencySeconds: Double
    /// Raw payload text (joined textBlocks) from the moot_memory_search response.
    /// Used by the report builder to compute tokens_per_result and provenance_summary.
    /// Nil when the MCP response carried no textBlocks.
    let payloadText: String?
    /// Whether this query's estate was served from the snapshot cache.
    /// true = cache hit (ingest skipped), false = cache miss (ingest ran + snapshot saved).
    /// nil = --estate-cache off (cache not in use for this run).
    let cacheHit: Bool?
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// (Shape B response) before accepting idle. false = converged via the
    /// no-lanes grace window (ambiguous evidence). nil = barrier did not run
    /// (barrier != drain, or estate restored from cache).
    let drainLaneObserved: Bool?
    // MARK: Judge fields (additive — W4-lmeb-accuracy)
    /// LLM judge's answer for this query's question. Nil when judgeCmd was not
    /// set, when the query lacked a gold answer, or when the judge subprocess failed.
    let judgeAnswer: String?
    /// Whether the judge answer was graded CORRECT under the run's grading mode.
    /// Nil when judgeAnswer is nil (i.e. judge did not run for this query).
    let judgeCorrect: Bool?
    /// Estimated tokens in the judge context payload (top-K corpus doc texts).
    /// Nil when the judge did not run for this query.
    let judgeTokens: Int?
}

// MARK: - Run config

/// Configuration for one LMEB run.

struct LMEBRunConfig: Sendable {
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Root data directory (contains one subdirectory per evidence type).
    let dataDir: URL
    /// Evidence types to include, e.g. ["user_evidence", "preference_evidence"].
    let evidenceTypes: [String]
    /// Maximum number of queries to run. nil = all queries.
    let limit: Int?
    /// Skip this many queries from the (seeded-shuffled) list.
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
    /// Seed for deterministic query shuffling.
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
    // MARK: Judge fields (additive — W4-lmeb-accuracy)
    /// Judge subprocess command (e.g. "claude -p"). Nil = judge mode off.
    /// SECRECY RULE: only boolean presence is written to the report
    /// (judge_cmd_set). The command text itself — which may carry API keys —
    /// is never logged, hashed, or partially printed.
    let judgeCmd: String?
    /// How the judge answer is graded: substring containment (.substring) or
    /// an explicit CORRECT/INCORRECT verdict via a second judge call (.verdict).
    let judgeGrading: LMEJudgeGrading
    /// Number of top-ranked corpus docs to include in the judge context payload.
    /// Defaults to lmeDefaultJudgePayloadHydrationDepth (10). Unlike the LME arm,
    /// LMEB hydration reads directly from the corpus — no moot_memory_get needed.
    let judgeHydrationDepth: Int
    /// Path to write the pre-judge JSONL payload file (`--dump-judge-inputs`).
    /// When set, the runner appends one JSON line per query (after writing a
    /// header line before the loop) capturing the judge payload before teardown.
    /// nil = do not write.
    let dumpJudgeInputsPath: String?
    /// How the seed loads into the estate. `.batch` (default, ruling 8D5B8053):
    /// emit seed-file schema v1 → one `moot_json_import` with `return_id_map: true`
    /// → encode barrier → full-manifest ranked attribution via `seedIDMap()`;
    /// unmapped UUIDs hold their rank slot as NUL-prefixed placeholders rather
    /// than being dropped. `.live` is the retained
    /// slow lane (per-doc `moot_file_memory`) kept for periodic equivalence
    /// re-proving. The two cells are NOT interchangeable in published numbers.
    var seedPath: SeedPathMode = .batch
    /// Guard probe sampling policy for this leg.
    ///
    /// Default `.oncePerLeg`: the guard probes the first query only and caches
    /// the verdict for the rest of the leg, cutting 3 × (N-1) unnecessary MCP
    /// search calls from an N-query leg. Use `.perUnit` only for debugging.
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
    /// SHA-256 digest of the corpus fixture inputs (B2 provenance). Computed
    /// once at CLI load time; "unknown" when unreadable (never validates).
    var corpusDigest: String = "unknown"
    /// Estate storage shape for this run: .disk (default, standard on-disk SQLite)
    /// or .ram (--in-memory, no keychain, no cache permitted).
    /// Recorded in the report JSON as "shape".
    var shape: BenchRunShape = .disk
    /// Effective number of concurrent units (C6). 1 = serial (previous behavior).
    /// Set from --parallel N; default = max(1, 80% of logical cores) at CLI parse
    /// time. Recorded in the report JSON as "parallel_units".
    var parallelUnits: Int = 1
}

// MARK: - Scratch estate management

/// Creates a fresh scratch directory under /tmp/lmeb-bench-<12hex> for LMEB use.
///
/// The /tmp/lmeb-bench- prefix is the contract with `lmebGuardedTeardown`.
/// The UUID suffix guarantees uniqueness across concurrent runs.
///
/// - Parameter posture: At-rest posture for the estate this dir will hold
///   (see ScratchPosture.swift). No default value on purpose: every call
///   site decides posture explicitly.
func lmebScratchDir(posture: ScratchEstatePosture) throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/lmeb-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description: "lmebScratchDir: could not create \(path): \(error)")
    }
    return url
}

/// Deletes a scratch directory created by `lmebScratchDir`. Refuses any path
/// that does not carry the `/tmp/lmeb-bench-` prefix — mirrors the safety
/// guard in `lmeGuardedTeardown` (commit f5e51a50).
func lmebGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/lmeb-bench-") else {
        throw MCPError(description:
            "SAFETY: lmebGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/lmeb-bench- prefix. "
            + "Only directories created by lmebScratchDir(posture:) may be torn down by this guard.")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data(
            "[lmeb] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - Concurrent dump-file writer

/// Serializes concurrent JSONL appends to the pre-judge dump file.
///
/// Multiple Swift tasks sharing this actor queue each `append` call onto the
/// actor's serial executor, which prevents interleaved writes when the per-unit
/// loop runs in parallel. Each call opens the file, seeks to the end, writes
/// one newline-terminated line, and closes — matching the existing single-task
/// pattern but safe under concurrency.
private actor DumpFileWriter {
    private let path: String

    init(_ path: String) {
        self.path = path
    }

    /// Appends one newline-terminated line to the dump file.
    func append(_ line: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        }
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a scratch estate.
///
/// - Parameter shape: Estate storage shape. When `.ram`, injects
///   `--in-memory` into the serve environment so mootx01
///   selects PersistenceKit's InMemory backend — no keychain, no SQLite I/O.
func lmebEndpointConfig(scratchDir: URL, mootBinaryPath: String,
                        posture: ScratchEstatePosture,
                        shape: BenchRunShape = .disk) throws -> EndpointConfig {
    // The env-prefix token (empty for plaintext) declares the temporal-key
    // posture to serve; the stdio launcher runs the command through `env`.
    // MOOTX01_VAULT=1: the batch seed path calls the vault-gated
    // `moot_json_import`. Vault defaults ON (any value but "0"), so this is
    // defensive — it pins the tool available even when the harness runs in a
    // shell whose environment carries a vault-off override.
    //
    // --in-memory (ram shape only): selects PersistenceKit's
    // InMemory backend — no keychain contact, no SQLite persistence. The C1
    // backend contract guarantees the served process honours this env var.
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: scratchDir, inMemory: shape == .ram, environment: scratchServeEnvironment)
    let endpoint = EndpointConfig(
        name: "mootx01-lmeb",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmebMootVerbMap,
        role: .target
    )
    // Belt-and-suspenders: assertScratchBackend verifies the scratch constraint
    // independently before any write begins.
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
    return endpoint
}

// MARK: - Batch seed builder

/// Projects one LMEB query's candidate documents onto seed-file records in
/// the same ingest order as the live path (candidateDocIDs iteration order).
///
/// Room = `"benchmarks/lmeb"` (the location constant the live `moot_file_memory`
/// calls carry). Event times are synthesized at +1 s per record from a fixed
/// base — the live path does not pass `event_time` (the product uses wall-clock
/// capture time), so we fix a base and increment to keep times unique within
/// the room and runs reproducible. IDs are the doc IDs directly (already unique
/// within the candidate pool; human-readable for diagnostics).
///
/// Docs absent from `corpus.docsByID` are silently skipped — same policy as
/// the live path (`continue` on corpus miss).
func lmebSeedRecords(
    candidateDocIDs: [String],
    corpus: LMEBCorpus,
    baseOffset: Int = 0
) -> [SeedFileRecord] {
    var records: [SeedFileRecord] = []
    var ingestIndex = baseOffset
    for docID in candidateDocIDs {
        guard let doc = corpus.docsByID[docID] else { continue }
        records.append(SeedFileRecord(
            id: docID,
            content: doc.text,
            eventTime: syntheticEventTime(offsetSeconds: ingestIndex),
            room: "benchmarks/lmeb"
        ))
        ingestIndex += 1
    }
    return records
}

// MARK: - Per-query unit

/// Runs the LMEB harness for a single query: create scratch dir → launch
/// mootx01 → ingest candidate docs → guard probe → query → map UUIDs → teardown.
///
/// Private helper for `runLMEBQueries`. Each invocation is fully isolated:
/// own /tmp/lmeb-bench-* directory, own MCPClient, own mootx01 process.
/// Safe to invoke concurrently from multiple Swift tasks (Swift 6
/// strict-concurrency: all captured values are Sendable; guardSampler is
/// an actor that serializes probe calls).
///
/// - Parameters:
///   - idx: 0-based position in the sliced list. Carried in the progress line
///     so interleaved stderr output identifies each unit.
///   - total: Total queries in the sliced list (progress denominator).
///   - dumpWriter: Actor-based JSONL writer. Nil when --dump-judge-inputs was
///     not set. Concurrent tasks call `await dumpWriter?.append(_:)` which
///     serializes file appends through the actor's executor.
private func runOneLMEBQuery(
    idx: Int,
    total: Int,
    query: LMEBQuery,
    corpus: LMEBCorpus,
    config: LMEBRunConfig,
    guardSampler: LegGuardSampler,
    timingSampler: LegTimingSampler,
    runProvenance: ArtifactProvenance,
    resolvedCacheDir: URL,
    dumpWriter: DumpFileWriter?
) async throws -> LMEBQueryResult {
    // Relevant docs (qrels) for this query — the scoring ground truth.
    let relevantDocIDs = corpus.relevantDocs(forQuery: query.id)

    // Measure-only provisioning: restore this query's pre-built estate
    // artifact, or hard-fail. Estate building is owned by the seeding
    // pipeline (benchmarks/seeding/); a miss — under any --estate-cache mode,
    // including off — is ArtifactRequiredError, never a fresh build.
    let manifest: [LMEBManifestEntry]

    let cacheEntry = estateCacheEntryURL(
        cacheDir: resolvedCacheDir,
        benchmark: "lmeb",
        variant: "",
        seed: config.seed,
        encodeBarrier: config.encodeBarrier,
        posture: config.scratchPosture,
        seedPath: config.seedPath,
        unitID: query.id
    )
    guard config.estateCache.readsCache,
          let (scratchURL, hit): (URL, [LMEBManifestEntry]) =
              try restoreEstateCacheEntry(
                  from: cacheEntry,
                  expectedProvenance: runProvenance,
                  scratchDirFactory: { try lmebScratchDir(posture: config.scratchPosture) })
    else {
        throw ArtifactRequiredError(entryPath: cacheEntry.path)
    }
    manifest = hit

    let endpoint = try lmebEndpointConfig(scratchDir: scratchURL,
                                          mootBinaryPath: config.mootBinaryPath,
                                          posture: config.scratchPosture,
                                          shape: config.shape)
    // Embedding-provider seam on restored estates is verified by
    // verifyEmbeddingProviderSeam inside restoreEstateCacheEntry.
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    // Retire the estate only when this query finished. A throw leaves it on
    // disk under a loud notice: an error keeps its evidence (see
    // keepScratchEstateOnFailure).
    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            // Retirement = teardown + zero-residual-key verification.
            try? retireScratchEstate(scratchURL, expectPlaintext: config.scratchPosture == .plaintextTransient, teardown: lmebGuardedTeardown)
        } else {
            keepScratchEstateOnFailure(scratchURL, lane: "lmeb")
        }
    }

    // The restored artifact is settled by construction (the seeding
    // pipeline builds import → drain → dream → reindex → drain); this
    // lane never ingests, settles, or snapshots. drainLaneObserved is
    // nil because the drain barrier does not run on a restored estate.
    let drainLaneObserved: Bool? = nil

    // DegeneracyGuard probe: sampled — probes on the first query of the leg
    // and caches the verdict for subsequent queries. The guard validates a
    // property of the binary, not of the individual query estate.
    let (verdict, _) = await guardSampler.probe {
        await probeMCPClient(client, verbMap: lmebMootVerbMap, name: "mootx01-lmeb")
    }
    let guardHealthy: Bool
    if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
    let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

    // Query through the configured retrieval door.
    // D-2026-08-20-A: seam failure hard-fails the unit with a named error.
    let queryStart = Date()
    let queryResult: MCPToolResult
    do {
        queryResult = try await retrieveThroughSeam(
            query.text, client: client,
            verbMap: lmebMootVerbMap, spec: config.retrievalCall,
            arm: config.payloadArm)
    } catch {
        if let spec = config.retrievalCall {
            throw MCPError(description:
                "[lmeb \(query.id)] seam call failed "
                + "(tool=\(spec.tool), extraArgs=\(spec.extraArgs)): \(error)")
        }
        throw error
    }
    let queryLatency = Date().timeIntervalSince(queryStart)

    // Map returned UUIDs → docIDs using the manifest. Unmapped UUIDs keep
    // their rank slot as NUL-prefixed placeholders — dropping them is wrong
    // in the generous direction (collapses rank gaps and overstates recall@k
    // and nDCG). With a complete manifest, no placeholder is ever emitted.
    let (rankedDocIDs, _) = lmebRankedDocsAudited(uuids: queryResult.orderedIDs, manifest: manifest)

    // No writes happen on a restored estate; write latency is a build-time
    // property of the artifact, not of this run.
    let writeMean = 0.0

    // Capture raw payload text for token-efficiency and provenance_summary.
    let rawPayload = queryResult.textBlocks.isEmpty ? nil
        : queryResult.textBlocks.joined(separator: "\n")

    // Pre-judge JSONL: append one question line per query.
    // Builds the judge payload using the same top-ranked corpus docs as the
    // judge call below; null when no ranked docs are available.
    // dumpWriter serializes concurrent appends from parallel tasks through
    // its actor executor — each task awaits the actor method, so lines are
    // never interleaved at the byte level.
    if let dumpWriter {
        let exactPayload: String?
        if !rankedDocIDs.isEmpty {
            let topDocs = rankedDocIDs.prefix(config.judgeHydrationDepth)
            let parts = topDocs.compactMap { corpus.docsByID[$0]?.text }
            exactPayload = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        } else {
            exactPayload = nil
        }
        let goldAnswerStr = relevantDocIDs.joined(separator: ",")
        let questionLine: [String: Any] = [
            "type": "question",
            "question_id": query.id,
            "question": query.text,
            "gold_answer": goldAnswerStr,
            "exact_payload": exactPayload as Any? ?? NSNull(),
            "exact_payload_tokens": exactPayload.map(lmeEstimateTokens) as Any? ?? NSNull(),
            "dense_payload": NSNull(),
            "dense_payload_tokens": NSNull(),
        ]
        if let lineData = try? JSONSerialization.data(withJSONObject: questionLine, options: [.sortedKeys]),
           var lineStr = String(data: lineData, encoding: .utf8) {
            lineStr += "\n"
            await dumpWriter.append(lineStr)
        }
    }

    // MARK: Judge call (W4-lmeb-accuracy)
    // Requires judgeCmd set AND the query has a gold answer. LMEB hydration
    // reads corpus text directly — no moot_memory_get, unlike the LME arm.
    // Soft errors (failed subprocess, non-zero exit) are logged and skipped —
    // a judge failure does not fail the query; judge fields stay nil.
    // Verdict mode spends a SECOND judge call for the correctness verdict and
    // falls back to substring grading when the verdict is unparseable.
    var judgeAnswer: String? = nil
    var judgeCorrect: Bool? = nil
    var judgeTokens: Int? = nil
    if let judgeCmd = config.judgeCmd,
       let goldAnswer = query.answer,
       !rankedDocIDs.isEmpty {
        let topDocs = rankedDocIDs.prefix(config.judgeHydrationDepth)
        let payloadParts = topDocs.compactMap { corpus.docsByID[$0]?.text }
        let judgePayload = payloadParts.joined(separator: "\n\n")
        let prompt = lmeJudgePrompt(question: query.text, payload: judgePayload)
        judgeTokens = lmeEstimateTokens(judgePayload)
        if let answer = try? lmeRunJudge(cmd: judgeCmd, prompt: prompt) {
            judgeAnswer = answer
            switch config.judgeGrading {
            case .substring:
                judgeCorrect = lmeGradeJudgeAnswer(answer, goldAnswer: goldAnswer)
            case .verdict:
                let vPrompt = lmeVerdictPrompt(question: query.text,
                                               goldAnswer: goldAnswer,
                                               candidateAnswer: answer)
                if let reply = try? lmeRunJudge(cmd: judgeCmd, prompt: vPrompt),
                   let verdict = lmeParseVerdict(reply) {
                    judgeCorrect = verdict
                } else {
                    // Verdict unparseable — fall back to substring grading so a
                    // chatty judge degrades the grade rather than losing the data.
                    FileHandle.standardError.write(Data(
                        ("[lmeb] verdict unparseable for \(query.id) "
                        + "— falling back to substring\n").utf8))
                    judgeCorrect = lmeGradeJudgeAnswer(answer, goldAnswer: goldAnswer)
                }
            }
        } else {
            FileHandle.standardError.write(Data(
                "[lmeb] judge subprocess failed for \(query.id) — skipping\n".utf8))
        }
    }

    let result = LMEBQueryResult(
        queryID: query.id,
        queryLatencySeconds: queryLatency,
        retrievedDocIDs: rankedDocIDs,
        relevantDocIDs: relevantDocIDs,
        guardHealthy: guardHealthy,
        guardDiagnostic: guardDiagnostic,
        guardSamplingMode: config.guardSamplingPolicy,
        docsIngested: manifest.count,
        writeMeanLatencySeconds: writeMean,
        payloadText: rawPayload,
        cacheHit: true,
        drainLaneObserved: drainLaneObserved,
        judgeAnswer: judgeAnswer,
        judgeCorrect: judgeCorrect,
        judgeTokens: judgeTokens
    )

    let progressMsg = "[lmeb] \(idx + 1)/\(total) "
        + "\(query.id): ingested \(manifest.count) docs, "
        + "guard=\(guardHealthy ? "healthy" : "EXCLUDED"), "
        + "retrieved \(rankedDocIDs.count) docs\n"
    FileHandle.standardError.write(Data(progressMsg.utf8))

    unitCompleted = true
    return result
}

// MARK: - Runner

/// Runs the LMEB harness against a loaded corpus. Returns per-query results
/// with manifest, latency, and guard verdict for each query.
///
/// Strategy: fresh-per-query estate. Each query gets its own /tmp/lmeb-bench-*
/// directory → clean ingest → guard probe → retrieval query → teardown.
/// This matches the `longmemeval` default (--fresh-per-question) and gives
/// correct isolation across queries from different scenes.
///
/// Parallelism (C6): when `config.parallelUnits > 1`, queries run as
/// independent Swift tasks up to the concurrency limit. Each task owns its
/// own scratch dir, MCPClient, and mootx01 process. Results are collected
/// as (original-index, result) pairs and sorted by index before return so
/// ordering is byte-deterministic regardless of task completion order.
/// Per-unit stderr lines carry the query id; interleaving is acceptable.


func runLMEBQueries(
    queries: [LMEBQuery],
    corpus: LMEBCorpus,
    config: LMEBRunConfig
) async throws -> (results: [LMEBQueryResult], timingReport: String?) {
    // --ids pinned subset (before shuffle: same file → same units always).
    let queries = try filterUnits(
        queries, ids: config.unitIDs, id: { $0.id }, lane: "lmeb")
    // Deterministic shuffle using SplitMix64 (fleet-standard PRNG).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = queries
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let sliced: [LMEBQuery]
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    // One sampler per leg: probes on the first query; caches for subsequent queries.
    // LegGuardSampler is an actor — safe to share across concurrent Swift tasks.
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    // C4: one timing sampler per leg — captures the audit-derived timing
    // report on the first freshly-settled estate (same actor-sharing shape).
    let timingSampler = LegTimingSampler()

    // Cache-mode setup (reuse only; zero cost when estateCache == .off).
    // B2: one provenance per run (see makeArtifactProvenance).
    let runProvenance = makeArtifactProvenance(
        benchmark: "lmeb",
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

    // Pre-judge JSONL header: create the file and write the header line once
    // before the per-unit loop. LMEB variant is null; arm is always "exact".
    // The DumpFileWriter actor is created here (non-nil when a dump path is
    // configured) and shared across all tasks for serialized appends.
    let dumpWriter: DumpFileWriter?
    if let dumpPath = config.dumpJudgeInputsPath {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "lmeb",
            "variant": NSNull(),
            "seed": config.seed,
            "run_label": config.runLabel,
            "arm": "exact",
            "judge_hydration_depth": config.judgeHydrationDepth,
        ]
        if let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
           var headerLine = String(data: headerData, encoding: .utf8) {
            headerLine += "\n"
            FileManager.default.createFile(atPath: dumpPath, contents: Data(headerLine.utf8), attributes: [.posixPermissions: 0o600 as NSNumber])
        }
        dumpWriter = DumpFileWriter(dumpPath)
    } else {
        dumpWriter = nil
    }

    // ── Bounded-concurrency parallel dispatch (C6) ──────────────────────────
    // parallelUnits == 1: serial behavior — the throttle below ensures at most
    // one task is in flight at any time, matching the pre-C6 serial-only
    // baseline exactly. parallelUnits > 1 (the default): up to N tasks run
    // concurrently; each owns its own scratch dir, MCPClient, and mootx01
    // process.
    //
    // Error semantics (cross-port asymmetry, intentional): a per-query error
    // here propagates through withThrowingTaskGroup and ABORTS the run —
    // fail-fast, no partial report. The Rust twin records a stub result for
    // the failed item and continues with guard_healthy=false. Swift is the
    // measurement instrument, so it refuses to produce a report with holes;
    // the Rust twin exists for parity conformance, where a stub localizes
    // the diff to the failing item.
    //
    // Results are collected as (original-index, result) pairs, then sorted by
    // index so report ordering is byte-deterministic regardless of completion
    // order. Per-unit stderr lines carry the query id; interleaving is fine.
    var indexedResults: [(Int, LMEBQueryResult)] = []
    indexedResults.reserveCapacity(sliced.count)

    try await withThrowingTaskGroup(of: (Int, LMEBQueryResult).self) { group in
        var inFlight = 0
        for (idx, query) in sliced.enumerated() {
            // Throttle: drain one completed task before dispatching a new one
            // when the in-flight count reaches the concurrency limit.
            if inFlight >= config.parallelUnits {
                if let pair = try await group.next() {
                    indexedResults.append(pair)
                    inFlight -= 1
                }
            }
            let capturedIdx   = idx
            let capturedQuery = query
            group.addTask {
                let result = try await runOneLMEBQuery(
                    idx: capturedIdx,
                    total: sliced.count,
                    query: capturedQuery,
                    corpus: corpus,
                    config: config,
                    guardSampler: guardSampler,
                    timingSampler: timingSampler,
                    runProvenance: runProvenance,
                    resolvedCacheDir: resolvedCacheDir,
                    dumpWriter: dumpWriter
                )
                return (capturedIdx, result)
            }
            inFlight += 1
        }
        // Drain remaining in-flight tasks.
        for try await pair in group {
            indexedResults.append(pair)
        }
    }

    // Sort by original index: restores byte-deterministic ordering regardless
    // of which tasks completed first.
    indexedResults.sort { $0.0 < $1.0 }
    // C4: the leg's sampled timing report rides back beside the results —
    // nil when every unit restored from cache or the capture failed.
    return (indexedResults.map(\.1), await timingSampler.text())
}
