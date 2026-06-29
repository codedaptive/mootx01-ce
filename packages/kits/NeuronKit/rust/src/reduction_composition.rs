//! A REDUCTION COMPOSITION is a declarative recipe: an ordered, weighted list of
//! signal components folded into one precision score per candidate, then a
//! BOUNDED top-k re-rank. Rust port of
//! `NeuronKit/Sources/NeuronKit/Reduction/ReductionComposition.swift`.
//!
//! The bounded-reduce discipline: a composition only RE-ORDERS the coarse pool
//! and truncates to the caller's `limit`; it never prunes the pool below the
//! coarse grab. The true target, once surfaced by the coarse grab, can never be
//! dropped out of the returned set.
//!
//! Determinism: the fold is a pure function of (query, candidates). The final
//! sort is stable by construction — weighted score descending, then a
//! CONTENT-stable tie-break (content lexicographic, then coarse rank) — so the
//! reduce is reproducible across runs and bit-identical to the Swift port on
//! shared vectors.

use std::collections::BTreeSet;

use crate::hybrid_recall::shingle_similarity;
use crate::reduction_signals::{
    reduction_score, reference_codes, ReductionCandidate, ReductionQuery, ReductionSignal,
};

/// One weighted term in a composition: a signal and its non-negative weight.
/// Mirrors Swift `NeuronKit.WeightedSignal`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WeightedSignal {
    /// The signal component to evaluate.
    pub signal: ReductionSignal,
    /// The non-negative weight applied to this signal's `[0, 1]` score.
    pub weight: f64,
}

impl WeightedSignal {
    /// Build a weighted term. Mirrors Swift `WeightedSignal.init(_:weight:)`
    /// with `weight` defaulting to 1.0 — use `new` for the default.
    pub fn new(signal: ReductionSignal) -> Self {
        WeightedSignal { signal, weight: 1.0 }
    }

    /// Build a weighted term with an explicit weight.
    pub fn weighted(signal: ReductionSignal, weight: f64) -> Self {
        WeightedSignal { signal, weight }
    }
}

/// A named, declarative reduction composition: a weighted sum of signal
/// components plus the bounded-reduce policy. Pure and deterministic.
/// Mirrors Swift `NeuronKit.ReductionComposition`.
#[derive(Debug, Clone, PartialEq)]
pub struct ReductionComposition {
    /// The composition's stable name — the gauntlet column id and the
    /// `composition` arg value on `moot_recall_precise`.
    pub name: String,
    /// The weighted signal terms summed into the per-candidate precision score.
    pub terms: Vec<WeightedSignal>,
    /// The MMR trade-off λ for the `mmr` re-rank term, in `[0, 1]`.
    pub mmr_lambda: f64,
}

impl ReductionComposition {
    /// Build a composition with the default `mmr_lambda` (0.7, the HybridRecall
    /// default). Mirrors Swift `ReductionComposition.init(name:terms:)`.
    pub fn new(name: impl Into<String>, terms: Vec<WeightedSignal>) -> Self {
        ReductionComposition {
            name: name.into(),
            terms,
            mmr_lambda: 0.7,
        }
    }

    /// Build a composition with an explicit `mmr_lambda`. Mirrors Swift
    /// `ReductionComposition.init(name:terms:mmrLambda:)`.
    pub fn with_lambda(name: impl Into<String>, terms: Vec<WeightedSignal>, mmr_lambda: f64) -> Self {
        ReductionComposition {
            name: name.into(),
            terms,
            mmr_lambda,
        }
    }

    /// The per-candidate terms (everything except the set-level signals).
    fn per_candidate_terms(&self) -> Vec<WeightedSignal> {
        self.terms
            .iter()
            .filter(|t| !t.signal.is_set_level())
            .copied()
            .collect()
    }

    /// True when this composition includes an `mmr` diversity re-rank pass.
    pub fn has_mmr(&self) -> bool {
        self.terms.iter().any(|t| t.signal == ReductionSignal::Mmr)
    }

    /// True when this composition includes the `assembly` split-fact expansion.
    pub fn has_assembly(&self) -> bool {
        self.terms.iter().any(|t| t.signal == ReductionSignal::Assembly)
    }

    /// The per-candidate terms that read NO content (the dense signals).
    pub fn dense_per_candidate_terms(&self) -> Vec<WeightedSignal> {
        self.per_candidate_terms()
            .into_iter()
            .filter(|t| !t.signal.needs_content())
            .collect()
    }

    /// True when this composition needs a hydrated body for ANY term.
    pub fn needs_content(&self) -> bool {
        self.terms.iter().any(|t| t.signal.needs_content())
    }
}

/// Reduce `candidates` under `composition` against `query`, returning the top
/// `limit` in precision order. Steps: weighted sum → stable sort (precision
/// desc, content lexicographic, coarse rank) → optional MMR re-rank → optional
/// assembly expansion → bounded truncate. Mirrors Swift `NeuronKit.reduce`.
pub fn reduce(
    composition: &ReductionComposition,
    query: &ReductionQuery,
    candidates: &[ReductionCandidate],
    limit: usize,
) -> Vec<ReductionCandidate> {
    if candidates.is_empty() || limit == 0 {
        return Vec::new();
    }

    // 1. WEIGHTED SUM per candidate over the per-candidate terms.
    let per_terms = composition.per_candidate_terms();
    let scored: Vec<(ReductionCandidate, f64)> = candidates
        .iter()
        .map(|candidate| {
            let mut sum = 0.0;
            for term in &per_terms {
                if term.weight != 0.0 {
                    sum += term.weight * reduction_score(term.signal, query, candidate);
                }
            }
            (candidate.clone(), sum)
        })
        .collect();

    // 2a. STAMP precision_score onto each candidate so callers (e.g.
    //     precise_recall) can surface the composition score, not the coarse
    //     fusion score, as the reported match score. Mirrors the Swift
    //     `stamped` block in `ReductionComposition.reduce`.
    let stamped: Vec<ReductionCandidate> = scored
        .into_iter()
        .map(|(mut c, precision)| {
            c.precision_score = precision;
            c
        })
        .collect();

    // 2b. STABLE SORT on precision_score desc, then a CONTENT-stable tie-break.
    //     The content tie-break (not coarse rank alone) makes the reduce
    //     deterministic across runs: the coarse-grab pool order is itself
    //     unstable run-to-run (random UUIDs break RRF ties), so tie-breaking on
    //     the stable content string removes that dependence. Coarse rank is the
    //     last resort for the degenerate identical-content case.
    let mut stamped = stamped;
    stamped.sort_by(|lhs, rhs| {
        // precision desc
        match rhs.precision_score.partial_cmp(&lhs.precision_score)
            .unwrap_or(std::cmp::Ordering::Equal)
        {
            std::cmp::Ordering::Equal => {}
            ord => return ord,
        }
        // content asc
        match lhs.content.cmp(&rhs.content) {
            std::cmp::Ordering::Equal => {}
            ord => return ord,
        }
        // coarse rank asc
        lhs.coarse_rank.cmp(&rhs.coarse_rank)
    });
    let mut ranked: Vec<ReductionCandidate> = stamped;

    // 3. MMR RE-RANK (optional, set-level).
    if composition.has_mmr() {
        ranked = mmr_diversity_rerank(&ranked, composition.mmr_lambda);
    }

    // 3b. ASSEMBLY EXPANSION (optional, set-level), over the WHOLE ranked pool
    //     before the truncate so a partner past `limit` is promoted in.
    if composition.has_assembly() {
        ranked = assembly_expand(&ranked);
    }

    // 4. BOUNDED TRUNCATE.
    ranked.truncate(limit);
    ranked
}

/// NARROW-THEN-HYDRATE reduce — the dense-first body-saving path. Runs the
/// composition's BODY-FREE signals over the whole wide pool, narrows to a
/// bounded survivor set on that dense score, and only then hydrates the
/// survivors' bodies (via `hydrate`) to evaluate the content signals. Mirrors
/// Swift `NeuronKit.reduceLate`.
///
/// `hydrate` is a synchronous closure (id set → id→body map). The Rust GLK
/// recall path is synchronous, so the recipe's late-hydration capability is a
/// plain closure rather than the Swift `async` one — same contract, same
/// determinism.
pub fn reduce_late<F>(
    composition: &ReductionComposition,
    query: &ReductionQuery,
    candidates: &[ReductionCandidate],
    limit: usize,
    survivor_multiple: usize,
    hydrate: F,
) -> Vec<ReductionCandidate>
where
    F: Fn(&[String]) -> std::collections::HashMap<String, String>,
{
    if candidates.is_empty() || limit == 0 {
        return Vec::new();
    }

    // PURE-DENSE shortcut: the composition needs no content. `reduce` SELECTS
    // the final top-k body-free, then we hydrate the SELECTED top-k (≈ `limit`
    // records, not the wide pool) for OUTPUT — the two-lane principle.
    if !composition.needs_content() {
        let selected = reduce(composition, query, candidates, limit);
        return hydrate_candidates(&selected, &hydrate);
    }

    // No dense signal to narrow on: hydrate the whole pool, then reduce.
    if composition.dense_per_candidate_terms().is_empty() {
        let hydrated = hydrate_candidates(candidates, &hydrate);
        return reduce(composition, query, &hydrated, limit);
    }

    // MIXED: rank the pool body-free on the dense terms, keep the top
    // survivors, hydrate only those, then run the FULL composition on them.
    let dense_terms = composition.dense_per_candidate_terms();
    let mut dense_scored: Vec<(ReductionCandidate, f64)> = candidates
        .iter()
        .map(|candidate| {
            let mut sum = 0.0;
            for term in &dense_terms {
                if term.weight != 0.0 {
                    sum += term.weight * reduction_score(term.signal, query, candidate);
                }
            }
            (candidate.clone(), sum)
        })
        .collect();
    // Stable dense sort: dense score desc, then coarse rank asc (bodies are
    // empty here, so the content tie-break is not available pre-hydration).
    dense_scored.sort_by(|lhs, rhs| {
        match rhs.1.partial_cmp(&lhs.1).unwrap_or(std::cmp::Ordering::Equal) {
            std::cmp::Ordering::Equal => lhs.0.coarse_rank.cmp(&rhs.0.coarse_rank),
            ord => ord,
        }
    });
    let dense_ranked: Vec<ReductionCandidate> = dense_scored.into_iter().map(|(c, _)| c).collect();

    // Bounded survivor set: a few× the limit, never below `limit`, never above
    // the pool. Use saturating_mul to avoid integer overflow when limit and
    // survivor_multiple are both large: debug-mode wrapping panics, release-mode
    // wrap produces a silently wrong negative count. Saturates at usize::MAX then
    // clamps to pool size. Mirrors Swift safe-multiplication fix. (NK-8 planned hardening)
    let survivor_count = candidates
        .len()
        .min(limit.max(limit.saturating_mul(survivor_multiple.max(1))));
    let survivors: Vec<ReductionCandidate> = dense_ranked.into_iter().take(survivor_count).collect();

    let hydrated = hydrate_candidates(&survivors, &hydrate);
    reduce(composition, query, &hydrated, limit)
}

/// The default survivor multiple for `reduce_late` (8× the limit, bounded).
/// Mirrors the Swift `reduceLate` `survivorMultiple` default.
pub const DEFAULT_SURVIVOR_MULTIPLE: usize = 8;

/// Hydrate a candidate set: fetch each id's body via `hydrate` and return copies
/// carrying that content. Candidates with no body keep their existing content.
/// Order is preserved. Mirrors Swift `hydrateCandidates`.
fn hydrate_candidates<F>(candidates: &[ReductionCandidate], hydrate: &F) -> Vec<ReductionCandidate>
where
    F: Fn(&[String]) -> std::collections::HashMap<String, String>,
{
    let ids: Vec<String> = candidates.iter().map(|c| c.id.clone()).collect();
    let bodies = hydrate(&ids);
    candidates
        .iter()
        .map(|c| {
            match bodies.get(&c.id) {
                Some(body) if *body != c.content => {
                    let mut copy = c.clone();
                    copy.content = body.clone();
                    copy
                }
                _ => c.clone(),
            }
        })
        .collect()
}

/// Content-shingle MMR diversity re-rank over an already-relevance-ordered pool.
/// Relevance is the pool POSITION (1.0 at the front, decaying to 0 at the back).
/// Similarity is the 3-gram shingle Jaccard. Deterministic: ties resolve to the
/// earlier pool position. `MMR(i) = λ·relevance(i) − (1−λ)·maxSim(i, selected)`.
/// Mirrors Swift `mmrDiversityRerank`.
pub fn mmr_diversity_rerank(pool: &[ReductionCandidate], lambda: f64) -> Vec<ReductionCandidate> {
    let n = pool.len();
    if n <= 1 {
        return pool.to_vec();
    }
    // Guard NaN: f64::clamp returns NaN when the input is NaN (IEEE 754). A NaN
    // lambda propagates to every MMR score, making all scores NaN. NaN > NEG_INFINITY
    // is false, so best_idx stays -1 and `best_idx as usize` wraps to usize::MAX,
    // causing an out-of-bounds panic. Default NaN to 0.5 (equal weight between
    // relevance and diversity — the neutral MMR operating point).
    // Mirrors Swift mmrDiversityRerank NaN guard. (NK-9 planned hardening)
    let lam = if lambda.is_nan() { 0.5 } else { lambda.clamp(0.0, 1.0) };

    // relevance(i) = (n - i) / n, strictly decreasing in (0, 1].
    let relevance: Vec<f64> = (0..n).map(|i| (n - i) as f64 / n as f64).collect();

    let mut selected: Vec<usize> = Vec::with_capacity(n);
    let mut is_selected = vec![false; n];
    let mut max_sim = vec![0.0_f64; n];

    while selected.len() < n {
        let mut best_idx: isize = -1;
        let mut best_score = f64::NEG_INFINITY;
        for i in 0..n {
            if is_selected[i] {
                continue;
            }
            let score = lam * relevance[i] - (1.0 - lam) * max_sim[i];
            // Strict `>` plus ascending scan = earliest-position tie-break.
            if score > best_score {
                best_score = score;
                best_idx = i as isize;
            }
        }
        let pick = best_idx as usize;
        is_selected[pick] = true;
        selected.push(pick);
        let pick_content = &pool[pick].content;
        for i in 0..n {
            if is_selected[i] {
                continue;
            }
            let sim = shingle_similarity(&pool[i].content, pick_content) as f64;
            if sim > max_sim[i] {
                max_sim[i] = sim;
            }
        }
    }
    selected.into_iter().map(|i| pool[i].clone()).collect()
}

/// SPLIT-FACT ASSEMBLY EXPANSION (T4). For each ranked candidate carrying a
/// reference code (`REF-NNNN`), promote the FIRST not-yet-emitted partner
/// sharing that code to immediately follow it, so both halves of a split fact
/// are co-surfaced inside the bounded window. Deterministic forward scan;
/// idempotent. Mirrors Swift `assemblyExpand`.
pub fn assembly_expand(pool: &[ReductionCandidate]) -> Vec<ReductionCandidate> {
    let n = pool.len();
    if n <= 1 {
        return pool.to_vec();
    }
    let codes: Vec<BTreeSet<String>> = pool.iter().map(|c| reference_codes(&c.content)).collect();
    let mut emitted = vec![false; n];
    let mut out: Vec<ReductionCandidate> = Vec::with_capacity(n);

    for i in 0..n {
        if emitted[i] {
            continue;
        }
        emitted[i] = true;
        out.push(pool[i].clone());
        if codes[i].is_empty() {
            continue;
        }
        // Pull the first not-yet-emitted partner sharing any of i's codes.
        for j in 0..n {
            if emitted[j] || j == i {
                continue;
            }
            if !codes[i].is_disjoint(&codes[j]) {
                emitted[j] = true;
                out.push(pool[j].clone());
                break;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use genius_locus_kit::recall::RecallScoreVector;

    fn cand(id: &str, content: &str, coarse_rank: usize) -> ReductionCandidate {
        ReductionCandidate {
            id: id.to_string(),
            content: content.to_string(),
            room: String::new(),
            score: RecallScoreVector::ZERO,
            udc_code: String::new(),
            udc_facets: None,
            coarse_rank,
            event_time: None,
            is_currently_believed: true,
            // precision_score is 0 here — the fold stamps the real value.
            precision_score: 0.0,
        }
    }

    #[test]
    fn empty_or_zero_limit_returns_empty() {
        let comp = ReductionComposition::new("text", vec![WeightedSignal::new(ReductionSignal::Text)]);
        let q = ReductionQuery::new("x");
        assert!(reduce(&comp, &q, &[], 5).is_empty());
        assert!(reduce(&comp, &q, &[cand("a", "x", 0)], 0).is_empty());
    }

    #[test]
    fn text_reduce_ranks_exact_answer_first() {
        let comp = ReductionComposition::new("text", vec![WeightedSignal::new(ReductionSignal::Text)]);
        let q = ReductionQuery::new("indemnity 46 million marks");
        let pool = vec![
            cand("a", "the indemnity was 11 million marks", 0),
            cand("b", "the indemnity was 46 million marks", 1),
        ];
        let out = reduce(&comp, &q, &pool, 2);
        assert_eq!(out[0].id, "b", "the candidate with 46 must rank first");
    }

    #[test]
    fn bounded_truncate_never_exceeds_limit() {
        let comp = ReductionComposition::new("text", vec![WeightedSignal::new(ReductionSignal::Text)]);
        let q = ReductionQuery::new("x");
        let pool = vec![cand("a", "x", 0), cand("b", "x y", 1), cand("c", "z", 2)];
        let out = reduce(&comp, &q, &pool, 2);
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn assembly_pulls_partner_adjacent() {
        // 'a' references ref-0001; 'c' shares it but ranks last. Assembly pulls c after a.
        let comp = ReductionComposition::new(
            "text+assembly",
            vec![
                WeightedSignal::new(ReductionSignal::Text),
                WeightedSignal::new(ReductionSignal::Assembly),
            ],
        );
        let q = ReductionQuery::new("alpha");
        let pool = vec![
            cand("a", "alpha ref-0001", 0),
            cand("b", "beta", 1),
            cand("c", "value ref-0001", 2),
        ];
        let out = reduce(&comp, &q, &pool, 3);
        let ids: Vec<&str> = out.iter().map(|c| c.id.as_str()).collect();
        // a first (matches alpha), then its partner c, then b.
        assert_eq!(ids[0], "a");
        assert_eq!(ids[1], "c");
    }

    #[test]
    fn mmr_demotes_near_duplicate() {
        let comp = ReductionComposition::with_lambda(
            "text+mmr",
            vec![
                WeightedSignal::new(ReductionSignal::Text),
                WeightedSignal::new(ReductionSignal::Mmr),
            ],
            0.5,
        );
        let q = ReductionQuery::new("organic chemistry");
        let pool = vec![
            cand("a", "organic chemistry is the study of carbon compounds", 0),
            cand("b", "organic chemistry is the study of carbon compounds again", 1),
            cand("c", "inorganic salts dissolve in water", 2),
        ];
        let out = reduce(&comp, &q, &pool, 3);
        // The diverse candidate c should not be pushed to the very end after the
        // near-duplicate of a (b) — MMR penalizes b's redundancy with a.
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].id, "a");
    }
}
