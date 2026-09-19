import Foundation

/// Default judge-payload hydration depth when `--judge-hydration-depth` is
/// not given. Ten covers recall@10, the deepest cut-off the lane scores.
let lmeDefaultJudgePayloadHydrationDepth = 10


// LongMemEvalRunner.swift — LongMemEval session-recall harness (Part 4).
//
// This lane is MEASURE-ONLY: for each question it restores a pre-built estate
// artifact into a fresh scratch dir under /tmp/lme-bench-XXXXXX, launches
// mootx01 with --db pointing at it, queries via live MCP query,
// and tears down the estate. Estate artifacts are built by the seeding
// pipeline (benchmarks/seeding/, BENCHMARK_ESTATES.md); a missing artifact is
// a hard failure (ArtifactRequiredError), never a fresh build.
//
// Safety guarantees:
//   - lmeScratchDir(posture:) names the dir with /tmp/lme-bench- so the teardown guard
//     can distinguish LME scratch dirs from arbitrary /tmp directories.
//   - lmeGuardedTeardown() refuses any path that does not carry the
//     /tmp/lme-bench- prefix; a non-scratch path cannot be passed by mistake.
//   - The built EndpointConfig always carries --db /tmp/lme-bench-...
//     so assertScratchBackend (GauntletCLI.swift) independently verifies the
//     scratch constraint before any write begins.

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

/// Standard mootx01 v2 VerbMap used for LME ingestion + exact recall queries.
/// Matches the live E2E test's mootEndpoint verbMap convention.
///
/// write:         AriaV2Surface.fileMemory   (moot_file_memory)
/// query:         AriaV2Surface.memorySearch  (moot_memory_search)
/// constantArgs:  { "location": "benchmarks/longmemeval" }
/// resultFormat:  .mootV2  (reads structuredContent.data.results[].memory_id)
/// v1 `ordering` arg removed — v2 moot_memory_search defaults to byRelevanceDesc.
let lmeMootVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: ["location": "benchmarks/longmemeval"],
    resultFormat: .mootV2
)

/// Dense recall v2 VerbMap for the token-efficiency benchmark.
/// Uses moot_recall_distilled.
///   - Runs the SAME exact-search geometry as moot_memory_search and hydrates
///     each hit with its on-row DISTILLED representation (token-economical
///     prose) — identical ranking, smaller payloads, per-hit
///     distilled_token_count metadata
///   - Falls back to full content (marked served-from-content) for rows not
///     yet distilled
///   - Does NOT use a location constant arg (queries the estate-default wing)
///
/// write:  AriaV2Surface.fileMemory      (same ingest tool as lmeMootVerbMap)
/// query:  AriaV2Surface.recallDistilled
/// constantArgs:  {} — v2 has no ack gate on moot_recall_distilled
/// resultFormat:  .mootV2
let lmeDenseMootVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.recallDistilled,
    list: nil,
    constantArgs: [:],
    resultFormat: .mootV2
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
    /// Sampling policy that determined whether this question issued its own probe
    /// or used the cached verdict from the first question of the leg.
    let guardSamplingMode: GuardSamplingPolicy
    /// Total number of turns ingested for this question's haystack.
    let turnsIngested: Int
    /// Mean write latency (seconds) across all ingested turns.
    let writeMeanLatencySeconds: Double
    /// Raw payload text from the exact-arm moot_memory_search call.
    /// The joined textBlocks from the MCPToolResult — used by Part 2's token
    /// estimator and evidence scorer. nil when arm = .dense.
    let exactPayloadText: String?
    /// Raw payload text from the dense-arm moot_recall_distilled call.
    /// Contains each hit's distilled representation (token-economical prose,
    /// uncapped) with per-hit `tokens:`/`source:` metadata lines; rows not
    /// yet distilled appear as full content marked served-from-content.
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
    /// Did the gold answer text reach the judge's context? nil when no judge
    /// ran. This bounds answer accuracy from above — see lmeGoldAnswerInPayload.
    let exactGoldReachable: Bool?
    /// Tokens in the payload the judge ACTUALLY READ, per arm.
    ///
    /// Distinct from the token-efficiency block's `exact_arm_mean_tokens`,
    /// which counts the recall verb's 120-char PREVIEW payload. Previews are
    /// not what a consumer reads, so comparing them against the dense arm's
    /// distillate compares two different things and makes the distillate look
    /// expensive. These two fields are the like-for-like pair: full hydrated
    /// content vs distillate, both as the judge received them.
    let exactJudgeTokens: Int?
    let denseJudgeTokens: Int?
    /// Preview-payload judged cell — the third point on the token/quality
    /// frontier (see the preview judge block in the runner).
    let previewJudgeAnswer: String?
    let previewJudgeCorrect: Bool?
    let previewJudgeTokens: Int?
    /// Judge subprocess answer for the dense arm. nil when judgeCmd was not set
    /// or the dense arm was not run.
    let denseJudgeAnswer: String?
    /// True when denseJudgeAnswer contains the normalized gold answer as a substring.
    /// nil when denseJudgeAnswer is nil.
    let denseJudgeCorrect: Bool?
    /// Whether this question's estate was served from the artifact cache.
    /// Always true in this measure-only lane: a run either restores every
    /// unit's artifact or hard-fails before producing a result.
    let cacheHit: Bool?
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// (Shape B response) before accepting idle. false = the barrier converged
    /// via the no-lanes grace window without ever seeing the lane — ambiguous
    /// evidence (tiny corpus finished early, or lane never wired). nil = the
    /// drain barrier did not run for this question (barrier != drain, or the
    /// estate was restored from cache and ingest was skipped).
    let drainLaneObserved: Bool?
    // MARK: Synthesize arm (additive — PR-08)
    /// Raw payload text from the `moot_synthesize` call. The synthesize verb
    /// generates a direct answer from the estate without returning ranked IDs,
    /// so there is no retrieval metric — only judge accuracy is measurable.
    /// nil when synthesizeArm was not enabled for this run.
    let synthesizePayloadText: String?
    /// Judge subprocess answer for the synthesize arm. nil when synthesizeArm
    /// was not enabled, the judge was not configured, or the arm errored.
    let synthesizeJudgeAnswer: String?
    /// True when synthesizeJudgeAnswer contains the gold answer as a substring
    /// (or the verdict judge says CORRECT). nil when synthesizeJudgeAnswer is nil.
    let synthesizeJudgeCorrect: Bool?
    /// Estimated token count for the synthesize payload, using the same
    /// byte-count/4 estimator as the other arms. nil when payload is nil.
    let synthesizeJudgeTokens: Int?
    // MARK: Settle cell (--settle mode, Mission 11X-RECALL-GAP-01 Stream C)
    /// UUIDs returned by the settled exact-arm query, in ranked order.
    /// nil when --settle was not set or the exact arm was not run.
    let settledRetrievedUUIDs: [String]?
    /// Time taken for the settled exact-arm moot_memory_search call, in seconds.
    /// nil when --settle was not set or the exact arm was not run.
    let settledQueryLatencySeconds: Double?
    /// Whether the post-reindex drain barrier observed the corpus_encode lane.
    /// nil when --settle was not set.
    let settledDrainLaneObserved: Bool?
}

// MARK: - Shape

/// Backend shape for the scratch estate used in LME runs.
///
/// `.disk` (default): standard SQLite-backed PersistenceKit estate.
///
/// `.ram`: injects `--in-memory` into the mootx01 serve command,
/// selecting PersistenceKit's InMemory backend. Faster but volatile — the estate
/// vanishes on server exit. Incompatible with `--estate-cache reuse` or `require`;
/// that combination is rejected at CLI parse time because there is no snapshot to
/// restore from a process that no longer holds the estate in memory.
enum LMEShape: String, Sendable, CaseIterable {
    case disk
    case ram
}

// MARK: - Run config

/// Configuration for one LME run. Built from CLI arguments in `runLongMemEval`.
struct LMERunConfig: Sendable {
    /// Path to the mootx01 binary. The runner launches it as a stdio MCP server
    /// with --db set to the provisioned scratch estate.
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
    /// How judge answers are graded. `.substring` is deterministic and free;
    /// `.verdict` spends a second judge call per answer and matches the
    /// protocol published leaderboard numbers use. Recorded in the report —
    /// the two modes are not comparable to each other.
    let judgeGrading: LMEJudgeGrading
    /// How many ranked hits are hydrated to full content for the judge.
    ///
    /// THIS PARAMETER MOVES THE ACCURACY NUMBER and must be recorded in any
    /// judged cell. Measured on a 10-question slice: depth 10 → 0.30, depth
    /// 30 → 0.40. The cause is a level mismatch — recall is scored over
    /// SESSIONS, while the judge reads DRAWERS. A session scores a hit as
    /// soon as any one of its turns ranks, but the turn that actually
    /// carries the answer can sit far deeper, so a deeper hydration window
    /// hands the judge more chances to see it.
    let judgeHydrationDepth: Int
    /// RecallShape preset for `--exact-strategy shaped`. nil uses the product
    /// default (balanced, unsteered).
    let recallShape: String?
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
    /// At-rest posture for scratch estates. Default plaintextTransient: the runner
    /// attaches each scratch dir as a transient catalog record (plaintext by rule) before
    /// serve launch so the estate is created plaintext (no keychain contact).
    /// --estate-mode encrypted selects encryptedEphemeral. Recorded in the report
    /// JSON as "estate_encryption".
    let scratchPosture: ScratchEstatePosture
    /// Exact-arm retrieval strategy (--exact-strategy). Follows the program's
    /// documented client protocol; see the strategy comment at the query site.
    let exactStrategy: ExactRecallStrategy
    /// When true, run the query set twice per question: first as the ORGANIC
    /// cell (immediately after ingest + drain barrier, the current behavior),
    /// then trigger estate settling via `moot_reindex`, wait for the drain
    /// barrier again, and re-run the identical queries as the SETTLED cell.
    ///
    /// Rationale: with two-tier vector composition, ORGANIC and SETTLED are two
    /// distinct performance states. A short haystack may finish encoding before
    /// the first query; `moot_reindex` ensures the estate is at full coverage
    /// before the settled measurement. Neither cell may substitute for the other
    /// in published numbers.
    let settle: Bool
    // MARK: Rerank (additive — W2-rerank)
    /// Optional command for post-retrieval reranking. When set, the top
    /// `rerankWindowSize` hits from the exact arm are handed to this command
    /// before scoring. The command reads a numbered candidate prompt on stdin
    /// and writes a permutation of candidate numbers on stdout (exit 0).
    ///
    /// The command is recorded as PRESENCE ONLY in the report (`rerank_cmd_set`).
    /// It may carry API keys; never log, hash, or derive any value from it.
    let rerankCmd: String?
    // MARK: Synthesize arm (additive — PR-08)
    /// When true, run `moot_synthesize` per question as a fourth answer-payload
    /// mode beside preview / distilled / full-hydrated. The synthesize arm calls
    /// the estate's synthesis verb directly, bypassing retrieval entirely, and
    /// judges the generated answer under the same judge/grading configuration.
    ///
    /// This is an ADDITIVE arm — it runs alongside whatever `arm` value is set
    /// and does not affect retrieval scoring. Requires `judgeCmd` to be non-nil;
    /// without a judge the synthesize payload is captured but not graded.
    ///
    /// Off by default. Enable with `--synthesize-arm`. Actual runs require
    /// the ruled quiet-machine authorization; the plumbing is built and labeled
    /// without pre-judging the outcome.
    let synthesizeArm: Bool
    /// Optional `limit` forwarded to moot_synthesize (`--synthesize-limit`).
    /// The tool's own default is 20, applied newest-first BEFORE any
    /// relevance signal — on a ~500-turn estate the query-matched pool far
    /// exceeds 20, so the cap usually evicts the answer turn. This knob
    /// isolates how much of the synthesize cell's score is that cap. nil
    /// omits the argument (tool default).
    let synthesizeLimit: Int?
    /// Path to write the pre-judge JSONL payload file (`--dump-judge-inputs`).
    /// When set, the runner appends one JSON line per question to this file
    /// (after writing a header line before the loop) capturing the exact and
    /// dense payloads before teardown. nil = do not write.
    let dumpJudgeInputsPath: String?
    /// Partition of the seeded-shuffled question list (`--slice`). Applied
    /// AFTER the Fisher-Yates shuffle and BEFORE offset and limit, so a run
    /// at `--slice dev --limit 10` returns the first 10 questions of the
    /// dev half — it does not take 10 from the full set and then filter.
    ///
    /// Accepted values:
    ///   "dev"     — first 50 shuffled questions (the historical tuning slice)
    ///   "holdout" — everything after the first 50 shuffled questions
    ///   nil       — full shuffled set (today's default behaviour, unchanged)
    ///
    /// The partition boundary is hard-coded at 50. Cells produced with and
    /// without this flag are NOT interchangeable — record it in every report.
    let slice: String?
    /// --ids: pinned debug-subset unit IDs (nil = whole corpus).
    var unitIDs: Set<String>? = nil
    /// Optional retrieval-call override (environment seam; see
    /// RetrievalCallSpec.swift). When set it replaces the exact-arm query
    /// call; named strategies are explicit and unaffected paths.
    var retrievalCall: RetrievalCallSpec? = nil
    /// Payload-economics shape-variant arm (--payload-arm /
    /// MOOT_BENCH_PAYLOAD_ARM; see PayloadArm.swift). Applied by
    /// retrieveThroughSeam to the seam result's textBlocks so judged-output
    /// row text carries the arm's field subset. nil = full ruled payload.
    var payloadArm: PayloadArm? = nil
    /// How the seed loads into the estate. `.batch` (default, ruling 8D5B8053):
    /// emit seed-file schema v1 → one `moot_json_import` (return_id_map) →
    /// encode barrier; the importer's id map IS the manifest. `.live` is the retained
    /// slow lane (per-turn `moot_file_memory`) kept for periodic equivalence
    /// re-proving. The two cells are NOT interchangeable in published numbers.
    var seedPath: SeedPathMode = .batch
    /// Guard probe sampling policy for this leg.
    ///
    /// Default `.oncePerLeg`: the guard probes the first question only and caches
    /// the verdict for the rest of the leg, cutting 3 × (N-1) unnecessary MCP
    /// search calls from an N-question leg. Use `.perUnit` only for debugging.
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
    /// SHA-256 of the corpus fixture file (B2 provenance). Computed once at
    /// CLI load time; "unknown" when unreadable (never validates — an
    /// unverifiable artifact is a hard fail at restore).
    var corpusDigest: String = "unknown"
    /// Backend shape for the scratch estate. `.disk` (default) = standard SQLite;
    /// `.ram` = PersistenceKit InMemory backend (--in-memory injected
    /// into the serve command). Rejected at CLI parse time when combined with
    /// estateCache .reuse or .require — an in-memory estate vanishes on server
    /// exit, so there is no snapshot to restore.
    var shape: LMEShape = .disk
    /// Maximum number of questions to run concurrently. 1 = serial.
    /// Default: max(1, 80% of logical cores).
    var parallelUnits: Int = max(1, Int(Double(ProcessInfo.processInfo.activeProcessorCount) * 0.8))
}

// MARK: - Seed-record metadata (shared with the lme-spec lane)

/// Per-record metadata stored alongside each seed record so a seeding lane
/// can reconstruct `LMEManifestEntry` values from an importer id map.
/// Consumed by the lme-spec lane's own seed builder (`lmeSpecSeedRecords`);
/// this measure-only lane reads it back from restored artifact manifests.
struct LMESeedMeta {
    let sessionID: String
    let turnIndex: Int
    let sessionIndex: Int
    let role: String
    /// True when the session ID is in the question's `answerSessionIDs` set.
    let isAnswerSession: Bool
}

/// Ingest granularity: what one filed document is. Used by the locomo-spec
/// lane, whose seeding is methodology-defining (its `--granularity` flag
/// selects the estate shape). Twin of Rust `IngestGranularity`. THE TWO
/// CELLS ARE NOT COMPARABLE: ranking among tens of thousands of turns and
/// ranking among tens of session documents are different tasks, so every
/// published cell names its granularity.
enum IngestGranularity: String, Sendable, Codable {
    /// One document per conversational turn (this harness's original shape).
    case turn
    /// One document per session — all of a session's turns joined into a
    /// single document ("speaker: text" lines).
    case session
}

/// How the exact arm drives the estate's recall surface.
/// The program's tool descriptions are the client contract:
/// - .search    — bare moot_memory_search (v2 always returns byRelevanceDesc).
/// - .relevance — moot_memory_search (v2: ordering arg removed; behaviour
///                is identical to .search — v2 defaults to byRelevanceDesc).
/// - .precise   — moot_recall_precise (the documented precision-retrieval mode).
/// - .auto      — DEFAULT: moot_memory_search, escalating to
///                moot_recall_precise when the response reports
///                "discrimination: low" — exactly the escalation the tool
///                descriptions instruct clients to perform.
enum ExactRecallStrategy: String, Sendable, Codable {
    case search
    case relevance
    case precise
    case auto
    /// `moot_recall_shaped` — the signed-weight fusion engine, steered by a
    /// named RecallShape preset (`--recall-shape`). This is the advanced
    /// recall surface; `search` is the unsteered baseline verb.
    case shaped
}

/// RecallShape presets accepted by `--recall-shape`, mirroring the product's
/// `moot_recall_shaped` roster. Each steers the fusion differently — which one
/// wins on a given corpus is an empirical question, so the harness carries the
/// whole roster and the answer comes from ablation, not from picking one.
let lmeRecallShapePresets = [
    "balanced", "precise", "conceptual", "broad", "lexical", "not_lexical",
    "associative", "consensus", "ri_forward", "ppmi_forward", "lsa_forward",
    "nmf_forward", "fast", "structural", "temporal", "connection", "field",
    "preference", "anti_redundant", "session_hybrid",
]

// MARK: - Scratch estate management

/// Creates a fresh scratch directory under /tmp/lme-bench-<UUID> for LME use.
/// The /tmp/lme-bench- prefix is the contract with `lmeGuardedTeardown`.
///
/// The UUID suffix guarantees uniqueness across concurrent runs without needing
/// mkdtemp(3) or a subprocess call.
///
/// - Parameter posture: At-rest posture for the estate this dir will hold.
///   `plaintextTransient` attaches the dir as a transient catalog record (plaintext by rule)
///   BEFORE any serve launch (see ScratchPosture.swift). No default value on
///   purpose: every call site decides posture explicitly.
/// - Returns: The URL of the created directory.
/// - Throws: `MCPError` when directory creation fails.
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
/// The command form is `--db <scratchDir> <mootBinaryPath>` which:
///   1. Passes assertScratchBackend (scratchDir is always /tmp/lme-bench-*).
///   2. Tells the MCPClient how to launch the server (stdio transport).
///
/// - Parameters:
///   - scratchDir: A directory created by `lmeScratchDir(posture:)`.
///   - mootBinaryPath: Path to the mootx01 binary.
/// - Returns: A validated EndpointConfig for this estate.
/// - Throws: `MCPError` via assertScratchBackend when the config does not meet
///   the scratch safety constraint (should not happen for lmeScratchDir output).
/// - Parameter benchClockEpoch: When non-nil, `MOOT_BENCH_EPOCH_NOW=<value>`
///   is prepended to the serve command so the product server pins its clock
///   to this ISO8601 instant for the duration of the run. Used in replay lanes
///   to make `filedAt` stamps and temporal scores bit-identical across runs
///   from the same seed. Nil (default) → wall-clock (production behaviour).
///   The env var is a benchmarker-only seam; not exposed on the MCP surface.
func lmeEndpointConfig(scratchDir: URL, mootBinaryPath: String,
                       posture: ScratchEstatePosture,
                       shape: LMEShape = .disk,
                       benchClockEpoch: String? = nil) throws -> EndpointConfig {
    // The env-prefix token (empty for plaintext) declares the temporal-key
    // posture to serve; the stdio launcher runs the command through `env`.
    // MOOTX01_VAULT=1: the batch seed path calls the vault-gated
    // `moot_json_import`. Vault defaults ON (any value but "0"), so this is
    // defensive — it pins the tool available even when the harness runs in
    // a shell whose environment carries a vault-off override.
    // C1 — shape: when .ram, inject --in-memory before the
    // standard env vars so PersistenceKit selects the InMemory backend.
    // The in-memory estate is faster but volatile; it vanishes when the
    // server exits, so estate-cache snapshotting is incompatible (rejected
    // at CLI parse time).
    // Bench-clock seam: when `benchClockEpoch` is non-nil, pin the server's
    // clock to that ISO8601 instant. The env var is consumed once at server
    // startup; thereafter every tool dispatch gets base + N*1s for its `now`.
    // Nil → no env token → wall-clock (the default for all non-replay lanes).
    let epochPrefix = benchClockEpoch.map { "\(mootBenchEpochNowEnvKey)=\($0) " } ?? ""
    let command = try mootServeCommand(
        binary: mootBinaryPath, scratchDir: scratchDir, inMemory: shape == .ram,
        environment: epochPrefix.split(separator: " ").map(String.init) + scratchServeEnvironment)
    let endpoint = EndpointConfig(
        name: "mootx01-lme",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmeMootVerbMap,
        role: .target
    )
    // Validate scratch constraint before returning — belt-and-suspenders.
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
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
) async throws -> (results: [LMEQuestionResult], rerankFailures: Int, timingReport: String?) {
    // --ids pinned subset (before shuffle: same file → same units always).
    let questions = try filterUnits(
        questions, ids: config.unitIDs, id: { $0.questionID }, lane: "longmemeval")
    // Apply slice → offset → limit to the (seeded-shuffled) question list.
    // SplitMix64 is the fleet-standard seeded PRNG (GauntletRNG.swift).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = questions
    // Fisher-Yates shuffle using SplitMix64 for determinism.
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    // Slice the shuffled list BEFORE applying offset or limit.
    // The dev partition is always the first 50 questions of the seeded shuffle;
    // holdout is everything after. Cells with different --slice values are NOT
    // comparable: record the value in every run_parameters block.
    let lmeDevSliceSize = 50
    let afterSlice: [LMEQuestion]
    switch config.slice {
    case "dev":
        afterSlice = Array(shuffled.prefix(lmeDevSliceSize))
    case "holdout":
        afterSlice = Array(shuffled.dropFirst(lmeDevSliceSize))
    case nil:
        afterSlice = shuffled
    default:
        // Validated at CLI parse time; this branch is unreachable in production.
        fatalError("[longmemeval] unreachable: --slice value '\(config.slice!)' was not validated at parse")
    }
    let sliced: [LMEQuestion]
    let afterOffset = Array(afterSlice.dropFirst(config.offset))
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    var results: [LMEQuestionResult] = []
    // Rerank failure counter: incremented for every question whose rerank command
    // returned an unparseable reply or non-zero exit. Reported as `rerank_failures`
    // in the run report when `--rerank-cmd` is active.
    var rerankFailures = 0
    results.reserveCapacity(sliced.count)

    // Cache-mode setup (reuse only; zero cost when estateCache == .off).
    // B2: one provenance per run — every unit of a leg shares the declared
    // dependency set; only the unit id varies (it lives in the entry path).
    let runProvenance = makeArtifactProvenance(
        benchmark: "lme",
        variant: config.variant,
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

    // Pre-judge JSONL: create the output file and write the header line once
    // before the question loop so the file exists even if the run is empty.
    // Header captures benchmark identity and run parameters so the offline
    // judge-batch subcommand can attribute verdicts without re-running anything.
    if let dumpPath = config.dumpJudgeInputsPath {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "longmemeval",
            "variant": config.variant,
            "seed": config.seed,
            "run_label": config.runLabel,
            "arm": config.arm.rawValue,
            "judge_hydration_depth": config.judgeHydrationDepth,
        ]
        if let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
           var headerLine = String(data: headerData, encoding: .utf8) {
            headerLine += "\n"
            // Create or overwrite the file with the header line.
            FileManager.default.createFile(atPath: dumpPath, contents: Data(headerLine.utf8), attributes: [.posixPermissions: 0o600 as NSNumber])
        }
    }

    // One sampler per leg: probes on the first question; caches for subsequent questions.
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    // C4: one timing sampler for the leg — captures the audit-derived timing
    // report from the first freshly-settled estate (INGEST samples + four CYCLE
    // tiers). The `@Sendable runFreshQuestion` closure captures it by reference
    // (actors are Sendable); the serial loop uses it directly.
    let timingSampler = LegTimingSampler()

    // C6: @Sendable local function encapsulating the per-question body so the
    // parallel task group can dispatch it concurrently without duplicating the
    // restore+query+judge logic. The serial loop below covers parallelUnits == 1.
    //
    // All captured outer values are Sendable:
    //   config: LMERunConfig (Sendable struct)
    //   resolvedCacheDir: URL (Sendable)
    //   runProvenance: ArtifactProvenance (Sendable)
    //   guardSampler: LegGuardSampler (actor — Sendable)
    @Sendable func runFreshQuestion(
        _ question: LMEQuestion,
        at originalIndex: Int
    ) async throws -> (Int, LMEQuestionResult, Int) {
        let manifest: [LMEManifestEntry]
        var taskRerankCount = 0

        // Measure-only provisioning: restore this question's pre-built estate
        // artifact, or hard-fail. Estate building is owned by the seeding
        // pipeline (benchmarks/seeding/, BENCHMARK_ESTATES.md); a miss — under
        // any --estate-cache mode, including off — is ArtifactRequiredError,
        // never a fresh build.
        let cacheEntry = estateCacheEntryURL(
            cacheDir: resolvedCacheDir,
            benchmark: "lme",
            variant: config.variant,
            seed: config.seed,
            encodeBarrier: config.encodeBarrier,
            posture: config.scratchPosture,
            seedPath: config.seedPath,
            unitID: question.questionID
        )
        guard config.estateCache.readsCache,
              let (freshScratch, hit): (URL, [LMEManifestEntry]) =
                  try restoreEstateCacheEntry(
                      from: cacheEntry,
                      expectedProvenance: runProvenance,
                      scratchDirFactory: { try lmeScratchDir(posture: config.scratchPosture) })
        else {
            throw ArtifactRequiredError(entryPath: cacheEntry.path)
        }
        manifest = hit

        let endpoint = try lmeEndpointConfig(
            scratchDir: freshScratch,
            mootBinaryPath: config.mootBinaryPath,
            posture: config.scratchPosture,
            shape: config.shape
        )
        // Embedding-provider seam on restored estates is verified by
        // verifyEmbeddingProviderSeam inside restoreEstateCacheEntry.
        // Default deadline: the slow calls on this client (moot_reindex,
        // moot_dream) carry MCPDeadline.bulk themselves, so the CONNECTION
        // does not have to be widened to survive them. Leaving it at 1800
        // would mean every status poll on this client waited up to thirty
        // minutes before reporting a dead server.
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        // Retired only when this question finished. A throw keeps the estate
        // and says where (see keepScratchEstateOnFailure).
        var freshQuestionCompleted = false
        defer {
            Task { await client.disconnect() }
            if freshQuestionCompleted {
                try? retireScratchEstate(freshScratch,
                                         expectPlaintext: config.scratchPosture == .plaintextTransient,
                                         teardown: lmeGuardedTeardown)
            } else {
                keepScratchEstateOnFailure(freshScratch, lane: "lme")
            }
        }

        // --- Common body (query + judge) ---
        // This is identical to the serial loop's body.
        // Two differences from the serial loop:
        //   • rerankFailures += 1  →  taskRerankCount += 1  (local accumulator)
        //   • results.append(LMEQuestionResult(...))  →  returned as tuple element

        // The restored artifact is settled by construction (the seeding
        // pipeline builds import → drain → dream → reindex → drain); this
        // lane never ingests, settles, or snapshots. drainLaneObserved is
        // nil because the drain barrier does not run on a restored estate.
        let drainLaneObserved: Bool? = nil

        let (verdict, _) = await guardSampler.probe {
            await probeMCPClient(client, verbMap: lmeMootVerbMap, name: "mootx01-lme")
        }
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

        // No writes happen on a restored estate; write latency is a
        // build-time property of the artifact, not of this run.
        let writeMean = 0.0

        var exactPayloadText: String? = nil
        var exactQueryLatency: Double? = nil
        var retrievedUUIDs: [String] = []
        var exactTextBlocks: [String] = []
        if config.arm == .exact || config.arm == .both {
            let queryStart = Date()
            if let spec = config.retrievalCall {
                // D-2026-08-20-A: seam failure hard-fails the unit. The error
                // names the unit and seam args so the run log is unambiguous.
                do {
                    let seamResult = try await retrieveThroughSeam(
                        question.question, client: client,
                        verbMap: lmeMootVerbMap, spec: spec,
                        arm: config.payloadArm)
                    retrievedUUIDs = seamResult.orderedIDs
                    exactTextBlocks = seamResult.textBlocks
                    exactPayloadText = seamResult.textBlocks.joined(separator: "\n")
                } catch {
                    throw MCPError(description:
                        "[lme \(question.questionID)] seam call failed "
                        + "(tool=\(spec.tool), extraArgs=\(spec.extraArgs)): \(error)")
                }
                exactQueryLatency = Date().timeIntervalSince(queryStart)
            } else {
            let queryArgs = AriaV2Surface.memorySearchArgs(verbMap: lmeMootVerbMap, query: question.question)
            // v2: ordering arg removed; moot_memory_search defaults to byRelevanceDesc.
            if config.exactStrategy == .shaped {
                var shapedArgs: [String: JSONValue] = [
                    lmeMootVerbMap.queryArg: .string(question.question),
                ]
                if let shape = config.recallShape {
                    shapedArgs["preset"] = .string(shape)
                }
                let shapedResult = try await client.callTool(
                    AriaV2Surface.recallShaped,
                    arguments: shapedArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = shapedResult.orderedIDs
                exactTextBlocks = shapedResult.textBlocks
                exactPayloadText = shapedResult.textBlocks.joined(separator: "\n")
            } else if config.exactStrategy == .precise {
                let preciseResult = try await client.callTool(
                    AriaV2Surface.recallPrecise,
                    arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = preciseResult.orderedIDs
                exactTextBlocks = preciseResult.textBlocks
                exactPayloadText = preciseResult.textBlocks.joined(separator: "\n")
            } else {
                let queryResult = try await client.callTool(
                    lmeMootVerbMap.query,
                    arguments: queryArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = queryResult.orderedIDs
                exactTextBlocks = queryResult.textBlocks
                exactPayloadText = queryResult.textBlocks.joined(separator: "\n")
                if config.exactStrategy == .auto,
                   exactPayloadText?.contains("discrimination: low") == true {
                    let preciseResult = try await client.callTool(
                        AriaV2Surface.recallPrecise,
                        arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                        format: lmeMootVerbMap.resultFormat
                    )
                    if !preciseResult.orderedIDs.isEmpty {
                        retrievedUUIDs = preciseResult.orderedIDs
                        exactTextBlocks = preciseResult.textBlocks
                        exactPayloadText = preciseResult.textBlocks.joined(separator: "\n")
                    }
                }
            }
            exactQueryLatency = Date().timeIntervalSince(queryStart)
            }

            if let rerankCmd = config.rerankCmd {
                let (reranked, failed) = applyRerank(
                    cmd: rerankCmd,
                    question: question.question,
                    ids: retrievedUUIDs,
                    previews: exactTextBlocks
                )
                retrievedUUIDs = reranked
                if failed { taskRerankCount += 1 }
            }
        }

        let densePayloadText: String? = nil
        let denseQueryLatency: Double? = nil
        if config.arm == .dense || config.arm == .both {
            // moot_distill is retired on the ARIA v2 surface
            // (negative_catalog_assertions absent_reason: "Retired alias.").
            // The dense arm refuses with a typed error; Swift parity: Rust
            // returns LaneError::Config via aria_v2_surface::refused_distill_call().
            throw AriaV2SurfaceError.retiredOperation("moot_distill")
        }

        func hydratedPayload(ids: [String], fallback: String?) async -> String? {
            guard config.judgeCmd != nil || config.dumpJudgeInputsPath != nil,
                  !ids.isEmpty else { return fallback }
            var blocks: [String] = []
            for id in ids.prefix(config.judgeHydrationDepth) {
                do {
                    let full = try await client.callTool(
                        AriaV2Surface.memoryGet,
                        arguments: AriaV2Surface.memoryGetArgs(memoryId: id),
                        format: lmeMootVerbMap.resultFormat
                    )
                    let text = full.textBlocks.joined(separator: "\n")
                    if !text.isEmpty { blocks.append(text) }
                } catch {
                    FileHandle.standardError.write(Data(
                        "[lme] hydrate failed for \(id): \(error)\n".utf8))
                }
            }
            return blocks.isEmpty ? fallback : blocks.joined(separator: "\n\n")
        }

        let exactJudgePayload = await hydratedPayload(
            ids: retrievedUUIDs, fallback: exactPayloadText)
        let denseJudgePayload = densePayloadText

        if let dumpPath = config.dumpJudgeInputsPath {
            let questionLine: [String: Any?] = [
                "type": "question",
                "question_id": question.questionID,
                "question": question.question,
                "gold_answer": question.answer,
                "exact_payload": exactJudgePayload,
                "exact_payload_tokens": exactJudgePayload.map(lmeEstimateTokens),
                "dense_payload": denseJudgePayload,
                "dense_payload_tokens": denseJudgePayload.map(lmeEstimateTokens),
            ]
            let coerced: [String: Any] = questionLine.mapValues { v in
                if case let val? = v { return val as Any }
                return NSNull()
            }
            if let lineData = try? JSONSerialization.data(withJSONObject: coerced, options: [.sortedKeys]),
               var lineStr = String(data: lineData, encoding: .utf8) {
                lineStr += "\n"
                if let fh = FileHandle(forWritingAtPath: dumpPath) {
                    fh.seekToEndOfFile()
                    fh.write(Data(lineStr.utf8))
                    fh.closeFile()
                }
            }
        }

        func gradeAnswer(_ answer: String) -> Bool {
            switch config.judgeGrading {
            case .substring:
                return lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
            case .verdict:
                guard let judgeCmd = config.judgeCmd else {
                    return lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
                }
                let vPrompt = lmeVerdictPrompt(question: question.question,
                                               goldAnswer: question.answer,
                                               candidateAnswer: answer)
                guard let reply = try? lmeRunJudge(cmd: judgeCmd, prompt: vPrompt),
                      let verdict = lmeParseVerdict(reply) else {
                    FileHandle.standardError.write(Data(
                        "[lme] verdict unparseable for \(question.questionID) — falling back to substring\n".utf8))
                    return lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
                }
                return verdict
            }
        }

        let exactGoldReachable: Bool? = exactJudgePayload.map {
            lmeGoldAnswerInPayload(goldAnswer: question.answer, payloadText: $0)
        }

        var exactJudgeAnswer: String? = nil
        var exactJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = exactJudgePayload,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                exactJudgeAnswer = answer
                exactJudgeCorrect = gradeAnswer(answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (exact) for \(question.questionID): \(error)\n".utf8))
            }
        }

        var previewJudgeAnswer: String? = nil
        var previewJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = exactPayloadText,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                previewJudgeAnswer = answer
                previewJudgeCorrect = gradeAnswer(answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (preview) for \(question.questionID): \(error)\n".utf8))
            }
        }

        var synthesizePayloadText: String? = nil
        var synthesizeJudgeAnswer: String? = nil
        var synthesizeJudgeCorrect: Bool? = nil
        if config.synthesizeArm {
            do {
                var synthArgs: [String: JSONValue] = [
                    lmeMootVerbMap.queryArg: .string(question.question),
                ]
                if let synthLimit = config.synthesizeLimit {
                    synthArgs["limit"] = .number(Double(synthLimit))
                }
                let synthResult = try await client.callTool(
                    AriaV2Surface.synthesize,
                    arguments: synthArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                synthesizePayloadText = synthResult.textBlocks.joined(separator: "\n")
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] moot_synthesize error for \(question.questionID): \(error)\n".utf8))
            }
            if let judgeCmd = config.judgeCmd,
               let payload = synthesizePayloadText,
               !payload.isEmpty {
                let prompt = lmeJudgePrompt(question: question.question, payload: payload)
                do {
                    let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                    synthesizeJudgeAnswer = answer
                    synthesizeJudgeCorrect = gradeAnswer(answer)
                } catch {
                    FileHandle.standardError.write(Data(
                        "[lme] judge error (synthesize) for \(question.questionID): \(error)\n".utf8))
                }
            }
        }

        var denseJudgeAnswer: String? = nil
        var denseJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = denseJudgePayload,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                denseJudgeAnswer = answer
                denseJudgeCorrect = gradeAnswer(answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (dense) for \(question.questionID): \(error)\n".utf8))
            }
        }

        var settledRetrievedUUIDs: [String]? = nil
        var settledQueryLatencySeconds: Double? = nil
        var settledDrainLaneObserved: Bool? = nil
        if config.settle && (config.arm == .exact || config.arm == .both) {
            let _ = try await client.callTool(
                AriaV2Surface.reindex,
                arguments: [:],
                format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk
            )
            let settleOutcome = await waitForEncodeDrain(
                client: client,
                label: "lme settle \(question.questionID)"
            )
            settledDrainLaneObserved = settleOutcome.laneObserved
            let settledArgs = AriaV2Surface.memorySearchArgs(verbMap: lmeMootVerbMap, query: question.question)
            // v2: ordering arg removed; moot_memory_search defaults to byRelevanceDesc.
            let settledStart = Date()
            if config.exactStrategy == .precise {
                let sr = try await client.callTool(
                    AriaV2Surface.recallPrecise,
                    arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                    format: lmeMootVerbMap.resultFormat
                )
                settledRetrievedUUIDs = sr.orderedIDs
            } else {
                let sr = try await client.callTool(
                    lmeMootVerbMap.query,
                    arguments: settledArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                settledRetrievedUUIDs = sr.orderedIDs
                let settledPayload = sr.textBlocks.joined(separator: "\n")
                if config.exactStrategy == .auto,
                   settledPayload.contains("discrimination: low") {
                    let pr = try await client.callTool(
                        AriaV2Surface.recallPrecise,
                        arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                        format: lmeMootVerbMap.resultFormat
                    )
                    if !pr.orderedIDs.isEmpty {
                        settledRetrievedUUIDs = pr.orderedIDs
                    }
                }
            }
            settledQueryLatencySeconds = Date().timeIntervalSince(settledStart)
        }

        let taskResult = LMEQuestionResult(
            questionID: question.questionID,
            questionType: question.questionType,
            queryLatencySeconds: exactQueryLatency,
            retrievedUUIDs: retrievedUUIDs,
            manifest: manifest,
            answerSessionIDs: question.answerSessionIDs,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            guardSamplingMode: config.guardSamplingPolicy,
            turnsIngested: manifest.count,
            writeMeanLatencySeconds: writeMean,
            exactPayloadText: exactPayloadText,
            densePayloadText: densePayloadText,
            denseQueryLatencySeconds: denseQueryLatency,
            exactJudgeAnswer: exactJudgeAnswer,
            exactJudgeCorrect: exactJudgeCorrect,
            exactGoldReachable: exactGoldReachable,
            exactJudgeTokens: exactJudgePayload.map(lmeEstimateTokens),
            denseJudgeTokens: denseJudgePayload.map(lmeEstimateTokens),
            previewJudgeAnswer: previewJudgeAnswer,
            previewJudgeCorrect: previewJudgeCorrect,
            previewJudgeTokens: exactPayloadText.map(lmeEstimateTokens),
            denseJudgeAnswer: denseJudgeAnswer,
            denseJudgeCorrect: denseJudgeCorrect,
            cacheHit: true,
            drainLaneObserved: drainLaneObserved,
            synthesizePayloadText: synthesizePayloadText,
            synthesizeJudgeAnswer: synthesizeJudgeAnswer,
            synthesizeJudgeCorrect: synthesizeJudgeCorrect,
            synthesizeJudgeTokens: synthesizePayloadText.map(lmeEstimateTokens),
            settledRetrievedUUIDs: settledRetrievedUUIDs,
            settledQueryLatencySeconds: settledQueryLatencySeconds,
            settledDrainLaneObserved: settledDrainLaneObserved
        )
        freshQuestionCompleted = true
        return (originalIndex, taskResult, taskRerankCount)
    } // end runFreshQuestion

    // C6: parallel per-question path (parallelUnits > 1).
    // Results are sorted by original question index before returning so the
    // ordering is byte-deterministic regardless of task completion order.
    //
    // Error semantics (cross-port asymmetry, intentional): a per-question
    // error propagates through withThrowingTaskGroup and ABORTS the run —
    // Swift is the measurement instrument and refuses a report with holes.
    // The Rust twin records a stub result (guard_healthy=false) and continues,
    // localizing a parity diff to the failing item.
    if config.parallelUnits > 1 {
        var indexedResults: [(Int, LMEQuestionResult, Int)] = []
        indexedResults.reserveCapacity(sliced.count)
        // Bounded concurrency: at most parallelUnits tasks in flight at once.
        try await withThrowingTaskGroup(of: (Int, LMEQuestionResult, Int).self) { group in
            var pending = 0
            for (i, question) in sliced.enumerated() {
                // When the concurrency cap is reached, harvest one completed result
                // before adding the next task.
                if pending >= config.parallelUnits {
                    if let t = try await group.next() {
                        indexedResults.append(t)
                        pending -= 1
                    }
                }
                group.addTask { try await runFreshQuestion(question, at: i) }
                pending += 1
            }
            // Drain remaining in-flight tasks.
            for try await t in group {
                indexedResults.append(t)
            }
        }
        // Sort by original question index for byte-deterministic output ordering.
        indexedResults.sort { $0.0 < $1.0 }
        results = indexedResults.map { $0.1 }
        rerankFailures = indexedResults.reduce(0) { $0 + $1.2 }
        return (results, rerankFailures, await timingSampler.text())
    }

    for question in sliced {
        // Measure-only provisioning (serial twin of runFreshQuestion): restore
        // this question's pre-built estate artifact, or hard-fail. Estate
        // building is owned by the seeding pipeline (benchmarks/seeding/,
        // BENCHMARK_ESTATES.md); a miss — under any --estate-cache mode,
        // including off — is ArtifactRequiredError, never a fresh build.
        let manifest: [LMEManifestEntry]

        let cacheEntry = estateCacheEntryURL(
            cacheDir: resolvedCacheDir,
            benchmark: "lme",
            variant: config.variant,
            seed: config.seed,
            encodeBarrier: config.encodeBarrier,
            posture: config.scratchPosture,
            seedPath: config.seedPath,
            unitID: question.questionID
        )
        guard config.estateCache.readsCache,
              let (scratch, hit): (URL, [LMEManifestEntry]) =
                  try restoreEstateCacheEntry(
                      from: cacheEntry,
                      expectedProvenance: runProvenance,
                      scratchDirFactory: { try lmeScratchDir(posture: config.scratchPosture) })
        else {
            throw ArtifactRequiredError(entryPath: cacheEntry.path)
        }
        manifest = hit

        let endpoint = try lmeEndpointConfig(scratchDir: scratch,
                                             mootBinaryPath: config.mootBinaryPath,
                                             posture: config.scratchPosture,
                                             shape: config.shape)
        // Embedding-provider seam on restored estates is verified by
        // verifyEmbeddingProviderSeam inside restoreEstateCacheEntry.
        // Default deadline — see the note at the client construction in
        // runFreshQuestion.
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        // Defer teardown for this question's estate.
        // Retired only when this question finished. A throw keeps the estate
        // and says where (see keepScratchEstateOnFailure).
        var questionCompleted = false
        defer {
            Task { await client.disconnect() }
            if questionCompleted {
                try? retireScratchEstate(scratch, expectPlaintext: config.scratchPosture == .plaintextTransient, teardown: lmeGuardedTeardown)
            } else {
                keepScratchEstateOnFailure(scratch, lane: "lme")
            }
        }

        // The restored artifact is settled by construction (the seeding
        // pipeline builds import → drain → dream → reindex → drain); this
        // lane never ingests, settles, or snapshots. drainLaneObserved is
        // nil because the drain barrier does not run on a restored estate.
        let drainLaneObserved: Bool? = nil

        // DegeneracyGuard probe: sampled — probes on the first question of the leg
        // and caches the verdict for subsequent questions. Always uses the exact
        // verbMap (moot_memory_search) regardless of arm — the guard verifies
        // estate health, not arm-specific retrieval quality.
        let (verdict, _) = await guardSampler.probe {
            await probeMCPClient(client, verbMap: lmeMootVerbMap, name: "mootx01-lme")
        }
        // Use pattern matching: Verdict has associated values so `==` is unavailable.
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

        // No writes happen on a restored estate; write latency is a
        // build-time property of the artifact, not of this run.
        let writeMean = 0.0

        // Exact arm query: moot_memory_search.
        // ORDER IS LOAD-BEARING: the exact-arm query MUST run before any
        // moot_distill call. Distillation
        // is not read-only — it writes on-row distilled representations, after
        // which the originals no longer surface in default search (proven
        // 2026-07-27: LME q1 answer at rank 2 pre-distill, absent from top-20
        // post-distill, 330 rows). Distilling first contaminates the exact-arm
        // measurement; it depressed 1.1.x any@5 from ~0.85-shape to ~0.6.
        var exactPayloadText: String? = nil
        var exactQueryLatency: Double? = nil
        var retrievedUUIDs: [String] = []
        // Individual text blocks parallel to retrievedUUIDs — used to build the
        // rerank prompt (id + text preview per candidate). Populated alongside
        // retrievedUUIDs in each strategy branch.
        var exactTextBlocks: [String] = []
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
            //
            // D-2026-08-20-A: when a retrieval seam is configured, it REPLACES
            // the entire exact-arm query path. A seam failure hard-fails the
            // unit — the throw propagates out of this loop body before
            // results.append is reached, so no partial result is recorded.
            // Falling back to the default door is explicitly forbidden: a run
            // with seam args must measure the seam, never the default path.
            let queryStart = Date()
            if let spec = config.retrievalCall {
                // Seam path: override tool + args. Any call failure names the
                // unit and seam args so the error is unambiguous in the log.
                do {
                    let seamResult = try await retrieveThroughSeam(
                        question.question, client: client,
                        verbMap: lmeMootVerbMap, spec: spec,
                        arm: config.payloadArm)
                    retrievedUUIDs = seamResult.orderedIDs
                    exactTextBlocks = seamResult.textBlocks
                    exactPayloadText = seamResult.textBlocks.joined(separator: "\n")
                } catch {
                    throw MCPError(description:
                        "[lme \(question.questionID)] seam call failed "
                        + "(tool=\(spec.tool), extraArgs=\(spec.extraArgs)): \(error)")
                }
                exactQueryLatency = Date().timeIntervalSince(queryStart)
                // Reranking applies to the seam path identically to the default path.
                if let rerankCmd = config.rerankCmd {
                    let (reranked, failed) = applyRerank(
                        cmd: rerankCmd,
                        question: question.question,
                        ids: retrievedUUIDs,
                        previews: exactTextBlocks
                    )
                    retrievedUUIDs = reranked
                    if failed { rerankFailures += 1 }
                }
            } else {
            // Default path (no seam override).
            let queryArgs = AriaV2Surface.memorySearchArgs(verbMap: lmeMootVerbMap, query: question.question)
            // v2: ordering arg removed; moot_memory_search defaults to byRelevanceDesc.
            if config.exactStrategy == .shaped {
                var shapedArgs: [String: JSONValue] = [
                    lmeMootVerbMap.queryArg: .string(question.question),
                ]
                if let shape = config.recallShape {
                    shapedArgs["preset"] = .string(shape)
                }
                let shapedResult = try await client.callTool(
                    AriaV2Surface.recallShaped,
                    arguments: shapedArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = shapedResult.orderedIDs
                exactTextBlocks = shapedResult.textBlocks
                exactPayloadText = shapedResult.textBlocks.joined(separator: "\n")
            } else if config.exactStrategy == .precise {
                let preciseResult = try await client.callTool(
                    AriaV2Surface.recallPrecise,
                    arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = preciseResult.orderedIDs
                exactTextBlocks = preciseResult.textBlocks
                exactPayloadText = preciseResult.textBlocks.joined(separator: "\n")
            } else {
                let queryResult = try await client.callTool(
                    lmeMootVerbMap.query,
                    arguments: queryArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                retrievedUUIDs = queryResult.orderedIDs
                exactTextBlocks = queryResult.textBlocks
                exactPayloadText = queryResult.textBlocks.joined(separator: "\n")
                // Documented escalation: low discrimination → recall_precise.
                if config.exactStrategy == .auto,
                   exactPayloadText?.contains("discrimination: low") == true {
                    let preciseResult = try await client.callTool(
                        AriaV2Surface.recallPrecise,
                        arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                        format: lmeMootVerbMap.resultFormat
                    )
                    if !preciseResult.orderedIDs.isEmpty {
                        retrievedUUIDs = preciseResult.orderedIDs
                        exactTextBlocks = preciseResult.textBlocks
                        exactPayloadText = preciseResult.textBlocks.joined(separator: "\n")
                    }
                }
            }
            exactQueryLatency = Date().timeIntervalSince(queryStart)

            // Post-retrieval reranking (W2-rerank): hand the top `rerankWindowSize`
            // hits to the external command before scoring. The raw payload text is
            // kept as-is for diagnostics; only the ranked ID list is updated.
            if let rerankCmd = config.rerankCmd {
                let (reranked, failed) = applyRerank(
                    cmd: rerankCmd,
                    question: question.question,
                    ids: retrievedUUIDs,
                    previews: exactTextBlocks
                )
                retrievedUUIDs = reranked
                if failed { rerankFailures += 1 }
            }
            } // end else (default path — no seam override)
        }

        // Dense arm: moot_distill is retired on the ARIA v2 surface
        // (negative_catalog_assertions absent_reason: "Retired alias.").
        // The dense arm refuses with a typed error; Swift parity: Rust
        // returns LaneError::Config via aria_v2_surface::refused_distill_call().
        let densePayloadText: String? = nil
        let denseQueryLatency: Double? = nil
        if config.arm == .dense || config.arm == .both {
            throw AriaV2SurfaceError.retiredOperation("moot_distill")
        }

        // Judge payload hydration (answer-accuracy path).
        //
        // The recall verbs return a 120-CHARACTER PREVIEW per hit
        // (`ToolDispatch.swift`: `content.prefix(120)`) — the right shape for
        // a search tool's token economy, and useless as judge context: a
        // conversational turn's answer usually sits past character 120, so a
        // judge reading previews answers "I don't know" even when the correct
        // item ranked first. That is what produced answer accuracy 0.20
        // against recall-any@5 0.90, and the long-standing
        // exact-evidence-rate 0.000.
        //
        // So when a judge is configured, the ranked ids are hydrated to FULL
        // content via `moot_memory_get` and the judge reads that. Retrieval
        // metrics are untouched — they score the ranked id list, which this
        // does not change. Hydration is capped at the top `judgePayloadHydrationDepth`
        // hits: the judge only needs the head of the ranking, and hydrating
        // fifty items per question would dominate run time.
        //
        // A failed fetch falls back to that hit's preview rather than
        // dropping the hit, so a partial hydration degrades the payload
        // instead of silently shrinking it.
        func hydratedPayload(ids: [String], fallback: String?) async -> String? {
            // Widen: hydrate when judgeCmd is set OR when dump-judge-inputs was
            // requested, so pre-judge JSONL captures the full payload even in
            // offline-dump-only runs (no live judge subprocess needed).
            guard config.judgeCmd != nil || config.dumpJudgeInputsPath != nil,
                  !ids.isEmpty else { return fallback }
            var blocks: [String] = []
            for id in ids.prefix(config.judgeHydrationDepth) {
                do {
                    let full = try await client.callTool(
                        AriaV2Surface.memoryGet,
                        arguments: AriaV2Surface.memoryGetArgs(memoryId: id),
                        format: lmeMootVerbMap.resultFormat
                    )
                    let text = full.textBlocks.joined(separator: "\n")
                    if !text.isEmpty { blocks.append(text) }
                } catch {
                    FileHandle.standardError.write(Data(
                        "[lme] hydrate failed for \(id): \(error)\n".utf8))
                }
            }
            return blocks.isEmpty ? fallback : blocks.joined(separator: "\n\n")
        }

        let exactJudgePayload = await hydratedPayload(
            ids: retrievedUUIDs, fallback: exactPayloadText)
        // The DENSE arm is deliberately NOT hydrated. Its payload is the
        // distilled, token-efficient rendering from `moot_recall_distilled`,
        // and that text is the thing under test: the question this arm answers
        // is whether a judge can still answer from the distillate. Hydrating it
        // to full content would substitute the original text and collapse the
        // dense arm into the exact arm, measuring nothing.
        let denseJudgePayload = densePayloadText

        // Pre-judge JSONL: append one question line per question to the dump file.
        // Written before the judge subprocess runs so the payload is captured even
        // if the judge call fails or is absent (dump-only mode).
        if let dumpPath = config.dumpJudgeInputsPath {
            let questionLine: [String: Any?] = [
                "type": "question",
                "question_id": question.questionID,
                "question": question.question,
                "gold_answer": question.answer,
                "exact_payload": exactJudgePayload,
                "exact_payload_tokens": exactJudgePayload.map(lmeEstimateTokens),
                "dense_payload": denseJudgePayload,
                "dense_payload_tokens": denseJudgePayload.map(lmeEstimateTokens),
            ]
            // Coerce Optional values to NSNull so JSONSerialization writes null.
            let coerced: [String: Any] = questionLine.mapValues { v in
                if case let val? = v { return val as Any }
                return NSNull()
            }
            if let lineData = try? JSONSerialization.data(withJSONObject: coerced, options: [.sortedKeys]),
               var lineStr = String(data: lineData, encoding: .utf8) {
                lineStr += "\n"
                if let fh = FileHandle(forWritingAtPath: dumpPath) {
                    fh.seekToEndOfFile()
                    fh.write(Data(lineStr.utf8))
                    fh.closeFile()
                }
            }
        }

        // Judge mode (Part 4): optional LLM-judged QA per arm.
        // Soft errors (failed subprocess, non-zero exit) are logged and skipped —
        // a judge failure does not fail the question; the answer fields stay nil.
        // Grades one candidate answer under the run's grading mode. Verdict
        // mode spends a SECOND judge call to ask for a correctness verdict —
        // the protocol published leaderboard figures are produced under —
        // and falls back to substring grading when that verdict is
        // unparseable, so a chatty judge degrades the grade rather than
        // failing the question.
        func gradeAnswer(_ answer: String) -> Bool {
            switch config.judgeGrading {
            case .substring:
                return lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
            case .verdict:
                guard let judgeCmd = config.judgeCmd else {
                    return lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
                }
                let vPrompt = lmeVerdictPrompt(question: question.question,
                                               goldAnswer: question.answer,
                                               candidateAnswer: answer)
                guard let reply = try? lmeRunJudge(cmd: judgeCmd, prompt: vPrompt),
                      let verdict = lmeParseVerdict(reply) else {
                    FileHandle.standardError.write(Data(
                        "[lme] verdict unparseable for \(question.questionID) — falling back to substring\n".utf8))
                    return lmeGradeJudgeAnswer(answer, goldAnswer: question.answer)
                }
                return verdict
            }
        }

        // Retrieval ceiling for the judged metric: did the gold answer text
        // even reach the judge's context? See lmeGoldAnswerInPayload.
        let exactGoldReachable: Bool? = exactJudgePayload.map {
            lmeGoldAnswerInPayload(goldAnswer: question.answer, payloadText: $0)
        }

        var exactJudgeAnswer: String? = nil
        var exactJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = exactJudgePayload,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                exactJudgeAnswer = answer
                exactJudgeCorrect = gradeAnswer(answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (exact) for \(question.questionID): \(error)\n".utf8))
            }
        }

        // THIRD payload mode: the raw PREVIEW payload, judged as-is. The three
        // modes form the token/quality frontier a consumer actually chooses
        // between — preview (cheapest, 120 chars/hit), distilled (mid), full
        // hydrated content (most expensive). Judging all three on the same
        // question with the same judge is the only way to say which is worth
        // its tokens.
        var previewJudgeAnswer: String? = nil
        var previewJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = exactPayloadText,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                previewJudgeAnswer = answer
                previewJudgeCorrect = gradeAnswer(answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (preview) for \(question.questionID): \(error)\n".utf8))
            }
        }

        // FOURTH payload mode: moot_synthesize (--synthesize-arm, PR-08).
        //
        // The synthesize verb grounds on the question (its `query` argument
        // scopes recall to cue-relevant memories) and returns a synthesized
        // context document — summary, patterns, recommendations, insights —
        // not ranked IDs. This makes it fundamentally different from the
        // other three modes — there is no retrieval list to score recall
        // against. Only the judge accuracy metric is measurable.
        //
        // The cell is publishable regardless of how it scores: the corrections-
        // table ethos applies here. No pre-judgment appears in code or comments.
        //
        // Ordering: after the exact arm (which may distill on the dense path).
        // moot_synthesize is read-only — it does not mutate the estate.
        var synthesizePayloadText: String? = nil
        var synthesizeJudgeAnswer: String? = nil
        var synthesizeJudgeCorrect: Bool? = nil
        if config.synthesizeArm {
            do {
                var synthArgs: [String: JSONValue] = [
                    lmeMootVerbMap.queryArg: .string(question.question),
                ]
                if let synthLimit = config.synthesizeLimit {
                    synthArgs["limit"] = .number(Double(synthLimit))
                }
                let synthResult = try await client.callTool(
                    AriaV2Surface.synthesize,
                    arguments: synthArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                synthesizePayloadText = synthResult.textBlocks.joined(separator: "\n")
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] moot_synthesize error for \(question.questionID): \(error)\n".utf8))
            }
            if let judgeCmd = config.judgeCmd,
               let payload = synthesizePayloadText,
               !payload.isEmpty {
                let prompt = lmeJudgePrompt(question: question.question, payload: payload)
                do {
                    let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                    synthesizeJudgeAnswer = answer
                    synthesizeJudgeCorrect = gradeAnswer(answer)
                } catch {
                    FileHandle.standardError.write(Data(
                        "[lme] judge error (synthesize) for \(question.questionID): \(error)\n".utf8))
                }
            }
        }

        var denseJudgeAnswer: String? = nil
        var denseJudgeCorrect: Bool? = nil
        if let judgeCmd = config.judgeCmd,
           let payload = denseJudgePayload,
           !payload.isEmpty {
            let prompt = lmeJudgePrompt(question: question.question, payload: payload)
            do {
                let answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                denseJudgeAnswer = answer
                denseJudgeCorrect = gradeAnswer(answer)
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme] judge error (dense) for \(question.questionID): \(error)\n".utf8))
            }
        }

        // Settle cell (--settle mode): trigger moot_reindex, wait for drain
        // to converge, then re-run the exact-arm queries as the SETTLED cell.
        // Runs only after the organic cell's exact query so both cells use the
        // same estate and haystack; the dense arm is NOT re-run (consolidation
        // is not re-entrant and the dense cell is not a settle target).
        var settledRetrievedUUIDs: [String]? = nil
        var settledQueryLatencySeconds: Double? = nil
        var settledDrainLaneObserved: Bool? = nil
        if config.settle && (config.arm == .exact || config.arm == .both) {
            // Trigger background reindex so every drawer is at full coverage.
            let _ = try await client.callTool(
                AriaV2Surface.reindex,
                arguments: [:],
                format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk
            )
            // Wait for the corpus_encode drain to converge after reindex.
            let settleOutcome = await waitForEncodeDrain(
                client: client,
                label: "lme settle \(question.questionID)"
            )
            settledDrainLaneObserved = settleOutcome.laneObserved
            // Re-run the exact-arm queries with the same strategy as the organic cell.
            let settledArgs = AriaV2Surface.memorySearchArgs(verbMap: lmeMootVerbMap, query: question.question)
            // v2: ordering arg removed; moot_memory_search defaults to byRelevanceDesc.
            let settledStart = Date()
            if config.exactStrategy == .precise {
                let sr = try await client.callTool(
                    AriaV2Surface.recallPrecise,
                    arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                    format: lmeMootVerbMap.resultFormat
                )
                settledRetrievedUUIDs = sr.orderedIDs
            } else {
                let sr = try await client.callTool(
                    lmeMootVerbMap.query,
                    arguments: settledArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                settledRetrievedUUIDs = sr.orderedIDs
                let settledPayload = sr.textBlocks.joined(separator: "\n")
                if config.exactStrategy == .auto,
                   settledPayload.contains("discrimination: low") {
                    let pr = try await client.callTool(
                        AriaV2Surface.recallPrecise,
                        arguments: [lmeMootVerbMap.queryArg: .string(question.question)],
                        format: lmeMootVerbMap.resultFormat
                    )
                    if !pr.orderedIDs.isEmpty {
                        settledRetrievedUUIDs = pr.orderedIDs
                    }
                }
            }
            settledQueryLatencySeconds = Date().timeIntervalSince(settledStart)
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
            guardSamplingMode: config.guardSamplingPolicy,
            // Restored artifact: the manifest names every record the seeding
            // pipeline imported, so its count is the ingested count.
            turnsIngested: manifest.count,
            writeMeanLatencySeconds: writeMean,
            exactPayloadText: exactPayloadText,
            densePayloadText: densePayloadText,
            denseQueryLatencySeconds: denseQueryLatency,
            exactJudgeAnswer: exactJudgeAnswer,
            exactJudgeCorrect: exactJudgeCorrect,
            exactGoldReachable: exactGoldReachable,
            exactJudgeTokens: exactJudgePayload.map(lmeEstimateTokens),
            denseJudgeTokens: denseJudgePayload.map(lmeEstimateTokens),
            previewJudgeAnswer: previewJudgeAnswer,
            previewJudgeCorrect: previewJudgeCorrect,
            previewJudgeTokens: exactPayloadText.map(lmeEstimateTokens),
            denseJudgeAnswer: denseJudgeAnswer,
            denseJudgeCorrect: denseJudgeCorrect,
            cacheHit: true,
            drainLaneObserved: drainLaneObserved,
            synthesizePayloadText: synthesizePayloadText,
            synthesizeJudgeAnswer: synthesizeJudgeAnswer,
            synthesizeJudgeCorrect: synthesizeJudgeCorrect,
            synthesizeJudgeTokens: synthesizePayloadText.map(lmeEstimateTokens),
            settledRetrievedUUIDs: settledRetrievedUUIDs,
            settledQueryLatencySeconds: settledQueryLatencySeconds,
            settledDrainLaneObserved: settledDrainLaneObserved
        ))
        questionCompleted = true
    }

    return (results, rerankFailures, await timingSampler.text())
}

// MARK: - Default mootx01 binary discovery

/// Probes candidate binary paths in order and returns the first executable one.
/// Falls back to `~/.mootx01/bin/mootx01` (installed binary) then to the CE
/// debug build (relative to the current working directory at invocation time).
///
/// The caller may override with `--mootx01-binary` to short-circuit this search.
func discoverMootBinary() -> String? {
    // ISOLATION RULE ( operator ruling 2026-08-18): measurement never uses the installed
    // binary — it builds one from the CURRENT TREE and uses it in 100%
    // isolation. The installed ~/.mootx01/bin candidate that used to lead this
    // list silently substituted a stale product for the tree under test (found
    // by the locomo-spec smoke: a pre-return_id_map install shadowed the fresh
    // tree build). Discovery now looks ONLY at this repo's own build products,
    // release before debug; anything else must be passed explicitly via
    // --mootx01-binary (or built by `make moot-binary`).
    let candidates = [
        // This repo's product build (harness cwd is benchmarks/).
        "../apps/mootx01/.build/release/mootx01",
        "../apps/mootx01/.build/debug/mootx01",
        // In-package build paths (harness invoked from a package checkout).
        ".build/out/Products/Debug/mootx01",
        ".build/debug/mootx01",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
