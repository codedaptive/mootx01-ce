use std::collections::HashMap;

use fact_extraction_kit::FactSearchProjection;
use genius_locus_kit::fact_first_recall::{
    FactFirstRecallDecision, FactFirstRecallStage, FactFirstRecallThresholds,
};
use locus_kit::{drawer::Drawer, kg_fact::KGFact};

fn fact(id: &str, subject: &str, object: &str, source: &str, projection: &str) -> KGFact {
    KGFact {
        search_projection: projection.into(),
        search_projection_version: FactSearchProjection::VERSION.into(),
        ..KGFact::new(
            id.into(),
            subject.into(),
            "birthday".into(),
            object.into(),
            source.into(),
            1_800_000_000,
        )
    }
}

fn drawer(id: &str, content: &str) -> Drawer {
    let mut drawer = Drawer::new(id, content, "room", "test", 1_800_000_000, "test");
    drawer.operational_bitmap |= locus_kit::drawer_operational::DrawerFeatureFlags::FACTS_EXTRACTED;
    drawer
}

#[test]
fn solid_fact_carries_its_source_as_one_family() {
    let jack = fact(
        "jack-birthday",
        "Jack",
        "June 20th",
        "source-jack",
        "Jack birthday June 20th when is Jack birthday",
    );
    let jill = fact(
        "jill-birthday",
        "Jill",
        "May 18th",
        "source-jill",
        "Jill birthday May 18th",
    );
    let sources = HashMap::from([
        (
            "source-jack".into(),
            drawer("source-jack", "Jack's birthday is June 20th."),
        ),
        (
            "source-jill".into(),
            drawer("source-jill", "Jill's birthday is May 18th."),
        ),
    ]);
    let decision = FactFirstRecallStage::decide(
        "when is jacks birthday",
        &["Jack".into()],
        &[jill, jack],
        &sources,
        None,
        FactFirstRecallThresholds::default(),
    );
    let FactFirstRecallDecision::Solid(family) = decision else {
        panic!("expected solid fact-first result")
    };
    assert_eq!(family.fact.id, "jack-birthday");
    assert_eq!(family.source.id, "source-jack");
    assert!(family.margin >= 0.20);
    assert_eq!(family.entity_containment, 1.0);
}

#[test]
fn missing_entities_and_a_tied_head_both_fall_through() {
    let first = fact(
        "a",
        "Jack",
        "June 20th",
        "source-jack",
        "Jack birthday June 20th",
    );
    let second = fact(
        "b",
        "Jack",
        "June 21st",
        "source-jack",
        "Jack birthday June 21st",
    );
    let sources = HashMap::from([("source-jack".into(), drawer("source-jack", "source"))]);
    assert_eq!(
        FactFirstRecallStage::decide(
            "when is jacks birthday",
            &[],
            std::slice::from_ref(&first),
            &sources,
            None,
            FactFirstRecallThresholds::default(),
        ),
        FactFirstRecallDecision::FallThrough
    );
    assert_eq!(
        FactFirstRecallStage::decide(
            "when is jacks birthday",
            &["Jack".into()],
            &[first.clone(), second],
            &sources,
            None,
            FactFirstRecallThresholds::default(),
        ),
        FactFirstRecallDecision::FallThrough
    );
    let mut stale = drawer("source-jack", "edited");
    stale.operational_bitmap = 0;
    let stale_sources = HashMap::from([("source-jack".into(), stale)]);
    assert_eq!(
        FactFirstRecallStage::decide(
            "when is jacks birthday",
            &["Jack".into()],
            std::slice::from_ref(&first),
            &stale_sources,
            None,
            FactFirstRecallThresholds::default(),
        ),
        FactFirstRecallDecision::FallThrough
    );
    let weak = fact("weak", "Jack", "Seattle", "source-jack", "Jack Seattle");
    let vector_scores = HashMap::from([("weak".into(), 1.0)]);
    assert_eq!(
        FactFirstRecallStage::decide(
            "when is jacks birthday",
            &["Jack".into()],
            &[weak],
            &sources,
            Some(&vector_scores),
            FactFirstRecallThresholds::default(),
        ),
        FactFirstRecallDecision::FallThrough
    );
}

// Gate B: a fact with a stale search_projection_version is excluded from recall
// by FactFirstRecall's version guard. Once the correct version is stamped (the
// exact bytes the backfill writes), the fact wins the query. Twin of Swift Gate B.
//
// Design — inverted so the test discriminates:
//   f-unprojected (Jack) carries the content the query asks for, but
//   search_projection_version = "" (wrong, backfill not yet run). The version
//   guard at fact_first_recall.rs lines 92-93 excludes it.
//   f-projected (Jill) has the correct version but scores poorly: coverage 0.5
//   and entity_containment = 0 (Jill ≠ Jack).
//
//   Phase 1: f-unprojected excluded by the version guard. Jill scores 0.5 <
//   0.70 and has containment 0 → FallThrough.
//   Phase 2: f-unprojected receives FactSearchProjection::VERSION — the exact
//   bytes the gateway writes. Jack scores ≥ 0.70, margin ≥ 0.20, containment
//   = 1 → Solid(f-unprojected).
//
// Discrimination: deleting lines 92-93 from fact_first_recall.rs (the version
// guard block) makes f-unprojected eligible in Phase 1; Jack scores ≥ 0.70 and
// wins, so Phase 1's FallThrough assertion fails → red. Restoring those lines
// returns the test to green.
//
// Note on empty search_projection (the actual schema DEFAULT): for facts where
// search_projection = "", lines 92-93 and the downstream tokens.is_empty() guard
// both exclude the fact. Removing lines 92-93 alone does not expose an
// empty-string fact because default_keyword_tokens("") always returns []. This
// test exercises line 93 (the version check) — the condition the backfill satisfies.
#[test]
fn gate_b_un_projected_fact_is_invisible_to_recall() {
    let source_id = "source-b";
    let source = drawer(source_id, "Jack's birthday is in June.");
    let sources = HashMap::from([(source_id.into(), source)]);

    // Fact 1 (the winning candidate): Jack, with the correct projection content
    // but search_projection_version = "" (wrong — backfill has not yet stamped
    // the version). The version guard (line 93) excludes this fact.
    let jack_projection = FactSearchProjection::build("Jack", "birthday", "June", &[]);
    let un_projected = KGFact {
        search_projection: jack_projection.clone(),
        search_projection_version: String::new(),   // wrong — excluded by version guard
        ..KGFact::new(
            "f-unprojected".into(), "Jack".into(), "birthday".into(), "June".into(),
            source_id.into(), 1_800_000_000,
        )
    };

    // Fact 2 (the decoy): Jill, correctly versioned, but low-scoring.
    // "jack birthday" ∩ {"jill", "birthday", "june"} = {"birthday"} → coverage 0.5,
    // below 0.70; entity_containment = 0 (Jill ≠ Jack).
    let jill_projection = FactSearchProjection::build("Jill", "birthday", "June", &[]);
    let projected = KGFact {
        search_projection: jill_projection,
        search_projection_version: FactSearchProjection::VERSION.into(),
        ..KGFact::new(
            "f-projected".into(), "Jill".into(), "birthday".into(), "June".into(),
            source_id.into(), 1_800_000_000,
        )
    };

    // Phase 1: guard active — f-unprojected (Jack) excluded by the version guard.
    // Jill is the only eligible candidate but scores 0.5 and has containment 0
    // → FallThrough.
    let decision = FactFirstRecallStage::decide(
        "jack birthday",
        &["Jack".into()],
        &[un_projected.clone(), projected.clone()],
        &sources,
        None,
        FactFirstRecallThresholds::default(),
    );
    assert_eq!(
        decision,
        FactFirstRecallDecision::FallThrough,
        "Phase 1: stale-versioned Jack fact must not be returned; \
         Jill alone fails score floor and entity containment"
    );

    // Phase 2: f-unprojected (Jack) receives FactSearchProjection::VERSION —
    // the exact bytes the gateway writes. Coverage 2/2 = 1.0, margin ≥ 0.20,
    // containment = 1 → Solid(f-unprojected).
    let now_projected = KGFact {
        search_projection: jack_projection,
        search_projection_version: FactSearchProjection::VERSION.into(),   // backfill's stamp
        ..un_projected
    };

    let after_decision = FactFirstRecallStage::decide(
        "jack birthday",
        &["Jack".into()],
        &[now_projected, projected],
        &sources,
        None,
        FactFirstRecallThresholds::default(),
    );
    let FactFirstRecallDecision::Solid(family) = after_decision else {
        panic!("Phase 2: expected Solid after version stamp; got {:?}", after_decision)
    };
    assert_eq!(
        family.fact.id, "f-unprojected",
        "Phase 2: the formerly-stale Jack fact must win once the version is stamped"
    );
}

// Gate B extension: the empty-projection shape after a correct-version backfill.
//
// A post-migration-plus-wrong-order scenario: the fact's search_projection_version
// is correct (the backfill stamped the version) but search_projection is "" (the
// backfill wrote an empty string, which is the actual schema DEFAULT for unextracted
// rows). The version guard passes; only the empty-projection guards remain.
//
// Two mechanisms exclude the empty-projection fact:
//   1. fact_first_recall.rs lines 92-93: `fact.search_projection.is_empty()` check.
//   2. `tokens.is_empty()` guard (default_keyword_tokens("") returns []).
//
// This test CANNOT discriminate between the two mechanisms: an empty
// search_projection triggers both at once — the is_empty check fires first, and
// even if it were removed, the downstream tokens guard would exclude the fact.
// The test documents a defended invariant — both guards cover the empty-projection
// shape — without claiming a discrimination it does not have.
#[test]
fn gate_b_empty_projection_fact_excluded() {
    let source_id = "source-empty";
    let source = drawer(source_id, "Jack's birthday is in June.");
    let sources = HashMap::from([(source_id.into(), source)]);

    // Fact with a correct search_projection_version but an empty search_projection —
    // the honest shape for isolating the empty-projection guards. Subject/object
    // match the query so only the empty-projection guards prevent a hit.
    let empty_fact = KGFact {
        search_projection: String::new(),
        search_projection_version: FactSearchProjection::VERSION.into(),
        ..KGFact::new(
            "f-empty".into(), "Jack".into(), "birthday".into(), "June".into(),
            source_id.into(), 1_800_000_000,
        )
    };

    // Phase 1: the empty-projection fact is excluded. No eligible fact
    // remains → FallThrough.
    let decision = FactFirstRecallStage::decide(
        "jack birthday",
        &["Jack".into()],
        &[empty_fact.clone()],
        &sources,
        None,
        FactFirstRecallThresholds::default(),
    );
    assert_eq!(
        decision,
        FactFirstRecallDecision::FallThrough,
        "empty-projection fact must not be returned; excluded by is_empty guard and downstream tokens.is_empty() guard"
    );

    // Phase 2: stamp the fact with the real FactSearchProjection values —
    // the exact bytes the backfill writes. Now it must win.
    let stamped = KGFact {
        search_projection: FactSearchProjection::build("Jack", "birthday", "June", &[]),
        search_projection_version: FactSearchProjection::VERSION.into(),
        ..empty_fact
    };

    let after_decision = FactFirstRecallStage::decide(
        "jack birthday",
        &["Jack".into()],
        &[stamped],
        &sources,
        None,
        FactFirstRecallThresholds::default(),
    );
    let FactFirstRecallDecision::Solid(family) = after_decision else {
        panic!("Phase 2: expected Solid after stamp; got {:?}", after_decision)
    };
    assert_eq!(
        family.fact.id, "f-empty",
        "Phase 2: the stamped fact must win recall"
    );
}
