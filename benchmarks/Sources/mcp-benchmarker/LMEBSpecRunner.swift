import Foundation

// LMEBSpecRunner.swift — Official LMEB-spec and ConvoMem-spec runner.
//
// Estate source contract: the runner opens PRE-BUILT artifact estates via the
// id-map.json seam. It builds nothing, settles nothing, and never deletes anything.
// At unit scale one fleet estate per scene is opened (unit stem = "<set>__scene_<i>",
// e.g. "user_evidence__scene_0"). At bench-aggregate one estate is opened serially.
// id-map.json keys are the artifact's session-level seed ids
// "<set>/scene_<i>_session_<j>" (e.g. "user_evidence/scene_0_session_1") —
// NOT the corpus loader's turn-level "__"-namespaced docIDs. qrels ground
// truth is folded turn → session (lmebArtifactSessionKey) before scoring.
//
// Two run modes over the same per-query artifact retrieval machinery:
//
//   1. lmeb-spec retrieval mode (§A1–§A4):
//      §A4: when with-instruction is on, the subset's verbatim instruction string
//      (from LMEBSpecMetrics.swift) is prepended to the recall query before
//      moot_memory_search. Scores the ranked list through LMEBSpecMetrics: full grid
//      at k∈{1,5,10,25,50}, R_cap, both aggregation levels (subset-level macro mean
//      → task mean). Per-query values are emitted into records.
//
//   2. convomem-spec judged mode (§B1–§B4):
//      Retrieves memories as above (same artifact estate open, same pool from id-map,
//      §A2 scope equivalence), builds the §B1 memory-based answer prompt from the
//      top-K retrieved corpus texts, obtains the answer through the harness's BYOAI
//      external-command seam (the same lmeRunJudge subprocess seam from
//      LongMemEvalJudge.swift), selects the §B2 judge template by evidence type via
//      ConvoMemSpecProtocol.swift, applies the §B3 verdict rule with bounded retries
//      for invalid responses (distinct from .incorrect — exhausted retries leave the
//      question unscored per §B3), and aggregates per §B4 (accuracy per type, per
//      evidence count, overall). With no answerCmd/judgeCmd set, answered_count and
//      judged_count are 0 — mechanisms are complete, no heuristic fallback scoring.
//
// Record naming (RecordWriter conventions):
//   lmeb-spec-<arm>-<serial>.json       / lmeb-spec-<arm>-<serial>-params.json
//   convomem-spec-<arm>-<serial>.json   / convomem-spec-<arm>-<serial>-params.json
//
// DO NOT wire CLI entry points. The orchestrator wires the lanes.
// Public run functions match the existing runner's signature style.

// MARK: - VerbMap

// Bare verb map: NO constant location arg — artifact estates are provenance-blind
// (rooms carry nothing benchmark-shaped). Mirrors lmeSpecVerbMap pattern.
private let lmebSpecVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: [:],
    resultFormat: .mootV2
)

// MARK: - Extended query type (with evidence type and optional QA annotation)

/// An LMEB query extended with the evidence-type label and optional QA annotation
/// fields needed for the spec runner's two modes.
///
/// Wraps `LMEBQuery` so that callers loading per-subset query lists can tag each
/// query with its subset name and, for ConvoMem-spec judged mode, with the QA
/// fields the §B1/§B2 prompts require.
///
/// For lmeb-spec retrieval mode, only `query` and `evidenceType` are needed.
/// For convomem-spec judged mode, `correctAnswer`, `evidenceCount`, and
/// `evidenceMessages` are additionally required. When unavailable (e.g. the QA
/// annotation file has not been loaded — see MOOT FUNCTION NEEDED below), defaults
/// are (correctAnswer: nil → judging skipped, evidenceCount: 1, evidenceMessages: []).
struct LMEBSpecQuery: Sendable {
    /// The base LMEB query (id, text, optional gold answer).
    let query: LMEBQuery
    /// Evidence type for this query, e.g. "user_evidence". Used for §A4 instruction
    /// lookup and §B2 judge template selection.
    let evidenceType: String
    /// Ground-truth correct answer for this query. Used in §B2 judge prompts.
    /// Sourced from query.answer when available. Nil → judge step is skipped for
    /// this query and it is counted as unscored.
    var correctAnswer: String? { query.answer }
    /// Number of evidence documents supporting this question. Controls §B2 branch
    /// selection for UserFactsAnsweringEvaluation (single vs multi-evidence form).
    /// Populated from ConvoMem QA annotations; defaults to 1 when not loaded.
    var evidenceCount: Int = 1
    /// Evidence message texts for §B2 UserFacts judge prompt. Populated from ConvoMem
    /// QA annotations; empty when not loaded (judge prompt degrades gracefully to the
    /// single-evidence form with evidenceCount=1 and no embedded evidence text).
    var evidenceMessages: [ConvoMemEvidenceMessage] = []
}

// MARK: - Run config

/// Configuration for an LMEB-spec or ConvoMem-spec run.
///
/// Fields shared with LMEBRunConfig are listed first with identical semantics.
/// Spec-specific fields follow. The config is passed verbatim to both the
/// lmeb-spec and convomem-spec public run functions; mode-specific fields are
/// ignored when running the other mode.
struct LMEBSpecRunConfig: Sendable {
    // ── Fields shared with LMEBRunConfig ─────────────────────────────────────
    let mootBinaryPath: String
    let dataDir: URL
    let evidenceTypes: [String]
    let limit: Int?
    let offset: Int
    let seed: UInt64
    let outDir: URL?
    let runLabel: String
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
    var corpusDigest: String = "unknown"
    var parallelUnits: Int = 1
    /// When non-nil, only queries whose id is in this set run.
    /// The full corpus is still loaded (corpus_digest unchanged); the filter
    /// selects which queries run before the seeded shuffle.
    var unitIDs: Set<String>? = nil
    /// File path the unit-ID set was loaded from. Recorded in the report for
    /// subset identity per the testname-arm-serial discipline.
    var unitIDsPath: String? = nil

    // ── Artifact estate seam ─────────────────────────────────────────────────
    /// Which artifact scale the run opens. Default .unit (one fleet estate per scene).
    /// At .benchAggregate, one estate is opened serially for every query.
    var targetScale: ArtifactTargetScale = .unit
    /// Catalog.json path for the dataset (maps unit stems to estate directories).
    /// Required at .unit scale.
    var catalogPath: URL? = nil
    /// The bench-aggregate estate directory. Required at .benchAggregate scale.
    var estateDir: URL? = nil

    // ── §A4: Instruction setting ──────────────────────────────────────────────
    /// Whether to prepend the subset's §A4 instruction string to the recall query.
    /// Recorded per run; both settings produce published LMEB numbers.
    /// Default: .withoutInstruction (the canonical zero-instruction baseline).
    var instructionSetting: LMEBInstructionSetting = .withoutInstruction

    // ── §A3: Evaluation options ───────────────────────────────────────────────
    /// skip_first_result and ignore_identical_ids switches (§A3, both default off).
    var specOptions: LMEBSpecOptions = .default

    // ── Recall scoring strategy ───────────────────────────────────────────────
    /// When non-nil, passed as `"scoring"` in the moot_memory_search argument dict.
    /// Accepted values: "raw", "rrf", "matrixAware", "discriminative".
    /// When nil, the key is absent and the estate uses its default scoring — the
    /// call is byte-identical to the pre-flag baseline.
    /// Mutually exclusive with `recallShape`: the CLI parse rejects both together.
    var scoringStrategy: String? = nil

    // ── Recall shape preset ───────────────────────────────────────────────────
    /// When non-nil, the per-query recall call switches to moot_recall_shaped and
    /// passes this value as `"preset"`. The server validates the preset against its
    /// roster and fails closed on unknown names — the client passes through unvalidated.
    /// Mutually exclusive with `scoringStrategy`: moot_recall_shaped always runs
    /// matrixAware internally and does not accept a `"scoring"` key.
    /// When nil, the verb is moot_memory_search (byte-identical to the pre-flag baseline).
    var recallShape: String? = nil

    // ── §B1: Answer generation (convomem-spec mode) ───────────────────────────
    /// Shell command for answer generation, e.g. "claude -p" or "ollama run llama3 -".
    /// Nil → answer step is skipped, answered_count = 0.
    /// SECRECY: only boolean presence (answer_cmd_set) is written to the report.
    /// The command text itself — which may carry API keys — is never logged.
    var answerCmd: String? = nil

    /// Number of top-ranked corpus texts passed to the §B1 memory-based prompt.
    /// Default: 10 (matching the LME arm's default hydration depth).
    var answerHydrationDepth: Int = 10

    /// Depth tier passed as the `depth` argument to `moot_memory_get` during estate
    /// hydration. Distilled is the production shape — the reader sees what a real
    /// caller would receive. Full is the comparison arm for ablation.
    /// Default: .distilled (production shape; rows without a distillate fall back to
    /// full content on the server side — the server marks those `served_from_content`).
    var answerHydrationTier: HydrationDepth = .distilled

    // ── §B2/§B3: Judging (convomem-spec mode) ────────────────────────────────
    /// Shell command for judge calls (§B2/§B3), e.g. "gemini-flash -p".
    /// Nil → judge step is skipped, judged_count = 0. NO heuristic fallback.
    /// SECRECY: only boolean presence (judge_cmd_set) is written to the report.
    var judgeCmd: String? = nil

    /// Maximum retry count for the §B3 bounded retry loop on invalid judge responses.
    /// Exhausted retries yield no verdict (question unscored per §B3); the question
    /// is NOT scored incorrect — invalid means the judge response contained neither
    /// "right" nor "wrong" after trim+lowercase (see convoMemVerdict in
    /// ConvoMemSpecProtocol.swift).
    var judgeMaxRetries: Int = 3

    /// Judge identity string recorded in the ConvoMem-spec report per §B4.
    /// Example: "gemini-flash". Default: "unknown" when not configured.
    var judgeIdentity: String = "unknown"

    // ── Offline-batch dump paths ───────────────────────────────────────────────
    /// Path to write the per-query answer-input JSONL dump (offline-batch answer path).
    /// When set, one JSON line per query is appended after retrieval with:
    ///   { "type": "answer_input", "query_id", "evidence_type", "question",
    ///     "memory_texts": [...], "correct_answer": ... }
    /// Nil → no answer-input dump written.
    var dumpAnswerInputsPath: String? = nil

    /// Path to write the per-query judge-input JSONL dump (offline-batch judge path).
    /// When set, one JSON line per query is appended after answer generation with:
    ///   { "type": "judge_input", "query_id", "evidence_type", "evidence_count",
    ///     "question", "correct_answer", "model_answer", "judge_prompt" }
    /// Nil → no judge-input dump written.
    var dumpJudgeInputsPath: String? = nil

    // ── Expand-verify scoreboard (§1 / §7.5) ─────────────────────────────────
    /// Per-question verb limit sent as `"limit"` in every recall call.
    /// Default 20 matches the estate default and today's observed behaviour.
    /// The value is always sent explicitly so it is recorded in the report params.
    var requestLimit: Int = 20

    /// Pool metrics mode: 0 = off (pool = returned list, no explain payload sent),
    /// non-zero = on (request explain payload, read pool structure from response).
    /// Default 0 keeps all runs byte-identical to today's baseline.
    /// Read via poolMetricsEnabled.
    var poolMetricsMode: Int = 0

    /// True when pool metrics are active (poolMetricsMode != 0).
    var poolMetricsEnabled: Bool { poolMetricsMode != 0 }

    /// Short-query term threshold (§7.1): a question is short when its content-term
    /// count (lowercase alnum tokens minus the shared EN stopword fixture) is less
    /// than this value. Default 4 matches the spec default.
    var shortQueryTerms: Int = 4
}

// MARK: - Per-query result types

/// Per-query result for lmeb-spec retrieval mode. Carries both raw retrieval data
/// (from the estate loop) and computed spec metrics (from LMEBSpecMetrics).
struct LMEBSpecQueryResult: Sendable {
    /// Query identifier, e.g. "scene_42_q_0".
    let queryID: String
    /// Evidence type for this query (one of the six ConvoMem subsets).
    let evidenceType: String
    /// moot_memory_search latency in seconds.
    let queryLatencySeconds: Double
    /// Ranked doc IDs produced by UUID→docID mapping; NUL-prefixed for any unmapped UUID.
    let retrievedDocIDs: [String]
    /// Ground-truth relevant document IDs.
    let relevantDocIDs: Set<String>
    /// True when DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// Guard diagnostic message when not healthy.
    let guardDiagnostic: String?
    /// Guard sampling policy in effect.
    let guardSamplingMode: GuardSamplingPolicy
    /// Candidate docs ingested for this query.
    let docsIngested: Int
    /// Mean write latency (seconds) across ingested docs (0.0 for batch path).
    let writeMeanLatencySeconds: Double
    /// Estate cache status: true=hit, false=miss, nil=cache off.
    let cacheHit: Bool?
    /// Whether the drain barrier observed the corpus_encode lane registered.
    let drainLaneObserved: Bool?
    /// §A4 instruction setting in effect for this query.
    let instructionSetting: LMEBInstructionSetting
    /// The actual query text sent to moot_memory_search (instruction-augmented when applicable).
    let effectiveQueryText: String
    /// Full metric grid at every k in lmebSpecKValues (§A3). Computed by
    /// lmebSpecPerQueryMetrics with config.specOptions applied.
    let specMetrics: LMEBSpecQueryMetrics

    // ── Expand-verify scoreboard fields (§1 / §7.5) ───────────────────────────

    /// Content-term count of the effective query text (lowercase alnum tokens minus
    /// the shared EN stopword fixture). Used for §7.1 short-query gate.
    let contentTermCount: Int

    /// 1-based ranks of gold docs within the returned list (absent → rank not returned).
    /// Used to compute gold-in-pool and pool guarantee metrics.
    let goldRanks: [Int]

    /// Pool size: equals returned_count when --pool-metrics is off (default);
    /// equals the explain-payload pool count when --pool-metrics is on.
    let poolSize: Int

    /// 1 when at least one gold doc appears in the pool; 0 otherwise.
    /// Stored as Int for JSON serialisation (0/1 int per the brief schema).
    let poolGoldHit: Int

    /// Silo provenance map from the explain payload: silo_id → candidate count.
    /// Empty when --pool-metrics is off or the payload carries no pool structure.
    let poolProvenance: [String: Int]
}

/// Per-query result for convomem-spec judged mode. Carries retrieval data and
/// the §B1–§B4 judging fields.
struct ConvoMemSpecQueryResult: Sendable {
    /// Query identifier.
    let queryID: String
    /// Evidence type (one of the six ConvoMem subsets — governs §B2 template selection).
    let evidenceType: String
    /// Evidence count for §B2 UserFacts branch selection (single vs multi-evidence).
    let evidenceCount: Int
    /// The question text sent to the answer model.
    let questionText: String
    /// moot_memory_search latency in seconds.
    let queryLatencySeconds: Double
    /// Ranked doc IDs from the retrieval step.
    let retrievedDocIDs: [String]
    /// Ground-truth relevant document IDs.
    let relevantDocIDs: Set<String>
    /// True when DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// Guard diagnostic message when not healthy.
    let guardDiagnostic: String?
    /// Estate cache status: true=hit, false=miss, nil=cache off.
    let cacheHit: Bool?
    /// Memory texts (top-K corpus doc texts) passed to the §B1 prompt.
    let retrievedMemoryTexts: [String]
    /// The §B1 memory-based answer prompt sent to answerCmd. Nil when answerCmd
    /// was not configured.
    let answerPrompt: String?
    /// The model's answer returned by answerCmd. Nil when answerCmd was not set,
    /// or when the subprocess failed (error is logged to stderr; failure is soft
    /// so one query does not abort the run).
    let modelAnswer: String?
    /// The §B2 judge prompt. Nil when answerCmd was not set (judging requires an answer).
    let judgePrompt: String?
    /// §B3 verdict outcome. Nil when judging did not run.
    let verdictOutcome: ConvoMemVerdictOutcome?
    /// True when the §B3 retry count was exhausted without a valid verdict.
    /// The question is unscored (not counted as incorrect) per §B3.
    let retriesExhausted: Bool
    /// True when §B3 detected an ambiguous response (both "right" and "wrong")
    /// and defaulted to incorrect per §B3.
    let ambiguousVerdictWarned: Bool
    /// Estimated tokens in the memory-context payload sent to the answer model.
    let answerPayloadTokens: Int?
}

// MARK: - Run results

/// Aggregated results for a lmeb-spec retrieval run.
struct LMEBSpecRunResults: Sendable {
    /// Per-query results, in the shuffled+sliced order processed by the runner.
    let perQueryResults: [LMEBSpecQueryResult]
    /// Per-subset (level-1) aggregated metrics.
    let subsetMetrics: [LMEBSpecSubsetMetrics]
    /// Task-level (level-2) aggregated metrics (mean of subset scores).
    let taskMetrics: LMEBSpecTaskMetrics
    /// Leg timing report (from C4 audit timing capture). Nil when every estate
    /// was restored from cache or the capture failed.
    let timingReport: String?
    /// Number of queries whose guard verdict was not .healthy (excluded from
    /// published numbers per degeneracy protocol).
    let guardExcludedCount: Int
    /// Total queries processed (sliced list after seed-shuffle + offset/limit).
    let totalQueries: Int
    /// §A4 instruction setting used for this run.
    let instructionSetting: LMEBInstructionSetting
    /// §A3 spec options (skip_first_result, ignore_identical_ids).
    let specOptions: LMEBSpecOptions
    /// Pending dreaming jobs in the shared estate at measurement start.
    /// 0 for unit-scale runs (no shared estate).
    var dreamPending: Int = 0
    /// Dreaming drain lane state at measurement start: 0 = idle or absent, 1 = draining.
    /// 0 for unit-scale runs (no shared estate).
    var dreamDraining: Int = 0
}

/// Aggregated results for a convomem-spec judged run.
struct ConvoMemSpecRunResults: Sendable {
    /// Per-query results, in the shuffled+sliced order processed.
    let perQueryResults: [ConvoMemSpecQueryResult]
    /// §B4 aggregation result. Nil when judgedCount == 0 (no judging ran,
    /// e.g. answerCmd or judgeCmd was not configured).
    let aggregateResult: ConvoMemAggregateResult?
    /// Total queries that produced a model answer (answerCmd returned successfully).
    let answeredCount: Int
    /// Total questions that received a scored or unscored verdict from the judge.
    let judgedCount: Int
    /// Total queries processed.
    let totalQueries: Int
    /// Leg timing report (from C4 audit timing capture).
    let timingReport: String?
    /// Number of queries excluded by the DegeneracyGuard.
    let guardExcludedCount: Int
    /// Judge identity string recorded per §B4.
    let judgeIdentity: String
    /// Whether the answer command was set (secrecy: command text not recorded).
    let answerCmdSet: Bool
    /// Whether the judge command was set (secrecy: command text not recorded).
    let judgeCmdSet: Bool
    /// Queries for which memory_texts was empty after estate hydration.
    /// A run where this equals totalQueries is a broken hydration — the lane
    /// exits non-zero naming the first affected query.
    let memoryTextsEmptyCount: Int
    /// Pending dreaming jobs in the shared estate at measurement start.
    /// 0 for unit-scale runs (no shared estate).
    var dreamPending: Int = 0
    /// Dreaming drain lane state at measurement start: 0 = idle or absent, 1 = draining.
    /// 0 for unit-scale runs (no shared estate).
    var dreamDraining: Int = 0
}

// MARK: - §A4: Instruction-augmented query text

/// Returns the query text to send to moot_memory_search, prepending the §A4
/// instruction string when the run uses the with-instruction setting.
///
/// §A4 verbatim: the per-subset instruction string is prepended to the query.
/// Concatenation format: `"{instruction}\n{queryText}"` — the newline separator
/// follows the MTEB convention for embedding models that accept instruction+query input.
///
/// When the evidence type is not among the six ConvoMem subsets (unknown type),
/// the query text is returned unchanged and a warning is emitted to stderr.
///
/// - Parameters:
///   - queryText: The original query text from queries.jsonl.
///   - evidenceType: The subset name (e.g. "user_evidence").
///   - setting: Whether to prepend the instruction.
/// - Returns: The query text to send; unchanged when setting is .withoutInstruction.
func lmebSpecEffectiveQuery(
    queryText: String,
    evidenceType: String,
    setting: LMEBInstructionSetting
) -> String {
    guard setting == .withInstruction else { return queryText }
    guard let instruction = LMEBSubsetInstructions.bySubset[evidenceType] else {
        FileHandle.standardError.write(Data(
            ("[lmeb-spec] WARNING: no §A4 instruction for unknown evidenceType '\(evidenceType)' "
            + "— query sent without instruction\n").utf8))
        return queryText
    }
    // §A4: prepend instruction. "\n" separator follows MTEB embedding instruction convention.
    return instruction + "\n" + queryText
}

// MARK: - Concurrent dump-file writer (offline-batch paths)

/// Serializes concurrent JSONL appends to the offline-batch dump files.
/// Mirrors DumpFileWriter in LMEBRunner.swift — actor-based so multiple Swift
/// tasks can safely call append(_:) in parallel.
private actor LMEBSpecDumpWriter {
    private let path: String
    init(_ path: String) { self.path = path }
    /// Appends one newline-terminated JSONL line to the dump file.
    func append(_ line: String) {
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    }
}

// MARK: - MOOT FUNCTION NEEDED: ConvoMem QA annotation loader

// MOOT FUNCTION NEEDED: loadConvoMemEvidenceAnnotations(forQueryID:subsetDataDir:)
//   — returns (evidenceCount: Int, evidenceMessages: [ConvoMemEvidenceMessage])
//
// Inputs:
//   queryID:       String  — the ConvoMem query identifier (e.g. "scene_0_q_0").
//   subsetDataDir: URL     — the on-disk directory for one evidence type subset,
//                            expected to contain the QA annotation file (format TBD
//                            from the ConvoMem/SalesforceAIResearch dataset schema).
//
// Outputs:
//   evidenceCount:    Int                       — number of evidence documents for this
//                                                 question; controls the §B2 branch in
//                                                 UserFactsAnsweringEvaluation (single vs
//                                                 multi-evidence form).
//   evidenceMessages: [ConvoMemEvidenceMessage] — evidence message texts embedded verbatim
//                                                 in the §B2 UserFacts judge prompt.
//
// Behavior required by the spec:
//   Reads the per-subset QA annotation file (likely a JSONL mapping queryID →
//   {evidence_count, evidence_messages: [{text: str}, ...]}). The evidence_count
//   and evidence_messages are metadata from the ConvoMem benchmark dataset that
//   accompany its retrieval files. Returns (1, []) when the query is not found in
//   the annotation file (graceful degradation: single-evidence branch, empty messages).
//
// Why this cannot be built from existing corpus loader types:
//   LMEBCorpus loads corpus.jsonl, queries.jsonl, candidates.jsonl, and qrels.tsv.
//   The QA annotation file (evidence_count, evidence_messages per question) is a
//   separate dataset artifact not present in those four files. It requires its own
//   loader that reads the ConvoMem dataset's QA-specific annotation format.

/// Placeholder stub returning (evidenceCount: 1, evidenceMessages: []) until the
/// loadConvoMemEvidenceAnnotations loader is implemented (see MOOT FUNCTION NEEDED above).
private func convoMemEvidenceAnnotations_PLACEHOLDER(
    queryID: String,
    evidenceType: String
) -> (evidenceCount: Int, evidenceMessages: [ConvoMemEvidenceMessage]) {
    // This is a placeholder. Real data requires the QA annotation loader above.
    return (evidenceCount: 1, evidenceMessages: [])
}

// MARK: - Private per-query estate loop (artifact estate seam)

/// Shared per-query result carrying the raw retrieval output from the artifact estate loop.
/// Both mode-specific functions derive their outputs from this.
private struct LMEBSpecRawQueryResult: Sendable {
    let queryID: String
    let evidenceType: String
    let queryLatencySeconds: Double
    let retrievedDocIDs: [String]
    let relevantDocIDs: Set<String>
    let guardHealthy: Bool
    let guardDiagnostic: String?
    let guardSamplingMode: GuardSamplingPolicy
    let docsIngested: Int
    let writeMeanLatencySeconds: Double
    /// Always nil: artifact estates are pre-built; the estate-cache axis does not
    /// exist in this lane. Retained so the result schema keeps its column.
    let cacheHit: Bool?
    /// Always nil: artifact estates are pre-built; no drain observed.
    let drainLaneObserved: Bool?
    /// §A4 effective query text (instruction-augmented when applicable).
    let effectiveQueryText: String
    /// Memory texts hydrated from the estate via moot_memory_get, in retrieval
    /// order, capped at config.answerHydrationDepth. Populated while the MCP
    /// client is live inside runOneLMEBSpecQueryRaw. Falls back to corpus lookup
    /// on hydration failure; increments hydratedMissCount when both fail.
    let hydratedTexts: [String]
    /// Estate drawer UUIDs parallel to hydratedTexts: the UUID used for each
    /// moot_memory_get call, or an empty string when the text came from corpus
    /// fallback (no estate drawer for that doc). Recorded for artifact-recall scoring.
    let hydratedDrawerIDs: [String]
    /// Number of top-K doc IDs for which estate hydration and corpus fallback
    /// both produced no text. Zero means all retrieved docs were hydrated.
    let hydratedMissCount: Int
    /// Content-term count of the effective query text (§7.1 short-query gate).
    let contentTermCount: Int
    /// 1-based ranks of gold docs within the returned list.
    let goldRanks: [Int]
    /// Pool size: returned_count when poolMetrics is off; explain payload count when on.
    let poolSize: Int
    /// 1 when at least one gold doc is in the pool; 0 otherwise.
    let poolGoldHit: Int
    /// Silo provenance map from explain payload. Empty when poolMetrics is off.
    let poolProvenance: [String: Int]
}

/// Derives the unit stem for a query (used as the estate directory name in the catalog).
///
/// Unit stem = "<evidenceType>__scene_<sceneIndex>". The scene index is parsed from
/// the query id (format "scene_<i>_q_<j>" — the integer following the first "scene_"
/// prefix). When parsing fails, scene index defaults to 0.
private func lmebSpecUnitStem(queryID: String, evidenceType: String) -> String {
    // query.id format: "scene_<i>_q_<j>" (scene index is the first integer after "scene_").
    var sceneIndex = 0
    let parts = queryID.components(separatedBy: "_")
    if let scenePos = parts.firstIndex(of: "scene"),
       scenePos + 1 < parts.count,
       let idx = Int(parts[scenePos + 1]) {
        sceneIndex = idx
    }
    return "\(evidenceType)__scene_\(sceneIndex)"
}

/// Builds an EndpointConfig for mootx01 pointing at a pre-built artifact estate.
///
/// READ-ONLY use: the lane only calls moot_memory_search. The estate carries its
/// transient record (plaintext by rule). Deliberately NOT routed through assertScratchBackend.
private func lmebSpecEndpointConfig(
    estateDir: URL,
    mootBinaryPath: String
) throws -> EndpointConfig {
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: estateDir, environment: ["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"])
    return EndpointConfig(
        name: "mootx01-lmeb-spec",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmebSpecVerbMap,
        role: .target
    )
}

/// Runs the LMEB spec harness for a single query against a pre-built artifact estate:
/// resolve estate dir → load id-map → build manifest → open mootx01 → guard probe

/// Maps a qrels turn-level corpus docID into the artifact's session-level
/// seed-id space. qrels.tsv and the corpus loader address individual TURNS,
/// namespaced "<set>__scene_X_session_Y_turn_Z" ("__", the loader's
/// cross-category collision guard). The rebuilt artifacts store whole
/// sessions (Rule-1), keyed "<set>/scene_X_session_Y" in id-map.json — so
/// ground truth must be folded turn → containing session before comparison
/// or no ranked id can ever match. Duplicate sessions collapse via Set.
/// Twin of Rust `lmeb_artifact_session_key` (literal vector pinned in both
/// ports' tests).
func lmebArtifactSessionKey(_ turnDocID: String) -> String {
    guard let sep = turnDocID.range(of: "__") else { return turnDocID }
    let set = turnDocID[..<sep.lowerBound]
    var rest = String(turnDocID[sep.upperBound...])
    if let turn = rest.range(of: "_turn_") {
        rest = String(rest[..<turn.lowerBound])
    }
    return "\(set)/\(rest)"
}

// MARK: - Per-query raw retrieval

/// One frozen serve shared by every query of an aggregate-scale run.
///
/// At unit scale each query has its own scene estate, so the per-query
/// connect / probe / disconnect inside `runOneLMEBSpecQueryRaw` is the
/// natural shape. At bench-aggregate scale every query hits the same estate,
/// and a fresh serve per query pays the estate's cold load (the resident-array
/// read of the whole wing, over a minute on a 13,817-drawer ConvoMem wing)
/// once per query: 140 queries in three hours on the first aggregate run.
/// This value is opened once before the loop, probed once, and disconnected
/// after the loop; the per-query function uses it whenever it is present.
struct LMEBSpecSharedEstate: Sendable {
    let client: MCPClient
    let manifest: [LMEBManifestEntry]
    let guardHealthy: Bool
    let guardDiagnostic: String?
}

/// Opens the shared estate for an aggregate-scale run. Returns nil at unit
/// scale, where every query opens its own scene estate.
private func lmebSpecOpenSharedEstate(
    config: LMEBSpecRunConfig,
    guardSampler: LegGuardSampler
) async throws -> LMEBSpecSharedEstate? {
    guard config.targetScale != .unit else { return nil }
    guard let dir = config.estateDir else {
        throw MCPError(description:
            "lmeb-spec: \(config.targetScale.rawValue) scale requires --estate-dir")
    }
    // id-map.json keys are the artifact's session-level seed ids; see the
    // unit-scale branch of runOneLMEBSpecQueryRaw for the id-space note.
    let idMap = try loadArtifactIDMap(estateDir: dir)
    var manifest: [LMEBManifestEntry] = []
    for (seedID, uuid) in idMap {
        manifest.append(LMEBManifestEntry(uuid: uuid, docID: seedID))
    }
    let endpoint = try lmebSpecEndpointConfig(
        estateDir: dir, mootBinaryPath: config.mootBinaryPath)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    // The DegeneracyGuard verdict is per estate, so one probe covers the run.
    let (verdict, _) = await guardSampler.probe {
        await probeMCPClient(client, verbMap: lmebSpecVerbMap, name: "mootx01-lmeb-spec")
    }
    let healthy: Bool
    if case .healthy = verdict { healthy = true } else { healthy = false }
    return LMEBSpecSharedEstate(
        client: client, manifest: manifest,
        guardHealthy: healthy, guardDiagnostic: healthy ? nil : verdict.diagnostic)
}

/// → moot_memory_search (with optional §A4 instruction) → map UUIDs to docIDs.
///
/// Uses `LMEBSpecQuery` (carries evidenceType) for §A4 instruction lookup.
/// id-map.json keys are the artifact's session-level seed ids
/// "<set>/scene_<i>_session_<j>"; the inverse gives UUID → session key for
/// the manifest, and qrels turn ids fold into the same space. §A2
/// equivalence: the artifact estate was built from exactly the candidate
/// pool documents, so retrieval over it is already restricted to the pool.
private func runOneLMEBSpecQueryRaw(
    idx: Int,
    total: Int,
    specQuery: LMEBSpecQuery,
    corpus: LMEBCorpus,
    config: LMEBSpecRunConfig,
    shared: LMEBSpecSharedEstate?,
    guardSampler: LegGuardSampler,
    timingSampler: LegTimingSampler
) async throws -> LMEBSpecRawQueryResult {
    let query = specQuery.query
    let evidenceType = specQuery.evidenceType

    // Ground-truth relevant doc IDs for scoring, folded from the qrels'
    // turn-level id space into the artifact's session-level key space
    // (see lmebArtifactSessionKey — without the fold nothing can match).
    let relevantDocIDs = Set(
        corpus.relevantDocs(forQuery: query.id).map(lmebArtifactSessionKey))

    // §A4: build the effective query text (instruction-prepended when applicable).
    let effectiveQueryText = lmebSpecEffectiveQuery(
        queryText: query.text,
        evidenceType: evidenceType,
        setting: config.instructionSetting
    )

    // ── Estate resolution ─────────────────────────────────────────────────────
    // Aggregate scale: the run loop opened one frozen serve for every query
    // (LMEBSpecSharedEstate); reuse its connection, manifest, and guard verdict.
    // Unit scale: one fleet estate per scene (unit stem = "<set>__scene_<i>"),
    // opened, probed, and released here.
    let client: MCPClient
    let manifest: [LMEBManifestEntry]
    let guardHealthy: Bool
    let guardDiagnostic: String?
    let ownsClient: Bool
    if let shared {
        client = shared.client
        manifest = shared.manifest
        guardHealthy = shared.guardHealthy
        guardDiagnostic = shared.guardDiagnostic
        ownsClient = false
    } else {
        guard config.targetScale == .unit else {
            throw MCPError(description:
                "lmeb-spec: \(config.targetScale.rawValue) scale runs on the shared estate opened by the run loop")
        }
        guard let catalogPath = config.catalogPath else {
            throw MCPError(description: "lmeb-spec: unit scale requires --catalog")
        }
        let stem = lmebSpecUnitStem(queryID: query.id, evidenceType: evidenceType)
        // The catalog resolver checks existence and applies the containment guard.
        let estateDir = try artifactUnitEstateDir(catalogPath: catalogPath, id: stem)

        // id-map.json keys are the artifact's session-level seed ids
        // "<set>/scene_<i>_session_<j>" — a different id space from the corpus
        // loader's turn-level docIDs. Ranked results live in this session space;
        // ground truth is folded into it (lmebArtifactSessionKey).
        let idMap = try loadArtifactIDMap(estateDir: estateDir)
        var unitManifest: [LMEBManifestEntry] = []
        for (seedID, uuid) in idMap {
            unitManifest.append(LMEBManifestEntry(uuid: uuid, docID: seedID))
        }
        manifest = unitManifest

        let endpoint = try lmebSpecEndpointConfig(
            estateDir: estateDir, mootBinaryPath: config.mootBinaryPath)
        let unitClient = MCPClient(endpoint: endpoint)
        try await unitClient.connect()
        client = unitClient

        // ── DegeneracyGuard probe ──────────────────────────────────────────────
        let (verdict, _) = await guardSampler.probe {
            await probeMCPClient(unitClient, verbMap: lmebSpecVerbMap, name: "mootx01-lmeb-spec")
        }
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        guardDiagnostic = guardHealthy ? nil : verdict.diagnostic
        ownsClient = true
    }
    defer { if ownsClient { Task { await client.disconnect() } } }

    // ── §A4: Query with effective (possibly instruction-augmented) text ────────
    // Two verbs are possible depending on flags:
    //   moot_recall_shaped  — when --recall-shape is given: passes "query" + "preset";
    //                         never sends "scoring" (the verb runs matrixAware internally).
    //   moot_memory_search  — baseline when --recall-shape is absent: optional "scoring"
    //                         key; byte-identical to the pre-flag baseline when both absent.
    // The CLI rejects --scoring + --recall-shape together before this point.
    let queryVerb: String
    var queryArgs: [String: JSONValue] = [
        lmebSpecVerbMap.queryArg: .string(effectiveQueryText),
    ]
    // Always send the limit explicitly so the value is recorded and deterministic.
    queryArgs["limit"] = .number(Double(config.requestLimit))
    if let shape = config.recallShape {
        // moot_recall_shaped: preset steers the fusion engine; no scoring key.
        queryVerb = AriaV2Surface.recallShaped
        queryArgs["preset"] = .string(shape)
    } else {
        // moot_memory_search: pass scoring when given, omit otherwise.
        queryVerb = lmebSpecVerbMap.query
        if let s = config.scoringStrategy { queryArgs["scoring"] = .string(s) }
    }
    // Request explain payload only when --pool-metrics is active; omitting it keeps
    // default runs byte-identical to the pre-flag baseline.
    if config.poolMetricsEnabled {
        queryArgs["explain"] = .bool(true)
    }
    let queryStart = Date()
    let queryResult = try await client.callTool(
        queryVerb,
        arguments: queryArgs,
        format: lmebSpecVerbMap.resultFormat
    )
    let queryLatency = Date().timeIntervalSince(queryStart)

    // ── UUID → docID mapping ───────────────────────────────────────────────────
    let (rankedDocIDs, _) = lmebRankedDocsAudited(uuids: queryResult.orderedIDs, manifest: manifest)


    let progressMsg = "[lmeb-spec] \(idx + 1)/\(total) "
        + "\(query.id) [\(evidenceType)]: \(manifest.count) sessions in estate, "
        + "guard=\(guardHealthy ? "healthy" : "EXCLUDED"), "
        + "retrieved \(rankedDocIDs.count) docs\n"
    FileHandle.standardError.write(Data(progressMsg.utf8))

    // ── §B1: Estate hydration — moot_memory_get per ranked drawer UUID ──────
    // The id-map maps session-level seed IDs (doc IDs) → drawer UUIDs. Build
    // the reverse to look up UUIDs from ranked doc IDs, then call moot_memory_get
    // once per UUID (LongMemEvalRunner pattern) so each block is one drawer's
    // full content. This fixes the id-space mismatch: the corpus is keyed by
    // turn IDs while the estate is keyed by session UUIDs.
    //
    // Fallback chain: hydration failure → corpus.docsByID (also misses in the
    // session/turn mismatch case, preserved for non-artifact paths) → miss count.
    let docIDToUUID: [String: String] = Dictionary(
        manifest.map { ($0.docID, $0.uuid) },
        uniquingKeysWith: { first, _ in first })
    var hydratedTexts: [String] = []
    // Drawer UUIDs parallel to hydratedTexts: the UUID for estate-hydrated entries,
    // or empty string for corpus-fallback entries (no estate drawer to join against).
    var hydratedDrawerIDs: [String] = []
    var hydratedMissCount = 0
    for docID in rankedDocIDs.prefix(config.answerHydrationDepth) {
        guard !docID.hasPrefix("\0") else { continue }
        if let uuid = docIDToUUID[docID] {
            do {
                let get = try await client.callTool(
                    AriaV2Surface.memoryGet,
                    arguments: AriaV2Surface.memoryGetArgs(memoryId: uuid, depth: config.answerHydrationTier.rawValue),
                    format: lmebSpecVerbMap.resultFormat,
                    deadline: MCPDeadline.interactive)
                let text = get.textBlocks.joined(separator: "\n")
                if !text.isEmpty {
                    hydratedTexts.append(text)
                    hydratedDrawerIDs.append(uuid)
                } else if let t = corpus.docsByID[docID]?.text {
                    hydratedTexts.append(t)
                    // Corpus fallback: estate drawer exists but returned no text.
                    hydratedDrawerIDs.append(uuid)
                } else {
                    hydratedMissCount += 1
                }
            } catch {
                // Hydration failed: fall back to corpus lookup.
                if let t = corpus.docsByID[docID]?.text {
                    hydratedTexts.append(t)
                    // UUID known but hydration errored; still record the drawer ID
                    // so the join carries the UUID for future diagnostic use.
                    hydratedDrawerIDs.append(uuid)
                } else { hydratedMissCount += 1 }
            }
        } else {
            // No UUID in manifest (not seeded into this estate): fall back.
            if let t = corpus.docsByID[docID]?.text {
                hydratedTexts.append(t)
                // No estate drawer for this doc.
                hydratedDrawerIDs.append("")
            } else { hydratedMissCount += 1 }
        }
    }

    // ── Expand-verify scoreboard per-question fields (§1 / §7.5) ─────────────
    // Content-term count: lowercase alnum tokens minus the shared EN stopword fixture.
    // This is the harness's own gate, independent of the product's tokeniser.
    let contentTermCount = lmebContentTermCount(text: effectiveQueryText)

    // Gold ranks: 1-based positions of relevantDocIDs within rankedDocIDs.
    // A gold doc absent from the returned list has no rank entry.
    let goldRanks: [Int] = rankedDocIDs.enumerated().compactMap { i, docID in
        relevantDocIDs.contains(docID) ? i + 1 : nil
    }

    // Pool fields: when --pool-metrics is on, read the explain payload pool structure
    // (product side, RECIPE-1); otherwise pool equals the returned list.
    // explain payload pool structure is not yet wired in the product; we fall through
    // to the returned-list path for now, matching the brief's stated current behaviour.
    let poolSize = rankedDocIDs.count
    let poolGoldHit = goldRanks.isEmpty ? 0 : 1
    // Silo provenance: populated when the product returns an explain pool; empty otherwise.
    let poolProvenance: [String: Int] = [:]

    return LMEBSpecRawQueryResult(
        queryID:                 query.id,
        evidenceType:            evidenceType,
        queryLatencySeconds:     queryLatency,
        retrievedDocIDs:         rankedDocIDs,
        relevantDocIDs:          relevantDocIDs,
        guardHealthy:            guardHealthy,
        guardDiagnostic:         guardDiagnostic,
        guardSamplingMode:       config.guardSamplingPolicy,
        docsIngested:            manifest.count,
        writeMeanLatencySeconds: 0.0,
        cacheHit:                nil,
        drainLaneObserved:       nil,
        effectiveQueryText:      effectiveQueryText,
        hydratedTexts:           hydratedTexts,
        hydratedDrawerIDs:       hydratedDrawerIDs,
        hydratedMissCount:       hydratedMissCount,
        contentTermCount:        contentTermCount,
        goldRanks:               goldRanks,
        poolSize:                poolSize,
        poolGoldHit:             poolGoldHit,
        poolProvenance:          poolProvenance
    )
}

// MARK: - Public: lmeb-spec retrieval mode

/// Runs the lmeb-spec retrieval harness against a loaded corpus.
///
/// Produces the full official metric grid (§A1/§A3/§A4) at k∈{1,5,10,25,50},
/// two-level aggregation (subset-level macro mean → task mean), R_cap@k with
/// None-propagation, and per-query metric records.
///
/// Parallelism: when config.parallelUnits > 1, queries run as independent Swift
/// tasks (same mechanism as runLMEBQueries in LMEBRunner.swift). Results are
/// sorted by original index for byte-deterministic ordering.
///
/// - Parameters:
///   - specQueries: Flat list of queries with evidence type labels. The caller
///     loads per-subset query files and creates LMEBSpecQuery instances from them.
///     Multiple evidence types may be interleaved; the runner groups per-subset
///     for §A1/§A3 aggregation at the end.
///   - corpus: The loaded LMEB corpus (same type as the base runner — no modification).
///   - config: Spec run configuration.
/// - Returns: Aggregated metric results and per-query records.
func runLMEBSpecQueries(
    specQueries: [LMEBSpecQuery],
    corpus: LMEBCorpus,
    config: LMEBSpecRunConfig
) async throws -> LMEBSpecRunResults {
    // Unit-ID filter (before shuffle: same ids file → same units regardless of seed).
    let filteredQueries = try filterUnits(
        specQueries, ids: config.unitIDs, id: { $0.query.id }, lane: "lmeb-spec")
    // Deterministic shuffle using SplitMix64 (fleet-standard PRNG, same as base runner).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filteredQueries
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let sliced: [LMEBSpecQuery]
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    let guardSampler  = LegGuardSampler(policy: config.guardSamplingPolicy)
    let timingSampler = LegTimingSampler()

    // Bench-aggregate forces parallelism to 1 (one serve holds the estate at a time).
    let effectiveParallel = config.targetScale == .unit ? config.parallelUnits : 1

    // Bounded-concurrency parallel dispatch (mirrors runLMEBQueries in LMEBRunner.swift).
    var indexedResults: [(Int, LMEBSpecQueryResult)] = []
    indexedResults.reserveCapacity(sliced.count)

    // Aggregate scale: one frozen serve for every query (LMEBSpecSharedEstate);
    // nil at unit scale, where each query opens its own scene estate.
    let shared = try await lmebSpecOpenSharedEstate(config: config, guardSampler: guardSampler)
    defer { if let shared { Task { await shared.client.disconnect() } } }

    // Dream drain status at run start — informational field in the run results.
    // Unit-scale has no shared estate; dream fields default to 0/idle.
    let lmebDreamStatus = shared != nil
        ? await readDrainStatusOnce(client: shared!.client)
        : DreamStatus(pending: 0, settled: true)

    try await withThrowingTaskGroup(of: (Int, LMEBSpecQueryResult).self) { group in
        var inFlight = 0
        for (idx, sq) in sliced.enumerated() {
            if inFlight >= effectiveParallel {
                if let pair = try await group.next() {
                    indexedResults.append(pair)
                    inFlight -= 1
                }
            }
            let capturedIdx = idx
            let capturedSQ  = sq
            group.addTask {
                let raw = try await runOneLMEBSpecQueryRaw(
                    idx: capturedIdx,
                    total: sliced.count,
                    specQuery: capturedSQ,
                    corpus: corpus,
                    config: config,
                    shared: shared,
                    guardSampler: guardSampler,
                    timingSampler: timingSampler
                )
                // §A3: compute per-query spec metrics from the ranked list.
                let metrics = lmebSpecPerQueryMetrics(
                    rankedDocIDs: raw.retrievedDocIDs,
                    relevantDocIDs: raw.relevantDocIDs,
                    queryID: raw.queryID,
                    options: config.specOptions
                )
                let qr = LMEBSpecQueryResult(
                    queryID:                 raw.queryID,
                    evidenceType:            raw.evidenceType,
                    queryLatencySeconds:     raw.queryLatencySeconds,
                    retrievedDocIDs:         raw.retrievedDocIDs,
                    relevantDocIDs:          raw.relevantDocIDs,
                    guardHealthy:            raw.guardHealthy,
                    guardDiagnostic:         raw.guardDiagnostic,
                    guardSamplingMode:       raw.guardSamplingMode,
                    docsIngested:            raw.docsIngested,
                    writeMeanLatencySeconds: raw.writeMeanLatencySeconds,
                    cacheHit:               raw.cacheHit,
                    drainLaneObserved:       raw.drainLaneObserved,
                    instructionSetting:      config.instructionSetting,
                    effectiveQueryText:      raw.effectiveQueryText,
                    specMetrics:             metrics,
                    contentTermCount:        raw.contentTermCount,
                    goldRanks:               raw.goldRanks,
                    poolSize:                raw.poolSize,
                    poolGoldHit:             raw.poolGoldHit,
                    poolProvenance:          raw.poolProvenance
                )
                return (capturedIdx, qr)
            }
            inFlight += 1
        }
        for try await pair in group {
            indexedResults.append(pair)
        }
    }

    indexedResults.sort { $0.0 < $1.0 }
    let orderedResults = indexedResults.map(\.1)

    // ── §A1/§A3: Two-level aggregation ────────────────────────────────────────
    // Group per-query metrics by evidence type for subset-level (level-1) aggregation.
    var bySubset: [String: [LMEBSpecQueryMetrics]] = [:]
    var guardExcluded = 0
    for r in orderedResults {
        if !r.guardHealthy { guardExcluded += 1 }
        bySubset[r.evidenceType, default: []].append(r.specMetrics)
    }
    // Subset metrics in deterministic order (sorted by subset name).
    let subsetMetrics = bySubset.keys.sorted().map { subsetName in
        lmebSpecSubsetMetrics(queries: bySubset[subsetName]!, subsetName: subsetName)
    }
    // Level-2: task score = mean of subset scores.
    var taskMetrics = lmebSpecTaskMetrics(subsets: subsetMetrics)

    // ── Pool guarantee and short-query metrics (§3 / §7.5) ───────────────────
    // Computed from per-query results (not subset aggregates) so the guard
    // exclusion status per query is already resolved.
    let includedResults = orderedResults.filter { $0.guardHealthy }
    let totalIncluded = includedResults.count
    if totalIncluded > 0 {
        // Pool guarantee: fraction of questions with ≥1 gold doc in the pool.
        taskMetrics.poolGuarantee = Double(includedResults.filter { $0.poolGoldHit == 1 }.count) / Double(totalIncluded)
        // Pool gold recall: gold docs in pool / total gold docs across all questions.
        let totalGold = includedResults.map { $0.relevantDocIDs.count }.reduce(0, +)
        let goldInPool = includedResults.map { $0.goldRanks.count }.reduce(0, +)
        taskMetrics.poolGoldRecall = totalGold > 0 ? Double(goldInPool) / Double(totalGold) : 0.0

        // Short-query subset: queries with content_term_count < config.shortQueryTerms.
        let shortResults = includedResults.filter { $0.contentTermCount < config.shortQueryTerms }
        taskMetrics.shortQueryCount = shortResults.count
        if !shortResults.isEmpty {
            // Compute nDCG@10 and Recall@10 means over the short-query subset.
            let ndcg10 = shortResults.compactMap { $0.specMetrics.ndcg[10] }
            taskMetrics.shortQueryNdcgAt10 = ndcg10.isEmpty ? 0.0 : ndcg10.reduce(0, +) / Double(ndcg10.count)
            let rec10 = shortResults.compactMap { $0.specMetrics.recall[10] }
            taskMetrics.shortQueryRecallAt10 = rec10.isEmpty ? 0.0 : rec10.reduce(0, +) / Double(rec10.count)
            taskMetrics.shortQueryPoolGuarantee = Double(shortResults.filter { $0.poolGoldHit == 1 }.count) / Double(shortResults.count)
        }
    }

    var runResults = LMEBSpecRunResults(
        perQueryResults:    orderedResults,
        subsetMetrics:      subsetMetrics,
        taskMetrics:        taskMetrics,
        timingReport:       await timingSampler.text(),
        guardExcludedCount: guardExcluded,
        totalQueries:       orderedResults.count,
        instructionSetting: config.instructionSetting,
        specOptions:        config.specOptions
    )
    runResults.dreamPending  = lmebDreamStatus.pending
    runResults.dreamDraining = lmebDreamStatus.settled ? 0 : 1
    return runResults
}

// MARK: - Public: convomem-spec judged mode

/// Runs the ConvoMem-spec judged harness against a loaded corpus.
///
/// Retrieves memories per query (same estate provisioning as lmeb-spec), builds
/// the §B1 memory-based answer prompt, obtains answers via the BYOAI seam,
/// judges with the §B2 template selected by evidence type, parses verdicts per §B3
/// with bounded retries, and aggregates per §B4.
///
/// With no answerCmd/judgeCmd configured: answered_count and judged_count are 0,
/// all verdict rows are absent, and aggregateResult is nil. Mechanisms are complete;
/// the run report is still written with those zero counts.
///
/// NO heuristic fallback scoring — a failed answer or judge call leaves the
/// question counted (in totals) but unscored.
///
/// - Parameters:
///   - specQueries: Queries with evidence type labels and optional QA annotations.
///     correctAnswer, evidenceCount, and evidenceMessages should be populated from
///     ConvoMem QA annotation files (see MOOT FUNCTION NEEDED above). When
///     correctAnswer is nil, the judge step is skipped for that query.
///   - corpus: The loaded LMEB corpus.
///   - config: Spec run configuration.
/// - Returns: Per-query judged results and §B4 aggregation.
func runConvoMemSpecQueries(
    specQueries: [LMEBSpecQuery],
    corpus: LMEBCorpus,
    config: LMEBSpecRunConfig
) async throws -> ConvoMemSpecRunResults {
    // Unit-ID filter (before shuffle: same ids file → same units regardless of seed).
    // MOOT_BENCH_UNIT_IDS may contain bare query IDs (scene_N_q_M) or the full
    // unit-stem form (<evidence>__scene_N_q_M). Normalise via normalizeUnitID so
    // both representations match the same queries.
    let normalizedUnitIDs: Set<String>? = config.unitIDs.map { ids in
        Set(ids.map { normalizeUnitID($0) })
    }
    let filteredQueries = try filterUnits(
        specQueries, ids: normalizedUnitIDs, id: { $0.query.id }, lane: "convomem-spec")
    // Deterministic shuffle (same algorithm as lmeb-spec mode).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filteredQueries
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let sliced: [LMEBSpecQuery]
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    let guardSampler  = LegGuardSampler(policy: config.guardSamplingPolicy)
    let timingSampler = LegTimingSampler()

    // Bench-aggregate forces parallelism to 1 (one serve holds the estate at a time).
    let effectiveParallel = config.targetScale == .unit ? config.parallelUnits : 1

    // ── Optional offline-batch dump writers ───────────────────────────────────
    // Answer-input dump: write a JSONL header before the loop.
    let answerDumpWriter: LMEBSpecDumpWriter?
    if let dumpPath = config.dumpAnswerInputsPath {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "convomem-spec",
            "seed": config.seed,
            "run_label": config.runLabel,
            "answer_hydration_depth": config.answerHydrationDepth,
            "hydration_tier": config.answerHydrationTier.rawValue,
        ]
        if let hData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
           var hStr = String(data: hData, encoding: .utf8) {
            hStr += "\n"
            FileManager.default.createFile(
                atPath: dumpPath, contents: Data(hStr.utf8),
                attributes: [.posixPermissions: 0o600 as NSNumber])
        }
        answerDumpWriter = LMEBSpecDumpWriter(dumpPath)
    } else {
        answerDumpWriter = nil
    }

    // Judge-input dump: write a JSONL header before the loop.
    let judgeDumpWriter: LMEBSpecDumpWriter?
    if let dumpPath = config.dumpJudgeInputsPath {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "convomem-spec",
            "seed": config.seed,
            "run_label": config.runLabel,
            "judge_identity": config.judgeIdentity,
        ]
        if let hData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
           var hStr = String(data: hData, encoding: .utf8) {
            hStr += "\n"
            FileManager.default.createFile(
                atPath: dumpPath, contents: Data(hStr.utf8),
                attributes: [.posixPermissions: 0o600 as NSNumber])
        }
        judgeDumpWriter = LMEBSpecDumpWriter(dumpPath)
    } else {
        judgeDumpWriter = nil
    }

    // ── Bounded-concurrency parallel dispatch ─────────────────────────────────
    // ConvoMem judged mode runs with the same parallelism model as lmeb-spec
    // (withThrowingTaskGroup, effectiveParallel concurrency limit). The judge
    // subprocess calls are serialized within each task (one answer then one verdict
    // call per query), not across tasks — the external command path is independently
    // safe to invoke from multiple tasks.
    var indexedResults: [(Int, ConvoMemSpecQueryResult)] = []
    indexedResults.reserveCapacity(sliced.count)

    // Aggregate scale: one frozen serve for every query (LMEBSpecSharedEstate);
    // nil at unit scale, where each query opens its own scene estate.
    let shared = try await lmebSpecOpenSharedEstate(config: config, guardSampler: guardSampler)
    defer { if let shared { Task { await shared.client.disconnect() } } }

    // Dream drain status at run start — informational field in the run results.
    // Unit-scale has no shared estate; dream fields default to 0/idle.
    let convomemDreamStatus = shared != nil
        ? await readDrainStatusOnce(client: shared!.client)
        : DreamStatus(pending: 0, settled: true)

    try await withThrowingTaskGroup(of: (Int, ConvoMemSpecQueryResult).self) { group in
        var inFlight = 0
        for (idx, sq) in sliced.enumerated() {
            if inFlight >= effectiveParallel {
                if let pair = try await group.next() {
                    indexedResults.append(pair)
                    inFlight -= 1
                }
            }
            let capturedIdx = idx
            let capturedSQ  = sq
            group.addTask {
                let raw = try await runOneLMEBSpecQueryRaw(
                    idx: capturedIdx,
                    total: sliced.count,
                    specQuery: capturedSQ,
                    corpus: corpus,
                    config: config,
                    shared: shared,
                    guardSampler: guardSampler,
                    timingSampler: timingSampler
                )

                // ── §B1: Build memory-based answer prompt ─────────────────────
                // Memory texts are hydrated from the estate via moot_memory_get
                // inside runOneLMEBSpecQueryRaw (while the MCP client is live),
                // fixing the id-space mismatch: id-map.json maps session IDs →
                // drawer UUIDs while corpus.jsonl uses turn IDs, so corpus lookup
                // always returns empty. Estate hydration returns the drawer's full
                // body text in retrieval order, capped at answerHydrationDepth.
                let topDocTexts: [String] = raw.hydratedTexts
                let answerPayloadTokens: Int? = topDocTexts.isEmpty
                    ? nil
                    : lmeEstimateTokens(topDocTexts.joined(separator: "\n\n"))

                // §B1: memory-based prompt (verbatim from MemoryPromptUtils.scala,
                // implemented in ConvoMemSpecProtocol.swift).
                let answerPrompt: String? = config.answerCmd != nil
                    ? convoMemMemoryBasedPrompt(
                        question: capturedSQ.query.text,
                        memories: topDocTexts)
                    : nil

                // ── §B1: Obtain model answer (BYOAI seam) ─────────────────────
                // Uses lmeRunJudge (LongMemEvalJudge.swift) — the harness's existing
                // external-command seam. The answer command reads the prompt from
                // stdin and writes the answer to stdout, same contract as the judge.
                var modelAnswer: String? = nil
                if let answerCmd = config.answerCmd, let prompt = answerPrompt {
                    if let answer = try? lmeRunJudge(cmd: answerCmd, prompt: prompt) {
                        modelAnswer = answer
                    } else {
                        FileHandle.standardError.write(Data(
                            "[convomem-spec] answer cmd failed for \(raw.queryID) — skipping\n".utf8))
                    }
                }

                // ── Offline answer-input dump ──────────────────────────────────
                if let dumpWriter = answerDumpWriter {
                    let line: [String: Any] = [
                        "type": "answer_input",
                        "query_id": raw.queryID,
                        "evidence_type": raw.evidenceType,
                        "question": capturedSQ.query.text,
                        "memory_texts": topDocTexts,
                        // Estate drawer UUIDs parallel to memory_texts (empty string
                        // for corpus-only fallback entries); recorded for artifact-recall scoring.
                        "retrieved_drawer_ids": raw.hydratedDrawerIDs,
                        "correct_answer": capturedSQ.correctAnswer as Any? ?? NSNull(),
                        "memory_token_estimate": answerPayloadTokens as Any? ?? NSNull(),
                    ]
                    if let ld = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                       var ls = String(data: ld, encoding: .utf8) {
                        ls += "\n"
                        await dumpWriter.append(ls)
                    }
                }

                // ── §B2/§B3: Judge (only when answer was obtained) ─────────────
                // Template selection per §B2: evidence type → template.
                // Retry loop per §B3: bounded at config.judgeMaxRetries.
                var judgePrompt: String? = nil
                var verdictOutcome: ConvoMemVerdictOutcome? = nil
                var retriesExhausted = false
                var ambiguousVerdictWarned = false

                if let judgeCmd = config.judgeCmd,
                   let answer = modelAnswer,
                   let correctAnswer = capturedSQ.correctAnswer,
                   let evidenceType = ConvoMemEvidenceType(rawValue: raw.evidenceType) {

                    // §B2: select the judge template by evidence type.
                    // Evidence annotations (count, messages) from placeholder —
                    // see MOOT FUNCTION NEEDED: loadConvoMemEvidenceAnnotations.
                    let (evidenceCount, evidenceMessages) =
                        convoMemEvidenceAnnotations_PLACEHOLDER(
                            queryID: raw.queryID,
                            evidenceType: raw.evidenceType)

                    let jp = convoMemJudgePrompt(
                        evidenceType: evidenceType,
                        question: capturedSQ.query.text,
                        correctAnswer: correctAnswer,
                        modelAnswer: answer,
                        evidenceMessages: evidenceMessages,
                        evidenceCount: evidenceCount
                    )
                    judgePrompt = jp

                    // ── Offline judge-input dump ───────────────────────────────
                    if let dumpWriter = judgeDumpWriter {
                        let jline: [String: Any] = [
                            "type": "judge_input",
                            "query_id": raw.queryID,
                            "evidence_type": raw.evidenceType,
                            "evidence_count": evidenceCount,
                            "question": capturedSQ.query.text,
                            "correct_answer": correctAnswer,
                            "model_answer": answer,
                            "judge_prompt": jp,
                        ]
                        if let jd = try? JSONSerialization.data(withJSONObject: jline, options: [.sortedKeys]),
                           var js = String(data: jd, encoding: .utf8) {
                            js += "\n"
                            await dumpWriter.append(js)
                        }
                    }

                    // §B3: bounded retry loop for invalid responses.
                    // .invalid = neither "right" nor "wrong" after trim+lowercase.
                    // .incorrect (from ambiguous or "wrong" only) is a final verdict.
                    // Exhausted retries → no verdict (unscored, not counted as wrong).
                    var attempt = 0
                    while attempt < config.judgeMaxRetries {
                        if let reply = try? lmeRunJudge(cmd: judgeCmd, prompt: jp) {
                            let outcome = convoMemVerdict(reply)
                            if outcome == .incorrect && reply.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased().contains("right") {
                                // §B3 ambiguous: both "right" and "wrong" → .incorrect + warn.
                                ambiguousVerdictWarned = true
                                FileHandle.standardError.write(Data(
                                    ("[convomem-spec] §B3 ambiguous judge response for \(raw.queryID) "
                                    + "— defaulted to incorrect\n").utf8))
                            }
                            if outcome != .invalid {
                                verdictOutcome = outcome
                                break
                            }
                            // .invalid → retry.
                            FileHandle.standardError.write(Data(
                                ("[convomem-spec] §B3 invalid judge response (attempt \(attempt + 1)/"
                                + "\(config.judgeMaxRetries)) for \(raw.queryID) — retrying\n").utf8))
                        } else {
                            FileHandle.standardError.write(Data(
                                ("[convomem-spec] judge cmd failed (attempt \(attempt + 1)/"
                                + "\(config.judgeMaxRetries)) for \(raw.queryID)\n").utf8))
                        }
                        attempt += 1
                    }
                    if verdictOutcome == nil {
                        retriesExhausted = true
                        FileHandle.standardError.write(Data(
                            "[convomem-spec] §B3 retries exhausted for \(raw.queryID) — unscored\n".utf8))
                    }
                }

                let cmqr = ConvoMemSpecQueryResult(
                    queryID:               raw.queryID,
                    evidenceType:          raw.evidenceType,
                    evidenceCount:         capturedSQ.evidenceCount,
                    questionText:          capturedSQ.query.text,
                    queryLatencySeconds:   raw.queryLatencySeconds,
                    retrievedDocIDs:       raw.retrievedDocIDs,
                    relevantDocIDs:        raw.relevantDocIDs,
                    guardHealthy:          raw.guardHealthy,
                    guardDiagnostic:       raw.guardDiagnostic,
                    cacheHit:              raw.cacheHit,
                    retrievedMemoryTexts:  topDocTexts,
                    answerPrompt:          answerPrompt,
                    modelAnswer:           modelAnswer,
                    judgePrompt:           judgePrompt,
                    verdictOutcome:        verdictOutcome,
                    retriesExhausted:      retriesExhausted,
                    ambiguousVerdictWarned: ambiguousVerdictWarned,
                    answerPayloadTokens:   answerPayloadTokens
                )
                return (capturedIdx, cmqr)
            }
            inFlight += 1
        }
        for try await pair in group {
            indexedResults.append(pair)
        }
    }

    indexedResults.sort { $0.0 < $1.0 }
    let orderedResults = indexedResults.map(\.1)

    // ── §B4: Build verdict rows and aggregate ─────────────────────────────────
    var verdictRows: [ConvoMemVerdictRow] = []
    var answeredCount = 0
    var judgedCount   = 0
    var guardExcluded = 0
    var memoryTextsEmptyCount = 0

    for r in orderedResults {
        if r.retrievedMemoryTexts.isEmpty { memoryTextsEmptyCount += 1 }
        if !r.guardHealthy { guardExcluded += 1 }
        if r.modelAnswer != nil { answeredCount += 1 }
        if let outcome = r.verdictOutcome {
            // §B4: every result with a non-nil verdict (including .invalid outcomes
            // that exhausted retries) contributes to judgedCount.
            judgedCount += 1
            // Excluded queries (guard not healthy) still contribute to the verdict
            // row so the aggregate reflects the full judged set.
            verdictRows.append(ConvoMemVerdictRow(
                evidenceType: r.evidenceType,
                evidenceCount: r.evidenceCount,
                outcome: outcome
            ))
        } else if r.retriesExhausted {
            // §B3 exhausted retries → no verdict → question unscored.
            // Still counted in judgedCount (judging was attempted but inconclusive).
            judgedCount += 1
            verdictRows.append(ConvoMemVerdictRow(
                evidenceType: r.evidenceType,
                evidenceCount: r.evidenceCount,
                outcome: .invalid
            ))
        }
    }

    // §B4 aggregation. Nil when judgedCount == 0 (no commands configured).
    let aggregateResult: ConvoMemAggregateResult? = verdictRows.isEmpty
        ? nil
        : convoMemAggregate(verdictRows)

    var convomemResults = ConvoMemSpecRunResults(
        perQueryResults:      orderedResults,
        aggregateResult:      aggregateResult,
        answeredCount:        answeredCount,
        judgedCount:          judgedCount,
        totalQueries:         orderedResults.count,
        timingReport:         await timingSampler.text(),
        guardExcludedCount:   guardExcluded,
        judgeIdentity:        config.judgeIdentity,
        answerCmdSet:         config.answerCmd != nil,
        judgeCmdSet:          config.judgeCmd != nil,
        memoryTextsEmptyCount: memoryTextsEmptyCount
    )
    convomemResults.dreamPending  = convomemDreamStatus.pending
    convomemResults.dreamDraining = convomemDreamStatus.settled ? 0 : 1
    return convomemResults
}

// MARK: - Offline-batch: consume convomem answer dump

/// Reads a convomem-spec answer-input JSONL dump produced by dumpAnswerInputsPath,
/// runs the answer command offline, and writes a judge-input JSONL dump suitable
/// for consuming via runConvoMemSpecJudgeDump.
///
/// No mootx01 binary or live estate required. Use this to generate answers
/// asynchronously from retrieval runs when the answer model is not available
/// during the benchmark run.
///
/// - Parameters:
///   - inputsPath: Path to the answer-input dump JSONL file.
///   - answerCmd: Shell command to invoke for each query's memory prompt.
///   - outputPath: Path to write the resulting judge-input JSONL file.
public func runConvoMemSpecAnswerDump(
    inputsPath: String,
    answerCmd: String,
    outputPath: String,
    limit: Int? = nil,
    offset: Int = 0
) throws {
    guard let rawData = FileManager.default.contents(atPath: inputsPath),
          let content = String(data: rawData, encoding: .utf8) else {
        throw MCPError(description: "cannot read answer-input dump at '\(inputsPath)'")
    }
    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        throw MCPError(description: "answer-input dump is empty: '\(inputsPath)'")
    }
    // Parse and validate the header line.
    guard let hData = lines[0].data(using: .utf8),
          let hObj = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
          (hObj["type"] as? String) == "header" else {
        throw MCPError(description: "first line is not a valid header in '\(inputsPath)'")
    }
    // Create the output file with restricted permissions.
    FileManager.default.createFile(
        atPath: outputPath, contents: nil,
        attributes: [.posixPermissions: 0o600 as NSNumber])
    guard let fh = FileHandle(forWritingAtPath: outputPath) else {
        throw MCPError(description: "cannot open output path for writing: '\(outputPath)'")
    }
    defer { fh.closeFile() }

    // Collect answer_input lines; apply offset + limit so --limit caps the
    // ConvoMem branch the same way it caps every other branch.
    let answerInputLines = lines.dropFirst().filter {
        guard let d = $0.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return false }
        return (o["type"] as? String) == "answer_input"
    }
    let sliced = Array(answerInputLines.dropFirst(offset))
    let limitedLines = limit.map { Array(sliced.prefix($0)) } ?? sliced

    for line in limitedLines {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              (obj["type"] as? String) == "answer_input",
              let queryID       = obj["query_id"]      as? String,
              let evidenceType  = obj["evidence_type"] as? String,
              let question      = obj["question"]      as? String,
              let memoryTexts   = obj["memory_texts"]  as? [String] else {
            continue
        }
        let correctAnswer = obj["correct_answer"] as? String
        // §B1: build the memory-based prompt from the stored memory texts.
        let prompt = convoMemMemoryBasedPrompt(question: question, memories: memoryTexts)
        let answer: String
        do {
            answer = try lmeRunJudge(cmd: answerCmd, prompt: prompt)
        } catch {
            FileHandle.standardError.write(Data(
                "[convomem-spec-batch] answer cmd failed for \(queryID): \(error)\n".utf8))
            continue
        }
        let outLine: [String: Any] = [
            "type": "judge_ready",
            "query_id": queryID,
            "evidence_type": evidenceType,
            "question": question,
            "model_answer": answer,
            "correct_answer": correctAnswer as Any? ?? NSNull(),
        ]
        if let ld = try? JSONSerialization.data(withJSONObject: outLine, options: [.sortedKeys]),
           var ls = String(data: ld, encoding: .utf8) {
            ls += "\n"
            fh.write(Data(ls.utf8))
        }
    }
}

/// Reads a convomem-spec judge-ready JSONL dump (produced by runConvoMemSpecAnswerDump
/// or by inline dumpJudgeInputsPath), runs the judge offline per line, and returns
/// a §B4 aggregate result. No mootx01 binary or live estate required.
///
/// - Parameters:
///   - inputsPath: Path to the judge-input JSONL dump.
///   - judgeCmd: Shell command to invoke for judging.
///   - maxRetries: §B3 bounded retry count for invalid responses (default 3).
/// - Returns: §B4 aggregate accuracy result.
public func runConvoMemSpecJudgeDump(
    inputsPath: String,
    judgeCmd: String,
    maxRetries: Int = 3
) throws -> ConvoMemAggregateResult {
    guard let rawData = FileManager.default.contents(atPath: inputsPath),
          let content = String(data: rawData, encoding: .utf8) else {
        throw MCPError(description: "cannot read judge-input dump at '\(inputsPath)'")
    }
    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    var verdictRows: [ConvoMemVerdictRow] = []

    for line in lines {
        guard let ld = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else {
            continue
        }
        // Accept both "judge_input" (from inline dump) and "judge_ready" (from answer dump).
        let lineType = obj["type"] as? String ?? ""
        guard lineType == "judge_input" || lineType == "judge_ready" else { continue }
        guard let queryID      = obj["query_id"]      as? String,
              let evidenceType = obj["evidence_type"] as? String,
              let question     = obj["question"]      as? String,
              let modelAnswer  = obj["model_answer"]  as? String,
              let correctAnswer = obj["correct_answer"] as? String,
              let evidType     = ConvoMemEvidenceType(rawValue: evidenceType) else {
            continue
        }
        let evidenceCount = obj["evidence_count"] as? Int ?? 1
        // §B2: rebuild the judge prompt for offline judging.
        let jp = convoMemJudgePrompt(
            evidenceType: evidType,
            question: question,
            correctAnswer: correctAnswer,
            modelAnswer: modelAnswer,
            evidenceMessages: [],  // evidence messages not stored in dump; §B2 UserFacts degrades gracefully
            evidenceCount: evidenceCount
        )
        // §B3 bounded retry loop.
        var verdict: ConvoMemVerdictOutcome = .invalid
        for _ in 0..<maxRetries {
            if let reply = try? lmeRunJudge(cmd: judgeCmd, prompt: jp) {
                let outcome = convoMemVerdict(reply)
                if outcome != .invalid {
                    verdict = outcome
                    break
                }
            }
        }
        _ = queryID  // retained for logging; suppresses unused-variable warning
        verdictRows.append(ConvoMemVerdictRow(
            evidenceType: evidenceType,
            evidenceCount: evidenceCount,
            outcome: verdict
        ))
    }

    return convoMemAggregate(verdictRows)
}
