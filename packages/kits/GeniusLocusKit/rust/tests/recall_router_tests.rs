// recall_router_tests.rs
//
// Two gates for the recall router (recall_router.rs), driven from the shared
// fixture at Tests/Fixtures/recall_router_vectors.json:
//
//   router-on   — preference on (default), dialogue query: route fires,
//                 result.route is Some("cross_encoder_routing") and the
//                 cross-encoder stage ran (result.cross_encoder is Some,
//                 degraded because no scorer is registered in this estate).
//   router-off  — preference off (meta = "off"), same query: route does not
//                 fire, result.route is None and result.cross_encoder is None.
//
// Twin of Swift RecallRouterTests.swift.

use std::path::PathBuf;
use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, GLKRecallMode, GLKRecallRequest, GLKRecallScoring};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use locus_kit::filter::{Filter, RecallFrame};
use genius_locus_kit::recall::RecallFallbackPolicy;
use genius_locus_kit::recall::RecallOrigin;

const NOW: i64 = 1_700_000_000;

// MARK: - Fixture

#[derive(serde::Deserialize)]
struct RouterVectors {
    dialogue: String,
    #[allow(dead_code)]
    prose: String,
}

/// CARGO_MANIFEST_DIR is packages/kits/GeniusLocusKit/rust.
/// The fixture is one level up in Tests/Fixtures/.
fn load_vectors() -> RouterVectors {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Fixtures/recall_router_vectors.json");
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Cannot read {}: {e}", path.display()));
    serde_json::from_str(&data).expect("parse recall_router_vectors.json")
}

// MARK: - Helpers

fn open_estate(owner: &str) -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(owner), 0, i64::MAX)
        .expect("open must succeed");
    (coord, handle)
}

/// A minimal GLKRecallRequest carrying `query_text`. Uses locusOnly so no
/// corpus is needed; origin is Internal so no trace writes occur.
fn request(query: String) -> GLKRecallRequest {
    GLKRecallRequest::new(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        GLKRecallMode::LocusOnly,
        GLKRecallScoring::Raw,
        20,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    )
    .with_query_text(query)
}

// MARK: - Tests

/// Gate: preference on (default) + dialogue query → route fires.
///
/// The cross-encoder stage degrades in this in-memory estate (no scorer
/// registered), but result.route is the proof the router transformed the
/// request.
#[test]
fn router_on_dialogue_query_fires_route() {
    let vectors = load_vectors();
    let (coord, handle) = open_estate("router-on-test");
    // Do not write any meta — absent key defaults to ON.

    let result = coord
        .recall_scored(&handle, request(vectors.dialogue), NOW)
        .expect("recall_scored");

    // Route 1 fired: preference key carried in the result.
    assert_eq!(
        result.route.as_deref(),
        Some("cross_encoder_routing"),
        "route should be 'cross_encoder_routing' when preference is on"
    );
    // The transform was applied: the cross-encoder stage ran (degraded — no
    // scorer registered — but ran), so its report is present.
    assert!(
        result.cross_encoder.is_some(),
        "cross-encoder report should be present when route 1 fires"
    );
}

/// Gate: preference off + dialogue query → route does not fire.
///
/// Writing "off" to the meta key suppresses the router entirely. The result
/// carries no route key.
#[test]
fn router_off_dialogue_query_no_route() {
    let vectors = load_vectors();
    let (coord, handle) = open_estate("router-off-test");
    // Write the "off" preference to the estate manifest.
    let estate = coord.estate_for(&handle).expect("estate");
    estate
        .set_meta(EstateCoordinator::CROSS_ENCODER_ROUTING_META_KEY, "off")
        .expect("set_meta");

    let result = coord
        .recall_scored(&handle, request(vectors.dialogue), NOW)
        .expect("recall_scored");

    // Route suppressed by preference.
    assert!(
        result.route.is_none(),
        "route should be None when preference is 'off', got {:?}",
        result.route
    );
    // No directive → no cross-encoder stage → no report.
    assert!(
        result.cross_encoder.is_none(),
        "cross-encoder report should be absent when preference is 'off'"
    );
}
