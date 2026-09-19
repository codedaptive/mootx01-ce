import Foundation

// MemBenchSpecScorer.swift — Pure scoring logic for the membench-spec lane.
//
// Implements §3 (answer correctness + letter parsing), §4 (get_recall metric),
// aggregation across categories and perspectives, §5 (efficiency stats), and
// §6 (capacity bucketing) of MEMBENCH_OFFICIAL_PROTOCOL.md, verbatim.
//
// This file is purely functional: no I/O, no live products, no Date() calls.
// All external state arrives as parameters. Conformance vectors are at
// conformance/membench-spec/scorer_vectors.json; both ports must agree to 1e-9.
//
// §7 row 1: the correctness check here is exact string equality per §3 —
// the answering model provides a single letter; this scorer measures it.
// §7 row 3: the recall metric is §4 get_recall verbatim, not the LME ranked-list math.

// MARK: - §3 Letter parsing

/// Parses a response string via the strict path: the JSON schema output is already
/// a single letter A–D (json.loads(res)['choice']).
///
/// - Parameter response: The string returned by the answering model after strict JSON parse.
/// - Returns: The letter unchanged when it is exactly one of "A", "B", "C", "D"; nil otherwise.
///
/// §3: JSON schema {"choice": enum ["A","B","C","D"]} (strict).
func membenchSpecParseLetterStrict(_ response: String) -> String? {
    let valid: Set<String> = ["A", "B", "C", "D"]
    return valid.contains(response) ? response : nil
}

/// Parses a response string via the fallback normalization path.
/// Applies `s.replace(" ","").replace("\n","")` (§3) before validating.
///
/// - Parameter response: Raw response string from the model when JSON parse failed.
/// - Returns: The normalized letter when it is exactly one of "A", "B", "C", "D"; nil otherwise.
///
/// §3: fallback path — `s.replace(" ", "").replace("\n", "")`.
func membenchSpecParseLetterFallback(_ response: String) -> String? {
    let normalized = response
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "\n", with: "")
    let valid: Set<String> = ["A", "B", "C", "D"]
    return valid.contains(normalized) ? normalized : nil
}

// MARK: - §3 Answer correctness

/// True when the response letter exactly equals the ground truth letter.
///
/// This is the verbatim §3 correctness predicate:
/// `action['response'] == QA['ground_truth']` — plain string equality,
/// no normalization applied at this stage (normalization lives in the
/// letter-parse helpers above, which the runner calls before scoring).
/// Reward: 1.0 when correct, 0.0 otherwise. Mean across items = accuracy.
///
/// - Parameters:
///   - response: The letter the answering model produced ("A", "B", "C", or "D").
///   - groundTruth: The correct letter from the QA record ("A", "B", "C", or "D").
/// - Returns: True when `response == groundTruth`.
///
/// §3: "Correctness: action['response'] == QA['ground_truth'] — exact string equality of the letter."
func membenchSpecAnswerCorrect(response: String, groundTruth: String) -> Bool {
    return response == groundTruth
}

// MARK: - §4 Memory recall metric

/// Computes the §4 `get_recall` metric verbatim.
///
/// Python source (MEMBENCH_OFFICIAL_PROTOCOL.md §4):
/// ```python
/// def get_recall(res, std):
///     if res == None:
///         return 0
///     res = list(set(res))
///     std_set = set(std)
///     ct = 0
///     for step_id in res:
///         if step_id in std:
///             ct += 1
///     return ct/len(std_set)
/// ```
///
/// - Parameters:
///   - retrievedStepIDs: Step IDs parsed from the memory system's retrieved items via
///     `int(stored_text.split('[|]')[0])` (§2 storage prefix). Pass `nil` when the
///     recall call returned nothing — corresponding to Python `None`.
///   - targetStepIDs: The item's evidence step ids, flattened to global sids.
///     The runner extracts element 0 from each `target_step_id` pair (§4 shape note,
///     §1: "the global sid alone uniquely identifies the evidence turn").
/// - Returns: Recall score ∈ [0, 1]. Returns 0 when `retrievedStepIDs` is nil or
///   when `targetStepIDs` is empty (division by `len(std_set)` — we guard against
///   div-by-zero and return 0 rather than NaN/infinity).
///
/// §4: deduplicate retrieved ids (`res = list(set(res))`); count membership
/// in the ORIGINAL target list; divide by distinct target count (`len(std_set)`).
func membenchSpecGetRecall(retrievedStepIDs: [Int]?, targetStepIDs: [Int]) -> Double {
    // §4: "if res == None: return 0"
    guard let retrieved = retrievedStepIDs else { return 0.0 }
    // §4: "res = list(set(res))" — deduplicate retrieved ids.
    let deduped = Array(Set(retrieved))
    // §4: "std_set = set(std)" — distinct target count is len(std_set).
    let stdSet = Set(targetStepIDs)
    guard !stdSet.isEmpty else {
        // Empty target set: len(std_set) == 0 → division by zero in Python.
        // Return 0 as the safe sentinel (nothing to recall means 0 recall).
        return 0.0
    }
    // §4: "for step_id in res: if step_id in std: ct += 1"
    // "step_id in std" checks membership in the original list (equivalent to std_set
    // for presence checks, which is what Python's `in` operator does on both).
    var count = 0
    for stepID in deduped {
        if targetStepIDs.contains(stepID) {
            count += 1
        }
    }
    // §4: "return ct/len(std_set)"
    return Double(count) / Double(stdSet.count)
}

// MARK: - Per-item scored result

/// A single scored item from the membench-spec lane.
/// Carries the §3 correctness flag and §4 recall score for one QA item.
/// Pure value type; no references to runners, corpora, or I/O.
struct MemBenchSpecItemScore: Sendable, Equatable {
    /// Category label (e.g. "simple", "comparative", "aggregative", "conditional",
    /// "knowledge_update", "post_processing", "noisy", or a HighLevel label).
    let category: String
    /// Perspective label from which this item was observed:
    /// "FirstAgent" (Participation) or "ThirdAgent" (Observation).
    /// §3: the prompts differ between the two agents.
    let agent: String
    /// True when the response letter exactly equals the ground truth (§3).
    let correct: Bool
    /// §4 recall score for this item (∈ [0, 1]).
    let recall: Double
}

// MARK: - Per-slice aggregate

/// Canonical LowLevel category labels in paper order.
/// Mirrors `memBenchCategoryLabels` from the existing lane for optimizer compatibility.
/// §7 row 3: membench-spec implements §4 verbatim alongside these categories.
let membenchSpecCategoryLabels: [String] = [
    "simple",
    "comparative",
    "aggregative",
    "conditional",
    "knowledge_update",
    "post_processing",
    "noisy",
]

/// Aggregate metrics for one category or perspective slice.
struct MemBenchSpecAggregateSlice: Sendable, Equatable {
    /// Category or perspective label.
    let label: String
    /// Number of items contributing to this slice.
    let count: Int
    /// Accuracy: mean of `correct` flags over all items in this slice (§3 mean).
    let accuracy: Double
    /// Mean §4 recall score over all items in this slice.
    let meanRecall: Double
}

/// Full aggregation result: overall, per-category, and per-perspective slices.
struct MemBenchSpecAggregation: Sendable {
    /// Overall aggregate across all items.
    let overall: MemBenchSpecAggregateSlice
    /// Per-category breakdown. Canonical LowLevel categories appear first
    /// (in `membenchSpecCategoryLabels` order), then any HighLevel/reflective
    /// labels in first-seen order. Only categories present in `scores` appear.
    let byCategory: [MemBenchSpecAggregateSlice]
    /// Per-perspective breakdown: "FirstAgent" and/or "ThirdAgent",
    /// in first-seen order across the input.
    let byPerspective: [MemBenchSpecAggregateSlice]
}

/// Computes one aggregate slice from a homogeneous set of item scores.
/// Returns a zero-count slice with zero metrics when `items` is empty.
///
/// - Parameters:
///   - label: The category or perspective label for this slice.
///   - items: Items belonging to this slice (pre-filtered by the caller).
/// - Returns: Count, accuracy, and mean recall for the slice.
private func membenchSpecSlice(label: String, items: [MemBenchSpecItemScore]) -> MemBenchSpecAggregateSlice {
    guard !items.isEmpty else {
        return MemBenchSpecAggregateSlice(label: label, count: 0, accuracy: 0.0, meanRecall: 0.0)
    }
    let n = Double(items.count)
    let accuracy = items.map { $0.correct ? 1.0 : 0.0 }.reduce(0.0, +) / n
    let meanRecall = items.map(\.recall).reduce(0.0, +) / n
    return MemBenchSpecAggregateSlice(label: label, count: items.count, accuracy: accuracy, meanRecall: meanRecall)
}

/// Aggregates a set of membench-spec item scores across categories and perspectives.
///
/// Category ordering: canonical LowLevel labels first (in `membenchSpecCategoryLabels` order),
/// then any additional labels (HighLevel reflective sets) in the order they first appear
/// in `scores`. Only categories that have at least one item appear in the output.
///
/// Perspective ordering: agents in the order they first appear in `scores`.
///
/// - Parameter scores: All scored items for the run (or any coherent subset).
/// - Returns: Overall, per-category, and per-perspective aggregates.
func membenchSpecAggregate(_ scores: [MemBenchSpecItemScore]) -> MemBenchSpecAggregation {
    // ── Overall ─────────────────────────────────────────────────────────────
    let overall = membenchSpecSlice(label: "overall", items: scores)

    // ── Per-category: canonical order first, then unknown labels in appearance order ──
    var seenCategories = Set<String>()
    var orderedCategories: [String] = []
    // First pass: canonical labels (preserves paper ordering).
    for label in membenchSpecCategoryLabels {
        if scores.contains(where: { $0.category == label }) {
            orderedCategories.append(label)
            seenCategories.insert(label)
        }
    }
    // Second pass: HighLevel or unknown labels in first-seen order.
    for score in scores {
        if seenCategories.insert(score.category).inserted {
            orderedCategories.append(score.category)
        }
    }
    let byCategory = orderedCategories.map { label in
        membenchSpecSlice(label: label, items: scores.filter { $0.category == label })
    }

    // ── Per-perspective: agents in first-seen order ──────────────────────────
    var seenAgents = Set<String>()
    var orderedAgents: [String] = []
    for score in scores {
        if seenAgents.insert(score.agent).inserted {
            orderedAgents.append(score.agent)
        }
    }
    let byPerspective = orderedAgents.map { agent in
        membenchSpecSlice(label: agent, items: scores.filter { $0.agent == agent })
    }

    return MemBenchSpecAggregation(overall: overall, byCategory: byCategory, byPerspective: byPerspective)
}

// MARK: - §5 Efficiency aggregation

/// Statistics over a list of wall-clock duration samples (§5).
/// count / mean / p50 / p95, using the harness's `lmePercentile` convention
/// (nearest-rank, ceil(p × n), matching `RollingSeries.p95` and `lmePercentile`).
struct MemBenchSpecEfficiencyStats: Sendable, Equatable {
    /// Number of samples in the list.
    let count: Int
    /// Arithmetic mean (seconds).
    let mean: Double
    /// 50th-percentile latency (seconds). 0 when `count == 0`.
    let p50: Double
    /// 95th-percentile latency (seconds). 0 when `count == 0`.
    let p95: Double
}

/// Computes §5 efficiency stats over a duration list.
///
/// §5: "Per store: wall time around the `memory.store` call (`write_time` list).
/// Per question: wall time around the `memory.recall` call (`read_time` list).
/// `time.perf_counter()` deltas, reported as lists/means per run."
///
/// Percentiles use `lmePercentile` (nearest-rank, ceil(p × n)) so this surface
/// and the existing lane's latency stats are on the same scale.
///
/// - Parameter durations: Wall-clock durations in seconds (one per store or per recall).
///   Empty input produces all-zero stats.
/// - Returns: `MemBenchSpecEfficiencyStats` with count, mean, p50, and p95.
func membenchSpecEfficiencyStats(durations: [Double]) -> MemBenchSpecEfficiencyStats {
    guard !durations.isEmpty else {
        return MemBenchSpecEfficiencyStats(count: 0, mean: 0.0, p50: 0.0, p95: 0.0)
    }
    let n = Double(durations.count)
    let mean = durations.reduce(0.0, +) / n
    // lmePercentile is defined in LongMemEvalScorer.swift (same module).
    let p50 = lmePercentile(durations, 0.50)
    let p95 = lmePercentile(durations, 0.95)
    return MemBenchSpecEfficiencyStats(count: durations.count, mean: mean, p50: p50, p95: p95)
}

// MARK: - §6 Capacity bucketing

/// One bucket in the §6 capacity (step_cap) accuracy-vs-token-count analysis.
/// Records accuracy over the `(tokenCount, correct)` samples that fall in this range.
struct MemBenchSpecCapacityBucket: Sendable, Equatable {
    /// Inclusive lower bound (token count). 0 for the first bucket.
    let tokenLow: Int
    /// Exclusive upper bound. `nil` for the final, open-ended bucket.
    let tokenHigh: Int?
    /// Number of samples in this bucket.
    let count: Int
    /// Accuracy: fraction of `correct == true` samples in this bucket.
    /// 0.0 when `count == 0`.
    let accuracy: Double
}

/// Groups `(tokenCount, correct)` capacity samples into token-count buckets.
///
/// §6: "accuracy as a function of accumulated context tokens".
/// The `step_cap` variant yields one `(token_count_at_ask, correct)` pair per
/// question-ask per item. This function organizes them into buckets for the report.
///
/// Bucket layout example — `bucketBoundaries: [1000, 5000, 20000]` produces:
/// - `[0,  1000)` — early turns, short context
/// - `[1000, 5000)` — mid context
/// - `[5000, 20000)` — long context
/// - `[20000, ∞)` — very long context (open-ended)
///
/// Buckets with zero samples are included (count=0, accuracy=0.0) so the caller
/// always gets a fixed-length table regardless of which ranges have data.
///
/// Bucket boundaries are a parameter, not hardcoded: the exact capacity tiers
/// (`data2test`, 0–10k, 100k) are caller-chosen constants per §6.
///
/// - Parameters:
///   - samples: `(tokenCount, correct)` pairs from the step_cap runner.
///   - bucketBoundaries: Ascending token-count boundary values defining bucket edges.
///     Must be non-empty. Unsorted input is sorted internally.
/// - Returns: One `MemBenchSpecCapacityBucket` per boundary interval, including the
///   open-ended last bucket. Count equals `bucketBoundaries.count + 1`.
func membenchSpecCapacityBuckets(
    samples: [(tokenCount: Int, correct: Bool)],
    bucketBoundaries: [Int]
) -> [MemBenchSpecCapacityBucket] {
    // Build (low, high?) ranges from the sorted boundaries.
    // E.g. boundaries [1000, 5000] → [(0,1000), (1000,5000), (5000,nil)].
    let sorted = bucketBoundaries.sorted()
    var ranges: [(low: Int, high: Int?)] = []
    var prev = 0
    for bound in sorted {
        ranges.append((low: prev, high: bound))
        prev = bound
    }
    // Final open-ended bucket.
    ranges.append((low: prev, high: nil))

    return ranges.map { range in
        let inBucket = samples.filter { s in
            s.tokenCount >= range.low &&
            (range.high == nil || s.tokenCount < range.high!)
        }
        let count = inBucket.count
        let accuracy: Double
        if count == 0 {
            accuracy = 0.0
        } else {
            accuracy = inBucket.map { $0.correct ? 1.0 : 0.0 }.reduce(0.0, +) / Double(count)
        }
        return MemBenchSpecCapacityBucket(
            tokenLow: range.low,
            tokenHigh: range.high,
            count: count,
            accuracy: accuracy
        )
    }
}
