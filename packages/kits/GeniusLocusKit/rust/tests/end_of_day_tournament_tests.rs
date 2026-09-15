// end_of_day_tournament_tests.rs — the end-of-day tournament folds two
// traces recalled in the same minute into one contest and two rating rows.

use std::sync::Arc;

use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use locus_kit::recall_trace_item::RecallTraceItem;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

/// 2023-11-14T22:13:20Z — the tournament clock, in epoch seconds.
const NOW_SECS: i64 = 1_700_000_000;

#[test]
fn two_traces_in_one_minute_make_one_contest_and_two_rating_rows() {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW_SECS, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(Arc::clone(&store), OwnerCredentials::new("owner-tournament-tests"), 0, 100)
        .expect("open estate");

    let winner = Uuid::new_v4().to_string();
    let loser = Uuid::new_v4().to_string();
    // Both traces fall in the 22:10 minute, inside the 24h window ending at NOW.
    let traces = [
        RecallTraceItem::new(Uuid::new_v4().to_string(), winner.clone(), "2023-11-14T22:10:05Z", None, 0),
        RecallTraceItem::new(Uuid::new_v4().to_string(), loser.clone(), "2023-11-14T22:10:40Z", None, 0),
    ];
    coord.insert_recall_traces(&handle, &traces).expect("seed traces");

    let report = coord
        .end_of_day_tournament(&handle, NOW_SECS * 1000)
        .expect("tournament");
    assert_eq!(report.contests, 1);
    assert_eq!(report.rated_drawers, 2);

    let rows = store
        .recall_ratings(&[winner.as_str(), loser.as_str()])
        .expect("read ratings");
    assert_eq!(rows.len(), 2);
    let winner_row = rows.iter().find(|r| r.drawer_id == winner).expect("winner row");
    let loser_row = rows.iter().find(|r| r.drawer_id == loser).expect("loser row");
    assert!(winner_row.rating > loser_row.rating, "first-listed drawer beats the rest");
    assert_eq!(winner_row.contests, 1);
    assert_eq!(loser_row.contests, 1);
    assert_eq!(winner_row.updated_at, "2023-11-14T22:13:20Z");
}
