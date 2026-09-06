// ssc_facts_backfill.rs — the upgrade-time SSC facts backfill (contract
// sheet §6): rows whose `ssc_facts` column is NULL get their facts written
// once; rows that already carry facts, and rows whose content anchors
// nothing, are left alone.
//
// Swift twin: SSCFactsBackfillTests.swift.

use std::sync::Arc;

use genius_locus_kit::brain::enrichment_stage;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000_000;

fn frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "backfill",
        LatticeAnchor::udc("000"),
        "ssc-backfill-tests",
        "test-model-v1",
    )
}

/// Failure modes: a pass that recomputes every row would report a non-zero
/// count on a converged estate and trigger a needless BM25 rebuild; a pass
/// that skips NULL rows would leave migrated estates without SSC terms in
/// BM25.
#[test]
fn backfill_writes_only_the_rows_that_owe_facts() {
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("in-memory store"));
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-ssc-backfill-tests"), 0, 100)
        .expect("open");

    let anchored = "Sanjay loves painting in Brazil and runs marathons in Rio.";
    let owed = coord.capture(&handle, frame(anchored), NOW).expect("capture owed");
    let kept = coord
        .capture(&handle, frame("Priya reviewed the Geneva contract with Sarah."), NOW + 1)
        .expect("capture kept");
    let expected = enrichment_stage::facts(anchored).expect("fixture content must anchor facts");

    let estate = coord.estate_for(&handle).expect("estate");
    let kept_facts = estate
        .drawer_by_id(&kept.id)
        .expect("read kept")
        .expect("kept row")
        .ssc_facts
        .expect("the capture path writes facts at capture");

    // A migrated estate: the column is NULL on a row that owes facts.
    estate.set_ssc_facts(&owed.id, None).expect("clear facts");

    let written = coord.backfill_ssc_facts(&handle).expect("backfill");
    assert_eq!(written, 1, "exactly the NULL row is written");
    let owed_row = estate.drawer_by_id(&owed.id).expect("read owed").expect("owed row");
    assert_eq!(owed_row.ssc_facts.as_deref(), Some(expected.as_str()));
    let kept_row = estate.drawer_by_id(&kept.id).expect("read kept").expect("kept row");
    assert_eq!(
        kept_row.ssc_facts.as_deref(),
        Some(kept_facts.as_str()),
        "a row that already carries facts is untouched"
    );

    // Idempotent: a second pass finds nothing to write.
    assert_eq!(coord.backfill_ssc_facts(&handle).expect("second pass"), 0);
}
