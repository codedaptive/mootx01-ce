import Foundation

// LMEBScorer.swift — Pure scoring math for LMEB/ConvoMem document retrieval.
//
// Every function here is deterministic and pure: given ranked doc IDs and a
// ground-truth relevant set, returns a number. No I/O, no live products.
// Both legs (Swift + Rust) are pinned against the shared conformance vectors in
// conformance/lmeb_vectors.json.
//
// Key difference from LongMemEvalScorer.swift: LMEB ground truth is a SET of
// DOCUMENT IDs (not session IDs). The primary metric is nDCG@10 (standard IR).
// Additional metrics: MRR (document-level), Recall@k, AP@k / MAP@k.
//
// nDCG@k formula (binary relevance, rel_i ∈ {0,1}):
//   DCG@k  = Σ_{i=1}^{k}           rel_i / log2(i+1)
//   IDCG@k = Σ_{i=1}^{min(k,|R|)} 1.0   / log2(i+1)   (ideal ordering)
//   nDCG@k = DCG@k / IDCG@k  (returns 0.0 when IDCG=0, i.e. empty relevant set)
//
// AP@k formula (average precision at k, used for MAP@k):
//   AP@k = (1/|R|) × Σ_{j=1}^{k} P@j × rel_j
//   where P@j = (# relevant in top-j) / j, rel_j ∈ {0,1}
//   MAP@k = mean AP@k over guard-healthy queries

// MARK: - nDCG@k

/// nDCG@k with binary relevance over document IDs.
///
/// - Parameters:
///   - rankedDocIDs: Ranked document IDs, best first.
///   - relevantDocIDs: Ground-truth relevant document IDs.
///   - k: Cutoff rank; only positions 1…k contribute to the score.
/// - Returns: nDCG@k ∈ [0.0, 1.0]. Returns 0.0 when `k == 0` or
///   `relevantDocIDs` is empty (IDCG would be 0 — undefined, treated as 0).
func lmebNDCG(rankedDocIDs: [String], relevantDocIDs: Set<String>, k: Int) -> Double {
    guard k > 0, !relevantDocIDs.isEmpty else { return 0.0 }

    // DCG@k — sum rel_i / log2(rank+1) for each position in top-k.
    // zeroBasedRank = 0 → 1-based rank 1 → divisor log2(2).
    var dcg = 0.0
    for (zeroBasedRank, docID) in rankedDocIDs.prefix(k).enumerated() {
        if relevantDocIDs.contains(docID) {
            dcg += 1.0 / log2(Double(zeroBasedRank + 2))
        }
    }

    // IDCG@k — ideal DCG where the first min(k, |R|) positions are all relevant.
    let nIdeal = min(k, relevantDocIDs.count)
    var idcg = 0.0
    for i in 1...nIdeal {
        idcg += 1.0 / log2(Double(i + 1))
    }
    guard idcg > 0.0 else { return 0.0 }
    return dcg / idcg
}

// MARK: - Document-level MRR

/// Document-level MRR: 1 / (1-based rank of the FIRST relevant document found).
///
/// Returns 0.0 when no relevant document appears in the ranked list, or when
/// `relevantDocIDs` is empty.
func lmebMRR(rankedDocIDs: [String], relevantDocIDs: Set<String>) -> Double {
    guard !relevantDocIDs.isEmpty else { return 0.0 }
    for (zeroBasedRank, docID) in rankedDocIDs.enumerated() {
        if relevantDocIDs.contains(docID) {
            return 1.0 / Double(zeroBasedRank + 1)
        }
    }
    return 0.0
}

// MARK: - Recall@k

/// Recall@k: |relevant ∩ top-k| / |relevant|.
///
/// Returns 0.0 when `k == 0` or `relevantDocIDs` is empty.
func lmebRecall(rankedDocIDs: [String], relevantDocIDs: Set<String>, k: Int) -> Double {
    guard k > 0, !relevantDocIDs.isEmpty else { return 0.0 }
    let topK = Set(rankedDocIDs.prefix(k))
    let hits = topK.intersection(relevantDocIDs).count
    return Double(hits) / Double(relevantDocIDs.count)
}

// MARK: - AP@k (average precision)

/// Average precision at k: (1/|R|) × Σ_{j=1}^{k} P@j × rel_j.
///
/// P@j is the precision at the j-th position (running relevant count / j).
/// `rel_j` ∈ {0,1} for binary relevance. The denominator is |R| (total relevant
/// count) — not min(|R|, k) — matching the standard IR definition.
///
/// Returns 0.0 when `k == 0`, `relevantDocIDs` is empty, or no relevant document
/// appears in the top-k.
func lmebAP(rankedDocIDs: [String], relevantDocIDs: Set<String>, k: Int) -> Double {
    guard k > 0, !relevantDocIDs.isEmpty else { return 0.0 }
    var relevantSeen = 0
    var sumPrecision = 0.0
    for (zeroBasedRank, docID) in rankedDocIDs.prefix(k).enumerated() {
        if relevantDocIDs.contains(docID) {
            relevantSeen += 1
            let rank = zeroBasedRank + 1  // 1-based
            sumPrecision += Double(relevantSeen) / Double(rank)
        }
    }
    return sumPrecision / Double(relevantDocIDs.count)
}

// MARK: - Percentile helper

/// Nearest-rank percentile of a sample list at fraction `p` ∈ (0, 1].
///
/// Matches `lmePercentile` in LongMemEvalScorer.swift and `RollingSeries.p95` —
/// all latency reporting surfaces are on the same scale.
func lmebPercentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0.0 }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    let index = min(max(rank, 1) - 1, sorted.count - 1)
    return sorted[index]
}

// MARK: - Per-query score

/// The scored result for one LMEB query. Guard-excluded queries have all
/// retrieval metrics set to 0.0 and are excluded from aggregate scoring.
///
/// Latency and ingest counts are always recorded — they are measurement
/// observations, not quality metrics, and are not subject to guard exclusion.
struct LMEBQueryScore: Sendable {
    /// Query identifier, e.g. "scene_42_q_0".
    let queryID: String
    /// True when the DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// Diagnostic message when guard was not healthy (nil when healthy).
    let guardDiagnostic: String?
    // Retrieval metrics — all 0.0 when guardHealthy is false.
    let nDCGAt10: Double
    let mrr: Double
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let apAt10: Double
    // Latency and ingest — always recorded.
    let queryLatencySeconds: Double
    let writeMeanLatencySeconds: Double
    let docsIngested: Int
    let retrievedDocCount: Int
    /// Ranked doc IDs after UUID→docID mapping (for debugging and per_query JSON).
    let rankedDocIDs: [String]
    /// Ground-truth relevant doc IDs (for per_query JSON).
    let relevantDocIDs: [String]
}

/// Scores one `LMEBQueryResult`. If the guard was not healthy, all retrieval
/// metrics are zeroed and the query is flagged for aggregate exclusion.
func scoreLMEBQuery(_ result: LMEBQueryResult) -> LMEBQueryScore {
    let rankedDocIDs = result.retrievedDocIDs
    let relevantSet = result.relevantDocIDs

    let metrics: (Double, Double, Double, Double, Double, Double)
    if result.guardHealthy {
        metrics = (
            lmebNDCG(rankedDocIDs: rankedDocIDs, relevantDocIDs: relevantSet, k: 10),
            lmebMRR(rankedDocIDs: rankedDocIDs, relevantDocIDs: relevantSet),
            lmebRecall(rankedDocIDs: rankedDocIDs, relevantDocIDs: relevantSet, k: 1),
            lmebRecall(rankedDocIDs: rankedDocIDs, relevantDocIDs: relevantSet, k: 5),
            lmebRecall(rankedDocIDs: rankedDocIDs, relevantDocIDs: relevantSet, k: 10),
            lmebAP(rankedDocIDs: rankedDocIDs, relevantDocIDs: relevantSet, k: 10)
        )
    } else {
        metrics = (0, 0, 0, 0, 0, 0)
    }
    let (ndcg, mrr, r1, r5, r10, ap) = metrics

    return LMEBQueryScore(
        queryID: result.queryID,
        guardHealthy: result.guardHealthy,
        guardDiagnostic: result.guardDiagnostic,
        nDCGAt10: ndcg,
        mrr: mrr,
        recallAt1: r1,
        recallAt5: r5,
        recallAt10: r10,
        apAt10: ap,
        queryLatencySeconds: result.queryLatencySeconds,
        writeMeanLatencySeconds: result.writeMeanLatencySeconds,
        docsIngested: result.docsIngested,
        retrievedDocCount: result.retrievedDocIDs.count,
        rankedDocIDs: rankedDocIDs,
        relevantDocIDs: Array(relevantSet).sorted()
    )
}

// MARK: - Aggregate metrics

/// Aggregate LMEB retrieval metrics over many queries. All values are means over
/// guard-healthy queries only (per BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2).
struct LMEBAggregate: Sendable {
    let queryCount: Int
    let nDCGAt10: Double
    let mrr: Double
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let mapAt10: Double
}

/// Latency statistics over ALL queries (guard-healthy and guard-excluded alike).
struct LMEBLatencyStats: Sendable {
    let queryP50Seconds: Double
    let queryP95Seconds: Double
    let queryMeanSeconds: Double
    let writeMeanSeconds: Double
}

/// Computes aggregate metrics and latency stats from a slice of scored queries.
///
/// Aggregate: guard-healthy queries only (per contract §1.2).
/// Latency: all queries (guard-healthy and excluded).
func aggregateLMEBScores(
    _ scores: [LMEBQueryScore]
) -> (aggregate: LMEBAggregate, latency: LMEBLatencyStats) {
    // ── Aggregate (guard-healthy only) ──────────────────────────────────────
    let healthy = scores.filter(\.guardHealthy)
    let n = Double(healthy.count)
    let aggregate: LMEBAggregate
    if healthy.isEmpty {
        aggregate = LMEBAggregate(
            queryCount: 0, nDCGAt10: 0, mrr: 0,
            recallAt1: 0, recallAt5: 0, recallAt10: 0, mapAt10: 0
        )
    } else {
        aggregate = LMEBAggregate(
            queryCount: healthy.count,
            nDCGAt10:  healthy.map(\.nDCGAt10).reduce(0, +)  / n,
            mrr:       healthy.map(\.mrr).reduce(0, +)       / n,
            recallAt1: healthy.map(\.recallAt1).reduce(0, +) / n,
            recallAt5: healthy.map(\.recallAt5).reduce(0, +) / n,
            recallAt10: healthy.map(\.recallAt10).reduce(0, +) / n,
            mapAt10:   healthy.map(\.apAt10).reduce(0, +)    / n
        )
    }

    // ── Latency (all queries) ────────────────────────────────────────────────
    let queryLatencies = scores.map(\.queryLatencySeconds)
    let writeLatencies = scores.map(\.writeMeanLatencySeconds)
    let latency = LMEBLatencyStats(
        queryP50Seconds: lmebPercentile(queryLatencies, 0.50),
        queryP95Seconds: lmebPercentile(queryLatencies, 0.95),
        queryMeanSeconds: queryLatencies.isEmpty ? 0
            : queryLatencies.reduce(0, +) / Double(queryLatencies.count),
        writeMeanSeconds: writeLatencies.isEmpty ? 0
            : writeLatencies.reduce(0, +) / Double(writeLatencies.count)
    )

    return (aggregate, latency)
}

// MARK: - JSON report types

/// Corpus statistics block of the LMEB report.
struct LMEBReportCorpusStats: Codable, Sendable {
    /// Total queries across all loaded evidence types.
    let queriesLoaded: Int
    /// Queries actually run (after offset + limit).
    let queriesRun: Int
    /// Guard-excluded queries (not scored in aggregate).
    let guardExcluded: Int

    enum CodingKeys: String, CodingKey {
        case queriesLoaded  = "queries_loaded"
        case queriesRun     = "queries_run"
        case guardExcluded  = "guard_excluded"
    }
}

/// Aggregate metrics block of the LMEB report.
///
/// Key names follow the additive-compatible convention from
/// BENCHMARKER_OPTIMIZER_CONTRACT.md: new namespaced keys for LMEB, not
/// overwriting the existing LME recall_any_*/recall_all_* naming.
struct LMEBReportAggregate: Codable, Sendable {
    let queryCount: Int
    let nDCGAt10: Double
    let mrr: Double
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let mapAt10: Double

    enum CodingKeys: String, CodingKey {
        case queryCount  = "query_count"
        case nDCGAt10    = "ndcg_at_10"
        case mrr
        case recallAt1   = "recall_at_1"
        case recallAt5   = "recall_at_5"
        case recallAt10  = "recall_at_10"
        case mapAt10     = "map_at_10"
    }
}

/// Latency statistics block of the LMEB report.
struct LMEBReportLatency: Codable, Sendable {
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

/// Per-query entry in the LMEB report's `per_query` array.
struct LMEBReportPerQuery: Codable, Sendable {
    let queryID: String
    let docsIngested: Int
    let guardHealthy: Bool
    let guardDiagnostic: String?
    let nDCGAt10: Double
    let mrr: Double
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let apAt10: Double
    let queryLatencySeconds: Double
    let writeMeanLatencySeconds: Double
    let rankedDocIDs: [String]
    let relevantDocIDs: [String]
    let retrievedDocCount: Int
    // MARK: Estate cache (additive — LME-07, BENCHMARKER_OPTIMIZER_CONTRACT.md)
    /// Whether this query's estate was served from the snapshot cache.
    /// nil = --estate-cache off (caching not active for this run).
    let cacheHit: Bool?

    enum CodingKeys: String, CodingKey {
        case queryID             = "query_id"
        case docsIngested        = "docs_ingested"
        case guardHealthy        = "guard_healthy"
        case guardDiagnostic     = "guard_diagnostic"
        case nDCGAt10            = "ndcg_at_10"
        case mrr
        case recallAt1           = "recall_at_1"
        case recallAt5           = "recall_at_5"
        case recallAt10          = "recall_at_10"
        case apAt10              = "ap_at_10"
        case queryLatencySeconds     = "query_latency_seconds"
        case writeMeanLatencySeconds = "write_mean_latency_seconds"
        case rankedDocIDs        = "ranked_doc_ids"
        case relevantDocIDs      = "relevant_doc_ids"
        case retrievedDocCount   = "retrieved_doc_count"
        case cacheHit            = "cache_hit"
    }
}

/// The full LMEB run report. Written after a `lmeb` subcommand run.
///
/// Additive keys — does not overwrite any existing LME or benchmarker report keys.
struct LMEBReport: Codable, Sendable {
    let runID: String
    let runLabel: String
    /// Evidence types evaluated (e.g. ["user_evidence", "preference_evidence"]).
    let evidenceTypes: [String]
    let generatedAt: String
    let corpusStats: LMEBReportCorpusStats
    let aggregate: LMEBReportAggregate
    let latency: LMEBReportLatency
    let perQuery: [LMEBReportPerQuery]
    /// Encode barrier mode used for ingest (drain / impatient / none). Additive key.
    let encodeBarrier: String
    // MARK: Estate cache (additive — LME-07, BENCHMARKER_OPTIMIZER_CONTRACT.md)
    /// The estate cache mode used for this run: "off" or "reuse".
    let estateCache: String
    /// Total number of queries whose estate was served from the snapshot cache.
    let cacheHits: Int
    /// Total number of queries that triggered a fresh ingest + snapshot save.
    let cacheMisses: Int

    enum CodingKeys: String, CodingKey {
        case runID         = "run_id"
        case runLabel      = "run_label"
        case evidenceTypes = "evidence_types"
        case generatedAt   = "generated_at"
        case corpusStats   = "corpus_stats"
        case aggregate
        case latency
        case perQuery      = "per_query"
        case encodeBarrier = "encode_barrier"
        case estateCache   = "estate_cache"
        case cacheHits     = "cache_hits"
        case cacheMisses   = "cache_misses"
    }
}

// MARK: - Report builder

/// Assembles an `LMEBReport` from the run config, corpus stats, and scored results.
func buildLMEBReport(
    runLabel: String,
    evidenceTypes: [String],
    queriesLoaded: Int,
    results: [LMEBQueryResult],
    scores: [LMEBQueryScore],
    encodeBarrier: String,
    estateCache: String
) -> LMEBReport {
    // Build a queryID → raw result lookup for cacheHit propagation.
    let resultByID = Dictionary(
        uniqueKeysWithValues: results.map { ($0.queryID, $0) }
    )

    let (aggregate, latency) = aggregateLMEBScores(scores)
    let guardExcluded = scores.filter { !$0.guardHealthy }.count

    let corpusStats = LMEBReportCorpusStats(
        queriesLoaded: queriesLoaded,
        queriesRun: scores.count,
        guardExcluded: guardExcluded
    )

    let reportAggregate = LMEBReportAggregate(
        queryCount: aggregate.queryCount,
        nDCGAt10:   aggregate.nDCGAt10,
        mrr:        aggregate.mrr,
        recallAt1:  aggregate.recallAt1,
        recallAt5:  aggregate.recallAt5,
        recallAt10: aggregate.recallAt10,
        mapAt10:    aggregate.mapAt10
    )

    let reportLatency = LMEBReportLatency(
        queryP50Seconds:  latency.queryP50Seconds,
        queryP95Seconds:  latency.queryP95Seconds,
        queryMeanSeconds: latency.queryMeanSeconds,
        writeMeanSeconds: latency.writeMeanSeconds
    )

    let perQuery = scores.map { score in
        let raw = resultByID[score.queryID]
        return LMEBReportPerQuery(
            queryID: score.queryID,
            docsIngested: score.docsIngested,
            guardHealthy: score.guardHealthy,
            guardDiagnostic: score.guardDiagnostic,
            nDCGAt10: score.nDCGAt10,
            mrr: score.mrr,
            recallAt1: score.recallAt1,
            recallAt5: score.recallAt5,
            recallAt10: score.recallAt10,
            apAt10: score.apAt10,
            queryLatencySeconds: score.queryLatencySeconds,
            writeMeanLatencySeconds: score.writeMeanLatencySeconds,
            rankedDocIDs: score.rankedDocIDs,
            relevantDocIDs: score.relevantDocIDs,
            retrievedDocCount: score.retrievedDocCount,
            cacheHit: raw?.cacheHit ?? nil
        )
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let generatedAt = formatter.string(from: Date())

    // Estate cache aggregate counts (additive — LME-07).
    let cacheHits   = results.filter { $0.cacheHit == true  }.count
    let cacheMisses = results.filter { $0.cacheHit == false }.count

    return LMEBReport(
        runID: UUID().uuidString,
        runLabel: runLabel,
        evidenceTypes: evidenceTypes,
        generatedAt: generatedAt,
        corpusStats: corpusStats,
        aggregate: reportAggregate,
        latency: reportLatency,
        perQuery: perQuery,
        encodeBarrier: encodeBarrier,
        estateCache: estateCache,
        cacheHits: cacheHits,
        cacheMisses: cacheMisses
    )
}

/// Encodes and writes an `LMEBReport` to a JSON file.
///
/// Uses `.prettyPrinted` + `.sortedKeys` for human readability and deterministic
/// diffs, matching the existing report encoding convention in the benchmarker.
func writeLMEBReport(_ report: LMEBReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: url)
}
