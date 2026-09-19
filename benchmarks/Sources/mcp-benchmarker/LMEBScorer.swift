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

// MARK: - UUID → doc ID mapping

/// Maps a UUID-ranked result list to a doc-ID-ranked list, preserving the rank
/// of each doc's FIRST appearing UUID.
///
/// A UUID the manifest cannot map still OCCUPIES ITS RANK, under a placeholder
/// id that no real corpus doc id can equal. Dropping unmapped hits does not make
/// scoring conservative — it makes it wrong in the generous direction: every
/// dropped hit closes the gap between rank 1 and the first relevant doc, so a
/// manifest covering only the qrel-relevant docs scores a doc at true rank 40
/// as rank 1 and reports nDCG@10 of 1.0. The tell is recall@1 == @5 == @10:
/// the ranked list ends up shorter than k, so k stops mattering.
///
/// With a complete manifest no placeholder is ever emitted; a nonzero count
/// means a drawer came back that the run did not seed.
///
/// Each doc appears at most once — duplicate UUIDs from the same doc after
/// the first are ignored (the doc's rank is already established).
///
/// - Parameters:
///   - uuids: UUIDs returned by moot_memory_search, best-first.
///   - manifest: The per-query manifest mapping UUID → corpus doc ID.
/// - Returns: Deduplicated doc IDs in the order their first UUID appeared,
///   unmapped hits included as NUL-prefixed placeholders.
func lmebRankedDocs(uuids: [String], manifest: [LMEBManifestEntry]) -> [String] {
    lmebRankedDocsAudited(uuids: uuids, manifest: manifest).ranked
}

/// `lmebRankedDocs` plus the count of hits the manifest could not map, for
/// callers that surface manifest coverage as a run diagnostic.
///
/// Twin of `lmeRankedSessionsAudited(uuids:manifest:)` in LongMemEvalScorer.swift,
/// adapted for LMEB's document-level ground truth.
///
/// INTENTIONAL port asymmetry: this Swift twin takes the manifest entry list
/// and builds the UUID → docID map internally, while Rust's
/// `lmeb_ranked_docs_audited` takes a prebuilt `HashMap` because its runner
/// already holds one (avoids a re-parse). Semantics are identical and pinned
/// by the shared conformance vectors; do not "fix" the signatures to match.
func lmebRankedDocsAudited(
    uuids: [String],
    manifest: [LMEBManifestEntry]
) -> (ranked: [String], unmapped: Int) {
    // Build UUID → docID lookup in O(manifest).
    var uuidToDocID: [String: String] = Dictionary(minimumCapacity: manifest.count)
    for entry in manifest {
        uuidToDocID[entry.uuid] = entry.docID
    }
    var seen: Set<String> = []
    var ranked: [String] = []
    var unmapped = 0
    ranked.reserveCapacity(uuids.count)
    for uuid in uuids {
        let docID: String
        if let mapped = uuidToDocID[uuid] {
            docID = mapped
        } else {
            // NUL-prefixed so it can never collide with a real corpus doc id;
            // the uuid keeps distinct unmapped hits distinct so each consumes
            // exactly one rank slot.
            docID = "\u{0}unmapped:\(uuid)"
            unmapped += 1
        }
        if seen.insert(docID).inserted {
            ranked.append(docID)
        }
    }
    return (ranked, unmapped)
}

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
    /// Raw payload text from the MCP response. Nil when no textBlocks were returned.
    /// Carried from LMEBQueryResult to give the report builder token-efficiency data.
    let payloadText: String?
    // MARK: Judge fields (additive — W4-lmeb-accuracy)
    /// Whether the judge graded this query's answer CORRECT. Nil when the judge
    /// did not run for this query (no judgeCmd, missing gold answer, or subprocess fail).
    let judgeCorrect: Bool?
    /// Estimated tokens in the judge context payload for this query. Nil when the
    /// judge did not run. Used to compute tokens_per_correct at report level.
    let judgeTokens: Int?
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
        relevantDocIDs: Array(relevantSet).sorted(),
        payloadText: result.payloadText,
        judgeCorrect: result.judgeCorrect,
        judgeTokens: result.judgeTokens
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
    /// Query latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    var queryLatencySeconds: Double = 0.0
    /// Write latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    var writeMeanLatencySeconds: Double = 0.0
    let rankedDocIDs: [String]
    let relevantDocIDs: [String]
    let retrievedDocCount: Int
    /// Estimated tokens in the MCP payload divided by the retrieved result count.
    /// Nil when the payload was absent or the result count was zero.
    let tokensPerResult: Double?
    // MARK: Estate cache (additive — LME-07, BENCHMARKER_OPTIMIZER_CONTRACT.md)
    /// Whether this query's estate was served from the snapshot cache.
    /// nil = --estate-cache off (caching not active for this run).
    let cacheHit: Bool?
    // MARK: Drain-barrier lane evidence (additive — FIX-HARNESS-20260727)
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// before accepting idle. false = converged via the no-lanes grace window
    /// (ambiguous evidence). nil = barrier did not run for this query.
    let drainLaneObserved: Bool?
    // MARK: Judge accuracy (additive — W4-lmeb-accuracy)
    /// Whether the judge graded this query CORRECT. Nil when judge did not run.
    /// Presence of a non-nil value means the judge ran and produced a grade.
    let judgeCorrect: Bool?
    /// Estimated tokens in the judge context payload for this query.
    /// Nil when judge did not run. Used with tokens_per_correct at report level.
    let judgeTokens: Int?

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
        case rankedDocIDs        = "ranked_doc_ids"
        case relevantDocIDs      = "relevant_doc_ids"
        case retrievedDocCount   = "retrieved_doc_count"
        case tokensPerResult     = "tokens_per_result"
        case cacheHit            = "cache_hit"
        case drainLaneObserved   = "drain_lane_observed"
        case judgeCorrect        = "judge_correct"
        case judgeTokens         = "judge_tokens"
    }
}

/// Provenance summary for an LMEB run. Aggregates token-efficiency and encode
/// barrier state so every report JSON is self-documenting without cross-referencing
/// external logs. Mirrors LoCoMoProvenanceSummary and the LME token_efficiency block.
struct LMEBProvenanceSummary: Codable, Sendable {
    /// Number of queries for which the MCP response contained a non-empty payload.
    let queriesWithPayload: Int
    /// Mean (payload tokens / retrieved doc count) across queries where both
    /// payload and at least one retrieved result were present. Nil when no queries
    /// had payload text.
    let meanTokensPerResult: Double?
    /// Encode barrier mode used during ingest. Mirrors top-level encode_barrier
    /// to keep provenance summary self-contained for log analysis.
    let encodeBarrier: String

    enum CodingKeys: String, CodingKey {
        case queriesWithPayload  = "queries_with_payload"
        case meanTokensPerResult = "mean_tokens_per_result"
        case encodeBarrier       = "encode_barrier"
    }
}

/// The full LMEB run report. Written after a `lmeb` subcommand run.
///
/// Additive keys — does not overwrite any existing LME or benchmarker report keys.
struct LMEBReport: Codable, Sendable {
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
    /// Evidence types evaluated (e.g. ["user_evidence", "preference_evidence"]).
    let evidenceTypes: [String]
    let generatedAt: String
    let corpusStats: LMEBReportCorpusStats
    let aggregate: LMEBReportAggregate
    /// Latency stats kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    var latency: LMEBReportLatency? = nil
    let perQuery: [LMEBReportPerQuery]
    /// Encode barrier mode used for ingest (drain / impatient / none). Additive key.
    let encodeBarrier: String
    /// Guard probe sampling policy for the leg ("once" or "per-unit", C5).
    let guardSampling: String
    /// Token-efficiency and barrier provenance summary. Nil when no query had
    /// payload text (e.g. estate was empty during a dry run).
    let provenanceSummary: LMEBProvenanceSummary?
    // MARK: Estate cache (additive — LME-07, BENCHMARKER_OPTIMIZER_CONTRACT.md)
    /// The estate cache mode used for this run: "off" or "reuse".
    let estateCache: String
    /// Total number of queries whose estate was served from the snapshot cache.
    let cacheHits: Int
    /// Total number of queries that triggered a fresh ingest + snapshot save.
    let cacheMisses: Int
    // MARK: Estate encryption posture (additive — FIX-HARNESS-20260727)
    /// At-rest posture of the run's scratch estates: "plaintext-optout"
    /// (default) or "encrypted-ephemeral" (--estate-mode encrypted).
    let estateEncryption: String
    // MARK: Judge accuracy (additive — W4-lmeb-accuracy)
    /// Fraction of judged queries where the judge graded the answer CORRECT.
    /// Nil when no judge was configured (judgeCmd was nil) or no queries were
    /// judged. This is the same quantity as published LMEB/ConvoMem QA accuracy.
    let answerAccuracy: Double?
    /// Number of queries for which the judge actually ran and produced a grade.
    /// Zero when judgeCmd was nil. Queries skipped due to missing gold answer or
    /// subprocess failure are NOT counted here.
    let judgedCount: Int
    /// Total judge context tokens / number of correct answers (lower = better).
    /// Nil when no queries were graded correctly (division by zero avoided).
    /// Measures cost efficiency: how many tokens did the run spend per correct answer.
    let tokensPerCorrect: Double?
    /// True when --judge-cmd was set for this run; false otherwise.
    /// SECRECY RULE: only boolean presence is recorded — the command text itself
    /// may carry API keys and is never written to any output (not hashed, not
    /// truncated, not mentioned). Matching the LME report secrecy contract.
    let judgeCmdSet: Bool
    /// Grading mode used ("substring" or "verdict"). Nil when judgeCmd was nil.
    let judgeGrading: String?
    // MARK: Identity block (accuracy lane — binary + protocol version only)
    /// Binary SHA-256 + mootx01 version + protocol version. Timing-lane
    /// machine-profile fields are absent from accuracy files per the
    /// 2026-08-18 doctrine (accuracy vs timing lane separation).
    var identityEnvironment: IdentityEnvironment? = nil
    // MARK: Estate shape (additive — C1)
    /// Storage shape of the run's scratch estates: "disk" (default) or "ram"
    /// (--in-memory). RAM estates are ephemeral; no cache is
    /// possible — combining --shape ram with --estate-cache reuse|require
    /// is rejected at the CLI level.
    let shape: String
    // MARK: Parallelism (internal only — never emitted)
    /// Effective parallel-unit count. A run is a run; width is not a
    /// property of accuracy figures.
    var parallelUnits: Int = 1
    // MARK: Timing report (internal only — not emitted on accuracy lane)
    /// Leg-level timing report. Kept for internal diagnostics; excluded from
    /// the accuracy-lane report JSON per the 2026-08-18 benchmark-reset doctrine.
    var timingReport: String? = nil
    /// How timing capture was sampled. Internal only; not emitted on accuracy lane.
    var timingSampling: String = ""
    // MARK: Estate topology label
    /// The estate topology used for this run. Always "per-query": one restored
    /// artifact per query, the published per-item isolation protocol. The key
    /// is kept so downstream report parsers keep working.
    let estateShape: String
    /// True when a run departs from the published per-item isolation protocol.
    /// Always false in this lane; the key is kept for parsers.
    let protocolDeviation: Bool

    enum CodingKeys: String, CodingKey {
        case estateSchemaVersion     = "estate_schema_version"
        case runID             = "run_id"
        case runLabel          = "run_label"
        case evidenceTypes     = "evidence_types"
        case generatedAt       = "generated_at"
        case corpusStats       = "corpus_stats"
        case aggregate
        case perQuery          = "per_query"
        case encodeBarrier     = "encode_barrier"
        case guardSampling     = "guard_sampling"
        case provenanceSummary = "provenance_summary"
        case estateCache       = "estate_cache"
        case cacheHits         = "cache_hits"
        case cacheMisses       = "cache_misses"
        case estateEncryption  = "estate_encryption"
        case answerAccuracy    = "answer_accuracy"
        case judgedCount       = "judged_count"
        case tokensPerCorrect  = "tokens_per_correct"
        case judgeCmdSet       = "judge_cmd_set"
        case judgeGrading          = "judge_grading"
        case identityEnvironment   = "run_environment"
        case shape
        case estateShape           = "estate_shape"
        case protocolDeviation = "protocol_deviation"
    }
}

// MARK: - Report builder

/// Assembles an `LMEBReport` from the run config, corpus stats, and scored results.
///
/// - Parameters:
///   - judgeCmd: The judge command passed by the operator. Used ONLY for the boolean
///     `judgeCmdSet` field — the command text itself is never written to the report
///     per the secrecy rule (it may carry API keys).
///   - judgeGrading: The grading mode used; written as `judge_grading` when non-nil.
func buildLMEBReport(
    runLabel: String,
    evidenceTypes: [String],
    queriesLoaded: Int,
    results: [LMEBQueryResult],
    scores: [LMEBQueryScore],
    encodeBarrier: String,
    guardSampling: String,
    estateCache: String,
    estateEncryption: String,
    shape: String,
    parallelUnits: Int,
    judgeCmd: String? = nil,
    judgeGrading: LMEJudgeGrading? = nil,
    identityEnvironment: IdentityEnvironment? = nil,
    timingReport: String? = nil
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

    // Compute per-query tokensPerResult: estimated payload tokens / retrieved count.
    var tokensPerResultList: [Double] = []
    let perQuery = scores.map { score -> LMEBReportPerQuery in
        var tpr: Double? = nil
        if let text = score.payloadText,
           let n = lmeParseResultCount(text), n > 0 {
            tpr = Double(lmeEstimateTokens(text)) / Double(n)
            tokensPerResultList.append(tpr!)
        }
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
            tokensPerResult: tpr,
            cacheHit: raw?.cacheHit ?? nil,
            drainLaneObserved: raw?.drainLaneObserved ?? nil,
            judgeCorrect: score.judgeCorrect,
            judgeTokens: score.judgeTokens
        )
    }

    let queriesWithPayload = scores.filter { $0.payloadText != nil }.count
    let meanTokensPerResult: Double? = tokensPerResultList.isEmpty ? nil
        : tokensPerResultList.reduce(0, +) / Double(tokensPerResultList.count)
    let provenanceSummary = queriesWithPayload > 0
        ? LMEBProvenanceSummary(
            queriesWithPayload: queriesWithPayload,
            meanTokensPerResult: meanTokensPerResult,
            encodeBarrier: encodeBarrier)
        : nil

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let generatedAt = formatter.string(from: Date())

    // Estate cache aggregate counts (additive — LME-07).
    let cacheHits   = results.filter { $0.cacheHit == true  }.count
    let cacheMisses = results.filter { $0.cacheHit == false }.count

    // Judge accuracy aggregate (additive — W4-lmeb-accuracy).
    // judgedCount = queries where judgeCorrect is non-nil (judge ran and graded).
    // answerAccuracy = correct / judged (nil when judged == 0 or judgeCmd absent).
    // tokensPerCorrect = total judge tokens / correct count (nil when correct == 0).
    let judgedScores  = scores.filter { $0.judgeCorrect != nil }
    let judgedCount   = judgedScores.count
    let correctCount  = judgedScores.filter { $0.judgeCorrect == true }.count
    let totalJudgeTokens = judgedScores.compactMap(\.judgeTokens).reduce(0, +)
    let answerAccuracy: Double? = judgedCount > 0
        ? Double(correctCount) / Double(judgedCount)
        : nil
    let tokensPerCorrect: Double? = correctCount > 0
        ? Double(totalJudgeTokens) / Double(correctCount)
        : nil


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
        guardSampling: guardSampling,
        provenanceSummary: provenanceSummary,
        estateCache: estateCache,
        cacheHits: cacheHits,
        cacheMisses: cacheMisses,
        estateEncryption: estateEncryption,
        answerAccuracy: answerAccuracy,
        judgedCount: judgedCount,
        tokensPerCorrect: tokensPerCorrect,
        judgeCmdSet: judgeCmd != nil,
        judgeGrading: judgeGrading?.rawValue,
        identityEnvironment: identityEnvironment,
        shape: shape,
        parallelUnits: parallelUnits,
        // Timing fields stored internally; not emitted on accuracy-lane JSON.
        timingReport: timingReport,
        timingSampling: "once-per-leg",
        // Estate topology: per-query restored artifacts, the published
        // per-item isolation protocol. Lane constants; keys kept for parsers.
        estateShape: "per-query",
        protocolDeviation: false
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
    // Records are never overwritten (2026-08-17): a taken path raises so the
    // operator is told which measurement was about to be destroyed.
    try writeRecordNeverOverwrite(data, to: url)
}
