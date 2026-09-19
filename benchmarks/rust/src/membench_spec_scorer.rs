//! membench_spec_scorer.rs — Pure scoring logic for the membench-spec lane.
//!
//! Rust twin of `MemBenchSpecScorer.swift`. Every function is deterministic and
//! pure (no I/O, no live products) so the conformance vectors at
//! `conformance/membench-spec/scorer_vectors.json` drive both legs identically.
//!
//! Implements §3 (answer correctness + letter parsing), §4 (get_recall metric),
//! aggregation across categories and perspectives, §5 (efficiency stats), and
//! §6 (capacity bucketing) of MEMBENCH_OFFICIAL_PROTOCOL.md, verbatim.
//!
//! §7 row 1: exact-equality correctness per §3.
//! §7 row 3: §4 get_recall verbatim, not the LME ranked-list math.

use crate::longmemeval_scorer::lme_percentile;
use std::collections::HashSet;

// ─────────────────────────────────────────────────────────────────────────────
// §3 Letter parsing
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a response string via the strict path: the JSON schema output is
/// already a single letter A–D (json.loads(res)['choice']).
///
/// Returns the letter unchanged when it is exactly one of "A", "B", "C", "D";
/// `None` otherwise.
///
/// §3: JSON schema `{"choice": enum ["A","B","C","D"]}` (strict).
///
/// Twin of Swift `membenchSpecParseLetterStrict(_:)`.
pub fn membench_spec_parse_letter_strict(response: &str) -> Option<String> {
    match response {
        "A" | "B" | "C" | "D" => Some(response.to_string()),
        _ => None,
    }
}

/// Parses a response string via the fallback normalization path.
/// Applies `s.replace(" ","").replace("\n","")` (§3) before validating.
///
/// Returns the normalized letter when it is exactly one of "A", "B", "C", "D";
/// `None` otherwise.
///
/// §3: fallback path — `s.replace(" ", "").replace("\n", "")`.
///
/// Twin of Swift `membenchSpecParseLetterFallback(_:)`.
pub fn membench_spec_parse_letter_fallback(response: &str) -> Option<String> {
    let normalized = response.replace(' ', "").replace('\n', "");
    match normalized.as_str() {
        "A" | "B" | "C" | "D" => Some(normalized),
        _ => None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3 Answer correctness
// ─────────────────────────────────────────────────────────────────────────────

/// `true` when `response` exactly equals `ground_truth`.
///
/// This is the verbatim §3 correctness predicate:
/// `action['response'] == QA['ground_truth']` — plain string equality,
/// no normalization at this stage (normalization lives in the parse helpers above,
/// which the runner calls before scoring). Reward: 1.0 correct, 0.0 otherwise.
/// Mean across items = accuracy.
///
/// §3: "Correctness: action['response'] == QA['ground_truth'] — exact string equality of the letter."
///
/// Twin of Swift `membenchSpecAnswerCorrect(response:groundTruth:)`.
pub fn membench_spec_answer_correct(response: &str, ground_truth: &str) -> bool {
    response == ground_truth
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 Memory recall metric
// ─────────────────────────────────────────────────────────────────────────────

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
/// - `retrieved_step_ids`: Step IDs parsed from retrieved memory items via
///   `int(stored_text.split('[|]')[0])` (§2 storage prefix). Pass `None` when
///   the recall call returned nothing — corresponding to Python `None`.
/// - `target_step_ids`: The item's evidence step ids, flattened to global sids
///   (element 0 of each `target_step_id` pair per §4 shape note, §1:
///   "the global sid alone uniquely identifies the evidence turn").
///
/// Returns recall ∈ [0, 1]. Returns 0 when `retrieved_step_ids` is `None` or
/// when `target_step_ids` is empty (division by `len(std_set)` — guard against
/// div-by-zero and return 0 rather than NaN/infinity).
///
/// §4: deduplicate retrieved ids; count membership in the ORIGINAL target slice;
/// divide by distinct target count (`len(std_set)`).
///
/// Twin of Swift `membenchSpecGetRecall(retrievedStepIDs:targetStepIDs:)`.
pub fn membench_spec_get_recall(
    retrieved_step_ids: Option<&[i64]>,
    target_step_ids: &[i64],
) -> f64 {
    // §4: "if res == None: return 0"
    let retrieved = match retrieved_step_ids {
        None => return 0.0,
        Some(r) => r,
    };
    // §4: "res = list(set(res))" — deduplicate retrieved ids.
    let deduped: Vec<i64> = {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for &id in retrieved {
            if seen.insert(id) {
                out.push(id);
            }
        }
        out
    };
    // §4: "std_set = set(std)" — distinct target count.
    let std_set: HashSet<i64> = target_step_ids.iter().copied().collect();
    if std_set.is_empty() {
        // len(std_set) == 0 → division by zero in Python.
        // Return 0 as the safe sentinel.
        return 0.0;
    }
    // §4: "for step_id in res: if step_id in std: ct += 1"
    // Python's `in std` checks membership in the original list (semantically
    // equivalent to `in std_set` for presence; using a set here for O(1) lookup).
    let count = deduped
        .iter()
        .filter(|&id| std_set.contains(id))
        .count();
    // §4: "return ct/len(std_set)"
    count as f64 / std_set.len() as f64
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-item scored result
// ─────────────────────────────────────────────────────────────────────────────

/// A single scored item from the membench-spec lane.
/// Carries the §3 correctness flag and §4 recall score for one QA item.
///
/// Twin of Swift `MemBenchSpecItemScore`.
#[derive(Debug, Clone, PartialEq)]
pub struct MemBenchSpecItemScore {
    /// Category label (e.g. "simple", "comparative", "aggregative", "conditional",
    /// "knowledge_update", "post_processing", "noisy", or a HighLevel label).
    pub category: String,
    /// Perspective label: "FirstAgent" (Participation) or "ThirdAgent" (Observation).
    /// §3: the prompts differ between the two agents.
    pub agent: String,
    /// True when the response letter exactly equals the ground truth (§3).
    pub correct: bool,
    /// §4 recall score for this item (∈ [0, 1]).
    pub recall: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-slice aggregate
// ─────────────────────────────────────────────────────────────────────────────

/// Canonical LowLevel category labels in paper order.
/// Mirrors the Swift `membenchSpecCategoryLabels` constant.
/// §7 row 3: membench-spec implements §4 verbatim alongside these categories.
pub const MEMBENCH_SPEC_CATEGORY_LABELS: &[&str] = &[
    "simple",
    "comparative",
    "aggregative",
    "conditional",
    "knowledge_update",
    "post_processing",
    "noisy",
];

/// Aggregate metrics for one category or perspective slice.
///
/// Twin of Swift `MemBenchSpecAggregateSlice`.
#[derive(Debug, Clone, PartialEq)]
pub struct MemBenchSpecAggregateSlice {
    /// Category or perspective label.
    pub label: String,
    /// Number of items contributing to this slice.
    pub count: usize,
    /// Accuracy: mean of `correct` flags over all items in this slice (§3 mean).
    pub accuracy: f64,
    /// Mean §4 recall score over all items in this slice.
    pub mean_recall: f64,
}

/// Full aggregation result: overall, per-category, and per-perspective slices.
///
/// Twin of Swift `MemBenchSpecAggregation`.
#[derive(Debug, Clone)]
pub struct MemBenchSpecAggregation {
    /// Overall aggregate across all items.
    pub overall: MemBenchSpecAggregateSlice,
    /// Per-category breakdown. Canonical LowLevel labels appear first
    /// (in `MEMBENCH_SPEC_CATEGORY_LABELS` order), then any HighLevel/reflective
    /// labels in first-seen order. Only categories present in the input appear.
    pub by_category: Vec<MemBenchSpecAggregateSlice>,
    /// Per-perspective breakdown: agents in the order they first appear in the input.
    pub by_perspective: Vec<MemBenchSpecAggregateSlice>,
}

/// Computes one aggregate slice from a pre-filtered set of item scores.
/// Returns a zero-count slice with zero metrics when `items` is empty.
fn membench_spec_slice(label: &str, items: &[&MemBenchSpecItemScore]) -> MemBenchSpecAggregateSlice {
    if items.is_empty() {
        return MemBenchSpecAggregateSlice {
            label: label.to_string(),
            count: 0,
            accuracy: 0.0,
            mean_recall: 0.0,
        };
    }
    let n = items.len() as f64;
    let accuracy = items.iter().map(|s| if s.correct { 1.0_f64 } else { 0.0 }).sum::<f64>() / n;
    let mean_recall = items.iter().map(|s| s.recall).sum::<f64>() / n;
    MemBenchSpecAggregateSlice {
        label: label.to_string(),
        count: items.len(),
        accuracy,
        mean_recall,
    }
}

/// Aggregates a set of membench-spec item scores across categories and perspectives.
///
/// Category ordering: canonical LowLevel labels first (in `MEMBENCH_SPEC_CATEGORY_LABELS`
/// order), then any additional labels (HighLevel reflective sets) in first-seen order.
/// Only categories with at least one item appear in the output.
///
/// Perspective ordering: agents in the order they first appear in `scores`.
///
/// Twin of Swift `membenchSpecAggregate(_:)`.
pub fn membench_spec_aggregate(scores: &[MemBenchSpecItemScore]) -> MemBenchSpecAggregation {
    // ── Overall ─────────────────────────────────────────────────────────────
    let all_refs: Vec<&MemBenchSpecItemScore> = scores.iter().collect();
    let overall = membench_spec_slice("overall", &all_refs);

    // ── Per-category: canonical order first, then unknown labels ─────────────
    let mut seen_categories: HashSet<&str> = HashSet::new();
    let mut ordered_categories: Vec<&str> = Vec::new();
    // First pass: canonical labels preserve paper ordering.
    for &label in MEMBENCH_SPEC_CATEGORY_LABELS {
        if scores.iter().any(|s| s.category == label) {
            ordered_categories.push(label);
            seen_categories.insert(label);
        }
    }
    // Second pass: HighLevel or unknown labels in first-seen order.
    for score in scores {
        if seen_categories.insert(score.category.as_str()) {
            ordered_categories.push(score.category.as_str());
        }
    }
    let by_category = ordered_categories
        .iter()
        .map(|&label| {
            let items: Vec<&MemBenchSpecItemScore> =
                scores.iter().filter(|s| s.category == label).collect();
            membench_spec_slice(label, &items)
        })
        .collect();

    // ── Per-perspective: agents in first-seen order ──────────────────────────
    let mut seen_agents: HashSet<&str> = HashSet::new();
    let mut ordered_agents: Vec<&str> = Vec::new();
    for score in scores {
        if seen_agents.insert(score.agent.as_str()) {
            ordered_agents.push(score.agent.as_str());
        }
    }
    let by_perspective = ordered_agents
        .iter()
        .map(|&agent| {
            let items: Vec<&MemBenchSpecItemScore> =
                scores.iter().filter(|s| s.agent == agent).collect();
            membench_spec_slice(agent, &items)
        })
        .collect();

    MemBenchSpecAggregation {
        overall,
        by_category,
        by_perspective,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5 Efficiency aggregation
// ─────────────────────────────────────────────────────────────────────────────

/// Statistics over a list of wall-clock duration samples (§5).
/// count / mean / p50 / p95, using the harness's `lme_percentile` convention
/// (nearest-rank, ceil(p × n), matching `RollingSeries.p95` and `lmePercentile`).
///
/// Twin of Swift `MemBenchSpecEfficiencyStats`.
#[derive(Debug, Clone, PartialEq)]
pub struct MemBenchSpecEfficiencyStats {
    /// Number of samples in the list.
    pub count: usize,
    /// Arithmetic mean (seconds).
    pub mean: f64,
    /// 50th-percentile latency (seconds). 0.0 when `count == 0`.
    pub p50: f64,
    /// 95th-percentile latency (seconds). 0.0 when `count == 0`.
    pub p95: f64,
}

/// Computes §5 efficiency stats over a duration list.
///
/// §5: "Per store: wall time around the `memory.store` call (`write_time` list).
/// Per question: wall time around the `memory.recall` call (`read_time` list).
/// `time.perf_counter()` deltas, reported as lists/means per run."
///
/// Percentiles use `lme_percentile` (nearest-rank, ceil(p × n)) matching the
/// existing lane's latency-stats convention.
///
/// Empty input produces all-zero stats.
///
/// Twin of Swift `membenchSpecEfficiencyStats(durations:)`.
pub fn membench_spec_efficiency_stats(durations: &[f64]) -> MemBenchSpecEfficiencyStats {
    if durations.is_empty() {
        return MemBenchSpecEfficiencyStats {
            count: 0,
            mean: 0.0,
            p50: 0.0,
            p95: 0.0,
        };
    }
    let n = durations.len() as f64;
    let mean = durations.iter().sum::<f64>() / n;
    let p50 = lme_percentile(durations, 0.50);
    let p95 = lme_percentile(durations, 0.95);
    MemBenchSpecEfficiencyStats {
        count: durations.len(),
        mean,
        p50,
        p95,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6 Capacity bucketing
// ─────────────────────────────────────────────────────────────────────────────

/// One bucket in the §6 capacity (step_cap) accuracy-vs-token-count analysis.
///
/// Twin of Swift `MemBenchSpecCapacityBucket`.
#[derive(Debug, Clone, PartialEq)]
pub struct MemBenchSpecCapacityBucket {
    /// Inclusive lower bound (token count). 0 for the first bucket.
    pub token_low: i64,
    /// Exclusive upper bound. `None` for the final, open-ended bucket.
    pub token_high: Option<i64>,
    /// Number of samples in this bucket.
    pub count: usize,
    /// Accuracy: fraction of `correct == true` samples. 0.0 when `count == 0`.
    pub accuracy: f64,
}

/// Groups `(tokenCount, correct)` capacity samples into token-count buckets.
///
/// §6: "accuracy as a function of accumulated context tokens".
/// The `step_cap` variant yields one `(token_count_at_ask, correct)` pair per
/// question-ask per item. This function organizes them into buckets for the report.
///
/// Bucket layout: `bucket_boundaries = [1000, 5000]` produces
/// `[0,1000)`, `[1000,5000)`, `[5000,∞)`.
///
/// Buckets with zero samples are included (count=0, accuracy=0.0).
/// Bucket boundaries are a parameter (no hidden constants); the caller chooses
/// the tier-appropriate boundaries from §6 (`data2test`, 0–10k, 100k).
///
/// Result length is always `bucket_boundaries.len() + 1`.
///
/// Twin of Swift `membenchSpecCapacityBuckets(samples:bucketBoundaries:)`.
pub fn membench_spec_capacity_buckets(
    samples: &[(i64, bool)],
    bucket_boundaries: &[i64],
) -> Vec<MemBenchSpecCapacityBucket> {
    // Sort boundaries so the caller need not pre-sort.
    let mut sorted_bounds = bucket_boundaries.to_vec();
    sorted_bounds.sort_unstable();

    // Build (low, high?) ranges.
    let mut ranges: Vec<(i64, Option<i64>)> = Vec::new();
    let mut prev: i64 = 0;
    for &bound in &sorted_bounds {
        ranges.push((prev, Some(bound)));
        prev = bound;
    }
    // Final open-ended bucket.
    ranges.push((prev, None));

    ranges
        .into_iter()
        .map(|(low, high)| {
            let in_bucket: Vec<&(i64, bool)> = samples
                .iter()
                .filter(|(tc, _)| *tc >= low && high.map_or(true, |h| *tc < h))
                .collect();
            let count = in_bucket.len();
            let accuracy = if count == 0 {
                0.0
            } else {
                in_bucket.iter().filter(|(_, c)| *c).count() as f64 / count as f64
            };
            MemBenchSpecCapacityBucket {
                token_low: low,
                token_high: high,
                count,
                accuracy,
            }
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── §3 Letter parsing ────────────────────────────────────────────────────

    #[test]
    fn strict_parse_valid_letters() {
        assert_eq!(membench_spec_parse_letter_strict("A"), Some("A".to_string()));
        assert_eq!(membench_spec_parse_letter_strict("B"), Some("B".to_string()));
        assert_eq!(membench_spec_parse_letter_strict("C"), Some("C".to_string()));
        assert_eq!(membench_spec_parse_letter_strict("D"), Some("D".to_string()));
    }

    #[test]
    fn strict_parse_rejects_invalid() {
        assert_eq!(membench_spec_parse_letter_strict("A "), None);
        assert_eq!(membench_spec_parse_letter_strict("a"), None);
        assert_eq!(membench_spec_parse_letter_strict("E"), None);
        assert_eq!(membench_spec_parse_letter_strict(""), None);
    }

    #[test]
    fn fallback_parse_strips_spaces_and_newlines() {
        // §3: s.replace(" ","").replace("\n","")
        assert_eq!(membench_spec_parse_letter_fallback(" A "), Some("A".to_string()));
        assert_eq!(membench_spec_parse_letter_fallback("A\n"), Some("A".to_string()));
        assert_eq!(membench_spec_parse_letter_fallback("\nB\n"), Some("B".to_string()));
        assert_eq!(membench_spec_parse_letter_fallback("C D"), None); // "CD" not valid
    }

    // ── §3 Answer correctness ────────────────────────────────────────────────

    #[test]
    fn answer_correct_exact_match() {
        assert!(membench_spec_answer_correct("A", "A"));
        assert!(membench_spec_answer_correct("D", "D"));
    }

    #[test]
    fn answer_correct_mismatch() {
        assert!(!membench_spec_answer_correct("A", "B"));
        assert!(!membench_spec_answer_correct("C", "D"));
    }

    // ── §4 get_recall ────────────────────────────────────────────────────────

    #[test]
    fn get_recall_none_returns_zero() {
        // §4: "if res == None: return 0"
        let result = membench_spec_get_recall(None, &[1, 2]);
        assert!((result - 0.0).abs() < 1e-9, "None → 0.0");
    }

    #[test]
    fn get_recall_empty_retrieved_returns_zero() {
        // Empty (non-None) retrieved list → 0/2 = 0.0
        let result = membench_spec_get_recall(Some(&[]), &[1, 2]);
        assert!((result - 0.0).abs() < 1e-9, "empty retrieved → 0.0");
    }

    #[test]
    fn get_recall_duplicates_in_retrieved_deduped() {
        // §4: "res = list(set(res))" → [1,1,2] dedupes to {1,2}, both in std → 2/2 = 1.0
        let result = membench_spec_get_recall(Some(&[1, 1, 2]), &[1, 2]);
        assert!((result - 1.0).abs() < 1e-9, "duplicate retrieved deduped → 1.0");
    }

    #[test]
    fn get_recall_duplicate_targets_counted_once_in_denominator() {
        // §4: "std_set = set(std)" → targets [1,1,2] → std_set={1,2}, len=2.
        // Retrieved [1] → ct=1 → 1/2 = 0.5
        let result = membench_spec_get_recall(Some(&[1]), &[1, 1, 2]);
        assert!((result - 0.5).abs() < 1e-9, "duplicate targets: denominator = distinct count");
    }

    #[test]
    fn get_recall_partial_overlap() {
        // Retrieved [1,3], targets [1,2]. 1 is in targets, 3 is not → ct=1, std_set={1,2} → 0.5
        let result = membench_spec_get_recall(Some(&[1, 3]), &[1, 2]);
        assert!((result - 0.5).abs() < 1e-9, "partial overlap → 0.5");
    }

    #[test]
    fn get_recall_no_overlap() {
        // Retrieved [3,4], targets [1,2] → ct=0 → 0.0
        let result = membench_spec_get_recall(Some(&[3, 4]), &[1, 2]);
        assert!((result - 0.0).abs() < 1e-9, "no overlap → 0.0");
    }

    #[test]
    fn get_recall_full_overlap_single_target() {
        // Retrieved [5], target [5] → 1/1 = 1.0
        let result = membench_spec_get_recall(Some(&[5]), &[5]);
        assert!((result - 1.0).abs() < 1e-9, "full overlap single target → 1.0");
    }

    // ── Aggregation ─────────────────────────────────────────────────────────

    #[test]
    fn aggregate_overall_accuracy_and_recall() {
        let scores = vec![
            MemBenchSpecItemScore { category: "simple".to_string(), agent: "FirstAgent".to_string(), correct: true,  recall: 1.0 },
            MemBenchSpecItemScore { category: "simple".to_string(), agent: "FirstAgent".to_string(), correct: true,  recall: 1.0 },
            MemBenchSpecItemScore { category: "noisy".to_string(),  agent: "FirstAgent".to_string(), correct: false, recall: 0.5 },
        ];
        let agg = membench_spec_aggregate(&scores);
        // overall: 3 items, 2 correct → accuracy = 2/3; recall = (1+1+0.5)/3 = 5/6
        assert_eq!(agg.overall.count, 3);
        assert!((agg.overall.accuracy - 2.0 / 3.0).abs() < 1e-9, "overall accuracy");
        assert!((agg.overall.mean_recall - 5.0 / 6.0).abs() < 1e-9, "overall recall");
    }

    #[test]
    fn aggregate_category_order_canonical_first() {
        // "noisy" input before "simple" — canonical order must be preserved.
        let scores = vec![
            MemBenchSpecItemScore { category: "noisy".to_string(),  agent: "FirstAgent".to_string(), correct: true, recall: 1.0 },
            MemBenchSpecItemScore { category: "simple".to_string(), agent: "FirstAgent".to_string(), correct: true, recall: 1.0 },
        ];
        let agg = membench_spec_aggregate(&scores);
        let labels: Vec<&str> = agg.by_category.iter().map(|s| s.label.as_str()).collect();
        let simple_idx = labels.iter().position(|&l| l == "simple").unwrap();
        let noisy_idx  = labels.iter().position(|&l| l == "noisy").unwrap();
        assert!(simple_idx < noisy_idx, "simple must precede noisy in canonical order");
    }

    #[test]
    fn aggregate_empty_input() {
        let agg = membench_spec_aggregate(&[]);
        assert_eq!(agg.overall.count, 0);
        assert!((agg.overall.accuracy - 0.0).abs() < 1e-9);
        assert!(agg.by_category.is_empty());
        assert!(agg.by_perspective.is_empty());
    }

    // ── §5 Efficiency stats ──────────────────────────────────────────────────

    #[test]
    fn efficiency_stats_empty() {
        let stats = membench_spec_efficiency_stats(&[]);
        assert_eq!(stats.count, 0);
        assert!((stats.mean - 0.0).abs() < 1e-9);
        assert!((stats.p50 - 0.0).abs() < 1e-9);
        assert!((stats.p95 - 0.0).abs() < 1e-9);
    }

    #[test]
    fn efficiency_stats_single() {
        let stats = membench_spec_efficiency_stats(&[0.1]);
        assert_eq!(stats.count, 1);
        assert!((stats.mean - 0.1).abs() < 1e-9);
        assert!((stats.p50 - 0.1).abs() < 1e-9);
        assert!((stats.p95 - 0.1).abs() < 1e-9);
    }

    #[test]
    fn efficiency_stats_five_values() {
        // Values [0.1, 0.2, 0.3, 0.4, 0.5].
        // mean = 0.3
        // lme_percentile at 0.50: rank = ceil(0.5 * 5) = 3, index 2 → 0.3
        // lme_percentile at 0.95: rank = ceil(0.95 * 5) = 5, index 4 → 0.5
        let stats = membench_spec_efficiency_stats(&[0.1, 0.2, 0.3, 0.4, 0.5]);
        assert_eq!(stats.count, 5);
        assert!((stats.mean - 0.3).abs() < 1e-9, "mean {}", stats.mean);
        assert!((stats.p50 - 0.3).abs() < 1e-9, "p50 {}", stats.p50);
        assert!((stats.p95 - 0.5).abs() < 1e-9, "p95 {}", stats.p95);
    }

    // ── §6 Capacity bucketing ────────────────────────────────────────────────

    #[test]
    fn capacity_buckets_empty_samples() {
        let buckets = membench_spec_capacity_buckets(&[], &[1000, 5000]);
        assert_eq!(buckets.len(), 3, "always boundaries+1 buckets");
        assert!(buckets.iter().all(|b| b.count == 0), "zero samples → all counts 0");
        assert!(buckets.iter().all(|b| (b.accuracy - 0.0).abs() < 1e-9));
    }

    #[test]
    fn capacity_buckets_ranges() {
        // Boundaries [1000, 5000] → [0,1000), [1000,5000), [5000,∞)
        let samples = vec![(500, true), (1500, false), (6000, true)];
        let buckets = membench_spec_capacity_buckets(&samples, &[1000, 5000]);
        assert_eq!(buckets.len(), 3);
        assert_eq!(buckets[0].token_low, 0);
        assert_eq!(buckets[0].token_high, Some(1000));
        assert_eq!(buckets[0].count, 1);
        assert!((buckets[0].accuracy - 1.0).abs() < 1e-9, "bucket[0] has 1 correct");
        assert_eq!(buckets[1].count, 1);
        assert!((buckets[1].accuracy - 0.0).abs() < 1e-9, "bucket[1] has 1 incorrect");
        assert_eq!(buckets[2].count, 1);
        assert_eq!(buckets[2].token_high, None, "last bucket open-ended");
    }

    #[test]
    fn capacity_buckets_no_boundaries() {
        // Zero boundaries → one open-ended bucket covering everything.
        let samples = vec![(100, true), (9999, false)];
        let buckets = membench_spec_capacity_buckets(&samples, &[]);
        assert_eq!(buckets.len(), 1);
        assert_eq!(buckets[0].token_low, 0);
        assert_eq!(buckets[0].token_high, None);
        assert_eq!(buckets[0].count, 2);
        assert!((buckets[0].accuracy - 0.5).abs() < 1e-9);
    }
}
