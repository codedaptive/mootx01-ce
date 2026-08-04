//! DCP M1 golden corpus — Rust leg. The hardcoded literals here are the
//! CROSS-PORT FIXTURE: `ConflictProjectionGoldenTests.swift` asserts the
//! byte-identical strings from the same inputs, so the two ports cannot
//! silently diverge in canonical values, outcome classes, reason codes,
//! or stable identities. Ledger cases (SUBSTRATEML_SPEC § 5.29): F01–F05,
//! F07–F10, F17, F20.

use substrate_ml::conflict_projection::*;

const TX: i64 = 1_700_000_000;

fn sig(
    key: &str,
    dim: &str,
    value: TypedConflictValue,
    src: &str,
    validity: TemporalBasis,
    rule_id: &str,
) -> ConflictSignature {
    ConflictSignature {
        key: key.to_string(),
        dimension: dim.to_string(),
        value,
        source_drawer_id: src.to_string(),
        transaction_time: TX,
        validity,
        status: ConflictClaimStatus::Asserted,
        rule_id: rule_id.to_string(),
        rule_version: 1,
        extractor_id: None,
        evidence_locator: None,
    }
}

fn employer_pair() -> (ConflictSignature, ConflictSignature) {
    (
        sig(
            "person:sarah chen c0",
            "employer",
            normalize::employer("Acme Robotics").unwrap(),
            "drawer-a",
            TemporalBasis::Unknown,
            "dim.person.employer",
        ),
        sig(
            "person:sarah chen c0",
            "employer",
            normalize::employer("Beta Corp").unwrap(),
            "drawer-b",
            TemporalBasis::Unknown,
            "dim.person.employer",
        ),
    )
}

/// Golden identity literals (generated once, pinned in both ports).
#[test]
fn golden_stable_identities() {
    let (a, b) = employer_pair();
    assert_eq!(
        a.stable_id(),
        "d8cdc5118b6c55e03f62865f41d492651c6b4ce1c901c604d3f3d85899827950"
    );
    assert_eq!(
        b.stable_id(),
        "f5a34a5d6bc457c026373d07da6bc4b9b1e6b23f9fe5fa2306ce10fe0333475f"
    );
}

/// F03 — genuinely different values → ProvenContradiction, and
/// F20 — pair order can never change the result identity.
#[test]
fn f03_f20_planted_contradiction_and_pair_order_invariance() {
    let reg = ConflictRuleRegistry::v01();
    let (a, b) = employer_pair();
    let fwd = evaluate(&a, &b, &reg, false);
    let rev = evaluate(&b, &a, &reg, false);
    assert_eq!(fwd.kind, ConflictOutcomeKind::ProvenContradiction);
    assert_eq!(
        fwd.result_id,
        "c29f4790ef9f84f0846252d21768cdd64bc82ded5cf1867b11e29514a0b38212"
    );
    assert_eq!(rev.result_id, fwd.result_id);
    assert_eq!(rev.kind, fwd.kind);
    assert_eq!(fwd.source_drawer_ids, vec!["drawer-a", "drawer-b"]);
    let codes: Vec<&str> = fwd.reasons.iter().map(|r| r.as_str()).collect();
    assert_eq!(codes, vec!["same_coordinate", "validity_unknown", "values_exclusive"]);
}

/// F01 — identical decision, different wording → Agreement.
#[test]
fn f01_wording_variants_agree() {
    let reg = ConflictRuleRegistry::v01();
    let a = sig("person:x", "employer", normalize::employer("  acme   ROBOTICS ").unwrap(),
        "d1", TemporalBasis::Unknown, "dim.person.employer");
    let b = sig("person:x", "employer", normalize::employer("Acme Robotics").unwrap(),
        "d2", TemporalBasis::Unknown, "dim.person.employer");
    assert_eq!(a.value.canonical_bytes(), "e:dim.person.employer#acme robotics");
    let out = evaluate(&a, &b, &reg, false);
    assert_eq!(out.kind, ConflictOutcomeKind::Agreement);
    let codes: Vec<&str> = out.reasons.iter().map(|r| r.as_str()).collect();
    assert_eq!(codes, vec!["same_coordinate", "value_equivalent"]);
}

/// F02 — equivalent units agree exactly (1h == 60min == dur:3600), and
/// budget normalization folds k/m suffixes ($1.5m == 1,500k USD).
#[test]
fn f02_equivalent_units_agree() {
    assert_eq!(normalize::duration("1h").unwrap().canonical_bytes(), "dur:3600");
    assert_eq!(normalize::duration("60 min").unwrap().canonical_bytes(), "dur:3600");
    assert_eq!(
        normalize::budget_ceiling("1,500k USD").unwrap().canonical_bytes(),
        "d:1500000"
    );
    assert_eq!(
        normalize::budget_ceiling("$1.5m").unwrap().canonical_bytes(),
        "d:1500000"
    );
    assert_eq!(normalize::budget_ceiling("12.50").unwrap().canonical_bytes(), "d:12.5");
    let reg = ConflictRuleRegistry::v01();
    let a = sig("decision:phoenix", "decision:budget_ceiling",
        normalize::budget_ceiling("1,500k USD").unwrap(), "d1",
        TemporalBasis::Point { epoch_seconds: 100 }, "dim.decision.budget_ceiling");
    let b = sig("decision:phoenix", "decision:budget_ceiling",
        normalize::budget_ceiling("$1.5m").unwrap(), "d2",
        TemporalBasis::Point { epoch_seconds: 100 }, "dim.decision.budget_ceiling");
    assert_eq!(evaluate(&a, &b, &reg, false).kind, ConflictOutcomeKind::Agreement);
}

/// F04 — true vs false for the same proposition → ProvenContradiction.
#[test]
fn f04_boolean_opposition_contradicts() {
    // Boolean values through an unregistered dimension would be
    // rule_unknown; pin the VALUE layer here (registry-level boolean
    // rules arrive with a real boolean dimension) plus the evaluator
    // over a single-valued registered dimension using dates.
    assert_eq!(TypedConflictValue::Boolean(true).canonical_bytes(), "b:true");
    assert_eq!(TypedConflictValue::Boolean(false).canonical_bytes(), "b:false");
    assert!(!TypedConflictValue::Boolean(true)
        .is_equivalent(&TypedConflictValue::Boolean(false)));
    let reg = ConflictRuleRegistry::v01();
    let a = sig("decision:phoenix", "decision:launch_date",
        normalize::launch_date("2026-09-15").unwrap(), "d1",
        TemporalBasis::Unknown, "dim.decision.launch_date");
    let b = sig("decision:phoenix", "decision:launch_date",
        normalize::launch_date("2026-10-01").unwrap(), "d2",
        TemporalBasis::Unknown, "dim.decision.launch_date");
    assert_eq!(a.value.canonical_bytes(), "dt:2026-09-15");
    assert_eq!(evaluate(&a, &b, &reg, false).kind, ConflictOutcomeKind::ProvenContradiction);
}

/// F05 — same dimension, different scopes → Irrelevant (scope_mismatch).
#[test]
fn f05_distinct_scopes_are_irrelevant() {
    let reg = ConflictRuleRegistry::v01();
    let a = sig("org:acme/project:phoenix/release", "decision:launch_date",
        normalize::launch_date("2026-09-15").unwrap(), "d1",
        TemporalBasis::Unknown, "dim.decision.launch_date");
    let b = sig("org:acme/project:altair/release", "decision:launch_date",
        normalize::launch_date("2026-10-01").unwrap(), "d2",
        TemporalBasis::Unknown, "dim.decision.launch_date");
    let out = evaluate(&a, &b, &reg, false);
    assert_eq!(out.kind, ConflictOutcomeKind::Irrelevant);
    let codes: Vec<&str> = out.reasons.iter().map(|r| r.as_str()).collect();
    assert_eq!(codes, vec!["scope_mismatch"]);
}

/// F07 — overlapping validity remains contradictory; disjoint validity
/// is HistoricalSuccession, not contradiction.
#[test]
fn f07_validity_overlap_vs_disjoint() {
    let reg = ConflictRuleRegistry::v01();
    let mk = |src: &str, v: TemporalBasis, city: &str| {
        sig("person:x", "city", normalize::city(city).unwrap(), src, v, "dim.person.city")
    };
    let overlap = evaluate(
        &mk("d1", TemporalBasis::Interval { from: 0, to: 100 }, "Lisbon"),
        &mk("d2", TemporalBasis::Interval { from: 50, to: 150 }, "Osaka"),
        &reg, false);
    assert_eq!(overlap.kind, ConflictOutcomeKind::ProvenContradiction);
    let codes: Vec<&str> = overlap.reasons.iter().map(|r| r.as_str()).collect();
    assert_eq!(codes, vec!["same_coordinate", "validity_overlap", "values_exclusive"]);

    let disjoint = evaluate(
        &mk("d1", TemporalBasis::Interval { from: 0, to: 40 }, "Lisbon"),
        &mk("d2", TemporalBasis::Interval { from: 50, to: 150 }, "Osaka"),
        &reg, false);
    assert_eq!(disjoint.kind, ConflictOutcomeKind::HistoricalSuccession);

    // Accepted supersession converts even overlap into succession.
    let superseded = evaluate(
        &mk("d1", TemporalBasis::Interval { from: 0, to: 100 }, "Lisbon"),
        &mk("d2", TemporalBasis::Interval { from: 50, to: 150 }, "Osaka"),
        &reg, true);
    assert_eq!(superseded.kind, ConflictOutcomeKind::HistoricalSuccession);
    assert!(superseded.reasons.contains(&ConflictReason::AcceptedSupersession));
}

/// F08 — multi-valued dimensions never contradict.
#[test]
fn f08_multi_valued_compatible() {
    let reg = ConflictRuleRegistry::new(vec![ConflictRule {
        rule_id: "dim.test.tags",
        version: 1,
        dimension: "tags",
        cardinality: ConflictCardinality::Set,
        normalize: |raw| Some(TypedConflictValue::NormalizedString(normalize::collapse(raw))),
    }]);
    let a = sig("project:x", "tags", TypedConflictValue::NormalizedString("alpha".into()),
        "d1", TemporalBasis::Unknown, "dim.test.tags");
    let b = sig("project:x", "tags", TypedConflictValue::NormalizedString("beta".into()),
        "d2", TemporalBasis::Unknown, "dim.test.tags");
    let out = evaluate(&a, &b, &reg, false);
    assert_eq!(out.kind, ConflictOutcomeKind::CompatiblePlurality);
    assert!(out.reasons.contains(&ConflictReason::CardinalityMulti));
}

/// F09 — unknown rule/cardinality → CandidateReview, never proof.
#[test]
fn f09_unknown_rule_is_review_only() {
    let reg = ConflictRuleRegistry::v01();
    let a = sig("person:x", "favorite color",
        TypedConflictValue::NormalizedString("red".into()), "d1",
        TemporalBasis::Unknown, UNKNOWN_RULE_ID);
    let b = sig("person:x", "favorite color",
        TypedConflictValue::NormalizedString("blue".into()), "d2",
        TemporalBasis::Unknown, UNKNOWN_RULE_ID);
    let out = evaluate(&a, &b, &reg, false);
    assert_eq!(out.kind, ConflictOutcomeKind::CandidateReview);
    assert!(out.reasons.contains(&ConflictReason::RuleUnknown));
}

/// F10 — ambiguous date is unparseable; unknown-vs-known validity is
/// review, never proof.
#[test]
fn f10_ambiguity_stays_unknown() {
    assert!(normalize::launch_date("03/04/26").is_none());
    assert!(normalize::launch_date("2026-9-15").is_none());
    let reg = ConflictRuleRegistry::v01();
    let a = sig("person:x", "city", normalize::city("Lisbon").unwrap(), "d1",
        TemporalBasis::Point { epoch_seconds: 100 }, "dim.person.city");
    let b = sig("person:x", "city", normalize::city("Osaka").unwrap(), "d2",
        TemporalBasis::Unknown, "dim.person.city");
    let out = evaluate(&a, &b, &reg, false);
    assert_eq!(out.kind, ConflictOutcomeKind::CandidateReview);
    assert!(out.reasons.contains(&ConflictReason::ValidityUnknown));
}

/// F17 — malformed inputs are InvalidInput, and withdrawn/rejected
/// standing never evaluates.
#[test]
fn f17_malformed_and_withdrawn_are_invalid() {
    let reg = ConflictRuleRegistry::v01();
    let (mut a, b) = employer_pair();
    a.validity = TemporalBasis::Interval { from: 100, to: 0 };
    assert_eq!(evaluate(&a, &b, &reg, false).kind, ConflictOutcomeKind::InvalidInput);
    let (mut a2, b2) = employer_pair();
    a2.status = ConflictClaimStatus::Withdrawn;
    assert_eq!(evaluate(&a2, &b2, &reg, false).kind, ConflictOutcomeKind::InvalidInput);
    assert!(normalize::budget_ceiling("about five").is_none());
}

/// Decimal canonicalization: trailing-zero stripping and scale folding.
#[test]
fn decimal_canonical_bytes() {
    assert_eq!(
        TypedConflictValue::Decimal { mantissa: 1250, scale: 2 }.canonical_bytes(),
        "d:12.5"
    );
    assert_eq!(
        TypedConflictValue::Decimal { mantissa: 1500000, scale: 0 }.canonical_bytes(),
        "d:1500000"
    );
    assert_eq!(
        TypedConflictValue::Decimal { mantissa: -125, scale: 3 }.canonical_bytes(),
        "d:-0.125"
    );
}
