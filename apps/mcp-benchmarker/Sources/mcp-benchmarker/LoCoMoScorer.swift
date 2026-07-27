import Foundation

// LoCoMoScorer.swift — Scoring wrapper for LoCoMo turn-level recall.
//
// The core scoring math is 100% reused from LongMemEvalScorer.swift — the
// functions lmeRankedSessions, lmeRecallAny, lmeRecallAll, lmeSessionMRR,
// lmePercentile, and aggregateLMEScores are all string-agnostic and work
// identically with dia_ids (e.g. "D1:3") in place of session_ids.
//
// This file adds:
//   1. The manifest bridge: LoCoMoManifestEntry → [LMEManifestEntry] so the
//      string-agnostic lmeRankedSessions can map UUID → dia_id.
//   2. A thin scoreLoCoMoQuestion wrapper that calls the LME math with
//      LoCoMo-specific types.
//   3. Per-category aggregation (single_hop / temporal / multi_hop / open_domain).
//   4. LoCoMo-specific JSON report types (additive w.r.t.
//      BENCHMARKER_OPTIMIZER_CONTRACT.md — no existing keys changed).
//
// The conformance vectors (conformance/locomo_vectors.json) pin the underlying
// math against hand-computed values. Both the Swift and Rust legs must reproduce
// those values to within 1e-9.

// MARK: - Manifest bridge

/// Converts a LoCoMoManifestEntry to the LMEManifestEntry form that
/// lmeRankedSessions expects. The `sessionID` field carries the dia_id
/// so the string-agnostic lmeRankedSessions maps UUID → dia_id correctly.
///
/// - Parameter entries: The LoCoMo manifest for one conversation estate.
/// - Returns: Equivalent LMEManifestEntry list with diaID → sessionID.
private func loCoMoManifestAsLME(_ entries: [LoCoMoManifestEntry]) -> [LMEManifestEntry] {
    entries.map { e in
        LMEManifestEntry(
            uuid: e.uuid,
            sessionID: e.diaID,     // dia_id stands in for sessionID
            turnIndex: e.turnIndex,
            sessionIndex: e.sessionNumber,
            role: e.speaker          // speaker stands in for role
        )
    }
}

// MARK: - Per-question score

/// The scored result for one LoCoMo question.
/// Guard-excluded questions have all recall/MRR metrics set to 0.0 and are
/// excluded from aggregate scoring (per BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2).
struct LoCoMoQuestionScore: Sendable {
    let questionID: String
    /// Category label: "single_hop" | "temporal" | "multi_hop" | "open_domain".
    let categoryLabel: String
    /// Raw integer category (1-4).
    let category: Int
    /// True when the DegeneracyGuard classified the estate as healthy.
    let guardHealthy: Bool
    let guardDiagnostic: String?
    // Per-question recall/MRR metrics. All 0.0 when guardHealthy is false.
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
    /// Deduplicated dia_id ranking (first-UUID-appearance order).
    let rankedDiaIDs: [String]
    /// Ground-truth dia_ids for this question.
    let evidenceDiaIDs: [String]
    // Latency and ingest stats — always recorded, not excluded by guard.
    let queryLatencySeconds: Double
    let writeMeanLatencySeconds: Double
    let turnsIngested: Int
    let retrievedUUIDCount: Int
    /// Raw payload text from the MCP response. Nil when no textBlocks were returned.
    /// Carried from LoCoMoQuestionResult to give the report builder token-efficiency data.
    let payloadText: String?
}

/// Scores one `LoCoMoQuestionResult`. Guard-excluded questions are flagged with
/// zeroed recall/MRR (excluded from aggregate denominator).
func scoreLoCoMoQuestion(_ result: LoCoMoQuestionResult) -> LoCoMoQuestionScore {
    // Bridge manifest to LME form: LoCoMoManifestEntry.diaID → LMEManifestEntry.sessionID.
    let lmeManifest = loCoMoManifestAsLME(result.manifest)
    let rankedDiaIDs = lmeRankedSessions(uuids: result.retrievedUUIDs, manifest: lmeManifest)
    let evidenceSet = Set(result.evidenceDiaIDs)

    let metrics: (Double, Double, Double, Double, Double, Double, Double)
    if result.guardHealthy {
        metrics = (
            lmeRecallAny(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 1),
            lmeRecallAny(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 5),
            lmeRecallAny(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 10),
            lmeRecallAll(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 1),
            lmeRecallAll(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 5),
            lmeRecallAll(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 10),
            lmeSessionMRR(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet)
        )
    } else {
        metrics = (0, 0, 0, 0, 0, 0, 0)
    }
    let (rAny1, rAny5, rAny10, rAll1, rAll5, rAll10, mrrVal) = metrics

    return LoCoMoQuestionScore(
        questionID: result.questionID,
        categoryLabel: result.categoryLabel,
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
        rankedDiaIDs: rankedDiaIDs,
        evidenceDiaIDs: result.evidenceDiaIDs,
        queryLatencySeconds: result.queryLatencySeconds,
        writeMeanLatencySeconds: result.writeMeanLatencySeconds,
        turnsIngested: result.turnsIngested,
        retrievedUUIDCount: result.retrievedUUIDs.count,
        payloadText: result.payloadText
    )
}

// MARK: - Aggregate metrics

/// Aggregate LoCoMo retrieval metrics over guard-healthy questions.
/// Mirrors LMEAggregateMetrics; additive per BENCHMARKER_OPTIMIZER_CONTRACT.md.
struct LoCoMoAggregateMetrics: Sendable {
    let queryCount: Int
    let recallAnyAt1: Double
    let recallAnyAt5: Double
    let recallAnyAt10: Double
    let recallAllAt1: Double
    let recallAllAt5: Double
    let recallAllAt10: Double
    let mrr: Double
}

/// Per-category breakdown. One entry per category (single_hop, temporal,
/// multi_hop, open_domain). Only guard-healthy questions contribute.
struct LoCoMoCategoryBreakdown: Sendable {
    let label: String       // "single_hop" | "temporal" | "multi_hop" | "open_domain"
    let queryCount: Int
    let recallAnyAt5: Double
    let recallAllAt5: Double
    let mrr: Double
}

/// Latency statistics — parallel to LMELatencyStats.
struct LoCoMoLatencyStats: Sendable {
    let queryP50Seconds: Double
    let queryP95Seconds: Double
    let queryMeanSeconds: Double
    let writeMeanSeconds: Double
}

/// Computes aggregate metrics, per-category breakdown, and latency stats.
func aggregateLoCoMoScores(
    _ scores: [LoCoMoQuestionScore]
) -> (
    aggregate: LoCoMoAggregateMetrics,
    categories: [LoCoMoCategoryBreakdown],
    latency: LoCoMoLatencyStats
) {
    // ── Aggregate (guard-healthy only) ──────────────────────────────────────
    let healthy = scores.filter(\.guardHealthy)
    let n = Double(healthy.count)
    let aggregate: LoCoMoAggregateMetrics
    if healthy.isEmpty {
        aggregate = LoCoMoAggregateMetrics(
            queryCount: 0,
            recallAnyAt1: 0, recallAnyAt5: 0, recallAnyAt10: 0,
            recallAllAt1: 0, recallAllAt5: 0, recallAllAt10: 0,
            mrr: 0
        )
    } else {
        aggregate = LoCoMoAggregateMetrics(
            queryCount: healthy.count,
            recallAnyAt1:  healthy.map(\.recallAnyAt1).reduce(0, +) / n,
            recallAnyAt5:  healthy.map(\.recallAnyAt5).reduce(0, +) / n,
            recallAnyAt10: healthy.map(\.recallAnyAt10).reduce(0, +) / n,
            recallAllAt1:  healthy.map(\.recallAllAt1).reduce(0, +) / n,
            recallAllAt5:  healthy.map(\.recallAllAt5).reduce(0, +) / n,
            recallAllAt10: healthy.map(\.recallAllAt10).reduce(0, +) / n,
            mrr:           healthy.map(\.mrr).reduce(0, +) / n
        )
    }

    // ── Per-category breakdown ───────────────────────────────────────────────
    // Category labels in ascending category-integer order (1, 2, 3, 4).
    let categoryLabels = ["single_hop", "temporal", "multi_hop", "open_domain"]
    let categories: [LoCoMoCategoryBreakdown] = categoryLabels.map { label in
        let catHealthy = healthy.filter { $0.categoryLabel == label }
        let cn = Double(catHealthy.count)
        if catHealthy.isEmpty {
            return LoCoMoCategoryBreakdown(
                label: label, queryCount: 0,
                recallAnyAt5: 0, recallAllAt5: 0, mrr: 0)
        }
        return LoCoMoCategoryBreakdown(
            label: label,
            queryCount: catHealthy.count,
            recallAnyAt5:  catHealthy.map(\.recallAnyAt5).reduce(0, +) / cn,
            recallAllAt5:  catHealthy.map(\.recallAllAt5).reduce(0, +) / cn,
            mrr:           catHealthy.map(\.mrr).reduce(0, +) / cn
        )
    }

    // ── Latency (all questions) ──────────────────────────────────────────────
    let queryLatencies = scores.map(\.queryLatencySeconds)
    let writeLatencies = scores.map(\.writeMeanLatencySeconds)
    let latency = LoCoMoLatencyStats(
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

/// Corpus statistics block of the LoCoMo report.
struct LoCoMoReportCorpusStats: Codable, Sendable {
    let questionsLoaded: Int
    let adversarialExcluded: Int
    let questionsRun: Int
    let guardExcluded: Int

    enum CodingKeys: String, CodingKey {
        case questionsLoaded      = "questions_loaded"
        case adversarialExcluded  = "adversarial_excluded"
        case questionsRun         = "questions_run"
        case guardExcluded        = "guard_excluded"
    }
}

/// Aggregate metrics block of the LoCoMo report.
/// Additive w.r.t. BENCHMARKER_OPTIMIZER_CONTRACT.md: same recall_any_* /
/// recall_all_* / mrr / query_count key naming convention as LME.
struct LoCoMoReportAggregate: Codable, Sendable {
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

/// Per-category breakdown entry in the LoCoMo report (additive — new key).
struct LoCoMoReportCategoryEntry: Codable, Sendable {
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

/// Latency statistics block of the LoCoMo report.
struct LoCoMoReportLatency: Codable, Sendable {
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

/// Per-question entry in the LoCoMo report (additive keys parallel to LME).
struct LoCoMoReportPerQuestion: Codable, Sendable {
    let questionID: String
    let categoryLabel: String
    let category: Int
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
    let rankedDiaIDs: [String]
    let evidenceDiaIDs: [String]
    let retrievedUUIDCount: Int
    /// Estimated tokens in the MCP payload divided by the retrieved result count.
    /// Nil when the payload was absent or the result count was zero.
    let tokensPerResult: Double?
    // MARK: Estate cache (additive — LME-07, BENCHMARKER_OPTIMIZER_CONTRACT.md)
    /// Whether this question's conversation estate was served from the snapshot cache.
    /// nil = --estate-cache off (caching not active for this run).
    let cacheHit: Bool?

    enum CodingKeys: String, CodingKey {
        case questionID              = "question_id"
        case categoryLabel           = "category_label"
        case category
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
        case rankedDiaIDs            = "ranked_dia_ids"
        case evidenceDiaIDs          = "evidence_dia_ids"
        case retrievedUUIDCount      = "retrieved_uuid_count"
        case tokensPerResult         = "tokens_per_result"
        case cacheHit                = "cache_hit"
    }
}

/// Provenance summary for a LoCoMo run. Aggregates token-efficiency and encode
/// barrier state so every report JSON is self-documenting without cross-referencing
/// external logs. Mirrors the `token_efficiency` block in LME reports.
struct LoCoMoProvenanceSummary: Codable, Sendable {
    /// Number of questions for which the MCP response contained a non-empty payload.
    let questionsWithPayload: Int
    /// Mean (payload tokens / retrieved UUID count) across questions where both
    /// payload and at least one retrieved result were present. Nil when no questions
    /// had payload text.
    let meanTokensPerResult: Double?
    /// Encode barrier mode used during ingest. Mirrors top-level encode_barrier
    /// to keep provenance summary self-contained for log analysis.
    let encodeBarrier: String

    enum CodingKeys: String, CodingKey {
        case questionsWithPayload = "questions_with_payload"
        case meanTokensPerResult  = "mean_tokens_per_result"
        case encodeBarrier        = "encode_barrier"
    }
}

/// The full LoCoMo run report.
///
/// Additive with BENCHMARKER_OPTIMIZER_CONTRACT.md: `query_count` and `mrr`
/// keys match the existing convention; `recall_any_*` / `recall_all_*` extend
/// it for multi-turn evidence. The new `category_breakdown` key is additive.
struct LoCoMoReport: Codable, Sendable {
    let runID: String
    let runLabel: String
    /// ISO8601 timestamp of report generation.
    let generatedAt: String
    let corpusStats: LoCoMoReportCorpusStats
    let aggregate: LoCoMoReportAggregate
    /// Per-category breakdown: single_hop / temporal / multi_hop / open_domain.
    /// Additive key — new in LoCoMo, not present in LME reports.
    let categoryBreakdown: [LoCoMoReportCategoryEntry]
    let latency: LoCoMoReportLatency
    let perQuestion: [LoCoMoReportPerQuestion]
    /// Encode barrier mode used for ingest (drain / impatient / none). Additive key.
    let encodeBarrier: String
    /// Token-efficiency and barrier provenance summary. Nil when no question had
    /// payload text (e.g. estate was empty during a dry run).
    let provenanceSummary: LoCoMoProvenanceSummary?
    // MARK: Estate cache (additive — LME-07, BENCHMARKER_OPTIMIZER_CONTRACT.md)
    /// The estate cache mode used for this run: "off" or "reuse".
    let estateCache: String
    /// Total number of conversations whose estate was served from the snapshot cache.
    let cacheHits: Int
    /// Total number of conversations that triggered a fresh ingest + snapshot save.
    let cacheMisses: Int

    enum CodingKeys: String, CodingKey {
        case runID             = "run_id"
        case runLabel          = "run_label"
        case generatedAt       = "generated_at"
        case corpusStats       = "corpus_stats"
        case aggregate
        case categoryBreakdown = "category_breakdown"
        case latency
        case perQuestion       = "per_question"
        case encodeBarrier     = "encode_barrier"
        case provenanceSummary = "provenance_summary"
        case estateCache       = "estate_cache"
        case cacheHits         = "cache_hits"
        case cacheMisses       = "cache_misses"
    }
}

// MARK: - Report builder

/// Assembles a `LoCoMoReport` from the run config, corpus, and scored results.
func buildLoCoMoReport(
    config: LoCoMoRunConfig,
    corpus: LoCoMoCorpus,
    results: [LoCoMoQuestionResult],
    scores: [LoCoMoQuestionScore]
) -> LoCoMoReport {
    // Build a questionID → raw result lookup for cache hit propagation and future
    // per-question provenance fields (mirrors the LME builder's resultByID pattern).
    let resultByID = Dictionary(
        uniqueKeysWithValues: results.map { ($0.questionID, $0) }
    )

    let (agg, cats, lat) = aggregateLoCoMoScores(scores)
    let guardExcluded = scores.filter { !$0.guardHealthy }.count

    let corpusStats = LoCoMoReportCorpusStats(
        questionsLoaded: corpus.questions.count,
        adversarialExcluded: corpus.adversarialCount,
        questionsRun: scores.count,
        guardExcluded: guardExcluded
    )

    let reportAggregate = LoCoMoReportAggregate(
        queryCount:    agg.queryCount,
        recallAnyAt1:  agg.recallAnyAt1,
        recallAnyAt5:  agg.recallAnyAt5,
        recallAnyAt10: agg.recallAnyAt10,
        recallAllAt1:  agg.recallAllAt1,
        recallAllAt5:  agg.recallAllAt5,
        recallAllAt10: agg.recallAllAt10,
        mrr:           agg.mrr
    )

    let categoryEntries = cats.map { c in
        LoCoMoReportCategoryEntry(
            label: c.label,
            queryCount: c.queryCount,
            recallAnyAt5: c.recallAnyAt5,
            recallAllAt5: c.recallAllAt5,
            mrr: c.mrr
        )
    }

    let reportLatency = LoCoMoReportLatency(
        queryP50Seconds:  lat.queryP50Seconds,
        queryP95Seconds:  lat.queryP95Seconds,
        queryMeanSeconds: lat.queryMeanSeconds,
        writeMeanSeconds: lat.writeMeanSeconds
    )

    // Compute per-question tokensPerResult: estimated payload tokens / retrieved count.
    // Uses lmeEstimateTokens (byte-count/4) and lmeParseResultCount for consistency
    // with LME's dual-arm computation. Nil when payload was absent or count was zero.
    var tokensPerResultList: [Double] = []
    let perQuestion = scores.map { score -> LoCoMoReportPerQuestion in
        var tpr: Double? = nil
        if let text = score.payloadText,
           let n = lmeParseResultCount(text), n > 0 {
            tpr = Double(lmeEstimateTokens(text)) / Double(n)
            tokensPerResultList.append(tpr!)
        }
        let raw = resultByID[score.questionID]
        return LoCoMoReportPerQuestion(
            questionID: score.questionID,
            categoryLabel: score.categoryLabel,
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
            rankedDiaIDs: score.rankedDiaIDs,
            evidenceDiaIDs: score.evidenceDiaIDs,
            retrievedUUIDCount: score.retrievedUUIDCount,
            tokensPerResult: tpr,
            cacheHit: raw?.cacheHit ?? nil
        )
    }

    let questionsWithPayload = scores.filter { $0.payloadText != nil }.count
    let meanTokensPerResult: Double? = tokensPerResultList.isEmpty ? nil
        : tokensPerResultList.reduce(0, +) / Double(tokensPerResultList.count)
    let provenanceSummary = questionsWithPayload > 0
        ? LoCoMoProvenanceSummary(
            questionsWithPayload: questionsWithPayload,
            meanTokensPerResult: meanTokensPerResult,
            encodeBarrier: config.encodeBarrier.rawValue)
        : nil

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let generatedAt = formatter.string(from: Date())

    // Estate cache aggregate counts (additive — LME-07).
    let cacheHits   = results.filter { $0.cacheHit == true  }.count
    let cacheMisses = results.filter { $0.cacheHit == false }.count

    return LoCoMoReport(
        runID: UUID().uuidString,
        runLabel: config.runLabel,
        generatedAt: generatedAt,
        corpusStats: corpusStats,
        aggregate: reportAggregate,
        categoryBreakdown: categoryEntries,
        latency: reportLatency,
        perQuestion: perQuestion,
        encodeBarrier: config.encodeBarrier.rawValue,
        provenanceSummary: provenanceSummary,
        estateCache: config.estateCache.rawValue,
        cacheHits: cacheHits,
        cacheMisses: cacheMisses
    )
}

/// Encodes and writes a `LoCoMoReport` to a JSON file.
func writeLoCoMoReport(_ report: LoCoMoReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: url)
}
