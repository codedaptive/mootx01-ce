import Foundation

// MemBenchScorer.swift — Scoring wrapper for MemBench per-item recall.
//
// The core scoring math is 100% reused from LongMemEvalScorer.swift — the
// functions lmeRankedSessions, lmeRecallAny, lmeRecallAll, lmeSessionMRR,
// lmePercentile, and aggregateLMEScores are string-agnostic and work
// identically with global sids (e.g. "119") in place of session_ids.
//
// This file adds:
//   1. The manifest bridge: MemBenchManifestEntry → [LMEManifestEntry] so
//      lmeRankedSessions can map UUID → global sid.
//   2. A thin scoreMemBenchItem wrapper that calls the LME math with
//      MemBench-specific types.
//   3. Per-category aggregation (simple/comparative/aggregative/conditional/
//      knowledge_update/post_processing/noisy).
//   4. MemBench-specific JSON report types.

// MARK: - Manifest bridge

/// Converts a MemBenchManifestEntry to the LMEManifestEntry form that
/// lmeRankedSessions expects. The `sessionID` field carries the global sid
/// string so the string-agnostic lmeRankedSessions maps UUID → sid correctly.
///
/// - Parameter entries: The MemBench manifest for one item estate.
/// - Returns: Equivalent LMEManifestEntry list with sid → sessionID.
private func memBenchManifestAsLME(_ entries: [MemBenchManifestEntry]) -> [LMEManifestEntry] {
    entries.map { e in
        LMEManifestEntry(
            uuid: e.uuid,
            sessionID: e.sid,           // global sid stands in for sessionID
            turnIndex: 0,               // MemBench items score at the turn level, no sub-turn index
            sessionIndex: e.sessionIndex,
            role: "turn"                // generic role — MemBench has no explicit speaker
        )
    }
}

// MARK: - Multiple-choice selection (C9)

/// Selects the most likely answer letter from the MCP recall payload.
///
/// Selection rule (deterministic given retrieval output):
///   1. Scan choices in letter order A → B → C → D.
///   2. Return the first letter whose option text appears as a case-insensitive
///      substring of the payload.
///   3. If no option text matches, or the payload is nil, return nil.
///      A nil prediction scores 0 in the aggregate.
///
/// The rule is substring-based: retrieved turns contain verbatim assistant
/// text, so when the correct evidence was recalled the answer phrase appears
/// in the payload with high likelihood.
///
/// - Parameters:
///   - payloadText: Raw MCP recall response. Nil when no textBlocks were returned.
///   - choices: The item's four-option dict from the dataset (keys A/B/C/D).
/// - Returns: The selected letter (A/B/C/D), or nil when no option matched.
func selectMultipleChoicePrediction(from payloadText: String?, choices: [String: String]) -> String? {
    guard let payload = payloadText, !payload.isEmpty else { return nil }
    let payloadLower = payload.lowercased()
    for letter in ["A", "B", "C", "D"] {
        guard let optionText = choices[letter], !optionText.isEmpty else { continue }
        if payloadLower.contains(optionText.lowercased()) {
            return letter
        }
    }
    return nil
}

// MARK: - Per-item score

/// The scored result for one MemBench item.
/// Guard-excluded items have all recall/MRR metrics set to 0.0 and are
/// excluded from aggregate scoring (parallel to LoCoMo §1.2 contract).
/// Multiple-choice fields are computed regardless of guard status — they
/// depend only on the retrieved payload.
struct MemBenchItemScore: Sendable {
    let itemID: String
    /// Category label (e.g. "simple", "noisy", "knowledge_update").
    let category: String
    /// True when the DegeneracyGuard classified the estate as healthy.
    let guardHealthy: Bool
    let guardDiagnostic: String?
    // Per-item recall/MRR metrics. All 0.0 when guardHealthy is false.
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
    /// Deduplicated global sid ranking (first-UUID-appearance order).
    let rankedSids: [String]
    /// Ground-truth global sids for this item's question.
    let evidenceSids: [String]
    // Latency and ingest stats — always recorded, not excluded by guard.
    let queryLatencySeconds: Double
    let writeMeanLatencySeconds: Double
    let turnsIngested: Int
    let retrievedUUIDCount: Int
    /// Raw payload text from the MCP response. Nil when no textBlocks were returned.
    let payloadText: String?
    // MARK: C9 — multiple-choice arm
    /// The predicted answer letter (A/B/C/D) chosen from the recall payload by
    /// selectMultipleChoicePrediction, or nil when no option text matched.
    let multipleChoicePrediction: String?
    /// True when multipleChoicePrediction equals the dataset groundTruth letter.
    /// False for nil predictions or mismatches.
    let multipleChoiceCorrect: Bool
}

/// Scores one `MemBenchItemResult`. Guard-excluded items are flagged with
/// zeroed recall/MRR (excluded from aggregate denominator).
/// Multiple-choice scoring (C9) always runs — it depends only on the payload.
func scoreMemBenchItem(_ result: MemBenchItemResult) -> MemBenchItemScore {
    // Bridge manifest to LME form: MemBenchManifestEntry.sid → LMEManifestEntry.sessionID.
    let lmeManifest = memBenchManifestAsLME(result.manifest)
    let rankedSids = lmeRankedSessions(uuids: result.retrievedUUIDs, manifest: lmeManifest)
    let evidenceSet = Set(result.evidenceSids)

    let metrics: (Double, Double, Double, Double, Double, Double, Double)
    if result.guardHealthy {
        metrics = (
            lmeRecallAny(rankedSessions: rankedSids, answerIDs: evidenceSet, k: 1),
            lmeRecallAny(rankedSessions: rankedSids, answerIDs: evidenceSet, k: 5),
            lmeRecallAny(rankedSessions: rankedSids, answerIDs: evidenceSet, k: 10),
            lmeRecallAll(rankedSessions: rankedSids, answerIDs: evidenceSet, k: 1),
            lmeRecallAll(rankedSessions: rankedSids, answerIDs: evidenceSet, k: 5),
            lmeRecallAll(rankedSessions: rankedSids, answerIDs: evidenceSet, k: 10),
            lmeSessionMRR(rankedSessions: rankedSids, answerIDs: evidenceSet)
        )
    } else {
        metrics = (0, 0, 0, 0, 0, 0, 0)
    }
    let (rAny1, rAny5, rAny10, rAll1, rAll5, rAll10, mrrVal) = metrics

    // C9: multiple-choice arm — always scored regardless of guard status.
    let mcPrediction = selectMultipleChoicePrediction(from: result.payloadText, choices: result.choices)
    let mcCorrect = mcPrediction.map { $0 == result.groundTruth } ?? false

    return MemBenchItemScore(
        itemID: result.itemID,
        category: result.category,
        guardHealthy: result.guardHealthy,
        guardDiagnostic: result.guardDiagnostic,
        recallAnyAt1: rAny1,
        recallAnyAt5: rAny5,
        recallAnyAt10: rAny10,
        recallAllAt1: rAll1,
        recallAllAt5: rAll5,
        recallAllAt10: rAll10,
        mrr: mrrVal,
        rankedSids: rankedSids,
        evidenceSids: result.evidenceSids,
        queryLatencySeconds: result.queryLatencySeconds,
        writeMeanLatencySeconds: result.writeMeanLatencySeconds,
        turnsIngested: result.turnsIngested,
        retrievedUUIDCount: result.retrievedUUIDs.count,
        payloadText: result.payloadText,
        multipleChoicePrediction: mcPrediction,
        multipleChoiceCorrect: mcCorrect
    )
}

// MARK: - Aggregate metrics

/// Aggregate MemBench retrieval metrics over guard-healthy items.
/// Mirrors LMEAggregateMetrics; additive per BENCHMARKER_OPTIMIZER_CONTRACT.md.
struct MemBenchAggregateMetrics: Sendable {
    let queryCount: Int
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
    /// C9: proportion of guard-healthy items where the MC prediction matched
    /// the dataset groundTruth. Nil predictions count as incorrect.
    let multipleChoiceAccuracy: Double
}

/// Per-category breakdown. One entry per MemBench category label.
struct MemBenchCategoryBreakdown: Sendable {
    /// Category name (e.g. "simple", "noisy", "knowledge_update").
    let label: String
    let queryCount: Int
    let recallAnyAt5: Double
    let recallAllAt5: Double
    let mrr: Double
}

/// Latency statistics — parallel to LoCoMoLatencyStats.
struct MemBenchLatencyStats: Sendable {
    let queryP50Seconds: Double
    let queryP95Seconds: Double
    let queryMeanSeconds: Double
    let writeMeanSeconds: Double
}

/// MemBench category labels in canonical paper order.
/// LowLevel categories (the paper's main evaluation set).
let memBenchCategoryLabels: [String] = [
    "simple",
    "comparative",
    "aggregative",
    "conditional",
    "knowledge_update",
    "post_processing",
    "noisy",
]

/// Computes aggregate metrics, per-category breakdown, and latency stats
/// for a set of scored MemBench items.
func aggregateMemBenchScores(
    _ scores: [MemBenchItemScore]
) -> (
    aggregate: MemBenchAggregateMetrics,
    categories: [MemBenchCategoryBreakdown],
    latency: MemBenchLatencyStats
) {
    // ── Aggregate (guard-healthy only) ──────────────────────────────────────
    let healthy = scores.filter(\.guardHealthy)
    let n = Double(healthy.count)
    let aggregate: MemBenchAggregateMetrics
    if healthy.isEmpty {
        aggregate = MemBenchAggregateMetrics(
            queryCount: 0,
            recallAnyAt1: 0, recallAnyAt5: 0, recallAnyAt10: 0,
            recallAllAt1: 0, recallAllAt5: 0, recallAllAt10: 0,
            mrr: 0,
            multipleChoiceAccuracy: 0
        )
    } else {
        // C9: MC accuracy over guard-healthy items; nil predictions score 0.
        let mcCorrectCount = Double(healthy.filter(\.multipleChoiceCorrect).count)
        aggregate = MemBenchAggregateMetrics(
            queryCount: healthy.count,
            recallAnyAt1:  healthy.map(\.recallAnyAt1).reduce(0, +) / n,
            recallAnyAt5:  healthy.map(\.recallAnyAt5).reduce(0, +) / n,
            recallAnyAt10: healthy.map(\.recallAnyAt10).reduce(0, +) / n,
            recallAllAt1:  healthy.map(\.recallAllAt1).reduce(0, +) / n,
            recallAllAt5:  healthy.map(\.recallAllAt5).reduce(0, +) / n,
            recallAllAt10: healthy.map(\.recallAllAt10).reduce(0, +) / n,
            mrr:           healthy.map(\.mrr).reduce(0, +) / n,
            multipleChoiceAccuracy: mcCorrectCount / n
        )
    }

    // ── Per-category breakdown ───────────────────────────────────────────────
    // Categories in canonical paper order; unknown categories are collected as
    // an "other" bucket at the end.
    var seenCategories = Set<String>()
    var orderedCategories: [String] = []
    for label in memBenchCategoryLabels {
        if healthy.contains(where: { $0.category == label }) {
            orderedCategories.append(label)
            seenCategories.insert(label)
        }
    }
    // Append any category not in the canonical list (HighLevel categories, etc.).
    for score in healthy {
        if seenCategories.insert(score.category).inserted {
            orderedCategories.append(score.category)
        }
    }

    let categories: [MemBenchCategoryBreakdown] = orderedCategories.map { label in
        let catHealthy = healthy.filter { $0.category == label }
        let cn = Double(catHealthy.count)
        if catHealthy.isEmpty {
            return MemBenchCategoryBreakdown(
                label: label, queryCount: 0,
                recallAnyAt5: 0, recallAllAt5: 0, mrr: 0)
        }
        return MemBenchCategoryBreakdown(
            label: label,
            queryCount: catHealthy.count,
            recallAnyAt5:  catHealthy.map(\.recallAnyAt5).reduce(0, +) / cn,
            recallAllAt5:  catHealthy.map(\.recallAllAt5).reduce(0, +) / cn,
            mrr:           catHealthy.map(\.mrr).reduce(0, +) / cn
        )
    }

    // ── Latency (all items) ──────────────────────────────────────────────
    let queryLatencies = scores.map(\.queryLatencySeconds)
    let writeLatencies = scores.map(\.writeMeanLatencySeconds)
    let latency = MemBenchLatencyStats(
        queryP50Seconds: lmePercentile(queryLatencies, 0.50),
        queryP95Seconds: lmePercentile(queryLatencies, 0.95),
        queryMeanSeconds: queryLatencies.isEmpty ? 0
            : queryLatencies.reduce(0, +) / Double(queryLatencies.count),
        writeMeanSeconds: writeLatencies.isEmpty ? 0
            : writeLatencies.reduce(0, +) / Double(writeLatencies.count)
    )

    return (aggregate, categories, latency)
}

// MARK: - JSON report types

/// Corpus statistics block of the MemBench report.
struct MemBenchReportCorpusStats: Codable, Sendable {
    let itemsLoaded: Int
    let itemsSkipped: Int
    let itemsRun: Int
    let guardExcluded: Int

    enum CodingKeys: String, CodingKey {
        case itemsLoaded    = "items_loaded"
        case itemsSkipped   = "items_skipped"
        case itemsRun       = "items_run"
        case guardExcluded  = "guard_excluded"
    }
}

/// Aggregate metrics block of the MemBench report.
/// Uses the same recall_any_* / recall_all_* / mrr / query_count naming
/// convention as the LME and LoCoMo reports for optimizer compatibility.
/// C9 adds multiple_choice_accuracy alongside retrieval_accuracy so both
/// metrics are visible side by side.
struct MemBenchReportAggregate: Codable, Sendable {
    let queryCount: Int
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
    /// C9: fraction of guard-healthy items where the MC prediction matched
    /// groundTruth. Comparable to the paper's published primary metric.
    /// The retrieval figures above are the primary metric for this harness.
    let multipleChoiceAccuracy: Double

    enum CodingKeys: String, CodingKey {
        case queryCount             = "query_count"
        case recallAnyAt1           = "recall_any_at_1"
        case recallAnyAt5           = "recall_any_at_5"
        case recallAnyAt10          = "recall_any_at_10"
        case recallAllAt1           = "recall_all_at_1"
        case recallAllAt5           = "recall_all_at_5"
        case recallAllAt10          = "recall_all_at_10"
        case mrr
        case multipleChoiceAccuracy = "multiple_choice_accuracy"
    }
}

/// Per-category breakdown entry in the MemBench report.
struct MemBenchReportCategoryEntry: Codable, Sendable {
    let label: String
    let queryCount: Int
    let recallAnyAt5: Double
    let recallAllAt5: Double
    let mrr: Double

    enum CodingKeys: String, CodingKey {
        case label
        case queryCount   = "query_count"
        case recallAnyAt5 = "recall_any_at_5"
        case recallAllAt5 = "recall_all_at_5"
        case mrr
    }
}

/// Latency statistics block of the MemBench report.
struct MemBenchReportLatency: Codable, Sendable {
    let queryP50Seconds: Double
    let queryP95Seconds: Double
    let queryMeanSeconds: Double
    let writeMeanSeconds: Double

    enum CodingKeys: String, CodingKey {
        case queryP50Seconds  = "query_p50_seconds"
        case queryP95Seconds  = "query_p95_seconds"
        case queryMeanSeconds = "query_mean_seconds"
        case writeMeanSeconds = "write_mean_seconds"
    }
}

/// Per-item entry in the MemBench report.
struct MemBenchReportPerItem: Codable, Sendable {
    let itemID: String
    let category: String
    let turnsIngested: Int
    let guardHealthy: Bool
    let guardDiagnostic: String?
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
    /// Query latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    var queryLatencySeconds: Double = 0.0
    /// Write latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    var writeMeanLatencySeconds: Double = 0.0
    let rankedSids: [String]
    let evidenceSids: [String]
    let retrievedUUIDCount: Int
    /// Estimated tokens in the MCP payload divided by retrieved result count.
    /// Nil when payload was absent or result count was zero.
    let tokensPerResult: Double?
    /// Verbatim payload text returned by the recall verb. Nil when absent.
    let payloadText: String?
    // MARK: C9 — multiple-choice arm
    /// The predicted answer letter chosen by selectMultipleChoicePrediction.
    /// Null when no option text appeared in the payload.
    let multipleChoicePrediction: String?
    /// True when multipleChoicePrediction matches the dataset groundTruth.
    let multipleChoiceCorrect: Bool

    enum CodingKeys: String, CodingKey {
        case itemID                    = "item_id"
        case category
        case turnsIngested             = "turns_ingested"
        case guardHealthy              = "guard_healthy"
        case guardDiagnostic           = "guard_diagnostic"
        case recallAnyAt1              = "recall_any_at_1"
        case recallAnyAt5              = "recall_any_at_5"
        case recallAnyAt10             = "recall_any_at_10"
        case recallAllAt1              = "recall_all_at_1"
        case recallAllAt5              = "recall_all_at_5"
        case recallAllAt10             = "recall_all_at_10"
        case mrr
        case rankedSids                = "ranked_sids"
        case evidenceSids              = "evidence_sids"
        case retrievedUUIDCount        = "retrieved_uuid_count"
        case tokensPerResult           = "tokens_per_result"
        case payloadText               = "payload_text"
        case multipleChoicePrediction  = "multiple_choice_prediction"
        case multipleChoiceCorrect     = "multiple_choice_correct"
    }
}

/// The full MemBench run report.
/// Additive with BENCHMARKER_OPTIMIZER_CONTRACT.md: query_count and mrr match
/// the existing convention; recall_any_* / recall_all_* extend it for
/// multi-turn evidence. The category_breakdown key mirrors LoCoMo.
struct MemBenchReport: Codable, Sendable {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Constant rather than a parameter: a report
    /// describes the run that produced it, and that run's artifacts were
    /// validated against this exact value on open, so a mismatch fails the run
    /// rather than reaching a report.
    ///
    /// Declared with its value, so it is always encoded and never decoded: an
    /// older report that predates the field still reads.
    let estateSchemaVersion: String = currentEstateSchemaVersion

    let runID: String
    let runLabel: String
    /// ISO8601 timestamp of report generation.
    let generatedAt: String
    let corpusStats: MemBenchReportCorpusStats
    let aggregate: MemBenchReportAggregate
    /// Per-category breakdown: simple/comparative/aggregative/conditional/
    /// knowledge_update/post_processing/noisy (and any non-canonical labels).
    let categoryBreakdown: [MemBenchReportCategoryEntry]
    /// Latency stats kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    var latency: MemBenchReportLatency? = nil
    let perItem: [MemBenchReportPerItem]
    /// Encode barrier mode used during ingest (drain / impatient / none).
    let encodeBarrier: String
    /// Guard probe sampling policy for the leg ("once" or "per-unit", C5).
    let guardSampling: String
    /// At-rest posture of scratch estates ("plaintext-optout" or "encrypted-ephemeral").
    let estateEncryption: String
    /// Agent perspective loaded ("FirstAgent" or "ThirdAgent").
    let agent: String
    /// Categories included (nil = all LowLevel categories).
    let categoriesIncluded: [String]?
    /// Optional category filter applied before offset/limit (nil = all categories).
    let categoryFilter: String?
    // MARK: Identity block (accuracy lane — binary + protocol version only)
    /// Binary SHA-256 + mootx01 version + protocol version. Timing-lane
    /// machine-profile fields are absent from accuracy files per the
    /// 2026-08-18 doctrine (accuracy vs timing lane separation).
    var identityEnvironment: IdentityEnvironment? = nil
    /// Storage backend shape used for scratch estates: "disk" (SQLite) or "ram" (InMemory, C1).
    let shape: String
    /// Effective item concurrency. Internal only — never emitted: a run is
    /// a run; width is not a property of accuracy figures.
    var parallelUnits: Int = 1
    // MARK: Timing report (internal only — not emitted on accuracy lane)
    /// Leg-level timing report. Kept for internal diagnostics; excluded from
    /// the accuracy-lane report JSON per the 2026-08-18 benchmark-reset doctrine.
    var timingReport: String? = nil
    /// How timing capture was sampled. Internal only; not emitted on accuracy lane.
    var timingSampling: String = ""
    // MARK: C10 — Shape 3 deviation labels
    /// Estate grouping topology: "per-item" (published protocol) or
    /// "consolidated-shape3" (Shape 3 deviation). Nil in pre-C10 reports.
    let estateShape: String?
    /// True when the run departs from the published per-item protocol.
    /// False for standard per-item runs. Nil in pre-C10 reports.
    let protocolDeviation: Bool?
    /// Number of groups built for Shape 3. Nil for per-item runs.
    let shape3GroupCount: Int?
    /// Conflict key type used for grouping: "question_text". Nil for per-item runs.
    let shape3ConflictKeyType: String?
    /// Number of unique conflict keys found across all items. Nil for per-item runs.
    let shape3UniqueKeys: Int?
    /// Item counts per group, in assignment order. Nil for per-item runs.
    let shape3ItemsPerGroup: [Int]?
    // MARK: C11 — Capacity tier fields (all nil for baseline runs)
    /// CLI --capacity-tier value: "baseline", "10k", or "100k".
    /// Always present for C11+ reports; nil in pre-C11 reports.
    let capacityTier: String?
    /// Token target for this tier (nil for baseline or pre-C11 reports).
    let capacityTargetTokens: Int?
    /// Achieved estate token volume at p50 across all items (nil for baseline).
    let capacityAchievedTokensP50: Int?
    /// Maximum achieved estate token volume across all items (nil for baseline).
    let capacityAchievedTokensMax: Int?
    /// Achieved token count per item in result order (nil for baseline).
    let capacityAchievedTokensPerItem: [Int]?
    /// Items contributing sessions to each estate: 1 = X only, >1 = X + fillers (nil for baseline).
    let capacityItemsPerEstate: [Int]?
    /// Items where the filler pool was exhausted before reaching the target token count.
    /// Nil when baseline, or when no shortfall occurred (count == 0).
    let capacityShortfallItems: Int?

    enum CodingKeys: String, CodingKey {
        case estateSchemaVersion     = "estate_schema_version"
        case runID              = "run_id"
        case runLabel           = "run_label"
        case generatedAt        = "generated_at"
        case corpusStats        = "corpus_stats"
        case aggregate
        case categoryBreakdown  = "category_breakdown"
        case perItem            = "per_item"
        case encodeBarrier      = "encode_barrier"
        case guardSampling      = "guard_sampling"
        case estateEncryption   = "estate_encryption"
        case agent
        case categoriesIncluded = "categories_included"
        case categoryFilter     = "category_filter"
        case identityEnvironment = "run_environment"
        case shape
        // C10: Shape 3 deviation labels — optional, absent from pre-C10 reports.
        case estateShape            = "estate_shape"
        case protocolDeviation      = "protocol_deviation"
        case shape3GroupCount       = "shape_3_group_count"
        case shape3ConflictKeyType  = "shape_3_conflict_key_type"
        case shape3UniqueKeys       = "shape_3_unique_keys"
        case shape3ItemsPerGroup    = "shape_3_items_per_group"
        // C11: Capacity tier fields.
        case capacityTier               = "capacity_tier"
        case capacityTargetTokens       = "capacity_target_tokens"
        case capacityAchievedTokensP50  = "capacity_achieved_tokens_p50"
        case capacityAchievedTokensMax  = "capacity_achieved_tokens_max"
        case capacityAchievedTokensPerItem = "capacity_achieved_tokens_per_item"
        case capacityItemsPerEstate     = "capacity_items_per_estate"
        case capacityShortfallItems     = "capacity_shortfall_items"
    }
}

// MARK: - Report builder

/// Assembles a `MemBenchReport` from the run config, corpus, and scored results.
///
/// - Parameters:
///   - config: Immutable run configuration.
///   - corpus: Loaded corpus (for item counts).
///   - results: Per-item results from the runner.
///   - scores: Per-item scores from `scoreMemBenchItem`.
///   - runEnvironment: Machine provenance (JB-01). Nil for legacy or test runs.
///   - timingReport: C4 leg-level timing report text. Nil when absent.
///   - shape3Groups: C10 groups built by `runMemBenchItemsConsolidated`. Non-nil only
///     for Shape 3 runs; triggers deviation labeling and group stats in the report.
///   - achievedTokensPerItem: C11 per-item achieved token counts from
///     `runMemBenchItemsCapacityTier`. Nil for baseline and Shape 3 runs.
///   - itemsPerEstate: C11 per-item filler+own item counts from the capacity runner.
///     Nil for baseline and Shape 3 runs.
func buildMemBenchReport(
    config: MemBenchRunConfig,
    corpus: MemBenchCorpus,
    results: [MemBenchItemResult],
    scores: [MemBenchItemScore],
    identityEnvironment: IdentityEnvironment? = nil,
    // C4: leg-level timing report. Stored internally; not emitted on accuracy lane.
    timingReport: String? = nil,
    // C10: Shape 3 groups. Non-nil when estateGrouping == .consolidatedShape3.
    shape3Groups: [[MemBenchItem]]? = nil,
    // C11: Capacity tier results. Nil for baseline runs and Shape 3 runs.
    achievedTokensPerItem: [Int]? = nil,
    itemsPerEstate: [Int]? = nil
) -> MemBenchReport {
    let (agg, cats, lat) = aggregateMemBenchScores(scores)
    let guardExcluded = scores.filter { !$0.guardHealthy }.count

    let corpusStats = MemBenchReportCorpusStats(
        itemsLoaded: corpus.items.count,
        itemsSkipped: corpus.skippedCount,
        itemsRun: scores.count,
        guardExcluded: guardExcluded
    )

    let reportAggregate = MemBenchReportAggregate(
        queryCount:             agg.queryCount,
        recallAnyAt1:           agg.recallAnyAt1,
        recallAnyAt5:           agg.recallAnyAt5,
        recallAnyAt10:          agg.recallAnyAt10,
        recallAllAt1:           agg.recallAllAt1,
        recallAllAt5:           agg.recallAllAt5,
        recallAllAt10:          agg.recallAllAt10,
        mrr:                    agg.mrr,
        multipleChoiceAccuracy: agg.multipleChoiceAccuracy
    )

    let categoryEntries = cats.map { c in
        MemBenchReportCategoryEntry(
            label: c.label,
            queryCount: c.queryCount,
            recallAnyAt5: c.recallAnyAt5,
            recallAllAt5: c.recallAllAt5,
            mrr: c.mrr
        )
    }

    let reportLatency = MemBenchReportLatency(
        queryP50Seconds:  lat.queryP50Seconds,
        queryP95Seconds:  lat.queryP95Seconds,
        queryMeanSeconds: lat.queryMeanSeconds,
        writeMeanSeconds: lat.writeMeanSeconds
    )

    // Per-item entries with tokensPerResult computation (mirrors LoCoMo builder).
    let perItem = scores.map { score -> MemBenchReportPerItem in
        var tpr: Double? = nil
        if let text = score.payloadText,
           let n = lmeParseResultCount(text), n > 0 {
            tpr = Double(lmeEstimateTokens(text)) / Double(n)
        }
        return MemBenchReportPerItem(
            itemID: score.itemID,
            category: score.category,
            turnsIngested: score.turnsIngested,
            guardHealthy: score.guardHealthy,
            guardDiagnostic: score.guardDiagnostic,
            recallAnyAt1:  score.recallAnyAt1,
            recallAnyAt5:  score.recallAnyAt5,
            recallAnyAt10: score.recallAnyAt10,
            recallAllAt1:  score.recallAllAt1,
            recallAllAt5:  score.recallAllAt5,
            recallAllAt10: score.recallAllAt10,
            mrr: score.mrr,
            queryLatencySeconds: score.queryLatencySeconds,
            writeMeanLatencySeconds: score.writeMeanLatencySeconds,
            rankedSids: score.rankedSids,
            evidenceSids: score.evidenceSids,
            retrievedUUIDCount: score.retrievedUUIDCount,
            tokensPerResult: tpr,
            payloadText: score.payloadText,
            multipleChoicePrediction: score.multipleChoicePrediction,
            multipleChoiceCorrect: score.multipleChoiceCorrect
        )
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let generatedAt = formatter.string(from: Date())

    // C10 + C11: estate shape, protocol deviation flag, and group/capacity stats.
    //
    // Three mutually exclusive topologies, in precedence order:
    //   1. Consolidated Shape 3 (C10): all items share one estate per conflict-key group.
    //   2. Capacity tier (C11): per-item estates grown with conflict-free filler.
    //   3. Standard per-item (baseline): one estate per item, no filler.
    //
    // Per-item baseline writes "per-item" + protocolDeviation=false so the topology
    // is always self-documenting in the JSON report.
    let estateShape: String
    let protocolDeviation: Bool
    let shape3GroupCount: Int?
    let shape3ConflictKeyType: String?
    let shape3UniqueKeys: Int?
    let shape3ItemsPerGroup: [Int]?
    if let groups = shape3Groups {
        // C10 Shape 3: consolidated multi-item estates.
        estateShape = "consolidated-shape3"
        protocolDeviation = true
        shape3GroupCount = groups.count
        shape3ConflictKeyType = "question_text"
        let allItems = groups.flatMap { $0 }
        shape3UniqueKeys = Set(allItems.map { memBenchConflictKey($0) }).count
        shape3ItemsPerGroup = groups.map(\.count)
    } else if let shapeLabel = config.capacityTier.estateShapeLabel {
        // C11 capacity tier: per-item estates with conflict-free filler.
        estateShape = shapeLabel
        protocolDeviation = true
        shape3GroupCount = nil
        shape3ConflictKeyType = nil
        shape3UniqueKeys = nil
        shape3ItemsPerGroup = nil
    } else {
        // Baseline per-item: no filler, standard published protocol.
        estateShape = "per-item"
        protocolDeviation = false
        shape3GroupCount = nil
        shape3ConflictKeyType = nil
        shape3UniqueKeys = nil
        shape3ItemsPerGroup = nil
    }

    // C11: Capacity tier aggregate stats.
    // achievedTokensPerItem is nil for baseline and Shape 3 runs.
    let capTier: String? = config.capacityTier != .baseline ? config.capacityTier.reportLabel : nil
    let capTargetTokens: Int? = config.capacityTier.targetTokens
    let capP50: Int?
    let capMax: Int?
    let capShortfall: Int?
    if let tokens = achievedTokensPerItem, !tokens.isEmpty {
        let sorted = tokens.sorted()
        capMax = sorted.last
        // Integer p50: reuse lmePercentile by projecting to Double.
        capP50 = Int(lmePercentile(tokens.map { Double($0) }, 0.50))
        if let target = capTargetTokens {
            let shortfallCount = tokens.filter { $0 < target }.count
            capShortfall = shortfallCount > 0 ? shortfallCount : nil
        } else {
            capShortfall = nil
        }
    } else {
        capP50 = nil
        capMax = nil
        capShortfall = nil
    }

    return MemBenchReport(
        runID: UUID().uuidString,
        runLabel: config.runLabel,
        generatedAt: generatedAt,
        corpusStats: corpusStats,
        aggregate: reportAggregate,
        categoryBreakdown: categoryEntries,
        latency: reportLatency,
        perItem: perItem,
        encodeBarrier: config.encodeBarrier.rawValue,
        guardSampling: config.guardSamplingPolicy.rawValue,
        estateEncryption: config.scratchPosture.rawValue,
        agent: config.agent,
        categoriesIncluded: config.categories,
        categoryFilter: config.categoryFilter,
        identityEnvironment: identityEnvironment,
        shape: config.shape.rawValue,
        parallelUnits: config.parallelUnits,
        // Timing fields stored internally; not emitted on accuracy-lane JSON.
        timingReport: timingReport,
        timingSampling: "once-per-leg",
        // C10: Shape 3 deviation labels — always present for C10+ reports.
        estateShape: estateShape,
        protocolDeviation: protocolDeviation,
        shape3GroupCount: shape3GroupCount,
        shape3ConflictKeyType: shape3ConflictKeyType,
        shape3UniqueKeys: shape3UniqueKeys,
        shape3ItemsPerGroup: shape3ItemsPerGroup,
        // C11: Capacity tier fields — nil for baseline and Shape 3 runs.
        capacityTier: capTier,
        capacityTargetTokens: capTargetTokens,
        capacityAchievedTokensP50: capP50,
        capacityAchievedTokensMax: capMax,
        capacityAchievedTokensPerItem: achievedTokensPerItem,
        capacityItemsPerEstate: itemsPerEstate,
        capacityShortfallItems: capShortfall
    )
}

/// Encodes and writes a `MemBenchReport` to a JSON file.
func writeMemBenchReport(_ report: MemBenchReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    // Records are never overwritten (2026-08-17): a taken path raises so the
    // operator is told which measurement was about to be destroyed.
    try writeRecordNeverOverwrite(data, to: url)
}
