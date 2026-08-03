// conflict_projection_sweep.rs — Rust twin of Brain/ConflictProjectionSweep.swift.
//
// DCP M3 — the typed lane's orchestration: project KGFacts (M2), bucket
// them on the coordinate index (M2), evaluate every within-bucket pair
// (M1 evaluator), and return one deterministic report. Retrieval
// proposes; typed constraints prove.
//
// This module is the PURE core: estate reads (all_kg_facts, all_drawers,
// all_tunnels) happen in the coordinator's `conflict_projection_sweep`
// verb seam, which also owns the epoch-millisecond → epoch-second
// conversion (KI-003). No clock, no writes, no tunnel proposals here —
// report rendering is M4, tunnel lifecycle wiring is M5.

use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::kg_fact::KGFact;
use std::collections::{HashMap, HashSet};
use substrate_ml::conflict_projection::{
    evaluate, ConflictOutcome, ConflictOutcomeKind, ConflictRuleRegistry, ConflictSignature,
};

use super::conflict_projection_pass::{
    evidence_locator_for_fact, project, ConflictCoordinateIndex, ConflictProjectionDiagnostics,
    DEFAULT_BUCKET_CAP,
};

/// One proven-or-notable finding with the redaction input M4 needs: the
/// MAX sensitivity across both endpoints, counting each endpoint's own
/// KGFact as well as the drawer it was extracted from (M0 §8 — the report
/// ceiling is the max of sources; rendering applies grants).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictFinding {
    pub outcome: ConflictOutcome,
    /// Raw adjective-sensitivity of the most sensitive input to the pair:
    /// either endpoint's KGFact or either endpoint's source drawer. A
    /// fact carries its own sensitivity axis, independent of the drawer
    /// it came from, so a Restricted fact filed against a Normal drawer
    /// redacts the finding here. Any input whose sensitivity could not be
    /// resolved counts as the MAXIMUM tier (`Secret`), never as normal —
    /// see `run_sweep`'s `ceiling` closure for why this direction is the
    /// safe one.
    pub sensitivity_ceiling_raw: i64,
}

/// Outcome tallies for the report's additive lines (M0 §7).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConflictSweepCounts {
    pub agreement: usize,
    pub compatible_plurality: usize,
    pub historical_succession: usize,
    pub proven_contradiction: usize,
    pub candidate_review: usize,
    /// InvalidInput + Irrelevant — pairs the typed lane could not judge
    /// (report line `unknown_or_invalid` together with unparsed facts).
    pub unknown_or_invalid: usize,
}

/// One sweep's outcome. Deterministic for a given estate state.
#[derive(Debug, Clone)]
pub struct ConflictProjectionSweepReport {
    /// Projection exclusion counts (`coverage: projected/scanned`).
    pub diagnostics: ConflictProjectionDiagnostics,
    /// Coordinate buckets that hit the cap (report line only when > 0).
    pub truncated_buckets: usize,
    /// Within-bucket pairs evaluated this sweep.
    pub pairs_evaluated: usize,
    pub counts: ConflictSweepCounts,
    /// Full detail for ProvenContradiction findings — the block M4
    /// renders (result id, rule, coordinate, reasons, source ids).
    pub proven: Vec<ConflictFinding>,
    /// Full detail for HistoricalSuccession findings — the "superseded,
    /// not conflicting" ledger.
    pub historical: Vec<ConflictFinding>,
}

/// Canonical unordered pair key — mirrors GLK `pairKey` (smaller ID first).
pub fn pair_key(a: &str, b: &str) -> String {
    if a < b {
        format!("{a}||{b}")
    } else {
        format!("{b}||{a}")
    }
}

/// Run projection + index + evaluation. Pure on its inputs; the caller
/// supplies event times in EPOCH SECONDS and the accepted-supersession
/// pair-key set (ACTIVE `supersedes` tunnels between source drawers).
///
/// `sensitivity_raw_by_source_drawer` is ONE of the two axes of the
/// per-finding redaction ceiling. The other axis, each fact's own
/// sensitivity, is read straight off `facts` and needs no parameter (see
/// the locator map built below).
pub fn run_sweep(
    facts: &[KGFact],
    event_time_seconds_by_source_drawer: &HashMap<String, i64>,
    sensitivity_raw_by_source_drawer: &HashMap<String, i64>,
    accepted_supersession_pairs: &HashSet<String>,
    registry: &ConflictRuleRegistry,
    bucket_cap: usize,
) -> ConflictProjectionSweepReport {
    let projection = project(facts, event_time_seconds_by_source_drawer, registry);
    let mut index = ConflictCoordinateIndex::new(bucket_cap);
    index.insert_all(projection.signatures);

    // Each fact's OWN adjective sensitivity, keyed by the evidence locator
    // its signature carries. A KGFact has a sensitivity axis independent
    // of the drawer it was extracted from, so a Restricted fact filed
    // against a Normal drawer must still raise the finding's ceiling.
    //
    // Keyed PER FACT, never folded into the drawer map. Several facts
    // routinely share one source drawer, and facts filed with no source
    // share the key "" — a drawer-keyed fold would push one sensitive
    // fact's tier onto every unrelated Normal fact behind the same key.
    // That over-redaction is not the safe direction: it silently guts the
    // contradiction surface this lane exists to provide, and nothing
    // surfaces the loss.
    //
    // Derived from `facts` rather than taken as a parameter so the map is
    // complete by construction — every signature in the index was
    // projected from this same slice. A caller cannot hand in a stale or
    // partial map and blank the whole surface through the fail-closed
    // default below.
    let mut sensitivity_raw_by_evidence_locator: HashMap<String, i64> = HashMap::new();
    for fact in facts {
        let locator = evidence_locator_for_fact(&fact.id);
        let raw = fact.adjective_sensitivity().raw_value();
        // Fold duplicates with MAX. Fact ids are unique in the kg_facts
        // table, but `run_sweep` is public and takes an arbitrary slice;
        // on a repeated id the more sensitive reading wins.
        sensitivity_raw_by_evidence_locator
            .entry(locator)
            .and_modify(|existing| *existing = (*existing).max(raw))
            .or_insert(raw);
    }

    let mut counts = ConflictSweepCounts::default();
    let mut proven: Vec<ConflictFinding> = Vec::new();
    let mut historical: Vec<ConflictFinding> = Vec::new();
    let pairs = index.pairs();

    for (a, b) in &pairs {
        let accepted = accepted_supersession_pairs
            .contains(&pair_key(&a.source_drawer_id, &b.source_drawer_id));
        let outcome = evaluate(a, b, registry, accepted);
        // The finding's redaction ceiling: the MAX over four inputs —
        // each endpoint's own KGFact sensitivity and each endpoint's
        // source drawer sensitivity. The two axes are independent; a pair
        // discloses through whichever of them is the more sensitive.
        let ceiling = || -> i64 {
            // Fail closed. ANY of the four inputs that cannot be resolved
            // counts as the MAXIMUM tier, never as Normal: a hydration
            // gap — or a signature carrying no evidence locator — is not
            // evidence of low sensitivity, and the Elevated ceiling the
            // proposal loop enforces
            // (coordinator::propose_conflict_tunnels) must not be
            // passable by a failed lookup.
            //
            // Secret — a real tier — rather than a sentinel like
            // i64::MAX, because this field is documented as a raw
            // AdjectiveSensitivity value and `from_raw` coerces
            // beyond-spec raws back to Normal. Parking an out-of-range
            // value here would re-open the fail-open hole for any future
            // caller that decodes before comparing.
            let unresolved = AdjectiveSensitivity::Secret.raw_value();
            let fact_raw = |s: &ConflictSignature| -> i64 {
                s.evidence_locator
                    .as_deref()
                    .and_then(|locator| {
                        sensitivity_raw_by_evidence_locator.get(locator).copied()
                    })
                    .unwrap_or(unresolved)
            };
            let ra = sensitivity_raw_by_source_drawer
                .get(&a.source_drawer_id)
                .copied()
                .unwrap_or(unresolved);
            let rb = sensitivity_raw_by_source_drawer
                .get(&b.source_drawer_id)
                .copied()
                .unwrap_or(unresolved);
            fact_raw(a).max(fact_raw(b)).max(ra).max(rb)
        };
        match outcome.kind {
            ConflictOutcomeKind::Agreement => counts.agreement += 1,
            ConflictOutcomeKind::CompatiblePlurality => counts.compatible_plurality += 1,
            ConflictOutcomeKind::HistoricalSuccession => {
                counts.historical_succession += 1;
                historical.push(ConflictFinding {
                    sensitivity_ceiling_raw: ceiling(),
                    outcome,
                });
            }
            ConflictOutcomeKind::ProvenContradiction => {
                counts.proven_contradiction += 1;
                proven.push(ConflictFinding {
                    sensitivity_ceiling_raw: ceiling(),
                    outcome,
                });
            }
            ConflictOutcomeKind::CandidateReview => counts.candidate_review += 1,
            ConflictOutcomeKind::InvalidInput | ConflictOutcomeKind::Irrelevant => {
                counts.unknown_or_invalid += 1
            }
        }
    }
    ConflictProjectionSweepReport {
        diagnostics: projection.diagnostics,
        truncated_buckets: index.truncated_buckets(),
        pairs_evaluated: pairs.len(),
        counts,
        proven,
        historical,
    }
}

/// One M5 pass's outcome (typed proposals). Mirrors Swift
/// `ConflictTunnelProposalReport`.
#[derive(Debug, Clone)]
pub struct ConflictTunnelProposalReport {
    /// The sweep the proposals were derived from.
    pub sweep: ConflictProjectionSweepReport,
    /// Tunnel ids proposed THIS pass, in sweep order.
    pub proposed_tunnel_ids: Vec<String>,
    /// Proven findings suppressed by the dedup contract.
    pub suppressed: usize,
    /// Proven findings skipped because their sensitivity ceiling exceeds
    /// Elevated. Counted apart from `suppressed`: "already on the books"
    /// and "above the ceiling" are different facts, and folding the
    /// second into the first would hide the gate's activity from anyone
    /// reading the report — including from whoever has to notice it has
    /// regressed.
    pub ceiling_skipped: usize,
}

/// Default bucket cap re-export for the coordinator seam.
pub const SWEEP_DEFAULT_BUCKET_CAP: usize = DEFAULT_BUCKET_CAP;

// DCP M3 tests — Rust leg. Mirrors ConflictProjectionSweepTests.swift:
// F06 (accepted supersession → HistoricalSuccession), planted-shape
// proven counting, F20 at the sweep level (fact order cannot change
// result identities), the sensitivity ceiling carry on both axes, and
// the per-fact keying that keeps one sensitive fact from redacting its
// drawer-mates.
#[cfg(test)]
mod tests {
    use super::*;

    fn fact(id: &str, subject: &str, object: &str, source: &str) -> KGFact {
        KGFact::new(
            id.into(),
            subject.into(),
            "Employer".into(),
            object.into(),
            source.into(),
            // Epoch milliseconds (the LocusKit Rust clock).
            1_700_000_000_000,
        )
    }

    fn seconds(entries: &[(&str, i64)]) -> HashMap<String, i64> {
        entries.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    /// Planted shape: same coordinate, different enum values, same event
    /// time → proven: 1 with full finding detail.
    #[test]
    fn planted_shape_is_proven() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
        ];
        let report = run_sweep(
            &facts,
            &seconds(&[("d1", 500), ("d2", 500)]),
            // Real tiers, not arbitrary integers: only a defined tier
            // exercises the ceiling the proposal loop compares against.
            &seconds(&[
                ("d1", AdjectiveSensitivity::Normal.raw_value()),
                ("d2", AdjectiveSensitivity::Restricted.raw_value()),
            ]),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.pairs_evaluated, 1);
        assert_eq!(report.counts.proven_contradiction, 1);
        assert_eq!(report.proven.len(), 1);
        let finding = &report.proven[0];
        assert_eq!(finding.outcome.kind, ConflictOutcomeKind::ProvenContradiction);
        // Ceiling is the MAX over both axes of both endpoints. These
        // facts carry no adjective bitmap, so both read Normal and the
        // more sensitive DRAWER — d2's restricted tier — is what wins.
        assert_eq!(
            finding.sensitivity_ceiling_raw,
            AdjectiveSensitivity::Restricted.raw_value()
        );
        // And that is above the ceiling the proposal loop enforces, so
        // this finding is provable but not proposable.
        assert!(finding.sensitivity_ceiling_raw > AdjectiveSensitivity::Elevated.raw_value());
        assert_eq!(
            finding.outcome.source_drawer_ids,
            vec!["d1".to_string(), "d2".to_string()]
        );
    }

    /// F06 — an accepted supersedes tunnel between the source drawers
    /// converts the same pair to HistoricalSuccession.
    #[test]
    fn f06_accepted_supersession_is_historical() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
        ];
        let mut accepted = HashSet::new();
        accepted.insert(pair_key("d2", "d1")); // insertion order must not matter
        let report = run_sweep(
            &facts,
            &seconds(&[("d1", 500), ("d2", 500)]),
            &HashMap::new(),
            &accepted,
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.counts.proven_contradiction, 0);
        assert_eq!(report.counts.historical_succession, 1);
        assert_eq!(report.historical.len(), 1);
        assert_eq!(
            report.historical[0].outcome.kind,
            ConflictOutcomeKind::HistoricalSuccession
        );
    }

    /// F20 at sweep level — reversing fact order changes nothing about
    /// the result identities.
    #[test]
    fn f20_fact_order_cannot_change_result_ids() {
        let a = fact("f1", "Sarah Chen C0", "Acme Robotics", "d1");
        let b = fact("f2", "Sarah Chen C0", "Beta Corp", "d2");
        let times = seconds(&[("d1", 500), ("d2", 500)]);
        let reg = ConflictRuleRegistry::v01();
        let fwd = run_sweep(
            &[a.clone(), b.clone()],
            &times,
            &HashMap::new(),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        let rev = run_sweep(
            &[b, a],
            &times,
            &HashMap::new(),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(fwd.proven.len(), 1);
        assert_eq!(rev.proven.len(), 1);
        assert_eq!(fwd.proven[0].outcome.result_id, rev.proven[0].outcome.result_id);
    }

    /// Trap 2 — an endpoint whose sensitivity could not be resolved yields
    /// the MAXIMUM ceiling, not Normal. That is the value the proposal gate
    /// reads, so a hydration gap can no longer produce a proposal for a row
    /// of unknown sensitivity.
    ///
    /// Asserted at the pure core rather than end-to-end on purpose: in the
    /// coordinator seam a drawer that fails to hydrate also fails the
    /// proposal loop's endpoint-resolution guard, so an end-to-end test
    /// would pass for the wrong reason and could not distinguish a
    /// fail-closed ceiling from a fail-open one.
    #[test]
    fn unresolved_endpoint_sensitivity_fails_closed() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
        ];
        let times = seconds(&[("d1", 500), ("d2", 500)]);
        let reg = ConflictRuleRegistry::v01();
        let secret_raw = AdjectiveSensitivity::Secret.raw_value();

        // Neither endpoint resolvable.
        let both = run_sweep(
            &facts,
            &times,
            &HashMap::new(),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(both.proven.len(), 1);
        assert_eq!(both.proven[0].sensitivity_ceiling_raw, secret_raw);

        // One resolvable NORMAL endpoint must not pull the ceiling down —
        // the unresolved side still dominates the MAX.
        let one = run_sweep(
            &facts,
            &times,
            &seconds(&[("d1", AdjectiveSensitivity::Normal.raw_value())]),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(one.proven[0].sensitivity_ceiling_raw, secret_raw);
        assert!(one.proven[0].sensitivity_ceiling_raw > AdjectiveSensitivity::Elevated.raw_value());
    }

    // MARK: - Per-fact sensitivity ceiling

    /// A fact carrying `sensitivity` on its own adjective axis.
    ///
    /// Sensitivity lives at bits 6–11 of `adjective_bitmap` (cookbook
    /// §2.3, the same layout `Drawer` uses). LocusKit publishes the
    /// decoder (`KGFact::adjective_sensitivity`) but no encoder, so the
    /// shift is written out here rather than hidden behind a local helper
    /// that would silently rot if the field ever moved. Every test below
    /// asserts the round-trip before relying on it.
    fn sensitive_fact(
        id: &str,
        subject: &str,
        object: &str,
        source: &str,
        sensitivity: AdjectiveSensitivity,
    ) -> KGFact {
        let mut f = fact(id, subject, object, source);
        f.adjective_bitmap = sensitivity.raw_value() << 6;
        f
    }

    /// Both source drawers at the Normal tier — the setup every test in
    /// this section shares, so the only sensitivity in play is the facts'
    /// own.
    fn normal_drawers() -> HashMap<String, i64> {
        seconds(&[
            ("d1", AdjectiveSensitivity::Normal.raw_value()),
            ("d2", AdjectiveSensitivity::Normal.raw_value()),
        ])
    }

    /// The regression case. A RESTRICTED fact anchored to a NORMAL
    /// drawer: before the ceiling counted each fact's own axis this
    /// finding came back at raw 0 and the renderer emitted the whole
    /// PROVEN block — result id, rule, coordinate, value digests,
    /// temporal bases, reasons and dense source rows — for a claim the
    /// legacy contradiction view in the same response had already
    /// filtered out on the fact's own tier.
    ///
    /// The renderer's thresholds are asserted here as inequalities rather
    /// than by calling it: AriaMcpKit sits above this kit and cannot be
    /// reached from these tests. The two predicates mirror
    /// `recipe_tools.rs:186` (`>= secret_raw` → drop the finding) and
    /// `:190` (`>= restricted_raw` → coordinate digest only), and their
    /// Swift twins at `RecipeTools.swift:985,987`.
    #[test]
    fn restricted_fact_on_normal_drawer_raises_ceiling() {
        let restricted = sensitive_fact(
            "f1",
            "Sarah Chen C0",
            "Acme Robotics",
            "d1",
            AdjectiveSensitivity::Restricted,
        );
        // Guard the bitmap encoding this fixture depends on.
        assert_eq!(
            restricted.adjective_sensitivity(),
            AdjectiveSensitivity::Restricted
        );

        let report = run_sweep(
            &[restricted, fact("f2", "Sarah Chen C0", "Beta Corp", "d2")],
            &seconds(&[("d1", 500), ("d2", 500)]),
            &normal_drawers(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );

        assert_eq!(report.counts.proven_contradiction, 1);
        let finding = &report.proven[0];
        assert_eq!(
            finding.sensitivity_ceiling_raw,
            AdjectiveSensitivity::Restricted.raw_value()
        );
        // Renders as a coordinate digest, not the full PROVEN block…
        assert!(
            finding.sensitivity_ceiling_raw >= AdjectiveSensitivity::Restricted.raw_value()
        );
        // …and is not suppressed outright — the restricted tier exists so
        // a sensitive conflict can still be signalled without disclosure.
        assert!(finding.sensitivity_ceiling_raw < AdjectiveSensitivity::Secret.raw_value());
    }

    /// A SECRET fact on a Normal drawer takes the finding past the
    /// renderer's suppression threshold entirely (`recipe_tools.rs:186`,
    /// `RecipeTools.swift:985`): no line is emitted at all, not even the
    /// coordinate digest.
    #[test]
    fn secret_fact_on_normal_drawer_suppresses_the_finding() {
        let secret = sensitive_fact(
            "f1",
            "Sarah Chen C0",
            "Acme Robotics",
            "d1",
            AdjectiveSensitivity::Secret,
        );
        assert_eq!(secret.adjective_sensitivity(), AdjectiveSensitivity::Secret);

        let report = run_sweep(
            &[secret, fact("f2", "Sarah Chen C0", "Beta Corp", "d2")],
            &seconds(&[("d1", 500), ("d2", 500)]),
            &normal_drawers(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );

        assert_eq!(report.counts.proven_contradiction, 1);
        assert!(
            report.proven[0].sensitivity_ceiling_raw
                >= AdjectiveSensitivity::Secret.raw_value()
        );
    }

    /// The finding is carried, never dropped. A sensitive fact still
    /// projects, still pairs, and still proves — only its disclosure is
    /// reduced. Filtering sensitive facts out ahead of projection (the
    /// legacy view's approach) would remove them from contradiction
    /// detection altogether and leave the renderer's restricted tier with
    /// nothing to render.
    #[test]
    fn sensitive_fact_still_proves_and_is_counted() {
        let report = run_sweep(
            &[
                sensitive_fact(
                    "f1",
                    "Sarah Chen C0",
                    "Acme Robotics",
                    "d1",
                    AdjectiveSensitivity::Secret,
                ),
                fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            &seconds(&[("d1", 500), ("d2", 500)]),
            &normal_drawers(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.diagnostics.projected, 2);
        assert_eq!(report.pairs_evaluated, 1);
        assert_eq!(report.proven.len(), 1);
    }

    /// No over-redaction. `f1` and `f2` are Normal facts that prove
    /// against each other; `f3` is a Restricted fact on an unrelated
    /// coordinate that happens to share `f1`'s source drawer. The finding
    /// must still render in full.
    ///
    /// This is the case that fails the rejected mechanism. Folding each
    /// fact's tier into the DRAWER-keyed map with `max` would leave `d1`
    /// holding Restricted — inherited from `f3` — and the unrelated
    /// `f1`/`f2` finding would collapse to a coordinate digest. Nobody
    /// would see that happen: over-redaction raises no error, it just
    /// quietly empties the surface the typed lane exists to fill.
    #[test]
    fn unrelated_normal_facts_sharing_a_drawer_are_not_over_redacted() {
        let poisoner = sensitive_fact(
            "f3",
            "Noor Haddad C1",
            "Vireo Systems",
            "d1",
            AdjectiveSensitivity::Restricted,
        );
        assert_eq!(
            poisoner.adjective_sensitivity(),
            AdjectiveSensitivity::Restricted
        );

        let report = run_sweep(
            &[
                fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
                // Same source drawer as f1, different coordinate — so it
                // never pairs, and its only possible influence is through
                // a shared map key.
                poisoner,
            ],
            &seconds(&[("d1", 500), ("d2", 500)]),
            &normal_drawers(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );

        assert_eq!(report.counts.proven_contradiction, 1);
        let finding = &report.proven[0];
        assert_eq!(
            finding.sensitivity_ceiling_raw,
            AdjectiveSensitivity::Normal.raw_value()
        );
        // Below the digest threshold → the full PROVEN block renders.
        assert!(
            finding.sensitivity_ceiling_raw < AdjectiveSensitivity::Restricted.raw_value()
        );
    }

    /// Sourceless facts get their own ceiling slot and cannot contaminate
    /// anything else.
    ///
    /// Facts filed with no source drawer id all share the drawer key `""`.
    /// That shared key is the second reason the drawer-keyed fold was
    /// rejected: folding fact tiers into a drawer-keyed map would store
    /// one Secret sourceless fact's tier under `""` and hand it to every
    /// other sourceless fact in the estate. Keying on the evidence
    /// locator gives each fact a slot of its own regardless of source.
    ///
    /// Two facts about the terrain are asserted together here so a later
    /// reader does not mistake the second for a bug and "fix" it:
    ///
    /// 1. A pair with an empty `source_drawer_id` on either side is
    ///    InvalidInput at the evaluator (SubstrateML
    ///    `conflict_projection.rs:579-580`). It never becomes a finding,
    ///    so it never reaches a ceiling — which means the `""` collision
    ///    cannot surface through a finding as the code stands. The
    ///    per-fact keying is what guarantees it still could not if that
    ///    guard were ever relaxed.
    /// 2. A sourceless Secret fact sharing a sweep with an unrelated
    ///    sourced pair leaves that pair's ceiling at Normal.
    ///
    /// The discriminating test against the rejected fold is
    /// `unrelated_normal_facts_sharing_a_drawer_are_not_over_redacted`;
    /// this one pins the sourceless corner of the same contract.
    #[test]
    fn sourceless_facts_get_their_own_ceiling_slot() {
        let report = run_sweep(
            &[
                // An ordinary sourced pair, both Normal.
                fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
                // A SECRET sourceless fact, and a sourced claim on the
                // same coordinate so the two actually pair.
                sensitive_fact(
                    "f3",
                    "Noor Haddad C1",
                    "Vireo Systems",
                    "",
                    AdjectiveSensitivity::Secret,
                ),
                fact("f4", "Noor Haddad C1", "Beta Corp", "d2"),
            ],
            &seconds(&[("", 500), ("d1", 500), ("d2", 500)]),
            &normal_drawers(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );

        assert_eq!(report.pairs_evaluated, 2);
        // (1) The sourceless pair is judged InvalidInput, never a finding.
        assert_eq!(report.counts.unknown_or_invalid, 1);
        // (2) The unrelated sourced pair keeps its Normal ceiling.
        assert_eq!(report.counts.proven_contradiction, 1);
        assert_eq!(
            report.proven[0].sensitivity_ceiling_raw,
            AdjectiveSensitivity::Normal.raw_value()
        );
    }

    /// The two axes are symmetric and independent. A Restricted DRAWER
    /// under a Normal fact still yields a Restricted ceiling — the
    /// behaviour that existed before this change is intact — and a
    /// Restricted FACT under a Normal drawer now yields the same ceiling.
    /// Neither axis can be satisfied by the other.
    #[test]
    fn drawer_axis_and_fact_axis_are_symmetric() {
        let restricted_raw = AdjectiveSensitivity::Restricted.raw_value();
        let times = seconds(&[("d1", 500), ("d2", 500)]);
        let reg = ConflictRuleRegistry::v01();

        // Restricted DRAWER, Normal facts.
        let by_drawer = run_sweep(
            &[
                fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
            ],
            &times,
            &seconds(&[
                ("d1", AdjectiveSensitivity::Normal.raw_value()),
                ("d2", restricted_raw),
            ]),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(by_drawer.proven[0].sensitivity_ceiling_raw, restricted_raw);

        // Restricted FACT, Normal drawers.
        let by_fact = run_sweep(
            &[
                fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
                sensitive_fact(
                    "f2",
                    "Sarah Chen C0",
                    "Beta Corp",
                    "d2",
                    AdjectiveSensitivity::Restricted,
                ),
            ],
            &times,
            &normal_drawers(),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(by_fact.proven[0].sensitivity_ceiling_raw, restricted_raw);
    }

    /// Mixed outcomes tally into the additive count lines; agreement and
    /// unknown-vs-known review are counted, not detailed.
    #[test]
    fn mixed_outcomes_tally() {
        let facts = vec![
            // Agreement pair (same value, different drawers).
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Acme Robotics", "d2"),
            // Candidate-review pair (known vs unknown validity).
            fact("f3", "Noor Haddad C1", "Beta Corp", "d3"),
            fact("f4", "Noor Haddad C1", "Vireo Systems", "d4"),
        ];
        let report = run_sweep(
            &facts,
            // d4 has no event time → unknown validity → review.
            &seconds(&[("d1", 500), ("d2", 500), ("d3", 500)]),
            &HashMap::new(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.pairs_evaluated, 2);
        assert_eq!(report.counts.agreement, 1);
        assert_eq!(report.counts.candidate_review, 1);
        assert_eq!(report.counts.proven_contradiction, 0);
        assert!(report.proven.is_empty());
    }
}
