//! ThemeWeather — the conscious "what's rising, what's fading" recipe (Lens 2,
//! Topics). Recall a set, and for each room compare its historical presence
//! (raw count) to its recent attention (decay-weighted mass by capture time)
//! via NeuronKit `theme_weather` — momentum, not just presence.
//!
//! Paired with the Swift version (`Sources/CognitionKit/ThemeWeather.swift`).
//! Pure CognitionKit sequencing: recall via GLK + NeuronKit
//! recency_weight/theme_weather (SubstrateML decay). Read-only.

use std::collections::BTreeMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use neuron_kit::{recency_weight, theme_weather, CategoryMomentum};

use crate::error::{RecipeRunError, SubstrateError};

/// Per-room momentum (heating positive, cooling negative), hottest first.
/// `half_life_seconds` sets how fast attention decays with age. Read-only;
/// recall failure → `RecipeRunError::Substrate`.
pub fn run_theme_weather(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    half_life_seconds: f64,
    now: i64,
) -> Result<Vec<CategoryMomentum>, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    let mut raw: BTreeMap<String, f64> = BTreeMap::new();
    let mut weighted: BTreeMap<String, f64> = BTreeMap::new();
    for d in &drawers {
        let elapsed = (now - d.filed_at).max(0) as f64;
        *raw.entry(d.parent_node_id.clone()).or_insert(0.0) += 1.0;
        *weighted.entry(d.parent_node_id.clone()).or_insert(0.0) +=
            recency_weight(elapsed, half_life_seconds);
    }

    let cats: Vec<(String, f64, f64)> = raw
        .keys()
        .map(|k| (k.clone(), raw[k], weighted.get(k).copied().unwrap_or(0.0)))
        .collect();
    Ok(theme_weather(&cats))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer::Drawer;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;

    const HALF_LIFE: f64 = 2_000.0;
    const NOW: i64 = 10_000;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(1, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn capture_at(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        room: &str,
        when: i64,
    ) -> Drawer {
        let frame = CaptureFrame::new(
            "content",
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, when).unwrap()
    }

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-TW-1: equal historical presence, but "rising" was filed recently and
    // "fading" long ago — rising heats (positive momentum, hottest), fading
    // cools. The estate sees which topics have momentum, end-to-end.
    #[test]
    fn ck_tw1_recent_room_is_rising() {
        let (coord, h) = coord_with_parent();
        let mut rising_node = String::new();
        for _ in 0..3 {
            let d = capture_at(&coord, &h, "rising", NOW); // elapsed 0
            rising_node = d.parent_node_id;
        }
        let mut fading_node = String::new();
        for _ in 0..3 {
            let d = capture_at(&coord, &h, "fading", 1_000); // elapsed 9000, heavily decayed
            fading_node = d.parent_node_id;
        }
        let w = run_theme_weather(&coord, &h, all(), HALF_LIFE, NOW).expect("weather");
        assert_eq!(w[0].category, rising_node, "the recent room is hottest");
        assert!(w[0].momentum > 0.0, "rising is heating");
        assert!(
            w.iter()
                .find(|m| m.category == fading_node)
                .unwrap()
                .momentum
                < 0.0,
            "fading is cooling"
        );
    }

    // CK-TW-2: an empty estate yields no momentum (guarded).
    #[test]
    fn ck_tw2_empty_guarded() {
        let (coord, h) = coord_with_parent();
        let w = run_theme_weather(&coord, &h, all(), HALF_LIFE, NOW).expect("weather");
        assert!(w.is_empty());
    }
}
