// migration_parity.rs — conformance gate for the Rust migration API.
//
// Mirrors Swift `GLK_MIG_02_MigrationTests.swift`. The tests verify:
//   1. run_parallel routes captures to target in WriteToTarget mode
//   2. stop() causes subsequent captures to return ParallelRunStopped
//   3. verify_migration returns Identical for a fully migrated corpus
//   4. verify_migration returns Diverged for a missing entry

use std::sync::Arc;

use genius_locus_kit::{
    EstateCoordinator, EstateHandle, ExternalCorpus, ExternalEntry,
    MigrationError, MigrationVerification, ParallelCaptureMode, run_parallel, verify_migration,
};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
    filter::{Filter, RecallFrame},
    drawer_operational::CaptureChannel,
};

const NOW: i64 = 1_700_000_000;

fn open_estate(coord: &mut EstateCoordinator) -> EstateHandle {
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open")
}

fn test_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "migration",
        LatticeAnchor::udc("000"),
        "test",
        "test-v1",
    )
}

// Test 1: run_parallel routes captures to target in WriteToTarget mode.
// Mirrors Swift `runParallelWritesToTargetInWriteToTargetMode`.
#[test]
fn run_parallel_writes_to_target_in_write_to_target_mode() {
    let mut coord = EstateCoordinator::new();
    let source = open_estate(&mut coord);
    let target = open_estate(&mut coord);

    let handle = run_parallel(&coord, source.clone(), target.clone(), ParallelCaptureMode::WriteToTarget)
        .expect("run_parallel");

    let frame = test_frame("Parallel run test content");
    // capture takes &mut coord so it can route through capture_with_mode(Regular)
    // for FDC classification and corpus ingest queue entry.
    handle.capture(&mut coord, frame, NOW).expect("capture");

    let recall_frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    let target_rows = coord.recall(&target, recall_frame, NOW).expect("recall target");
    assert_eq!(target_rows.len(), 1, "WriteToTarget mode must route captures to the target estate");
}

// Test 2: stop() causes subsequent captures to return ParallelRunStopped.
// Mirrors Swift `runParallelStopPreventsFurtherCaptures`.
#[test]
fn run_parallel_stop_prevents_further_captures() {
    let mut coord = EstateCoordinator::new();
    let source = open_estate(&mut coord);
    let target = open_estate(&mut coord);

    let handle = run_parallel(&coord, source, target, ParallelCaptureMode::WriteToTarget)
        .expect("run_parallel");
    handle.stop();

    let frame = test_frame("Should not be captured");
    // ParallelRunStopped is returned before coord is touched, so &mut borrow
    // is taken and released immediately without any actual mutation.
    let result = handle.capture(&mut coord, frame, NOW);
    assert_eq!(
        result.unwrap_err(),
        MigrationError::ParallelRunStopped,
        "stop() must cause subsequent captures to return ParallelRunStopped"
    );
}

// Test 3: verify_migration returns Identical for a fully migrated corpus.
// Mirrors Swift `verifyMigrationReturnIdenticalForFullyMigratedCorpus`.
#[test]
fn verify_migration_returns_identical_for_fully_migrated_corpus() {
    let mut coord = EstateCoordinator::new();
    let handle = open_estate(&mut coord);

    let corpus = ExternalCorpus::new("test-corpus", vec![
        ExternalEntry::new("entry-0", "Unique content for entry zero: the quick brown fox", vec!["tag-0".into()]),
        ExternalEntry::new("entry-1", "Unique content for entry one: the lazy dog", vec!["tag-1".into()]),
    ]);

    // Capture each entry's content into the estate so verify finds them.
    for entry in &corpus.entries {
        let frame = test_frame(&entry.content);
        coord.capture(&handle, frame, NOW).expect("capture");
    }

    let result = verify_migration(&coord, &handle, &corpus, NOW).expect("verify_migration");
    assert_eq!(result, MigrationVerification::Identical, "fully migrated corpus should verify as Identical");
}

// Test 4: verify_migration returns Diverged for a missing entry.
// Mirrors Swift `verifyMigrationReturnsDivergedForMissingEntry`.
#[test]
fn verify_migration_returns_diverged_for_missing_entry() {
    let mut coord = EstateCoordinator::new();
    let handle = open_estate(&mut coord);

    // Only capture the first entry.
    let frame = test_frame("Unique content for entry zero: the quick brown fox");
    coord.capture(&handle, frame, NOW).expect("capture");

    // Verify against a two-entry corpus — entry-1 is absent.
    let corpus = ExternalCorpus::new("test-corpus", vec![
        ExternalEntry::new("entry-0", "Unique content for entry zero: the quick brown fox", vec![]),
        ExternalEntry::new("entry-1", "Unique content for entry one: the lazy dog", vec![]),
    ]);

    let result = verify_migration(&coord, &handle, &corpus, NOW).expect("verify_migration");
    match result {
        MigrationVerification::Identical => {
            panic!("Expected Diverged when corpus has entry not in estate");
        }
        MigrationVerification::Diverged(divergences) => {
            assert_eq!(divergences.len(), 1, "One missing entry should produce exactly one divergence");
            assert_eq!(divergences[0].entry_id, "entry-1", "The diverged entry should be the one not imported");
        }
    }
}
