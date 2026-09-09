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
