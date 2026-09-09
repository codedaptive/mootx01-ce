use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle, GeniusLocusKitError};
use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

#[test]
fn returns_the_registered_estate_storage_arc() {
    let mut coordinator = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
    let expected = store.storage().expect("in-memory store has storage");
    let handle = coordinator.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();

    let actual = coordinator.inventory_snapshot_storage(&handle).unwrap();
    assert!(Arc::ptr_eq(&actual, &expected));
}

#[test]
fn rejects_an_unregistered_handle() {
    let coordinator = EstateCoordinator::new();
    let handle = EstateHandle { estate_uuid: [7; 16], zoom_window_low: 0, zoom_window_high: 100 };

    assert!(matches!(
        coordinator.inventory_snapshot_storage(&handle),
        Err(GeniusLocusKitError::EstateNotOpen { .. })
    ));
}
