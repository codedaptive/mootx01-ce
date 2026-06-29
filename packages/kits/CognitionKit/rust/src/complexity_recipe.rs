//! Complexity — Shannon entropy recipe (Lens 4, Topics).
//!
//! Recall a frame via `EstateCoordinator`, project `field_a` (and
//! optionally `field_b`) values into frequency counts, and compute
//! Shannon entropy (plus optional mutual information) by delegating to
//! `neuron_kit::complexity`. Read-only (B-6, I-6).
//!
//! Paired with `Sources/CognitionKit/Complexity.swift`. Supported field
//! names: "room", "wing", "addedBy", "embeddingModelID". Both "room" and
//! "wing" resolve to `parent_node_id` (display names are resolved from
//! the node tree by the caller). Unknown fields are mapped to "_unknown"
//! (B-8 total-over-edge-input posture).

use std::collections::HashMap;

use genius_locus_kit::EstateCoordinator;
use genius_locus_kit::handle::EstateHandle;
use locus_kit::drawer::Drawer;
use locus_kit::filter::RecallFrame;

use crate::error::{RecipeRunError, SubstrateError};

pub use neuron_kit::{complexity, ComplexityResult};

/// Complexity recipe output: the Shannon entropy result and how many
/// drawers were recalled.
#[derive(Debug, Clone, PartialEq)]
pub struct ComplexityOutput {
    pub result: ComplexityResult,
    /// Number of drawers in the recalled set.
    pub total_count: usize,
}

/// Extract the `field` value from a recalled drawer. Supported fields:
/// "room", "wing", "addedBy", "embeddingModelID". Unknown field → "_unknown"
/// (B-8: total behaviour over edge inputs rather than panic).
///
/// Both "room" and "wing" resolve to `parent_node_id` — display names are
/// resolved from the node tree by the caller. For within-estate entropy
/// analysis, grouping by node ID is semantically correct.
fn field_value<'a>(drawer: &'a Drawer, field: &str) -> &'a str {
    match field {
        // Both room and wing are now resolved from the node tree via
        // parent_node_id. The Drawer no longer carries denormalized
        // display names.
        "room" | "wing" => &drawer.parent_node_id,
        "addedBy" => &drawer.added_by,
        "embeddingModelID" => &drawer.embedding_model_id,
        _ => "_unknown",
    }
}

/// Build a sorted frequency vector over `field` from `drawers`.
/// Returns (counts, sorted_keys) so the joint matrix can align axes.
fn distribution(drawers: &[Drawer], field: &str) -> (Vec<f32>, Vec<String>) {
    let mut freq: HashMap<String, usize> = HashMap::new();
    for d in drawers {
        *freq.entry(field_value(d, field).to_owned()).or_insert(0) += 1;
    }
    let mut keys: Vec<String> = freq.keys().cloned().collect();
    keys.sort();
    let counts = keys.iter().map(|k| freq[k] as f32).collect();
    (counts, keys)
}

/// Build the joint co-occurrence matrix aligned to `keys_a` × `keys_b`.
fn joint_matrix(
    drawers: &[Drawer],
    keys_a: &[String],
    keys_b: &[String],
    field_a: &str,
    field_b: &str,
) -> Vec<Vec<f32>> {
    let idx_a: HashMap<&str, usize> = keys_a.iter().enumerate().map(|(i, k)| (k.as_str(), i)).collect();
    let idx_b: HashMap<&str, usize> = keys_b.iter().enumerate().map(|(i, k)| (k.as_str(), i)).collect();
    let mut matrix = vec![vec![0.0f32; keys_b.len()]; keys_a.len()];
    for d in drawers {
        if let (Some(&ia), Some(&ib)) =
            (idx_a.get(field_value(d, field_a)), idx_b.get(field_value(d, field_b)))
        {
            matrix[ia][ib] += 1.0;
        }
    }
    matrix
}

/// Recall via `frame`, derive the frequency distribution of `field_a` (and
/// optionally `field_b`) values, and compute Shannon entropy / mutual
/// information.
///
/// Empty recall yields zero entropy (B-8). A recall failure propagates as
/// `RecipeRunError::Substrate`.
pub fn run_complexity(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    field_a: &str,
    field_b: Option<&str>,
    now: i64,
) -> Result<ComplexityOutput, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    let total_count = drawers.len();

    let (counts_a, keys_a) = distribution(&drawers, field_a);

    let result = if let Some(fb) = field_b {
        let (counts_b, keys_b) = distribution(&drawers, fb);
        let joint = joint_matrix(&drawers, &keys_a, &keys_b, field_a, fb);
        complexity(&counts_a, Some(&counts_b), Some(&joint))
    } else {
        complexity(&counts_a, None, None)
    };

    Ok(ComplexityOutput { result, total_count })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use genius_locus_kit::EstateCoordinator;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use locus_kit::frames::CaptureFrame;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn capture_in_room(coord: &EstateCoordinator, h: &EstateHandle, content: &str, room: &str) {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, NOW).unwrap();
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-CM-1 (Rust): recipe result equals the direct lens call on the same
    // shaped input.
    #[test]
    fn ck_cm1_matches_direct_lens_call() {
        let (coord, h) = coord_with_estate();
        for _ in 0..2 {
            capture_in_room(&coord, &h, &uuid_str(), "research");
        }
        capture_in_room(&coord, &h, "reading-note", "reading");

        let drawers = coord.recall(&h, unconfirmed(), NOW).unwrap();
        let (counts_a, _) = distribution(&drawers, "room");
        let expected = complexity(&counts_a, None, None);

        let out = run_complexity(&coord, &h, unconfirmed(), "room", None, NOW).unwrap();

        assert_eq!(out.result, expected,
            "run_complexity must equal the direct lens call");
        assert_eq!(out.total_count, drawers.len());
    }

    // CK-CM-2 (Rust): mutual information is computed when both fields are
    // supplied.
    #[test]
    fn ck_cm2_mutual_information_present_with_two_fields() {
        let (coord, h) = coord_with_estate();
        capture_in_room(&coord, &h, "a", "lab");
        capture_in_room(&coord, &h, "b", "office");

        let out = run_complexity(&coord, &h, unconfirmed(), "room", Some("wing"), NOW).unwrap();
        assert!(out.result.entropy_b.is_some(), "entropy_b present for field_b");
        // The implementation maps both "room" and "wing" to drawer.parent_node_id;
        // the fixture captures drawers in different rooms, so the second field is
        // not a shared estate owner/wing value. The test only asserts that mutual
        // information is present.
        assert!(out.result.mutual_information.is_some());
    }

    // CK-CM-3 (Rust): empty estate yields zero entropy (B-8).
    #[test]
    fn ck_cm3_empty_estate_is_guarded() {
        let (coord, h) = coord_with_estate();
        let out = run_complexity(&coord, &h, unconfirmed(), "room", None, NOW).unwrap();
        assert_eq!(out.result.entropy_a, 0.0);
        assert_eq!(out.total_count, 0);
    }

    fn uuid_str() -> String {
        // Deterministic pseudonym — avoids importing uuid crate.
        static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        format!("item-{n}")
    }
}
