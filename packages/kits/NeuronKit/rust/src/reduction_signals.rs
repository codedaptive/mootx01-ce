//! The composable precise-reduction signal components — the building blocks of
//! the reduction ablation harness. Rust port of
//! `NeuronKit/Sources/NeuronKit/Reduction/ReductionSignals.swift`.
//!
//! Each signal is a PURE, DETERMINISTIC per-candidate scorer in `[0, 1]` over
//! (query, candidate). A candidate carries the dense recall signal (the Step-2
//! `RecallScoreVector`: integer Hamming distance, per-lane bm25/vector/
//! coOccurrence/dense, the lattice anchor) plus the hydrated content.
//!
//! Determinism: no clock, no RNG, no locale-sensitive transform beyond
//! `to_lowercase()` (ASCII-folded, matching the Swift port). Every signal is a
//! total function of its inputs.

use std::collections::BTreeSet;

use genius_locus_kit::recall::{RecallHit, RecallScoreVector};
use locus_kit::adjectives::State;

use crate::query_precision::{distinctive_tokens, query_precision, word_tokens, DEFAULT_DISTINCTIVE_BONUS};

/// One candidate handed to the reduction signals: the dense recall signal
/// (`score`) plus the hydrated content and the lattice anchor. Built from a GLK
/// `RecallHit` by `from_hit`. The `coarse_rank` is the candidate's 0-based
/// position in the coarse-grab pool — the deterministic tie-break basis.
///
/// Mirrors Swift `NeuronKit.ReductionCandidate`.
#[derive(Debug, Clone)]
pub struct ReductionCandidate {
    /// The drawer's stable row id.
    pub id: String,
    /// The drawer's content (empty when the hit was not hydrated).
    pub content: String,
    /// The drawer's room (echoed for serialization parity).
    pub room: String,
    /// The dense per-lane recall signal carried from GLK (Step 2).
    pub score: RecallScoreVector,
    /// The candidate's UDC lattice code (`""` when unanchored).
    pub udc_code: String,
    /// The candidate's optional UDC facet expression.
    pub udc_facets: Option<String>,
    /// The candidate's 0-based rank in the coarse-grab pool. The deterministic
    /// tie-break key for the bounded reduce.
    pub coarse_rank: usize,
    /// The candidate's event time (epoch seconds), or `None` when the hit
    /// carried no structured drawer. Read body-free.
    pub event_time: Option<i64>,
    /// Whether the candidate is in a currently-believed state (drawer state
    /// Cluster A). Read body-free from the adjective state bitmap.
    pub is_currently_believed: bool,
    /// The composition precision score stamped during the weighted-sum fold
    /// (`reduce` / `reduce_late`). Callers (e.g. `precise_recall`) should
    /// surface this as `PreciseMatch.score` so discrimination classification
    /// operates on the re-rank signal, not the coarse fusion score.
    /// Defaults to 0.0 when a candidate has not been scored by a composition.
    /// Mirrors Swift `ReductionCandidate.precisionScore`.
    pub precision_score: f64,
}

impl ReductionCandidate {
    /// Build a reduction candidate from a GLK recall hit at coarse-pool
    /// position `coarse_rank`. An unhydrated hit (no drawer) yields empty
    /// content and an unanchored lattice. The temporal fields come from the
    /// drawer's body-free columns. Mirrors Swift `ReductionCandidate.from(hit:coarseRank:)`.
    pub fn from_hit(hit: &RecallHit, coarse_rank: usize) -> Self {
        // Bits 0–5 of the adjective bitmap hold the state axis (cookbook §2.3).
        // Decode to a State and ask the Cluster-A predicate — the same
        // body-free currency read the Swift port does via `drawer.state.isClusterA`.
        let (content, room, udc_code, udc_facets, event_time, is_currently_believed) =
            match &hit.drawer {
                Some(d) => {
                    let state = State::from_raw(d.adjective_bitmap & 0x3F);
                    (
                        d.content.clone(),
                        d.room.clone(),
                        d.udc_code.clone(),
                        d.udc_facets.clone(),
                        Some(d.event_time),
                        state.is_cluster_a(),
                    )
                }
                None => (String::new(), String::new(), String::new(), None, None, true),
            };
        ReductionCandidate {
            id: hit.id.clone(),
            content,
            room,
            score: hit.score,
            udc_code,
            udc_facets,
            coarse_rank,
            event_time,
            is_currently_believed,
            // precision_score is populated by the composition fold; zero here
            // because from_hit builds pre-fold candidates.
            precision_score: 0.0,
        }
    }
}

/// The query side a signal scores against: the raw query text plus its optional
/// lattice anchor. Mirrors Swift `NeuronKit.ReductionQuery`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReductionQuery {
    /// The raw query text.
    pub text: String,
    /// The query's UDC lattice code, or `""` when unanchored.
    pub udc_code: String,
}

impl ReductionQuery {
    /// Build a query context; `udc_code` defaults to unanchored.
    pub fn new(text: impl Into<String>) -> Self {
        ReductionQuery {
            text: text.into(),
            udc_code: String::new(),
        }
    }
}

/// A named precise-reduction signal component. Each variant is a pure
/// per-candidate scorer in `[0, 1]`; `mmr` and `assembly` are set-level and
/// handled by the composition fold, not by `reduction_score`.
///
/// Mirrors Swift `NeuronKit.ReductionSignal`. The raw string forms are the
/// serialization-stable signal names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReductionSignal {
    /// Content-word match (`query_precision`).
    Text,
    /// Vector closeness from integer Hamming distance: `(256 - distance) / 256`.
    Hamming,
    /// Matrix co-occurrence signal carried from GLK (`score.co_occurrence`).
    Matrix,
    /// Lattice proximity of candidate UDC code to query UDC region.
    Lattice,
    /// Raw BM25 lane score, squashed into `[0, 1]`.
    Bm25,
    /// Raw vector lane similarity (already normalized in `[0, 1]`).
    Vector,
    /// DENSE FLOAT cosine similarity from GLK (`score.dense`), already in `[0, 1]`.
    Dense,
    /// Exact distinctive-token / numeric match rate.
    TokenExact,
    /// Temporal currency from STRUCTURE (Cluster A → 1.0, else 0.0). Body-free.
    TemporalState,
    /// Temporal currency from CONTENT markers. Needs body.
    TemporalText,
    /// Split-fact assembly (set-level expansion). Needs body.
    Assembly,
    /// Diversity re-rank (MMR, set-level).
    Mmr,
}

impl ReductionSignal {
    /// The serialization-stable signal name, identical to the Swift raw value.
    pub fn name(self) -> &'static str {
        match self {
            ReductionSignal::Text => "text",
            ReductionSignal::Hamming => "hamming",
            ReductionSignal::Matrix => "matrix",
            ReductionSignal::Lattice => "lattice",
            ReductionSignal::Bm25 => "bm25",
            ReductionSignal::Vector => "vector",
            ReductionSignal::Dense => "dense",
            ReductionSignal::TokenExact => "tokenExact",
            ReductionSignal::TemporalState => "temporalState",
            ReductionSignal::TemporalText => "temporalText",
            ReductionSignal::Assembly => "assembly",
            ReductionSignal::Mmr => "mmr",
        }
    }

    /// True when this signal is a set-level re-rank/expansion (`mmr`,
    /// `assembly`) rather than a pure per-candidate scorer.
    pub fn is_set_level(self) -> bool {
        matches!(self, ReductionSignal::Mmr | ReductionSignal::Assembly)
    }

    /// True when this signal reads the candidate's TEXT CONTENT (the body):
    /// `text`, `tokenExact`, `mmr`, `temporalText`, `assembly`. The dense lanes
    /// (`hamming`/`matrix`/`lattice`/`bm25`/`vector`/`dense`/`temporalState`)
    /// score body-free. Mirrors Swift `ReductionSignal.needsContent`.
    pub fn needs_content(self) -> bool {
        match self {
            ReductionSignal::Text
            | ReductionSignal::TokenExact
            | ReductionSignal::Mmr
            | ReductionSignal::TemporalText
            | ReductionSignal::Assembly => true,
            ReductionSignal::Hamming
            | ReductionSignal::Matrix
            | ReductionSignal::Lattice
            | ReductionSignal::Bm25
            | ReductionSignal::Vector
            | ReductionSignal::Dense
            | ReductionSignal::TemporalState => false,
        }
    }
}

/// Score `candidate` under `signal` against `query`, in `[0, 1]`. For the
/// set-level signals (`mmr`, `assembly`) this returns the neutral 0.5 (they are
/// applied by the composition fold). Mirrors Swift `NeuronKit.reductionScore`.
pub fn reduction_score(
    signal: ReductionSignal,
    query: &ReductionQuery,
    candidate: &ReductionCandidate,
) -> f64 {
    match signal {
        ReductionSignal::Text => {
            query_precision(&query.text, &candidate.content, DEFAULT_DISTINCTIVE_BONUS) as f64
        }
        ReductionSignal::Hamming => hamming_similarity(candidate.score.hamming_distance()),
        ReductionSignal::Matrix => clamp01(candidate.score.co_occurrence as f64),
        ReductionSignal::Lattice => lattice_proximity(&query.udc_code, &candidate.udc_code),
        ReductionSignal::Bm25 => squash(candidate.score.bm25 as f64),
        ReductionSignal::Vector => clamp01(candidate.score.vector as f64),
        ReductionSignal::Dense => clamp01(candidate.score.dense as f64),
        ReductionSignal::TokenExact => token_exact_rate(&query.text, &candidate.content),
        ReductionSignal::TemporalState => {
            if candidate.is_currently_believed {
                1.0
            } else {
                0.0
            }
        }
        ReductionSignal::TemporalText => temporal_text_score(&candidate.content),
        ReductionSignal::Mmr | ReductionSignal::Assembly => 0.5,
    }
}

/// Vector closeness from an integer Hamming distance in `0..=256`:
/// `(256 - distance) / 256`. The `noHammingDistance` sentinel (< 0) → 0.
/// Mirrors Swift `hammingSimilarity`.
pub fn hamming_similarity(distance: i32) -> f64 {
    if distance < 0 {
        return 0.0; // sentinel → 0
    }
    let d = distance.min(256);
    (256 - d) as f64 / 256.0
}

/// Lattice proximity of a candidate UDC code to the query's UDC region, in
/// `[0, 1]`: the shared leading-prefix length over the longer of the two codes.
/// Unanchored query → neutral 0.5; anchored query, unanchored candidate → 0.
/// Mirrors Swift `latticeProximity`.
pub fn lattice_proximity(query_code: &str, candidate_code: &str) -> f64 {
    if query_code.is_empty() {
        return 0.5; // unanchored query → neutral
    }
    if candidate_code.is_empty() {
        return 0.0; // anchored query, unanchored candidate → far
    }
    if query_code == candidate_code {
        return 1.0;
    }
    let q: Vec<char> = query_code.chars().collect();
    let c: Vec<char> = candidate_code.chars().collect();
    let mut shared = 0usize;
    let bound = q.len().min(c.len());
    while shared < bound && q[shared] == c[shared] {
        shared += 1;
    }
    let longer = q.len().max(c.len());
    if longer == 0 {
        return 0.0;
    }
    shared as f64 / longer as f64
}

/// Monotonic squash of a non-negative raw score into `[0, 1)`: `x / (1 + x)`.
/// Negative inputs clamp to 0. Mirrors Swift `squash`.
pub fn squash(x: f64) -> f64 {
    if x <= 0.0 {
        return 0.0;
    }
    x / (1.0 + x)
}

/// Clamp a value into `[0, 1]`.
pub fn clamp01(x: f64) -> f64 {
    x.clamp(0.0, 1.0)
}

/// Content-marker temporal currency in `[0, 1]`. A stale marker dominates → 0.0;
/// an explicit current marker → 1.0; otherwise neutral 0.5. Case-folded
/// substring checks. Mirrors Swift `temporalTextScore`.
pub fn temporal_text_score(content: &str) -> f64 {
    if content.is_empty() {
        return 0.5;
    }
    let c = content.to_lowercase();
    // Stale markers dominate: a record that announces it is superseded is stale
    // even if it also contains the word "current" in passing.
    let stale_markers = [
        "superseded", "deprecated", "obsolete", "no longer", "formerly", "outdated",
    ];
    for m in stale_markers {
        if c.contains(m) {
            return 0.0;
        }
    }
    let current_markers = ["current as of", "current ", "as of ", "presently", "now in effect"];
    for m in current_markers {
        if c.contains(m) {
            return 1.0;
        }
    }
    0.5
}

/// Exact distinctive-token match rate: of the query's distinctive tokens, the
/// fraction present verbatim in the candidate's token set. 0 when the query
/// names no distinctive token, or either side is empty. Mirrors Swift
/// `tokenExactRate`.
pub fn token_exact_rate(query: &str, candidate: &str) -> f64 {
    let distinctive = distinctive_tokens(query);
    if distinctive.is_empty() {
        return 0.0;
    }
    let candidate_tokens: BTreeSet<String> = word_tokens(candidate).into_iter().collect();
    if candidate_tokens.is_empty() {
        return 0.0;
    }
    let matched = distinctive
        .iter()
        .filter(|t| candidate_tokens.contains(*t))
        .count();
    matched as f64 / distinctive.len() as f64
}

/// Extract reference codes of the form `REF-NNNN` (case-insensitive `ref`
/// prefix, a hyphen, then digits) from `content`. The split-fact join key.
/// Pure and deterministic; ASCII-only, matching the Swift port. Mirrors Swift
/// `referenceCodes(in:)`.
pub fn reference_codes(content: &str) -> BTreeSet<String> {
    let mut codes = BTreeSet::new();
    if content.is_empty() {
        return codes;
    }
    let lower = content.to_lowercase();
    // Token scan: split on non-alphanumeric-and-non-hyphen, keep ref-<digits>.
    for token in lower.split(|c: char| !c.is_alphanumeric() && c != '-') {
        if let Some(suffix) = token.strip_prefix("ref-") {
            if !suffix.is_empty() && suffix.chars().all(|c| c.is_numeric()) {
                codes.insert(token.to_string());
            }
        }
    }
    codes
}

/// The `hamming_distance` accessor on `RecallScoreVector`. The GLK vector lane
/// stores its score as `(256 - distance) / 256`, so the integer distance is
/// `256 - round(vector * 256)`; a hit with no vector contribution (vector == 0)
/// is the sentinel (distance 256 → similarity 0). This mirrors the Swift
/// `RecallScoreVector.hammingDistance` derived accessor.
trait HammingDistance {
    fn hamming_distance(&self) -> i32;
}

impl HammingDistance for RecallScoreVector {
    fn hamming_distance(&self) -> i32 {
        // vector lane normalized as (256 - d)/256 ⇒ d = 256 - vector*256.
        // Round to the nearest integer to invert the float division exactly on
        // the conformance vectors. Clamp into the valid 0..=256 band.
        let d = (256.0 - (self.vector as f64) * 256.0).round();
        (d as i32).clamp(0, 256)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hamming_similarity_endpoints() {
        assert_eq!(hamming_similarity(0), 1.0);
        assert_eq!(hamming_similarity(256), 0.0);
        assert_eq!(hamming_similarity(-1), 0.0); // sentinel
    }

    #[test]
    fn lattice_proximity_cases() {
        assert_eq!(lattice_proximity("", "53"), 0.5); // unanchored query
        assert_eq!(lattice_proximity("53", ""), 0.0); // anchored query, unanchored candidate
        assert_eq!(lattice_proximity("53", "53"), 1.0); // exact
        // "53" vs "54": shared prefix 1 over longer 2 = 0.5
        assert!((lattice_proximity("53", "54") - 0.5).abs() < 1e-9);
    }

    #[test]
    fn squash_monotone() {
        assert_eq!(squash(0.0), 0.0);
        assert!(squash(1.0) < squash(10.0));
    }

    #[test]
    fn temporal_text_markers() {
        assert_eq!(temporal_text_score("this is superseded"), 0.0);
        assert_eq!(temporal_text_score("current as of 2026"), 1.0);
        assert_eq!(temporal_text_score("plain content"), 0.5);
        // stale dominates current
        assert_eq!(temporal_text_score("current but superseded"), 0.0);
    }

    #[test]
    fn reference_codes_extracted() {
        let c = reference_codes("see ref-0042 and REF-0099 here");
        assert!(c.contains("ref-0042"));
        assert!(c.contains("ref-0099"));
        assert_eq!(c.len(), 2);
    }

    #[test]
    fn token_exact_rate_matches_distinctive() {
        assert_eq!(token_exact_rate("value of 46", "the answer is 46"), 1.0);
        assert_eq!(token_exact_rate("value of 46", "the answer is 11"), 0.0);
        assert_eq!(token_exact_rate("just plain words", "anything"), 0.0); // no distinctive
    }
}
