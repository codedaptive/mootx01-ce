//! TrustLens — provenance-weighted grounding (Lens 6, Grounding & Trust).
//! Recall a set of drawers, rank them by how authoritative their provenance
//! is (source-type trust: Canonical/User above Derived/etc., confidence as
//! tiebreak), and synthesize the trust-ordered set so the most trustworthy
//! memories ground the context first. The estate reasons about which of its
//! own memories to lean on.
//!
//! Paired with the Swift version (`Sources/CognitionKit/TrustLens.swift`).
//! PURE CognitionKit sequencing: recall via GLK + the drawer provenance
//! accessors (existing) + NeuronKit `synthesize` (existing). Zero new
//! substrate, zero new NeuronKit surface. Read-only.
//!
//! Trust signal: `source_type` is used (it is settable at capture and varies),
//! not `confirmation` — the user-confirmed tier can only be reached through
//! the confirm/mutate verb, which is Brain-layer (`NotSupportedByEstate`)
//! until that layer ships. When confirmation goes live, a user-confirmed boost
//! folds into `trust_rank` the same way.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use locus_kit::provenance::SourceType;
use neuron_kit::{synthesize, ContextDocument, DrawerRow, DrawerRowMeta, RecallPage};

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

/// Provenance-weighted grounding output: the synthesized context, the drawer
/// ids in trust order (most authoritative first), and how many are high-trust.
#[derive(Debug, Clone, PartialEq)]
pub struct TrustGroundedOutput {
    pub context: ContextDocument,
    /// Recalled drawer ids, most-trusted first.
    pub ranked_ids: Vec<String>,
    /// Count of high-trust rows (Canonical or User source type).
    pub high_trust_count: usize,
}

/// Authority score for a source type (higher = more trustworthy). Canonical
/// and User outrank derived/inferred provenance — "canonical + user above
/// derived/proposed" from the lens brainstorm. A v1 ordering; the precise
/// weights are a deliberate, documented choice, not a substrate constant.
fn trust_rank(st: SourceType) -> i32 {
    match st {
        SourceType::Canonical => 5,
        SourceType::User => 4,
        SourceType::Imported => 3,
        SourceType::Observed => 2,
        SourceType::Derived => 1,
        _ => 0,
    }
}

/// `true` for the high-trust tier (Canonical or User).
fn is_high_trust(st: SourceType) -> bool {
    trust_rank(st) >= 4
}

/// Recall via `frame`, rank by provenance trust, and synthesize the
/// trust-ordered set. Read-only; a recall failure propagates as
/// `RecipeRunError::Substrate`.
pub fn run_trust_grounded_synthesis(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    now: i64,
) -> Result<TrustGroundedOutput, RecipeRunError> {
    // B-5: capability gate before any substrate touch.
    verify_capabilities(&[NeuronKitCapability::Synthesize], &shipped_capabilities())?;

    let mut drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // Trust order: source-type authority desc, confidence desc, id asc
    // (deterministic).
    drawers.sort_by(|a, b| {
        trust_rank(b.source_type())
            .cmp(&trust_rank(a.source_type()))
            .then(b.confidence().raw_value().cmp(&a.confidence().raw_value()))
            .then(a.id.cmp(&b.id))
    });

    let high_trust_count = drawers
        .iter()
        .filter(|d| is_high_trust(d.source_type()))
        .count();
    let ranked_ids: Vec<String> = drawers.iter().map(|d| d.id.clone()).collect();

    let rows: Vec<DrawerRow> = drawers
        .iter()
        .map(|d| DrawerRow {
            id: d.id.clone(),
            content: d.content.clone(),
        })
        .collect();
    let meta: Vec<DrawerRowMeta> = drawers
        .iter()
        .map(|d| DrawerRowMeta {
            wing: d.wing.clone(),
            room: d.room.clone(),
            is_currently_believed: true,
        })
        .collect();

    let page = RecallPage {
        rows,
        page_index: 0,
        is_last: true,
    };
    let context = synthesize(&page, &meta);

    Ok(TrustGroundedOutput {
        context,
        ranked_ids,
        high_trust_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::sync::Arc;

    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    /// Capture a drawer with a given source type; return its minted id.
    fn capture(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        content: &str,
        st: SourceType,
    ) -> String {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        frame.source_type = st;
        coord.capture(h, frame, NOW).unwrap().id
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-TR-1: the lens RUNS and ranks by provenance trust — canonical
    // memories ground the context ahead of derived ones, end-to-end over a
    // real estate. The estate leans on what it most trusts.
    #[test]
    fn ck_tr1_canonical_outranks_derived() {
        let (coord, h) = coord_with_parent();
        let c1 = capture(&coord, &h, "canonical-a", SourceType::Canonical);
        let c2 = capture(&coord, &h, "canonical-b", SourceType::Canonical);
        let _d1 = capture(&coord, &h, "derived-a", SourceType::Derived);
        let _d2 = capture(&coord, &h, "derived-b", SourceType::Derived);

        let out = run_trust_grounded_synthesis(&coord, &h, unconfirmed(), NOW).expect("trust");
        assert_eq!(out.ranked_ids.len(), 4);
        // The two highest-ranked memories are the canonical ones.
        let top2: HashSet<&String> = out.ranked_ids[0..2].iter().collect();
        assert!(
            top2.contains(&c1) && top2.contains(&c2),
            "canonical memories rank first"
        );
        assert_eq!(out.high_trust_count, 2, "two canonical = two high-trust");
        assert!(
            !out.context.summary.is_empty(),
            "a grounded document is produced"
        );
    }

    // CK-TR-2: an empty estate yields an empty ranking and zero high-trust —
    // guarded, no panic.
    #[test]
    fn ck_tr2_empty_estate_guarded() {
        let (coord, h) = coord_with_parent();
        let out = run_trust_grounded_synthesis(&coord, &h, unconfirmed(), NOW).expect("trust");
        assert!(out.ranked_ids.is_empty());
        assert_eq!(out.high_trust_count, 0);
    }
}
