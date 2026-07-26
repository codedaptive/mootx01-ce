import Foundation

// LongMemEvalScorer.swift — Pure scoring math for LongMemEval session-recall.
//
// Every function here is deterministic and pure: it takes a ranked list of
// session IDs plus the ground-truth answer session IDs, and returns a number.
// No I/O, no live products. This is the part the unit tests and conformance
// vectors (conformance/longmemeval_vectors.json) pin against hand-computed values.
//
// Key difference from QualityScoring.swift: LongMemEval ground truth is a SET
// of session IDs (one question can have multiple evidence sessions). The scoring
// functions therefore have "any" and "all" variants:
//   - recall_any@k: 1.0 iff ANY answer session appears in the top-k
//   - recall_all@k: 1.0 iff ALL answer sessions appear in the top-k
//   - mrr: 1/(rank of the FIRST answer session found in the ranking)
//
// The pipeline:
//   1. `lmeRankedSessions(uuids:manifest:)` maps retrieved UUID order to session
//      order, deduplicating sessions while preserving the rank of their first UUID.
//   2. Scoring functions operate on the deduplicated session ranking.
//   3. Guard-excluded questions (guardHealthy=false) are excluded from aggregate
//      scoring per BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2 guarantee 1:
//      a non-.healthy guard verdict is "no fitness sample," never a zero.

// MARK: - UUID → session mapping

/// Maps a UUID-ranked result list to a session-ranked list, preserving the rank
/// of each session's FIRST appearing UUID.
///
/// A UUID not in the manifest is dropped (conservative: unmappable hits never
/// earn credit, and a product id that cannot be attributed to a session cannot
/// be judged — the same conservative choice as QualityScoring.swift). Each
/// session appears at most once — duplicate UUIDs from the same session after
/// the first are ignored (the session's rank is already established).
///
/// This is the bridge between what moot_memory_search returns (UUID-ordered items)
/// and what the scoring functions need (session-ordered results).
///
/// - Parameters:
///   - uuids: UUIDs returned by moot_memory_search, best-first.
///   - manifest: The per-question manifest mapping UUID → haystack position.
/// - Returns: Deduplicated session IDs in the order their first UUID appeared.
func lmeRankedSessions(uuids: [String], manifest: [LMEManifestEntry]) -> [String] {
    // Build UUID → sessionID lookup in O(manifest).
    var uuidToSession: [String: String] = Dictionary(minimumCapacity: manifest.count)
    for entry in manifest {
        uuidToSession[entry.uuid] = entry.sessionID
    }
    // Walk the ranked UUIDs; map each to its session; deduplicate while preserving
    // the order established by the first occurrence.
    var seen: Set<String> = []
    var ranked: [String] = []
    ranked.reserveCapacity(min(uuids.count, manifest.count))
    for uuid in uuids {
        guard let sessionID = uuidToSession[uuid] else { continue }  // unmappable: drop
        if seen.insert(sessionID).inserted {
            ranked.append(sessionID)
        }
    }
    return ranked
}

// MARK: - Recall-any@k

/// Recall-any@k: 1.0 iff ANY answer session appears in the top-k ranked sessions.
///
/// This is the single-relevant-item metric generalised to a set: the question is
/// "did the backend surface at least one evidence session in the top-k?" Empty
/// `answerIDs` or `k == 0` → 0.0.
func lmeRecallAny(rankedSessions: [String], answerIDs: Set<String>, k: Int) -> Double {
    guard k > 0, !answerIDs.isEmpty else { return 0.0 }
    return rankedSessions.prefix(k).contains(where: { answerIDs.contains($0) }) ? 1.0 : 0.0
}

// MARK: - Recall-all@k

/// Recall-all@k: 1.0 iff ALL answer sessions appear in the top-k ranked sessions.
///
/// The stricter variant: every evidence session must be within the top-k. Useful
/// for multi-session questions where partial recall is insufficient. Empty
/// `answerIDs` → 1.0 (vacuously true — nothing to recall). `k == 0` → 0.0
/// unless `answerIDs` is also empty.
func lmeRecallAll(rankedSessions: [String], answerIDs: Set<String>, k: Int) -> Double {
    guard !answerIDs.isEmpty else { return 1.0 }  // vacuous: nothing required
    guard k > 0 else { return 0.0 }
    let topK = Set(rankedSessions.prefix(k))
    return answerIDs.isSubset(of: topK) ? 1.0 : 0.0
}

// MARK: - Session-level MRR

/// Session-level MRR: 1 / (1-based rank of the FIRST answer session found in
/// the ranking). Returns 0.0 if no answer session appears in the ranked list.
///
/// For multi-session questions the "first" answer session is the one with the
/// lowest rank — the one the backend surfaced highest. The mean of this across
/// questions is the session MRR.
func lmeSessionMRR(rankedSessions: [String], answerIDs: Set<String>) -> Double {
    guard !answerIDs.isEmpty else { return 0.0 }
    for (zeroBased, sessionID) in rankedSessions.enumerated() {
        if answerIDs.contains(sessionID) {
            return 1.0 / Double(zeroBased + 1)
        }
    }
    return 0.0
}

// MARK: - Per-question score

/// The scored result for one LME question. Guard-excluded questions have all
/// recall/MRR metrics set to 0.0 and are excluded from aggregate scoring.
///
/// Latency and ingest counts are always recorded — they are measurement
/// observations, not quality metrics, and are not subject to guard exclusion.
struct LMEQuestionScore: Sendable {
    /// Question identifier.
    let questionID: String
    /// Question type (e.g. "single-session-user", "multi-session").
    let questionType: String
    /// True when the DegeneracyGuard classified the backend as healthy.
    /// False means this question is excluded from aggregate scoring.
    let guardHealthy: Bool
    /// Diagnostic message when the guard was not healthy (nil when healthy).
    let guardDiagnostic: String?
    // Per-question recall/MRR metrics. All 0.0 when guardHealthy is false.
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    /// Session-level MRR: 1/(rank of the first answer session found).
    let mrr: Double
    /// The deduplicated session-ranked result list (for debugging and per_question JSON).
    let rankedSessionIDs: [String]
    /// Ground-truth session IDs that contain evidence for the question.
    let answerSessionIDs: [String]
    // Latency and ingest stats — always recorded, not excluded by guard.
    let queryLatencySeconds: Double
    let writeMeanLatencySeconds: Double
    let turnsIngested: Int
    let retrievedUUIDCount: Int
}

/// Scores one `LMEQuestionResult`. If the guard was not healthy, all recall/MRR
/// metrics are zeroed and the question is flagged for aggregate exclusion.
func scoreLMEQuestion(_ result: LMEQuestionResult) -> LMEQuestionScore {
    let rankedSessions = lmeRankedSessions(uuids: result.retrievedUUIDs, manifest: result.manifest)
    let answerSet = Set(result.answerSessionIDs)

    // Per BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2 guarantee 1: a non-.healthy guard
    // verdict is "no fitness sample," never a zero. Guard-excluded questions are
    // counted but not scored, and are excluded from aggregate denominator.
    let metrics: (Double, Double, Double, Double, Double, Double, Double)
    if result.guardHealthy {
        metrics = (
            lmeRecallAny(rankedSessions: rankedSessions, answerIDs: answerSet, k: 1),
            lmeRecallAny(rankedSessions: rankedSessions, answerIDs: answerSet, k: 5),
            lmeRecallAny(rankedSessions: rankedSessions, answerIDs: answerSet, k: 10),
            lmeRecallAll(rankedSessions: rankedSessions, answerIDs: answerSet, k: 1),
            lmeRecallAll(rankedSessions: rankedSessions, answerIDs: answerSet, k: 5),
            lmeRecallAll(rankedSessions: rankedSessions, answerIDs: answerSet, k: 10),
            lmeSessionMRR(rankedSessions: rankedSessions, answerIDs: answerSet)
        )
    } else {
        metrics = (0, 0, 0, 0, 0, 0, 0)
    }
    let (rAny1, rAny5, rAny10, rAll1, rAll5, rAll10, mrrVal) = metrics

    return LMEQuestionScore(
        questionID: result.questionID,
        questionType: result.questionType,
        guardHealthy: result.guardHealthy,
        guardDiagnostic: result.guardDiagnostic,
        recallAnyAt1: rAny1,
        recallAnyAt5: rAny5,
        recallAnyAt10: rAny10,
        recallAllAt1: rAll1,
        recallAllAt5: rAll5,
        recallAllAt10: rAll10,
        mrr: mrrVal,
        rankedSessionIDs: rankedSessions,
        answerSessionIDs: result.answerSessionIDs,
        queryLatencySeconds: result.queryLatencySeconds,
        writeMeanLatencySeconds: result.writeMeanLatencySeconds,
        turnsIngested: result.turnsIngested,
        retrievedUUIDCount: result.retrievedUUIDs.count
    )
}

// MARK: - Aggregate metrics

/// Aggregate LME retrieval metrics over many questions. All values are means of
/// the per-question scores over guard-healthy questions only.
struct LMEAggregateMetrics: Sendable {
    /// Number of guard-healthy questions that contribute to the aggregate.
    let queryCount: Int
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
}

/// Latency statistics over ALL questions (guard-healthy and guard-excluded alike).
/// Latency is a measurement observation, not a quality metric.
struct LMELatencyStats: Sendable {
    let queryP50Seconds: Double
    let queryP95Seconds: Double
    let queryMeanSeconds: Double
    let writeMeanSeconds: Double
}

/// Nearest-rank percentile of a sample list at fraction `p` ∈ (0, 1].
///
/// Matches the implementation in `RollingSeries.p95` so both latency reporting
/// surfaces are on the same scale. Returns 0.0 for an empty input.
func lmePercentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0.0 }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    let index = min(max(rank, 1) - 1, sorted.count - 1)
    return sorted[index]
}

/// Computes aggregate metrics and latency stats from a slice of scored questions.
///
/// Aggregate: guard-healthy questions only (per contract §1.2 guarantee 1).
/// Latency: all questions (guard-healthy and excluded).
///
/// An empty input yields zeroed structs with `queryCount == 0`.
func aggregateLMEScores(
    _ scores: [LMEQuestionScore]
) -> (aggregate: LMEAggregateMetrics, latency: LMELatencyStats) {
    // ── Aggregate (guard-healthy only) ──────────────────────────────────────
    let healthy = scores.filter(\.guardHealthy)
    let n = Double(healthy.count)
    let aggregate: LMEAggregateMetrics
    if healthy.isEmpty {
        aggregate = LMEAggregateMetrics(
            queryCount: 0,
            recallAnyAt1: 0, recallAnyAt5: 0, recallAnyAt10: 0,
            recallAllAt1: 0, recallAllAt5: 0, recallAllAt10: 0,
            mrr: 0
        )
    } else {
        aggregate = LMEAggregateMetrics(
            queryCount: healthy.count,
            recallAnyAt1:  healthy.map(\.recallAnyAt1).reduce(0, +)  / n,
            recallAnyAt5:  healthy.map(\.recallAnyAt5).reduce(0, +)  / n,
            recallAnyAt10: healthy.map(\.recallAnyAt10).reduce(0, +) / n,
            recallAllAt1:  healthy.map(\.recallAllAt1).reduce(0, +)  / n,
            recallAllAt5:  healthy.map(\.recallAllAt5).reduce(0, +)  / n,
            recallAllAt10: healthy.map(\.recallAllAt10).reduce(0, +) / n,
            mrr:           healthy.map(\.mrr).reduce(0, +)           / n
        )
    }

    // ── Latency (all questions) ──────────────────────────────────────────────
    let queryLatencies = scores.map(\.queryLatencySeconds)
    let writeLatencies = scores.map(\.writeMeanLatencySeconds)
    let latency = LMELatencyStats(
        queryP50Seconds: lmePercentile(queryLatencies, 0.50),
        queryP95Seconds: lmePercentile(queryLatencies, 0.95),
        queryMeanSeconds: queryLatencies.isEmpty ? 0
            : queryLatencies.reduce(0, +) / Double(queryLatencies.count),
        writeMeanSeconds: writeLatencies.isEmpty ? 0
            : writeLatencies.reduce(0, +) / Double(writeLatencies.count)
    )

    return (aggregate, latency)
}

// MARK: - JSON report types

/// Corpus statistics block of the LME report.
struct LMEReportCorpusStats: Codable, Sendable {
    /// Total non-abstention questions in the loaded corpus.
    let questionsLoaded: Int
    /// Abstention questions excluded by the corpus loader (_abs suffix).
    let abstentionExcluded: Int
    /// Questions actually run (after --offset and --limit).
    let questionsRun: Int
    /// Guard-excluded questions (not scored in aggregate).
    let guardExcluded: Int

    enum CodingKeys: String, CodingKey {
        case questionsLoaded   = "questions_loaded"
        case abstentionExcluded = "abstention_excluded"
        case questionsRun      = "questions_run"
        case guardExcluded     = "guard_excluded"
    }
}

/// Aggregate metrics block of the LME report.
///
/// Contract compatibility note (BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2):
/// `query_count` and `mrr` use the same key names as the existing benchmarker
/// outcome record. Recall keys use the `recall_any_*` / `recall_all_*` convention
/// to extend the single-target `recall_at_*` pattern to multi-session truth —
/// additive, not a rename.
struct LMEReportAggregate: Codable, Sendable {
    let queryCount: Int
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double

    enum CodingKeys: String, CodingKey {
        case queryCount    = "query_count"
        case recallAnyAt1  = "recall_any_at_1"
        case recallAnyAt5  = "recall_any_at_5"
        case recallAnyAt10 = "recall_any_at_10"
        case recallAllAt1  = "recall_all_at_1"
        case recallAllAt5  = "recall_all_at_5"
        case recallAllAt10 = "recall_all_at_10"
        case mrr
    }
}

/// Latency statistics block of the LME report.
struct LMEReportLatency: Codable, Sendable {
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

/// Per-question entry in the LME report's `per_question` array.
struct LMEReportPerQuestion: Codable, Sendable {
    let questionID: String
    let questionType: String
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
    let queryLatencySeconds: Double
    let writeMeanLatencySeconds: Double
    /// Deduplicated session ranking (first-UUID-appearance order).
    let rankedSessionIDs: [String]
    /// Ground-truth answer sessions.
    let answerSessionIDs: [String]
    /// Raw count of UUIDs returned by moot_memory_search (before session dedup).
    let retrievedUUIDCount: Int

    enum CodingKeys: String, CodingKey {
        case questionID              = "question_id"
        case questionType            = "question_type"
        case turnsIngested           = "turns_ingested"
        case guardHealthy            = "guard_healthy"
        case guardDiagnostic         = "guard_diagnostic"
        case recallAnyAt1            = "recall_any_at_1"
        case recallAnyAt5            = "recall_any_at_5"
        case recallAnyAt10           = "recall_any_at_10"
        case recallAllAt1            = "recall_all_at_1"
        case recallAllAt5            = "recall_all_at_5"
        case recallAllAt10           = "recall_all_at_10"
        case mrr
        case queryLatencySeconds     = "query_latency_seconds"
        case writeMeanLatencySeconds = "write_mean_latency_seconds"
        case rankedSessionIDs        = "ranked_session_ids"
        case answerSessionIDs        = "answer_session_ids"
        case retrievedUUIDCount      = "retrieved_uuid_count"
    }
}

/// The full LME run report. Written to disk after a `longmemeval` run and
/// consumed by the quality-optimizer when it reads the benchmarker's output.
///
/// Additive/compatible with BENCHMARKER_OPTIMIZER_CONTRACT.md: `query_count` and
/// `mrr` keys are unchanged from the existing outcome-record convention; recall
/// keys extend the pattern with `recall_any_*` / `recall_all_*` for multi-session
/// ground truth.
struct LMEReport: Codable, Sendable {
    /// UUID for this run instance (unique across runs, useful for provenance).
    let runID: String
    /// Human-readable label (e.g. "lme-s-seed20260725").
    let runLabel: String
    /// LongMemEval variant: "s", "m", or "oracle".
    let variant: String
    /// ISO8601 timestamp of report generation.
    let generatedAt: String
    let corpusStats: LMEReportCorpusStats
    let aggregate: LMEReportAggregate
    let latency: LMEReportLatency
    let perQuestion: [LMEReportPerQuestion]

    enum CodingKeys: String, CodingKey {
        case runID       = "run_id"
        case runLabel    = "run_label"
        case variant
        case generatedAt = "generated_at"
        case corpusStats = "corpus_stats"
        case aggregate
        case latency
        case perQuestion = "per_question"
    }
}

// MARK: - Report builder

/// Assembles an `LMEReport` from the run config, corpus, and scored results.
///
/// Called in `runLongMemEval` (main.swift) after the harness completes.
func buildLMEReport(
    config: LMERunConfig,
    corpus: LMECorpus,
    scores: [LMEQuestionScore]
) -> LMEReport {
    let (aggregate, latency) = aggregateLMEScores(scores)
    let guardExcluded = scores.filter { !$0.guardHealthy }.count

    let corpusStats = LMEReportCorpusStats(
        questionsLoaded: corpus.questions.count,
        abstentionExcluded: corpus.abstentionCount,
        questionsRun: scores.count,
        guardExcluded: guardExcluded
    )

    let reportAggregate = LMEReportAggregate(
        queryCount: aggregate.queryCount,
        recallAnyAt1:  aggregate.recallAnyAt1,
        recallAnyAt5:  aggregate.recallAnyAt5,
        recallAnyAt10: aggregate.recallAnyAt10,
        recallAllAt1:  aggregate.recallAllAt1,
        recallAllAt5:  aggregate.recallAllAt5,
        recallAllAt10: aggregate.recallAllAt10,
        mrr: aggregate.mrr
    )

    let reportLatency = LMEReportLatency(
        queryP50Seconds:  latency.queryP50Seconds,
        queryP95Seconds:  latency.queryP95Seconds,
        queryMeanSeconds: latency.queryMeanSeconds,
        writeMeanSeconds: latency.writeMeanSeconds
    )

    let perQuestion = scores.map { score in
        LMEReportPerQuestion(
            questionID: score.questionID,
            questionType: score.questionType,
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
            rankedSessionIDs: score.rankedSessionIDs,
            answerSessionIDs: score.answerSessionIDs,
            retrievedUUIDCount: score.retrievedUUIDCount
        )
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let generatedAt = formatter.string(from: Date())

    return LMEReport(
        runID: UUID().uuidString,
        runLabel: config.runLabel,
        variant: config.variant,
        generatedAt: generatedAt,
        corpusStats: corpusStats,
        aggregate: reportAggregate,
        latency: reportLatency,
        perQuestion: perQuestion
    )
}

/// Encodes and writes an `LMEReport` to a JSON file.
///
/// Uses `.prettyPrinted` + `.sortedKeys` for human readability and deterministic
/// diffs, matching the existing report encoding convention in the benchmarker.
func writeLMEReport(_ report: LMEReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: url)
}
