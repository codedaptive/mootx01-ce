// non_drawer_recall_parity.rs — round-trip conformance for the non-drawer recall surfaces.
//
// Covers recall_proposals, recall_associations, and recall_learned_references.
// Each surface is exercised write-then-read, matching the pattern of the Swift
// KGFactVerbTests and VerbSurfaceTests. The authority for field semantics is
// VerbSurface.swift (recallProposals, recallAssociations, recallLearnedReferences).
//
// B-10a posture: none of these recall methods set trace_limit — they route
// through the internal read path (not recall_external), so no recall-trace rows
// are written. This mirrors Swift where these surfaces read-through without
// touching RecallTraceStore.
//
// recall_learned_references: the `learn` write path is live — it derives the
// reference's genuine lattice anchor from its SourceCatalogEntry and persists
// it. Tests verify: empty on fresh estate, stale handle raises EstateNotOpen,
// and a learn→recall round-trip returns the genuine reference.

use std::sync::Arc;

use genius_locus_kit::{
    AssociateFrame, EstateCoordinator, EstateHandle,
    // LearnFrame is the GLK-level verb boundary type — imported here so the
    // learn→recall round-trip test exercises the public-facing API, not the
    // LocusKit-internal LocusLearnFrame below the dispatch boundary.
    LearnFrame,
    ProposeFrame, SchedulerProposalKind as ProposalKind, VerbDispatchError,
};
use locus_kit::{
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
    source_catalog_entry::{SourceCatalogEntry, SourceKind},
};

const NOW: i64 = 1_700_000_000;

/// Open a fresh in-memory estate in a new coordinator. Returns (coordinator, handle).
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// A handle whose UUID is not registered in any coordinator — triggers
/// EstateNotOpen on all verb calls. Uses a fixed non-zero UUID pattern
/// ([99u8; 16]) that no open call would ever produce.
fn unregistered_handle() -> EstateHandle {
    EstateHandle {
        estate_uuid: [99u8; 16],
        zoom_window_low: 0,
        zoom_window_high: 100,
    }
}

/// Capture a drawer with the given content string and return its row ID.
/// Wing is "study", room convention is Typed/UDC-0. Uses `locus_kit::frames::CaptureFrame`
/// directly because the coordinator's internal `capture` method takes the LocusKit frame
/// (not the GLK-level re-export from `verbs/frames.rs`).
fn capture_drawer(coord: &EstateCoordinator, handle: &EstateHandle, content: &str) -> String {
    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "study",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-model-v1",
    );
    coord
        .capture(handle, frame, NOW)
        .expect("capture drawer")
        .id
}

// ---------------------------------------------------------------------------
// MARK: - recall_proposals
// ---------------------------------------------------------------------------

/// A proposal created via `propose` appears in `recall_proposals`.
///
/// Mirrors the round-trip pattern in Swift KGFactVerbTests:
/// write a fact through the write surface, then read it back through the
/// recall surface and assert field parity.
///
/// B-10a: recall_proposals does not pass through recall_external — no trace rows.
#[test]
fn recall_proposals_returns_filed_proposal() {
    let (coord, handle) = open_one();

    // Create a target drawer for the proposal.
    let drawer_id = capture_drawer(&coord, &handle, "proposal-target");

    let frame = ProposeFrame {
        target: drawer_id.clone(),
        kind: ProposalKind::Amend,
        justification: Some("test justification".to_string()),
    };
    let proposal = coord
        .propose(&handle, frame, NOW)
        .expect("propose should succeed with a valid target drawer");

    // The proposal must appear in the recall surface.
    let proposals = coord
        .recall_proposals(&handle)
        .expect("recall_proposals should succeed");

    assert_eq!(proposals.len(), 1, "exactly one proposal in a fresh estate after one propose call");
    assert_eq!(proposals[0].id, proposal.id, "round-trip id must match");
}

/// Multiple proposals all appear in recall_proposals, ordered by filed_at ascending.
///
/// Swift parity: recallProposals delegates to Estate.allProposals which sorts
/// by filedAt ascending. Two proposals filed at the same timestamp are returned
/// in insertion order (stable sort, substrate guarantee).
#[test]
fn recall_proposals_returns_all_proposals_ordered() {
    let (coord, handle) = open_one();

    let d1 = capture_drawer(&coord, &handle, "target-a");
    let d2 = capture_drawer(&coord, &handle, "target-b");

    let p1 = coord
        .propose(
            &handle,
            ProposeFrame { target: d1.clone(), kind: ProposalKind::Amend, justification: None },
            NOW,
        )
        .expect("propose p1");
    let p2 = coord
        .propose(
            &handle,
            ProposeFrame { target: d2.clone(), kind: ProposalKind::Amend, justification: None },
            NOW + 1,
        )
        .expect("propose p2");

    let proposals = coord
        .recall_proposals(&handle)
        .expect("recall_proposals");

    assert_eq!(proposals.len(), 2);
    // filed_at ascending: p1 (NOW) before p2 (NOW+1).
    assert_eq!(proposals[0].id, p1.id, "earlier proposal is first");
    assert_eq!(proposals[1].id, p2.id, "later proposal is second");
}

/// recall_proposals on a fresh estate returns an empty vec (not an error).
///
/// CO-13 promoted: the original CO-13 unit test verified Ok(empty vec); this
/// integration-level test confirms the same posture after the implementation
/// was promoted from stub to live.
#[test]
fn recall_proposals_empty_on_fresh_estate() {
    let (coord, handle) = open_one();
    let proposals = coord
        .recall_proposals(&handle)
        .expect("recall_proposals should succeed on fresh estate");
    assert!(proposals.is_empty(), "fresh estate has no proposals");
}

/// recall_proposals on a closed handle raises EstateNotOpen.
///
/// Handle validation runs before any verb dispatch — mirrors Swift
/// `GeniusLocusKitError.estateNotOpen` propagation.
#[test]
fn recall_proposals_stale_handle_raises_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord.recall_proposals(&bad_handle).unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "stale handle must raise EstateNotOpen, got: {err:?}"
    );
}

// ---------------------------------------------------------------------------
// MARK: - recall_associations
// ---------------------------------------------------------------------------

/// An association created via `associate` appears in `recall_associations`.
///
/// Mirrors the round-trip pattern in Swift VerbSurfaceTests for associations.
/// B-10a: recall_associations does not pass through recall_external — no trace rows.
#[test]
fn recall_associations_returns_filed_association() {
    let (coord, handle) = open_one();

    // Two drawers are required as association endpoints.
    let d_a = capture_drawer(&coord, &handle, "assoc-endpoint-a");
    let d_b = capture_drawer(&coord, &handle, "assoc-endpoint-b");

    let frame = AssociateFrame {
        a: d_a.clone(),
        b: d_b.clone(),
        weight: 0.75,
    };
    let association = coord
        .associate(&handle, frame, NOW)
        .expect("associate should succeed with valid endpoints");

    let associations = coord
        .recall_associations(&handle)
        .expect("recall_associations should succeed");

    assert_eq!(associations.len(), 1, "one association after one associate call");
    assert_eq!(associations[0].id, association.id, "round-trip id must match");
}

/// Multiple associations all appear in recall_associations, ordered by filed_at ascending.
#[test]
fn recall_associations_returns_all_ordered() {
    let (coord, handle) = open_one();

    let d1 = capture_drawer(&coord, &handle, "a1");
    let d2 = capture_drawer(&coord, &handle, "a2");
    let d3 = capture_drawer(&coord, &handle, "a3");

    let a1 = coord
        .associate(
            &handle,
            AssociateFrame { a: d1.clone(), b: d2.clone(), weight: 0.5 },
            NOW,
        )
        .expect("associate a1-a2");
    let a2 = coord
        .associate(
            &handle,
            AssociateFrame { a: d2.clone(), b: d3.clone(), weight: 0.8 },
            NOW + 1,
        )
        .expect("associate a2-a3");

    let associations = coord
        .recall_associations(&handle)
        .expect("recall_associations");

    assert_eq!(associations.len(), 2);
    // filed_at ascending: a1 (NOW) before a2 (NOW+1).
    assert_eq!(associations[0].id, a1.id, "earlier association is first");
    assert_eq!(associations[1].id, a2.id, "later association is second");
}

/// recall_associations on a fresh estate returns an empty vec (not an error).
#[test]
fn recall_associations_empty_on_fresh_estate() {
    let (coord, handle) = open_one();
    let associations = coord
        .recall_associations(&handle)
        .expect("recall_associations should succeed on fresh estate");
    assert!(associations.is_empty(), "fresh estate has no associations");
}

/// recall_associations on a closed handle raises EstateNotOpen.
#[test]
fn recall_associations_stale_handle_raises_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord.recall_associations(&bad_handle).unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "stale handle must raise EstateNotOpen, got: {err:?}"
    );
}

// ---------------------------------------------------------------------------
// MARK: - recall_learned_references
// ---------------------------------------------------------------------------
//
// The `learn` write path is live: it derives the reference's genuine lattice
// anchor from its SourceCatalogEntry and persists it. The recall surface
// (recall_learned_references) delegates to Estate::all_learned_references.
//
// Tests verify:
//   1. Empty result on a fresh estate (the recall surface is live and does not crash).
//   2. Stale handle raises EstateNotOpen (handle validation runs before any dispatch).
//   3. A learn→recall round-trip returns the genuine reference (write side is live).

/// recall_learned_references on a fresh estate returns an empty vec (not an error).
///
/// CO-15 promoted to integration level. Both surfaces are live: recall reads
/// through to the estate, and the write side (learn) persists genuine
/// references (see learn_then_recall_round_trips_genuine_reference).
#[test]
fn recall_learned_references_empty_on_fresh_estate() {
    let (coord, handle) = open_one();
    let refs = coord
        .recall_learned_references(&handle)
        .expect("recall_learned_references should succeed on fresh estate");
    assert!(refs.is_empty(), "fresh estate has no learned references");
}

/// recall_learned_references on a closed handle raises EstateNotOpen.
///
/// Handle validation runs before any verb dispatch — the same guard pattern
/// as recall_proposals and recall_associations.
#[test]
fn recall_learned_references_stale_handle_raises_estate_not_open() {
    let coord = EstateCoordinator::new();
    let bad_handle = unregistered_handle();
    let err = coord.recall_learned_references(&bad_handle).unwrap_err();
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "stale handle must raise EstateNotOpen, got: {err:?}"
    );
}

/// `learn` writes a genuine reference and `recall_learned_references` reads it
/// back — the full write→read round-trip. The reference's anchor is the
/// source's genuine anchor (never a sentinel), proving the write side is live.
#[test]
fn learn_then_recall_round_trips_genuine_reference() {
    let (coord, handle) = open_one();
    let source = SourceCatalogEntry::new(
        "src-1",
        SourceKind::User,
        "https://example.com",
        LatticeAnchor::udc("004"),
        NOW,
        "cataloger",
    );
    let frame = LearnFrame::new(source, "https://example.com/page");
    let reference = coord
        .learn(&handle, frame, NOW)
        .expect("learn should succeed");
    assert_eq!(reference.lattice_anchor.udc_code, "004");
    assert!(!reference.lattice_anchor.udc_code.is_empty());

    let refs = coord
        .recall_learned_references(&handle)
        .expect("recall_learned_references should succeed");
    assert_eq!(refs.len(), 1, "the learned reference must be recallable");
    assert_eq!(refs[0].handle, "https://example.com/page");
    assert_eq!(refs[0].source_catalog_id, "src-1");
}
