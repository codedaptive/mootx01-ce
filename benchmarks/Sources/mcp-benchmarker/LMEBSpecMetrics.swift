import Foundation

// LMEBSpecMetrics.swift — Official LMEB metric grid (§A3), instruction settings (§A4),
// and two-level aggregation (§A1/§A3).
//
// Implements the COMPLETE official metric surface specified in
// LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §A1, §A3, §A4:
//
//   Metrics at k ∈ {1, 5, 10, 25, 50}: nDCG@k, MAP@k, Recall@k, Precision@k, MRR@k
//   Plus: R_cap@k (§A3, verbatim from metric.py) with None-propagation
//
// Aggregation (§A1/§A3): per-query values → macro mean per subset (evidence category)
//   → mean of subset scores for the task score. BOTH levels are present in the output.
//
// NEW file — do NOT modify LMEBScorer.swift; do NOT reuse its aggregation (that is a
// single-level macro mean; the official protocol is two-level: subset then task).
//
// All functions are deterministic and pure. No I/O, no Date() calls.
// Both ports (Swift + Rust) are pinned to conformance/lmeb-spec/metric_vectors.json.

// MARK: - §A1: Canonical k values

/// The k values the LMEB protocol evaluates at (§A1, §A3).
/// nDCG@k, MAP@k, Recall@k, Precision@k, MRR@k, R_cap@k are computed for each.
let lmebSpecKValues: [Int] = [1, 5, 10, 25, 50]

// MARK: - §A4: Instruction settings enum

/// The two published evaluation settings for LMEB (§A4).
/// With-instruction prepends the subset-specific instruction string to the query;
/// the runner owns prompt construction and records which setting was used.
/// This enum is carried in run records so results are self-documenting.
enum LMEBInstructionSetting: String, Sendable, CaseIterable {
    /// Standard evaluation without any task instruction prepended to the query.
    case withoutInstruction = "without_instruction"
    /// Evaluation with the subset's per-instruction string prepended to the query (§A4).
    case withInstruction    = "with_instruction"
}

// MARK: - §A4: Verbatim per-subset instruction strings

/// Verbatim per-subset instruction strings from task_instructions.json (§A4).
/// The runner prepends the selected instruction to the query text when the run
/// uses `LMEBInstructionSetting.withInstruction`.
///
/// Strings are constants here; the runner owns the concatenation.
enum LMEBSubsetInstructions {

    // §A4, subset: abstention_evidence
    /// "Given a query, retrieve documents that answer the query"
    static let abstentionEvidence =
        "Given a query, retrieve documents that answer the query"

    // §A4, subset: assistant_facts_evidence
    /// "Given a query, retrieve assistant messages that answer the query"
    static let assistantFactsEvidence =
        "Given a query, retrieve assistant messages that answer the query"

    // §A4, subset: changing_evidence
    /// "Given a question, retrieve the latest information to answer the question"
    static let changingEvidence =
        "Given a question, retrieve the latest information to answer the question"

    // §A4, subset: implicit_connection_evidence
    /// "Given a query, retrieve documents that answer the query"
    static let implicitConnectionEvidence =
        "Given a query, retrieve documents that answer the query"

    // §A4, subset: preference_evidence
    /// "Given a query, retrieve the user's stated preferences that can help answer the query"
    static let preferenceEvidence =
        "Given a query, retrieve the user's stated preferences that can help answer the query"

    // §A4, subset: user_evidence
    /// "Given a query, retrieve documents that answer the query"
    static let userEvidence =
        "Given a query, retrieve documents that answer the query"

    /// Lookup map from subset name → instruction string (§A4).
    /// All six subsets are keyed; an absent key means the subset is unknown to the spec.
    static let bySubset: [String: String] = [
        "abstention_evidence":           abstentionEvidence,
        "assistant_facts_evidence":      assistantFactsEvidence,
        "changing_evidence":             changingEvidence,
        "implicit_connection_evidence":  implicitConnectionEvidence,
        "preference_evidence":           preferenceEvidence,
        "user_evidence":                 userEvidence,
    ]
}

// MARK: - §A3: Evaluation options

/// Options that modify which results enter the metric calculation (§A3).
/// Both default to false — matching the LMEB protocol defaults.
struct LMEBSpecOptions: Sendable, Equatable {
    /// When true, the first result in the ranked list is dropped before applying
    /// any k-cutoff (§A3, skip_first_result option, default off).
    let skipFirstResult: Bool
    /// When true, a result whose doc ID equals the query ID is removed before
    /// applying any k-cutoff (§A3, ignore_identical_ids option, default off;
    /// not applicable to ConvoMem data but the switch is required by the spec).
    let ignoreIdenticalIds: Bool

    /// Default options — both switches off (§A3 defaults).
    init(skipFirstResult: Bool = false, ignoreIdenticalIds: Bool = false) {
        self.skipFirstResult = skipFirstResult
        self.ignoreIdenticalIds = ignoreIdenticalIds
    }

    /// Convenience: the canonical default (no filtering).
    static let `default` = LMEBSpecOptions()
}

// MARK: - Per-query metric output (§A3)

/// Per-query metric values at every k in lmebSpecKValues (§A3).
/// Both aggregation levels start from these per-query values.
struct LMEBSpecQueryMetrics: Sendable {
    /// Query identifier.
    let queryID: String
    /// nDCG@k for each k in lmebSpecKValues (§A3, binary relevance, pytrec_eval semantics).
    let ndcg: [Int: Double]
    /// AP@k for each k (used to compute MAP@k at the subset level).
    /// Denominator is |relevant| (total relevant count), not min(|relevant|, k) — matching
    /// the standard IR definition and pytrec_eval on binary relevance (§A3).
    let ap: [Int: Double]
    /// Recall@k: |relevant ∩ top-k| / |relevant| (§A3).
    let recall: [Int: Double]
    /// Precision@k: |relevant ∩ top-k| / k (§A3, pytrec_eval semantics).
    let precision: [Int: Double]
    /// MRR@k: reciprocal rank of the first relevant doc in top-k; 0 if none (§A3).
    let mrr: [Int: Double]
    /// R_cap@k (§A3, metric.py verbatim): hits / min(total_relevant, k).
    /// nil when the query has zero relevant documents — the denominator would be 0.
    /// Macro average ignores nil values (§A3). Rounded to 5 decimals at aggregation.
    let rCap: [Int: Double?]
}

// MARK: - Subset-level aggregated metrics (§A1/§A3, level 1)

/// Macro mean of per-query metrics over all queries in one subset (§A1/§A3, level 1).
struct LMEBSpecSubsetMetrics: Sendable {
    /// Subset name, e.g. "user_evidence".
    let subsetName: String
    /// Number of queries in this subset.
    let queryCount: Int
    /// Per-k macro mean of nDCG@k over queries.
    let ndcg: [Int: Double]
    /// Per-k MAP@k: macro mean of AP@k over queries.
    let map: [Int: Double]
    /// Per-k macro mean of Recall@k.
    let recall: [Int: Double]
    /// Per-k macro mean of Precision@k.
    let precision: [Int: Double]
    /// Per-k macro mean of MRR@k.
    let mrr: [Int: Double]
    /// Per-k macro mean of R_cap@k, ignoring nil values (§A3).
    /// nil when ALL queries have nil for that k (i.e. the entire subset has no relevant docs).
    /// Values are rounded to 5 decimal places at this level (§A3, metric.py).
    let rCap: [Int: Double?]
    /// Per-query metrics (available for record-level JSON output).
    let perQuery: [LMEBSpecQueryMetrics]
}

// MARK: - Task-level aggregated metrics (§A1/§A3, level 2)

/// Mean of subset scores across all subsets (§A1/§A3, level 2 = task score).
/// The primary headline metric is ndcg_at_10.
struct LMEBSpecTaskMetrics: Sendable {
    /// Number of subsets contributing to the task score.
    let subsetCount: Int
    /// Per-k mean of subset nDCG@k scores.
    let ndcg: [Int: Double]
    /// Per-k mean of subset MAP@k scores.
    let map: [Int: Double]
    /// Per-k mean of subset Recall@k scores.
    let recall: [Int: Double]
    /// Per-k mean of subset Precision@k scores.
    let precision: [Int: Double]
    /// Per-k mean of subset MRR@k scores.
    let mrr: [Int: Double]
    /// Per-k mean of subset R_cap@k scores, nil when all subsets are nil for that k.
    let rCap: [Int: Double?]
    /// Headline metric (§A1, main_score="ndcg_at_10").
    var ndcgAt10: Double { ndcg[10] ?? 0.0 }

    // ── Expand-verify scoreboard metrics (§7.5, §3) ───────────────────────────

    /// Share of questions where at least one gold doc appears in the pool.
    /// Pool = returned list when --pool-metrics is absent; the explain payload pool otherwise.
    var poolGuarantee: Double = 0.0

    /// Gold docs found in the pool across all questions / total gold docs.
    /// This is the macro recall over the pool, not the per-question rate.
    var poolGoldRecall: Double = 0.0

    /// Number of questions classified as short queries (content_term_count < threshold).
    var shortQueryCount: Int = 0

    /// Mean nDCG@10 over the short-query subset. 0.0 when shortQueryCount == 0.
    var shortQueryNdcgAt10: Double = 0.0

    /// Mean Recall@10 over the short-query subset. 0.0 when shortQueryCount == 0.
    var shortQueryRecallAt10: Double = 0.0

    /// Pool guarantee (gold-in-pool rate) for the short-query subset.
    var shortQueryPoolGuarantee: Double = 0.0
}

// MARK: - §A3: Per-query metric primitives

/// Applies LMEBSpecOptions to a ranked list before cutoff scoring (§A3).
///
/// - Parameters:
///   - rankedDocIDs: Ranked document IDs produced by the runner (NUL-prefixed for unmapped UUIDs).
///   - queryID: The query's document ID. Used only when `options.ignoreIdenticalIds` is true.
///   - options: Evaluation options.
/// - Returns: Filtered ranked list ready for metric scoring.
func lmebSpecApplyOptions(
    rankedDocIDs: [String],
    queryID: String,
    options: LMEBSpecOptions
) -> [String] {
    var result = rankedDocIDs
    // §A3 ignore_identical_ids: remove any result whose doc ID equals the query ID.
    if options.ignoreIdenticalIds {
        result = result.filter { $0 != queryID }
    }
    // §A3 skip_first_result: drop rank 1 (index 0) before applying k-cutoffs.
    if options.skipFirstResult, !result.isEmpty {
        result = Array(result.dropFirst())
    }
    return result
}

/// nDCG@k with binary relevance (§A3, pytrec_eval semantics).
///
/// DCG@k  = Σ_{i=1..k} 1/log2(i+1) for each relevant hit at 1-based rank i.
/// IDCG@k = Σ_{i=1..min(k,|R|)} 1/log2(i+1)  (ideal ordering).
/// nDCG@k = DCG@k / IDCG@k; returns 0.0 when IDCG=0 (empty relevant set).
///
/// - Parameters:
///   - rankedDocIDs: Filtered, options-applied ranked list.
///   - relevantDocIDs: Ground-truth relevant document IDs.
///   - k: Cutoff rank.
func lmebSpecNDCG(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    k: Int
) -> Double {
    guard k > 0, !relevantDocIDs.isEmpty else { return 0.0 }
    // DCG@k: accumulate 1/log2(rank+1) for each relevant doc in top-k.
    // zeroBasedRank=0 → 1-based rank 1 → divisor log2(0+2).
    var dcg = 0.0
    for (zeroBasedRank, docID) in rankedDocIDs.prefix(k).enumerated() {
        if relevantDocIDs.contains(docID) {
            dcg += 1.0 / log2(Double(zeroBasedRank + 2))
        }
    }
    // IDCG@k: ideal DCG — first min(k, |R|) positions all relevant.
    let nIdeal = min(k, relevantDocIDs.count)
    var idcg = 0.0
    for i in 1...nIdeal {
        idcg += 1.0 / log2(Double(i + 1))
    }
    guard idcg > 0.0 else { return 0.0 }
    return dcg / idcg
}

/// AP@k (average precision at k) for MAP aggregation (§A3, pytrec_eval semantics).
///
/// AP@k = (1/|R|) × Σ_{j=1..k} P@j × rel_j
/// where P@j = (# relevant in top-j) / j and rel_j ∈ {0,1}.
/// The denominator is |R| (total relevant count), NOT min(|R|, k).
/// Returns 0.0 when k==0, relevantDocIDs is empty, or no relevant doc appears in top-k.
func lmebSpecAP(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    k: Int
) -> Double {
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

/// Recall@k: |relevant ∩ top-k| / |relevant| (§A3, pytrec_eval semantics).
///
/// Returns 0.0 when k==0 or relevantDocIDs is empty.
func lmebSpecRecall(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    k: Int
) -> Double {
    guard k > 0, !relevantDocIDs.isEmpty else { return 0.0 }
    let topK = Set(rankedDocIDs.prefix(k))
    let hits = topK.intersection(relevantDocIDs).count
    return Double(hits) / Double(relevantDocIDs.count)
}

/// Precision@k: |relevant ∩ top-k| / k (§A3, pytrec_eval semantics).
///
/// Returns 0.0 when k==0.
func lmebSpecPrecision(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    k: Int
) -> Double {
    guard k > 0 else { return 0.0 }
    let topK = rankedDocIDs.prefix(k)
    let hits = topK.filter { relevantDocIDs.contains($0) }.count
    return Double(hits) / Double(k)
}

/// MRR@k with cutoff at k (§A3, pytrec_eval semantics).
///
/// Reciprocal rank of the FIRST relevant document found in top-k.
/// Returns 0.0 when k==0, relevantDocIDs is empty, or no relevant doc in top-k.
func lmebSpecMRR(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    k: Int
) -> Double {
    guard k > 0, !relevantDocIDs.isEmpty else { return 0.0 }
    for (zeroBasedRank, docID) in rankedDocIDs.prefix(k).enumerated() {
        if relevantDocIDs.contains(docID) {
            return 1.0 / Double(zeroBasedRank + 1)
        }
    }
    return 0.0
}

/// R_cap@k — LMEB-specific capped recall (§A3, verbatim from metric.py).
///
/// R_cap@k = hits / min(total_relevant, k)
///
/// where hits = number of relevant docs in top-k.
/// Returns nil when the query has zero relevant documents (denominator = 0).
/// The macro average at the subset level ignores nil values; if ALL values are nil,
/// the subset R_cap@k is also nil (§A3). Values are rounded to 5 decimal places
/// at aggregation (§A3, metric.py).
///
/// - Parameters:
///   - rankedDocIDs: Filtered, options-applied ranked list.
///   - relevantDocIDs: Ground-truth relevant document IDs.
///   - k: Cutoff rank.
func lmebSpecRCap(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    k: Int
) -> Double? {
    guard k > 0 else { return 0.0 }
    let numRelevantTotal = relevantDocIDs.count
    // §A3: None when the query has no relevant documents (denominator = 0).
    let denom = min(numRelevantTotal, k)
    guard denom > 0 else { return nil }
    let topK = rankedDocIDs.prefix(k)
    let hits = topK.filter { relevantDocIDs.contains($0) }.count
    return Double(hits) / Double(denom)
}

// MARK: - §A3: Full per-query metric computation

/// Computes all official LMEB metrics at every k in lmebSpecKValues for one query (§A3).
///
/// The ranked list is first filtered by options before any k-cutoff is applied.
/// Accepts the NUL-prefixed-placeholder form that the runner produces.
///
/// - Parameters:
///   - rankedDocIDs: Ranked document IDs produced by the runner.
///   - relevantDocIDs: Ground-truth relevant document IDs for this query.
///   - queryID: The query identifier (used for ignore_identical_ids filtering).
///   - options: Evaluation options (skip_first_result, ignore_identical_ids; §A3 defaults = off).
func lmebSpecPerQueryMetrics(
    rankedDocIDs: [String],
    relevantDocIDs: Set<String>,
    queryID: String,
    options: LMEBSpecOptions = .default
) -> LMEBSpecQueryMetrics {
    // Apply options once before any k-cutoff — both filters operate on the full list.
    let filtered = lmebSpecApplyOptions(
        rankedDocIDs: rankedDocIDs,
        queryID: queryID,
        options: options
    )

    var ndcg: [Int: Double] = [:]
    var ap: [Int: Double] = [:]
    var recall: [Int: Double] = [:]
    var precision: [Int: Double] = [:]
    var mrr: [Int: Double] = [:]
    var rCap: [Int: Double?] = [:]

    // §A3: compute every metric at each k in the canonical k-value list.
    for k in lmebSpecKValues {
        ndcg[k]      = lmebSpecNDCG(rankedDocIDs: filtered, relevantDocIDs: relevantDocIDs, k: k)
        ap[k]        = lmebSpecAP(rankedDocIDs: filtered, relevantDocIDs: relevantDocIDs, k: k)
        recall[k]    = lmebSpecRecall(rankedDocIDs: filtered, relevantDocIDs: relevantDocIDs, k: k)
        precision[k] = lmebSpecPrecision(rankedDocIDs: filtered, relevantDocIDs: relevantDocIDs, k: k)
        mrr[k]       = lmebSpecMRR(rankedDocIDs: filtered, relevantDocIDs: relevantDocIDs, k: k)
        rCap[k]      = lmebSpecRCap(rankedDocIDs: filtered, relevantDocIDs: relevantDocIDs, k: k)
    }

    return LMEBSpecQueryMetrics(
        queryID: queryID,
        ndcg: ndcg,
        ap: ap,
        recall: recall,
        precision: precision,
        mrr: mrr,
        rCap: rCap
    )
}

// MARK: - §A1/§A3: Subset aggregation (level 1)

/// Computes subset-level metrics: macro mean of per-query values for each metric and k (§A1/§A3).
///
/// R_cap@k macro mean ignores nil values (§A3). If ALL query values are nil for a given k,
/// the subset R_cap@k is nil. Values are rounded to 5 decimal places per metric.py (§A3).
///
/// - Parameters:
///   - queries: Per-query metrics for all queries belonging to this subset.
///   - subsetName: The subset name (e.g. "user_evidence").
func lmebSpecSubsetMetrics(
    queries: [LMEBSpecQueryMetrics],
    subsetName: String
) -> LMEBSpecSubsetMetrics {
    let n = queries.count

    var ndcg: [Int: Double] = [:]
    var map: [Int: Double] = [:]
    var recall: [Int: Double] = [:]
    var precision: [Int: Double] = [:]
    var mrr: [Int: Double] = [:]
    var rCap: [Int: Double?] = [:]

    for k in lmebSpecKValues {
        // Simple macro means for nDCG, MAP, Recall, Precision, MRR.
        // Empty subset returns 0.0 rather than NaN.
        if n > 0 {
            ndcg[k]      = queries.map { $0.ndcg[k]      ?? 0.0 }.reduce(0, +) / Double(n)
            map[k]       = queries.map { $0.ap[k]         ?? 0.0 }.reduce(0, +) / Double(n)
            recall[k]    = queries.map { $0.recall[k]     ?? 0.0 }.reduce(0, +) / Double(n)
            precision[k] = queries.map { $0.precision[k]  ?? 0.0 }.reduce(0, +) / Double(n)
            mrr[k]       = queries.map { $0.mrr[k]        ?? 0.0 }.reduce(0, +) / Double(n)
        } else {
            ndcg[k] = 0.0; map[k] = 0.0; recall[k] = 0.0; precision[k] = 0.0; mrr[k] = 0.0
        }

        // §A3 R_cap macro mean: ignore nil values; all-nil → nil.
        let validRCap = queries.compactMap { q -> Double? in
            guard let opt = q.rCap[k] else { return nil }
            return opt  // unwrap Double? → Double
        }
        if validRCap.isEmpty {
            // All queries had nil (zero relevant docs) → subset R_cap@k is nil.
            rCap[k] = Optional<Double>.none
        } else {
            // §A3 round to 5 decimals (metric.py: `round(sum(valid) / len(valid), 5)`).
            let avg = validRCap.reduce(0.0, +) / Double(validRCap.count)
            rCap[k] = (avg * 1e5).rounded() / 1e5
        }
    }

    return LMEBSpecSubsetMetrics(
        subsetName: subsetName,
        queryCount: n,
        ndcg: ndcg,
        map: map,
        recall: recall,
        precision: precision,
        mrr: mrr,
        rCap: rCap,
        perQuery: queries
    )
}

// MARK: - Content-term counting (§7.1 short-query gate)

/// Shared English stopword set loaded from the conformance fixture.
///
/// Loading is done once at startup via the package-local conformance path.
/// The stopword list is the harness gate only — the product tokeniser is independent.
/// A token is a content term when it is lowercase-alphanumeric and NOT in this set.
///
/// Callers that cannot access the Bundle (e.g. Rust twin) load the same
/// `conformance/lmeb-spec/stopwords_en.json` fixture from a file path.
private let _lmebStopwordsLoaded: Set<String> = {
    // Locate conformance/lmeb-spec/stopwords_en.json relative to the source tree.
    // In SPM test/tool targets the bundle resource path is not guaranteed, so we
    // try a known relative path from the source directory and fall back to an
    // embedded minimal set when the file cannot be found. The embedded set is
    // kept identical to the fixture for byte-identical output across environments.
    let candidatePaths: [String] = [
        // When running from the package root (swift test / swift build).
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Sources/mcp-benchmarker/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // the suite root (benchmarks/)
            .appendingPathComponent("conformance/lmeb-spec/stopwords_en.json")
            .path,
    ]
    for path in candidatePaths {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let words = obj["stopwords"] as? [String] {
            return Set(words.map { $0.lowercased() })
        }
    }
    // Embedded fallback: complete copy of conformance/lmeb-spec/stopwords_en.json.
    // Kept in sync with the fixture so the function is byte-identical whether or not
    // the file can be located at runtime (SPM #file path is CWD-relative; tests may run
    // from a different directory than the source tree).
    return Set(["a","about","above","after","again","against","all","am","an","and",
                "any","are","aren't","as","at","be","because","been","before","being",
                "below","between","both","but","by","can","can't","cannot","could","couldn't",
                "did","didn't","do","does","doesn't","doing","don't","down","during","each",
                "few","for","from","further","get","got","had","hadn't","has","hasn't",
                "have","haven't","having","he","he'd","he'll","he's","her","here","here's",
                "hers","herself","him","himself","his","how","how's","i","i'd","i'll",
                "i'm","i've","if","in","into","is","isn't","it","it's","its",
                "itself","let's","me","more","most","mustn't","my","myself","no","nor",
                "not","of","off","on","once","only","or","other","ought","our",
                "ours","ourselves","out","over","own","same","shan't","she","she'd","she'll",
                "she's","should","shouldn't","so","some","such","than","that","that's","the",
                "their","theirs","them","themselves","then","there","there's","these","they","they'd",
                "they'll","they're","they've","this","those","through","to","too","under","until",
                "up","very","was","wasn't","we","we'd","we'll","we're","we've","were",
                "weren't","what","what's","when","when's","where","where's","which","while","who",
                "who's","whom","why","why's","will","with","won't","would","wouldn't","you",
                "you'd","you'll","you're","you've","your","yours","yourself","yourselves"])
}()

/// Counts content terms in a query string for the §7.1 short-query gate.
///
/// A content term is a lowercase alphanumeric token not present in the shared
/// English stopword list (`conformance/lmeb-spec/stopwords_en.json`).
/// The stopword list is the harness gate — the product tokeniser is independent.
///
/// Tokenisation: split on any non-alphanumeric character, lowercase each token,
/// discard empty tokens, discard tokens in the stopword set. The remaining count
/// is the content term count.
///
/// - Parameters:
///   - text: The query string to tokenise.
///   - stopwords: Stopword set. Defaults to the shared fixture set.
/// - Returns: Number of content terms after stopword removal.
func lmebContentTermCount(text: String, stopwords: Set<String> = _lmebStopwordsLoaded) -> Int {
    // Tokenise: split on non-alnum chars. Each non-empty token is a candidate.
    let tokens = text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    return tokens.filter { !stopwords.contains($0) }.count
}

// MARK: - §A1/§A3: Task aggregation (level 2)

/// Computes task-level metrics: mean of subset scores across all subsets (§A1/§A3).
///
/// R_cap@k at task level: mean of non-nil subset R_cap@k values; nil when ALL subsets are nil.
///
/// - Parameter subsets: Subset-level metrics for all six evidence categories.
func lmebSpecTaskMetrics(subsets: [LMEBSpecSubsetMetrics]) -> LMEBSpecTaskMetrics {
    let n = subsets.count

    var ndcg: [Int: Double] = [:]
    var map: [Int: Double] = [:]
    var recall: [Int: Double] = [:]
    var precision: [Int: Double] = [:]
    var mrr: [Int: Double] = [:]
    var rCap: [Int: Double?] = [:]

    for k in lmebSpecKValues {
        if n > 0 {
            ndcg[k]      = subsets.map { $0.ndcg[k]      ?? 0.0 }.reduce(0, +) / Double(n)
            map[k]       = subsets.map { $0.map[k]        ?? 0.0 }.reduce(0, +) / Double(n)
            recall[k]    = subsets.map { $0.recall[k]     ?? 0.0 }.reduce(0, +) / Double(n)
            precision[k] = subsets.map { $0.precision[k]  ?? 0.0 }.reduce(0, +) / Double(n)
            mrr[k]       = subsets.map { $0.mrr[k]        ?? 0.0 }.reduce(0, +) / Double(n)
        } else {
            ndcg[k] = 0.0; map[k] = 0.0; recall[k] = 0.0; precision[k] = 0.0; mrr[k] = 0.0
        }

        // R_cap@k: mean of non-nil subset values; nil when ALL subsets are nil for this k.
        let validRCap: [Double] = subsets.compactMap { s -> Double? in
            guard let opt = s.rCap[k] else { return nil }
            return opt
        }
        if validRCap.isEmpty {
            rCap[k] = Optional<Double>.none
        } else {
            rCap[k] = validRCap.reduce(0.0, +) / Double(validRCap.count)
        }
    }

    return LMEBSpecTaskMetrics(
        subsetCount: n,
        ndcg: ndcg,
        map: map,
        recall: recall,
        precision: precision,
        mrr: mrr,
        rCap: rCap
    )
}
