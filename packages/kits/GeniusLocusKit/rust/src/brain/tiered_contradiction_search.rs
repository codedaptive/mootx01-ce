// tiered_contradiction_search.rs — Rust twin of
// Brain/TieredContradictionSearch.swift.
//
// MXE-CT3 P2 — the tiered contradiction lanes and the synthesis
// assembler. One search verb (the coordinator's
// `tiered_contradiction_search` seam), two modes:
//
//   single tier N — run ONLY that tier's lane and answer its question
//     in isolation (no cross-tier dedup: a purpose-run answers its own
//     question, so a pair that is also a tier-1 proof still appears in
//     a tier-3 run).
//   synthesis (tier == None) — run all three lanes, then assemble:
//     duplicates promote to their highest tier, lower tiers backfill
//     from their over-fetch, and the three sections render in tier
//     order 1, 2, 3 — NEVER interleaved into one ranked list. Tiers
//     are epistemic classes, not score bands: a strong tier-3 lexical
//     cue never outranks a weak tier-1 typed proof.
//
// The tiers (P1, substrate_ml `ConflictCueKind::contradiction_tier`):
//   Tier 1 — typed proof (conflict_projection_sweep ProvenContradiction;
//     no lexical score exists — ranking is endpoint recency).
//   Tier 2 — structural lexical cues (negation_asymmetry,
//     marker_revision, word_exclusion).
//   Tier 3 — lexical value divergence (value_divergence).
//
// This module is the PURE core: pair-key canonicalization, clamp and
// fetch budgets, lane ranking, and the assembler. Estate reads (the
// typed sweep, the shared hunt retrieval, hydration) happen in the
// coordinator seam. Read-and-report ONLY — no tunnel proposals, no
// writes. The WRITE half lives in the coordinator's
// `propose_conflict_tunnels` (tier-labeled filing out of the same
// lexical scan) and `endorse_tunnel` / `object_to_tunnel` (the P2.5
// review ladder), plus `brain::review_queue` for queue ranking.

use super::conflict_projection_sweep::ConflictFinding;
use std::collections::{HashMap, HashSet};

/// Hard ceiling on `top_k` — a DoS bound, not a tuning knob. The
/// lexical lanes over-fetch at 3×top_k, so this cap bounds a single
/// search at 150 screened findings per lane no matter what the caller
/// (ultimately the MCP layer) asks for. Input validation is the MCP
/// layer's job; the engine guards anyway (a7ac773eb / edbb0298b
/// precedent: unbounded "all" modes got caps).
pub const TIERED_TOP_K_CEILING: usize = 50;

/// Clamp a requested `top_k` to the engine's bounds. Zero yields zero —
/// the verb answers it with a deterministic empty report rather than
/// guessing a default. (Negative requests cannot exist here: `usize`.
/// The Swift twin additionally maps negatives to zero.)
pub fn effective_top_k(requested: usize) -> usize {
    requested.min(TIERED_TOP_K_CEILING)
}

/// The three epistemic classes a contradiction finding can carry.
/// Named `ContradictionTier` (not `Tier`) to avoid colliding with the
/// existing `MatrixTier`. Raw values are the wire tier numbers from
/// P1's `ConflictCueKind::contradiction_tier` mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ContradictionTier {
    /// Tier 1 — a typed-lane proof (the strongest class; constraints
    /// proved the conflict, no lexical score applies).
    TypedProven = 1,
    /// Tier 2 — structural lexical cues.
    LexicalStructural = 2,
    /// Tier 3 — lexical value divergence.
    LexicalValue = 3,
}

impl ContradictionTier {
    pub fn raw_value(&self) -> u8 {
        *self as u8
    }

    pub fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            1 => Some(Self::TypedProven),
            2 => Some(Self::LexicalStructural),
            3 => Some(Self::LexicalValue),
            _ => None,
        }
    }

    /// Per-tier fetch budget: tier 1 fetches exactly top_k (its lane is
    /// the promotion target and never loses findings to dedup); tiers 2
    /// and 3 over-fetch at 2× and 3× so synthesis can backfill what
    /// promotion removes. Deeper tiers over-fetch more because they sit
    /// below MORE promotion sources (tier 3 loses pairs to both tier 1
    /// and tier 2; tier 2 only to tier 1).
    pub fn fetch_budget(&self, top_k: usize) -> usize {
        top_k * self.raw_value() as usize
    }
}

/// Case-canonical unordered drawer-pair key.
///
/// BOTH ids are lowercased before ordering and joining. Swift's
/// `UUID.uuidString` is UPPERCASE while Rust's `Uuid::to_string()` is
/// lowercase — the exact mismatch that made a Rust walk lane silently
/// return 0 results against lowercase storage keys (precedent
/// c95910dff). Canonicalizing case here means the same logical pair
/// keys identically across ports and across tiers (a tier-1 key built
/// from sweep source_drawer_ids matches a tier-2/3 key built from
/// hydrated drawer ids regardless of how either surface cased the
/// UUID).
///
/// Deliberately DISTINCT from the case-sensitive
/// `conflict_projection_sweep::pair_key`, which is already baked into
/// settled-tunnel dedup and accepted-supersession matching — changing
/// that key's semantics is a separate blast radius this wave does not
/// own. This key exists only inside tiered reports and their assembly.
pub fn tiered_pair_key(a: &str, b: &str) -> String {
    let la = a.to_lowercase();
    let lb = b.to_lowercase();
    if la < lb {
        format!("{la}||{lb}")
    } else {
        format!("{lb}||{la}")
    }
}

/// Order an endpoint pair to match `tiered_pair_key`'s canonical
/// ordering: case-insensitively smaller first; ties (ids differing
/// only by case) fall back to the raw comparison so the order is still
/// total and deterministic.
pub fn ordered_pair(x: &str, y: &str) -> (String, String) {
    let lx = x.to_lowercase();
    let ly = y.to_lowercase();
    if lx == ly {
        if x <= y {
            (x.to_string(), y.to_string())
        } else {
            (y.to_string(), x.to_string())
        }
    } else if lx < ly {
        (x.to_string(), y.to_string())
    } else {
        (y.to_string(), x.to_string())
    }
}

/// One finding in a tiered report. A tagged union in struct clothing:
/// tiers 2/3 carry the lexical fields (cue_kind, score, snippets) and
/// tier 1 carries the typed-proof fields (rule_id, result_id,
/// coordinate_digest, sensitivity_ceiling_raw); the other side's
/// fields are None. Kept as one flat type so the per-tier sections
/// share a report shape and the assembler stays generic over tiers.
/// Mirrors Swift `TierFinding`.
#[derive(Debug, Clone, PartialEq)]
pub struct TierFinding {
    pub tier: ContradictionTier,
    /// Case-canonical unordered drawer-pair key (`tiered_pair_key`) —
    /// the assembler's dedup identity across tiers AND ports.
    pub pair_key: String,
    /// Endpoint drawer ids in canonical order (case-insensitively
    /// smaller first, matching `pair_key`'s ordering). Original casing
    /// is preserved — these must round-trip to storage lookups.
    pub drawer_a: String,
    pub drawer_b: String,
    /// Tiers 2/3: `ConflictCueKind` wire string. Tier 1: None (a typed
    /// proof has a rule, not a cue).
    pub cue_kind: Option<String>,
    /// Tier 1: the typed rule that proved the pair. Tiers 2/3: None.
    pub rule_id: Option<String>,
    /// Tiers 2/3: the cue score. Tier 1: None — a typed proof has NO
    /// score; its lane ranks by endpoint recency, and the absence of a
    /// score is load-bearing (nothing may fold tiers into one ranked
    /// list by comparing across this field).
    pub score: Option<f32>,
    /// Tiers 2/3: endpoint content snippets, capped at
    /// `HUNT_SNIPPET_LIMIT` — the same bound the hunter's borderline
    /// feed carries. Ordered to match drawer_a/drawer_b. Tier 1: None
    /// (typed findings never carry content).
    pub source_snippet: Option<String>,
    pub target_snippet: Option<String>,
    /// Tier 1: pair-order-invariant stable result identity from the
    /// sweep's `ConflictOutcome`. Tiers 2/3: None.
    pub result_id: Option<String>,
    /// Tier 1: the coordinate digest for redacted rendering. Tiers
    /// 2/3: None.
    pub coordinate_digest: Option<String>,
    /// Tier 1: the sweep's per-finding sensitivity ceiling, carried
    /// through UNCHANGED (raw adjective-sensitivity value, fail-closed
    /// to Secret upstream when unresolvable — see `run_sweep`'s
    /// ceiling closure). Tiers 2/3: None — their endpoints already
    /// passed the hunter's hardcoded Elevated ceiling before
    /// screening.
    pub sensitivity_ceiling_raw: Option<i64>,
}

/// Which question a report answers. Mirrors Swift `TieredSearchMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TieredSearchMode {
    /// One lane ran; its section is the whole answer. No cross-tier
    /// dedup was applied.
    Single(ContradictionTier),
    /// All three lanes ran; sections were assembled with
    /// promote-to-highest-tier dedup and over-fetch backfill.
    Synthesis,
}

/// Per-lane bookkeeping. `fetched` is what the lane kept after its
/// fetch cap (K / 2K / 3K); `returned` is the section length;
/// `promoted_away` counts fetched findings removed because the same
/// pair exists at a higher tier; `backfilled` counts returned findings
/// that sat beyond the lane's first `top_k` ranks and moved up because
/// earlier findings promoted away. Mirrors Swift `TierLaneCounts`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TierLaneCounts {
    pub fetched: usize,
    pub returned: usize,
    pub promoted_away: usize,
    pub backfilled: usize,
}

/// Truncation and availability diagnostics — every place a bounded
/// pass may have dropped candidates is visible here, never silent.
/// Mirrors Swift `TieredSearchDiagnostics`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TieredSearchDiagnostics {
    /// False when a lexical lane ran and the estate has no registered
    /// VectorStore (the lexical lanes are honest no-ops, matching the
    /// hunter's reporting). A tier-1-only run reports true — the typed
    /// lane needs no vector store.
    pub vector_store_available: bool,
    /// Probe ids scanned by the shared lexical retrieval pass (0 when
    /// no lexical lane ran).
    pub probes_scanned: usize,
    /// The typed sweep's coordinate buckets that hit the bucket cap
    /// (0 when tier 1 did not run).
    pub sweep_truncated_buckets: usize,
    /// Qualifying candidates seen per lane BEFORE the fetch cap —
    /// candidates > fetched means the cap truncated that lane.
    pub tier1_candidates: usize,
    pub tier2_candidates: usize,
    pub tier3_candidates: usize,
    /// Tier-1 proven findings excluded by the search's sensitivity
    /// posture (ceiling above Elevated). Counted apart so the gate's
    /// activity is visible in the report — the same reason the typed
    /// proposal loop counts `ceiling_skipped` separately.
    pub tier1_ceiling_filtered: usize,
}

impl TieredSearchDiagnostics {
    pub fn empty() -> Self {
        Self {
            vector_store_available: true,
            ..Self::default()
        }
    }
}

/// One tiered search's outcome. Deterministic for a given estate
/// state: every section is sorted on an explicit key, so retrieval
/// iteration order cannot leak into the report. Sections are ALWAYS in
/// tier order 1, 2, 3 and never interleaved — tiers are epistemic
/// classes, and the report shape enforces that a strong tier-3 cannot
/// outrank a weak tier-1. Mirrors Swift `TieredContradictionReport`.
#[derive(Debug, Clone, PartialEq)]
pub struct TieredContradictionReport {
    pub mode: TieredSearchMode,
    pub tier1: Vec<TierFinding>,
    pub tier2: Vec<TierFinding>,
    pub tier3: Vec<TierFinding>,
    pub tier1_counts: TierLaneCounts,
    pub tier2_counts: TierLaneCounts,
    pub tier3_counts: TierLaneCounts,
    pub diagnostics: TieredSearchDiagnostics,
}

impl TieredContradictionReport {
    pub fn empty(mode: TieredSearchMode) -> Self {
        Self {
            mode,
            tier1: Vec::new(),
            tier2: Vec::new(),
            tier3: Vec::new(),
            tier1_counts: TierLaneCounts::default(),
            tier2_counts: TierLaneCounts::default(),
            tier3_counts: TierLaneCounts::default(),
            diagnostics: TieredSearchDiagnostics::empty(),
        }
    }
}

/// Map one typed proven finding into the tier-1 report shape, carrying
/// the sweep's sensitivity ceiling through unchanged. The caller
/// guards `source_drawer_ids.len() == 2` before ranking (the evaluator
/// always emits exactly two sorted ids for a pairwise outcome), so the
/// indexing here cannot panic through the verb.
pub fn tier_finding_from_proven(finding: &ConflictFinding) -> TierFinding {
    let ids = &finding.outcome.source_drawer_ids;
    let (a, b) = ordered_pair(&ids[0], &ids[1]);
    TierFinding {
        tier: ContradictionTier::TypedProven,
        pair_key: tiered_pair_key(&a, &b),
        drawer_a: a,
        drawer_b: b,
        cue_kind: None,
        rule_id: Some(finding.outcome.rule_id.clone()),
        score: None,
        source_snippet: None,
        target_snippet: None,
        result_id: Some(finding.outcome.result_id.clone()),
        coordinate_digest: Some(finding.outcome.coordinate_digest()),
        sensitivity_ceiling_raw: Some(finding.sensitivity_ceiling_raw),
    }
}

/// Rank + trim the tier-1 lane. Tier 1 has NO score — proofs do not
/// come in strengths at this surface — so the lane ranks by the most
/// recent endpoint event time (newest first): the proof whose evidence
/// is freshest answers "what contradicts right now" best. Event times
/// are EPOCH SECONDS in both ports (the sweep's KI-003 identity
/// domain) so the cross-port order agrees. Tie-break: `result_id`
/// ascending — stable and pair-order-invariant by construction.
///
/// A finding with NO resolvable endpoint event time ranks oldest
/// (`i64::MIN`): a hydration gap is not evidence of recency, and
/// pushing unresolved findings down keeps them from crowding out
/// findings with real timestamps. They are still returned when room
/// remains — resolution failure redacts rank, not existence.
pub fn rank_and_trim_tier1(
    findings: &[ConflictFinding],
    event_time_seconds_by_source_drawer: &HashMap<String, i64>,
    top_k: usize,
) -> Vec<TierFinding> {
    let mut keyed: Vec<(&ConflictFinding, i64)> = findings
        .iter()
        .map(|f| {
            let latest = f
                .outcome
                .source_drawer_ids
                .iter()
                .filter_map(|id| event_time_seconds_by_source_drawer.get(id).copied())
                .max()
                .unwrap_or(i64::MIN);
            (f, latest)
        })
        .collect();
    keyed.sort_by(|(fa, ka), (fb, kb)| {
        kb.cmp(ka)
            .then_with(|| fa.outcome.result_id.cmp(&fb.outcome.result_id))
    });
    keyed
        .into_iter()
        .take(top_k)
        .map(|(f, _)| tier_finding_from_proven(f))
        .collect()
}

/// Rank a lexical lane (tier 2 or 3): cue score descending — stronger
/// cues first — with `pair_key` ascending as the deterministic
/// tie-break. The retrieval pass's iteration order is NOT
/// deterministic; this sort is what makes the report reproducible.
/// Cue scores are always finite (the screen produces bounded [0, 1]
/// values), so the partial comparison's fallback to Equal is inert.
pub fn rank_lexical(mut findings: Vec<TierFinding>) -> Vec<TierFinding> {
    findings.sort_by(|a, b| {
        let sa = a.score.unwrap_or(0.0);
        let sb = b.score.unwrap_or(0.0);
        sb.partial_cmp(&sa)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.pair_key.cmp(&b.pair_key))
    });
    findings
}

/// The synthesis assembly: three ranked+trimmed lane lists in, three
/// deduplicated sections out. Mirrors Swift `SynthesisAssembly`.
#[derive(Debug, Clone, PartialEq)]
pub struct SynthesisAssembly {
    pub tier1: Vec<TierFinding>,
    pub tier2: Vec<TierFinding>,
    pub tier3: Vec<TierFinding>,
    pub tier1_counts: TierLaneCounts,
    pub tier2_counts: TierLaneCounts,
    pub tier3_counts: TierLaneCounts,
}

/// Assemble the synthesis report from the three lanes' fetched lists.
/// Pure — no I/O, unit-testable on hand-built findings.
///
/// Promotion: a pair present in a higher tier's FETCHED list is
/// removed from every lower tier's candidates. Membership is keyed on
/// the fetched list (not just the returned window) because a
/// tier-1-proven pair is tier-1 CLASS even when the tier-1 section is
/// full — rendering it lower down would misstate its epistemic
/// standing. Tier 2 only loses pairs upward to tier 1; tier 3 loses to
/// both. (With the current single-cue screen a pair cannot sit in both
/// lexical lanes at once — the cue evaluator returns one kind — but
/// the assembler stays generic rather than leaning on that: the
/// tier-2-shadows-tier-3 rule is contract, not coincidence.)
///
/// Backfill: each lower tier then fills to `top_k` from its own
/// over-fetch (the 2×/3× budgets exist for exactly this), and the
/// count of findings that moved up from beyond the first `top_k` ranks
/// is recorded per tier.
///
/// Sections are returned in tier order and NEVER merged into one
/// ranked list: tiers are epistemic classes, and a strong tier-3 never
/// outranks a weak tier-1.
pub fn assemble_synthesis(
    tier1_fetched: Vec<TierFinding>,
    tier2_fetched: Vec<TierFinding>,
    tier3_fetched: Vec<TierFinding>,
    top_k: usize,
) -> SynthesisAssembly {
    // Tier 1 — the promotion target. Fetch budget is exactly top_k,
    // nothing above it removes findings, so the section is the fetched
    // list (defensively re-trimmed) with zero promotion and zero
    // backfill by construction.
    let tier1_fetched_count = tier1_fetched.len();
    let tier1_keys: HashSet<String> =
        tier1_fetched.iter().map(|f| f.pair_key.clone()).collect();
    let tier1: Vec<TierFinding> = tier1_fetched.into_iter().take(top_k).collect();
    let tier1_counts = TierLaneCounts {
        fetched: tier1_fetched_count,
        returned: tier1.len(),
        promoted_away: 0,
        backfilled: 0,
    };

    let mut tier12_keys = tier1_keys.clone();
    tier12_keys.extend(tier2_fetched.iter().map(|f| f.pair_key.clone()));

    let (tier2, tier2_counts) = dedupe_and_backfill(tier2_fetched, &tier1_keys, top_k);
    let (tier3, tier3_counts) = dedupe_and_backfill(tier3_fetched, &tier12_keys, top_k);

    SynthesisAssembly {
        tier1,
        tier2,
        tier3,
        tier1_counts,
        tier2_counts,
        tier3_counts,
    }
}

/// One lower lane's promotion + backfill step. Ranks are the input
/// order (the lane was ranked before trimming); `backfilled` counts
/// survivors whose original rank sat at or beyond `top_k` — the
/// findings the over-fetch existed to hold in reserve.
fn dedupe_and_backfill(
    fetched: Vec<TierFinding>,
    promoted_keys: &HashSet<String>,
    top_k: usize,
) -> (Vec<TierFinding>, TierLaneCounts) {
    let fetched_count = fetched.len();
    let mut promoted_away = 0usize;
    let mut kept: Vec<(usize, TierFinding)> = Vec::new();
    for (rank, finding) in fetched.into_iter().enumerate() {
        if promoted_keys.contains(&finding.pair_key) {
            promoted_away += 1;
        } else {
            kept.push((rank, finding));
        }
    }
    kept.truncate(top_k);
    let backfilled = kept.iter().filter(|(rank, _)| *rank >= top_k).count();
    let returned: Vec<TierFinding> = kept.into_iter().map(|(_, f)| f).collect();
    let counts = TierLaneCounts {
        fetched: fetched_count,
        returned: returned.len(),
        promoted_away,
        backfilled,
    };
    (returned, counts)
}

// MXE-CT3 P2 tests — Rust leg. Mirrors TieredContradictionSearchTests
// (pure-core section) one-for-one: pinned pair-key literals, clamp and
// fetch budgets, lane ranking keys, assembler promotion / shadowing /
// case-crossing dedup / backfill exhaustion / window caps /
// determinism. The estate-level cases live on the Swift side (the
// sweep precedent: the Rust leg pins the pure core).
#[cfg(test)]
mod tests {
    use super::*;
    use crate::brain::conflict_projection_sweep::{run_sweep, SWEEP_DEFAULT_BUCKET_CAP};
    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::kg_fact::KGFact;
    use substrate_ml::conflict_projection::ConflictRuleRegistry;

    fn lexical(tier: ContradictionTier, a: &str, b: &str, score: f32) -> TierFinding {
        let (da, db) = ordered_pair(a, b);
        TierFinding {
            tier,
            pair_key: tiered_pair_key(a, b),
            drawer_a: da,
            drawer_b: db,
            cue_kind: Some(
                if tier == ContradictionTier::LexicalValue {
                    "value_divergence"
                } else {
                    "negation_asymmetry"
                }
                .to_string(),
            ),
            rule_id: None,
            score: Some(score),
            source_snippet: Some("s".to_string()),
            target_snippet: Some("t".to_string()),
            result_id: None,
            coordinate_digest: None,
            sensitivity_ceiling_raw: None,
        }
    }

    fn typed(a: &str, b: &str, result_id: &str) -> TierFinding {
        let (da, db) = ordered_pair(a, b);
        TierFinding {
            tier: ContradictionTier::TypedProven,
            pair_key: tiered_pair_key(a, b),
            drawer_a: da,
            drawer_b: db,
            cue_kind: None,
            rule_id: Some("employment.employer.v1".to_string()),
            score: None,
            source_snippet: None,
            target_snippet: None,
            result_id: Some(result_id.to_string()),
            coordinate_digest: Some(format!("digest-{result_id}")),
            sensitivity_ceiling_raw: Some(AdjectiveSensitivity::Normal.raw_value()),
        }
    }

    /// SAME fixture strings, SAME expected literal as the Swift test
    /// `pairKeyCanonicalizesCaseAndOrder` — if either port drifts, one
    /// of the two pins breaks (the c95910dff UUID-case trap).
    #[test]
    fn tiered_pair_key_case_canonical() {
        assert_eq!(tiered_pair_key("AAAA-1111", "bbbb-2222"), "aaaa-1111||bbbb-2222");
        assert_eq!(tiered_pair_key("bbbb-2222", "AAAA-1111"), "aaaa-1111||bbbb-2222");
        assert_eq!(
            tiered_pair_key("AaAa-1111", "BBBB-2222"),
            tiered_pair_key("aaaa-1111", "bbbb-2222")
        );
        // Ordering is decided AFTER lowercasing: uppercase 'B' < 'a' in
        // raw byte order, but the canonical key still puts a-first.
        assert_eq!(tiered_pair_key("BBBB-2222", "aaaa-1111"), "aaaa-1111||bbbb-2222");
    }

    #[test]
    fn ordered_pair_matches_key_ordering() {
        assert_eq!(
            ordered_pair("BBBB-2222", "aaaa-1111"),
            ("aaaa-1111".to_string(), "BBBB-2222".to_string())
        );
        // Case-insensitive tie: total order falls back to raw compare.
        assert_eq!(ordered_pair("AbC", "aBc"), ("AbC".to_string(), "aBc".to_string()));
    }

    #[test]
    fn top_k_clamps_to_ceiling() {
        assert_eq!(effective_top_k(0), 0);
        assert_eq!(effective_top_k(10), 10);
        assert_eq!(effective_top_k(50), 50);
        assert_eq!(effective_top_k(51), 50);
        assert_eq!(effective_top_k(5000), 50);
    }

    #[test]
    fn fetch_budgets_are_k_2k_3k() {
        assert_eq!(ContradictionTier::TypedProven.fetch_budget(7), 7);
        assert_eq!(ContradictionTier::LexicalStructural.fetch_budget(7), 14);
        assert_eq!(ContradictionTier::LexicalValue.fetch_budget(7), 21);
    }

    #[test]
    fn tier_raw_round_trip() {
        for tier in [
            ContradictionTier::TypedProven,
            ContradictionTier::LexicalStructural,
            ContradictionTier::LexicalValue,
        ] {
            assert_eq!(ContradictionTier::from_raw(tier.raw_value()), Some(tier));
        }
        assert_eq!(ContradictionTier::from_raw(0), None);
        assert_eq!(ContradictionTier::from_raw(4), None);
    }

    #[test]
    fn rank_lexical_orders_by_score_then_pair_key() {
        let low = lexical(ContradictionTier::LexicalValue, "cccc", "dddd", 0.50);
        let high_a = lexical(ContradictionTier::LexicalValue, "aaaa", "bbbb", 0.90);
        let high_b = lexical(ContradictionTier::LexicalValue, "eeee", "ffff", 0.90);
        let ranked = rank_lexical(vec![low.clone(), high_b.clone(), high_a.clone()]);
        assert_eq!(ranked, vec![high_a.clone(), high_b.clone(), low.clone()]);
        // Deterministic: input permutation cannot change the output.
        assert_eq!(rank_lexical(vec![high_b, low, high_a]), ranked);
    }

    /// Proven findings for the tier-1 ranking tests, produced through
    /// the real pure sweep core (mirrors the Swift fixture, which has
    /// no test-reachable ConflictFinding init either).
    fn proven_pair(subject: &str, d1: &str, d2: &str) -> ConflictFinding {
        let facts = vec![
            KGFact::new(
                format!("{subject}-f1"),
                subject.into(),
                "Employer".into(),
                "Acme Robotics".into(),
                d1.into(),
                1_700_000_000_000,
            ),
            KGFact::new(
                format!("{subject}-f2"),
                subject.into(),
                "Employer".into(),
                "Beta Corp".into(),
                d2.into(),
                1_700_000_000_000,
            ),
        ];
        let times: HashMap<String, i64> =
            [(d1.to_string(), 500), (d2.to_string(), 500)].into();
        let sens: HashMap<String, i64> = [
            (d1.to_string(), AdjectiveSensitivity::Normal.raw_value()),
            (d2.to_string(), AdjectiveSensitivity::Normal.raw_value()),
        ]
        .into();
        let report = run_sweep(
            &facts,
            &times,
            &sens,
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        report.proven[0].clone()
    }

    #[test]
    fn rank_tier1_newest_endpoint_first_result_id_ties_unresolved_last() {
        let older = proven_pair("Sarah Chen C0", "d1", "d2");
        let newer = proven_pair("Noor Haddad C1", "d3", "d4");
        let unresolved = proven_pair("Kim Osei C2", "d5", "d6");
        // The MAX endpoint decides: d2 is old but d1 is not — the
        // pair's most recent endpoint event is what "newest" means.
        let events: HashMap<String, i64> = [
            ("d1".to_string(), 2_000),
            ("d2".to_string(), 100),
            ("d3".to_string(), 3_000),
            ("d4".to_string(), 100),
            // d5/d6 absent: no resolvable endpoint → ranks oldest.
        ]
        .into();
        let ranked = rank_and_trim_tier1(
            &[unresolved.clone(), older.clone(), newer.clone()],
            &events,
            10,
        );
        assert_eq!(ranked.len(), 3);
        assert_eq!(ranked[0].result_id.as_deref(), Some(newer.outcome.result_id.as_str()));
        assert_eq!(ranked[1].result_id.as_deref(), Some(older.outcome.result_id.as_str()));
        assert_eq!(
            ranked[2].result_id.as_deref(),
            Some(unresolved.outcome.result_id.as_str())
        );
        // The tier-1 shape: typed fields populated, lexical fields
        // None, ceiling carried through unchanged.
        assert_eq!(ranked[0].tier, ContradictionTier::TypedProven);
        assert_eq!(ranked[0].score, None);
        assert_eq!(ranked[0].cue_kind, None);
        assert_eq!(ranked[0].rule_id.as_deref(), Some(newer.outcome.rule_id.as_str()));
        assert_eq!(
            ranked[0].coordinate_digest.as_deref(),
            Some(newer.outcome.coordinate_digest().as_str())
        );
        assert_eq!(
            ranked[0].sensitivity_ceiling_raw,
            Some(newer.sensitivity_ceiling_raw)
        );

        // Trim respects top_k.
        let trimmed = rank_and_trim_tier1(&[unresolved.clone(), older.clone(), newer.clone()], &events, 1);
        assert_eq!(trimmed.len(), 1);
        assert_eq!(trimmed[0].result_id.as_deref(), Some(newer.outcome.result_id.as_str()));

        // Equal recency: result_id ascending decides, deterministically.
        let flat: HashMap<String, i64> = ["d1", "d2", "d3", "d4", "d5", "d6"]
            .iter()
            .map(|d| (d.to_string(), 500))
            .collect();
        let tied = rank_and_trim_tier1(&[newer, unresolved, older], &flat, 10);
        let ids: Vec<&str> = tied.iter().filter_map(|f| f.result_id.as_deref()).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted);
    }

    #[test]
    fn assembler_promotes_to_highest_tier_and_backfills() {
        let x = typed("aaaa", "bbbb", "r-x");
        let x_as_t3 = lexical(ContradictionTier::LexicalValue, "aaaa", "bbbb", 0.95);
        let y = lexical(ContradictionTier::LexicalValue, "cccc", "dddd", 0.80);
        let z = lexical(ContradictionTier::LexicalValue, "eeee", "ffff", 0.70);

        let assembly = assemble_synthesis(
            vec![x.clone()],
            vec![],
            vec![x_as_t3, y.clone(), z.clone()],
            2,
        );

        // The pair appears ONLY at tier 1.
        assert_eq!(assembly.tier1, vec![x.clone()]);
        assert!(!assembly.tier3.iter().any(|f| f.pair_key == x.pair_key));
        // Tier 3 backfilled to top_k from its over-fetch: z (rank 2,
        // at or beyond top_k=2) moved up into the window.
        assert_eq!(assembly.tier3, vec![y, z]);
        assert_eq!(
            assembly.tier3_counts,
            TierLaneCounts { fetched: 3, returned: 2, promoted_away: 1, backfilled: 1 }
        );
        assert_eq!(
            assembly.tier1_counts,
            TierLaneCounts { fetched: 1, returned: 1, promoted_away: 0, backfilled: 0 }
        );
    }

    #[test]
    fn assembler_tier2_shadows_tier3() {
        let w2 = lexical(ContradictionTier::LexicalStructural, "aaaa", "bbbb", 0.60);
        let w3 = lexical(ContradictionTier::LexicalValue, "aaaa", "bbbb", 0.90);
        let v = lexical(ContradictionTier::LexicalValue, "cccc", "dddd", 0.50);
        let assembly = assemble_synthesis(vec![], vec![w2.clone()], vec![w3, v.clone()], 1);
        assert_eq!(assembly.tier2, vec![w2]);
        assert_eq!(assembly.tier3, vec![v]);
        assert_eq!(assembly.tier3_counts.promoted_away, 1);
        assert_eq!(assembly.tier3_counts.backfilled, 1);
    }

    /// Tier-1 endpoints cased the Swift way (UPPERCASE), tier-3 the
    /// Rust way (lowercase): still the same logical pair, still
    /// promoted. The cross-tier leg of the c95910dff guard.
    #[test]
    fn assembler_promotion_matches_across_case() {
        let upper = typed("AAAA-1111", "BBBB-2222", "r-upper");
        let lower = lexical(ContradictionTier::LexicalValue, "aaaa-1111", "bbbb-2222", 0.9);
        let assembly = assemble_synthesis(vec![upper.clone()], vec![], vec![lower], 5);
        assert_eq!(assembly.tier1, vec![upper]);
        assert!(assembly.tier3.is_empty());
        assert_eq!(assembly.tier3_counts.promoted_away, 1);
    }

    #[test]
    fn assembler_backfill_exhaustion_reports_shorter_section() {
        let x = typed("aaaa", "bbbb", "r-x");
        let x_as_t3 = lexical(ContradictionTier::LexicalValue, "aaaa", "bbbb", 0.95);
        let assembly = assemble_synthesis(vec![x], vec![], vec![x_as_t3], 3);
        assert!(assembly.tier3.is_empty());
        assert_eq!(
            assembly.tier3_counts,
            TierLaneCounts { fetched: 1, returned: 0, promoted_away: 1, backfilled: 0 }
        );
        // Tier 2 was genuinely empty — zero everything, no invention.
        assert_eq!(assembly.tier2_counts, TierLaneCounts::default());
    }

    #[test]
    fn assembler_sections_never_exceed_top_k() {
        let fetched: Vec<TierFinding> = (0..4)
            .map(|i| {
                lexical(
                    ContradictionTier::LexicalStructural,
                    &format!("a{i}"),
                    &format!("b{i}"),
                    0.9 - i as f32 * 0.1,
                )
            })
            .collect();
        let assembly = assemble_synthesis(vec![], fetched.clone(), vec![], 2);
        assert_eq!(assembly.tier2, fetched[..2].to_vec());
        assert_eq!(
            assembly.tier2_counts,
            TierLaneCounts { fetched: 4, returned: 2, promoted_away: 0, backfilled: 0 }
        );
    }

    #[test]
    fn assembler_is_deterministic() {
        let t1 = vec![typed("aaaa", "bbbb", "r-1")];
        let t2 = vec![lexical(ContradictionTier::LexicalStructural, "cccc", "dddd", 0.6)];
        let t3 = vec![
            lexical(ContradictionTier::LexicalValue, "aaaa", "bbbb", 0.9),
            lexical(ContradictionTier::LexicalValue, "eeee", "ffff", 0.5),
        ];
        let first = assemble_synthesis(t1.clone(), t2.clone(), t3.clone(), 2);
        let second = assemble_synthesis(t1, t2, t3, 2);
        assert_eq!(first, second);
    }
}
