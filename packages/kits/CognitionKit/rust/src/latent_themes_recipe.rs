//! LatentThemes — the conscious "what you're actually about" recipe (Lens 2,
//! Topics). Recalls a set of drawers, builds the co-occurrence of their
//! metadata field-values, and factors it (NeuronKit `latent_themes` → GLK
//! `MatrixNMF`) into soft latent themes — the emergent topics in how the
//! estate is filed, with mixed membership.
//!
//! Paired with the Swift version (`Sources/CognitionKit/LatentThemes.swift`).
//! Layer discipline: the recipe SEQUENCES — recall via GLK, factor
//! via NeuronKit. Read-only; no capability gate (a structural read + a
//! reasoning surface, not a declared NeuronKitCapability function).
//!
//! Co-occurrence model: within each recalled drawer, its field-value labels
//! (`room:`, `kind:`, `channel:`, `sensitivity:`) all co-occur — the same
//! field-value co-occurrence the matrix tier accumulates from the audit log,
//! built here directly from the recalled set so the recipe stays a pure
//! sequence over the GLK recall verb (no audit-log/MatrixTier plumbing).

use std::collections::{BTreeMap, BTreeSet};

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
use locus_kit::filter::RecallFrame;
use neuron_kit::{latent_themes, LatentThemes};

use crate::error::{RecipeRunError, SubstrateError};

/// Fixed deterministic NMF seed so a given recalled set yields identical
/// themes across runs (the reasoning is reproducible, per the determinism rule).
const LATENT_THEMES_SEED: u64 = 0x_4C41_5445_4E54_3031; // "LATENT01"

/// The canonical label token for a content kind — the Swift case-name
/// spelling both versions emit (the Swift version is the design surface
/// for the label vocabulary; Debug formatting would diverge on e.g.
/// `structuredJSON`).
fn kind_label(k: ContentKind) -> &'static str {
    match k {
        ContentKind::Prose => "prose",
        ContentKind::Code => "code",
        ContentKind::Transcript => "transcript",
        ContentKind::List => "list",
        ContentKind::StructuredJson => "structuredJSON",
        ContentKind::ImageCaption => "imageCaption",
        ContentKind::FingerprintOnly => "fingerprintOnly",
    }
}

/// The canonical label token for a capture channel (Swift case names).
fn channel_label(c: CaptureChannel) -> &'static str {
    match c {
        CaptureChannel::Typed => "typed",
        CaptureChannel::Voiced => "voiced",
        CaptureChannel::Ocr => "ocr",
        CaptureChannel::ImportedFile => "importedFile",
        CaptureChannel::Sensor => "sensor",
        CaptureChannel::Actuator => "actuator",
    }
}

/// The canonical label token for a sensitivity (Swift case names).
fn sensitivity_label(s: AdjectiveSensitivity) -> &'static str {
    match s {
        AdjectiveSensitivity::Normal => "normal",
        AdjectiveSensitivity::Elevated => "elevated",
        AdjectiveSensitivity::Restricted => "restricted",
        AdjectiveSensitivity::Secret => "secret",
    }
}

/// The metadata field-value labels of a drawer — the tokens whose
/// co-occurrence the lens factors. Spelled with the canonical (Swift
/// case-name) vocabulary so both versions emit identical labels.
fn field_value_labels(d: &Drawer) -> Vec<String> {
    let mut fv = vec![
        format!("room:{}", d.room),
        format!("kind:{}", kind_label(d.content_kind())),
        format!("channel:{}", channel_label(d.capture_channel())),
        format!(
            "sensitivity:{}",
            sensitivity_label(d.adjective_sensitivity())
        ),
    ];
    fv.sort();
    fv.dedup();
    fv
}

/// Recall via `frame`, then factor the recalled set's metadata field-value
/// co-occurrence into `k` soft latent themes. Read-only; a recall failure
/// propagates as `RecipeRunError::Substrate`.
pub fn run_latent_themes(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    k: usize,
    now: i64,
) -> Result<LatentThemes, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    let mut labels: BTreeSet<String> = BTreeSet::new();
    // Canonical (a < b) pair -> co-occurrence weight.
    let mut cooc: BTreeMap<(String, String), f64> = BTreeMap::new();
    for d in &drawers {
        let fv = field_value_labels(d);
        for l in &fv {
            labels.insert(l.clone());
        }
        for i in 0..fv.len() {
            for j in (i + 1)..fv.len() {
                *cooc.entry((fv[i].clone(), fv[j].clone())).or_insert(0.0) += 1.0;
            }
        }
    }

    let label_vec: Vec<String> = labels.into_iter().collect();
    let cooccurrence: Vec<(String, String, f64)> =
        cooc.into_iter().map(|((a, b), w)| (a, b, w)).collect();

    Ok(latent_themes(
        &label_vec,
        &cooccurrence,
        k,
        LATENT_THEMES_SEED,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn capture(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        room: &str,
        kind: ContentKind,
        channel: CaptureChannel,
        sensitivity: AdjectiveSensitivity,
    ) {
        let mut frame = CaptureFrame::new(
            "content",
            channel,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        frame.kind = kind;
        frame.sensitivity = sensitivity;
        coord.capture(h, frame, NOW).unwrap();
    }

    fn unconfirmed() -> RecallFrame {
        // Admit elevated rows too — recall defaults to a Normal sensitivity
        // ceiling, which would otherwise drop the Elevated work regime.
        let mut f = RecallFrame::new(vec![
            Filter::Unconfirmed,
            Filter::SensitivityAtMost(AdjectiveSensitivity::Secret),
        ]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn dominant(t: &LatentThemes, label: &str) -> usize {
        t.loadings
            .iter()
            .find(|l| l.label == label)
            .unwrap()
            .dominant_theme
    }

    // CK-LT-1: two FULLY DISJOINT metadata regimes across the recalled set —
    // study drawers (room:study, Prose, Typed, Normal) vs work drawers
    // (room:work, Code, Voiced, Elevated), sharing no field-value — separate
    // into two latent themes. (Shared field-values would correctly LINK the
    // regimes; disjoint ones make the separation clean.) The estate surfaces
    // the emergent topics in how it's filed, end-to-end over a real estate.
    #[test]
    fn ck_lt1_two_regimes_separate_into_themes() {
        let (coord, h) = coord_with_parent();
        for _ in 0..3 {
            capture(
                &coord,
                &h,
                "study",
                ContentKind::Prose,
                CaptureChannel::Typed,
                AdjectiveSensitivity::Normal,
            );
        }
        for _ in 0..3 {
            capture(
                &coord,
                &h,
                "work",
                ContentKind::Code,
                CaptureChannel::Voiced,
                AdjectiveSensitivity::Elevated,
            );
        }

        let t = run_latent_themes(&coord, &h, unconfirmed(), 2, NOW).expect("themes");
        assert_eq!(t.k, 2);
        // The study/prose field-values cluster together, distinct from work/code.
        let study = dominant(&t, "room:study");
        assert_eq!(
            dominant(&t, "kind:prose"),
            study,
            "study & prose share a theme"
        );
        let work = dominant(&t, "room:work");
        assert_eq!(dominant(&t, "kind:code"), work, "work & code share a theme");
        assert_ne!(
            study, work,
            "the two filing regimes are different latent themes"
        );
    }

    // CK-LT-2: an empty estate yields no themes — guarded, no panic.
    #[test]
    fn ck_lt2_empty_estate_has_no_themes() {
        let (coord, h) = coord_with_parent();
        let t = run_latent_themes(&coord, &h, unconfirmed(), 2, NOW).expect("themes");
        assert!(t.loadings.is_empty());
    }
}
