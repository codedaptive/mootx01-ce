// verb_parity.rs — conformance gate for the Rust verb surface.
//
// Shared vectors below mirror the Swift `VerbSurfaceTests.swift`
// AriaLexicon assertions. The unit of conformance is the (verb, noun)
// acceptance matrix and the nine-verb method-name set, not the
// per-drawer dispatch payload. When the Swift surface changes a verb
// name, an acceptance row, or the surface target list, this file must
// change in lock-step.
//
// The live dispatch surface is `EstateCoordinator`; tests that exercise
// boundary guards or per-verb behavior call it directly.

use std::sync::Arc;

use genius_locus_kit::{
    Acceptance, AssociateFrame, EstateCoordinator, EstateHandle, Noun, ProposeFrame,
    SchedulerProposalKind as ProposalKind, SurfaceTarget, Verb, VerbDispatchError, VerbError,
    VERB_NAMES,
};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// `Verb` enumerates exactly the nine cases the Swift mirror does, in
/// the same order. Swift declares the cases in `Verb.swift`; the Rust
/// `Verb::ALL` array mirrors that declaration order.
#[test]
fn verb_count_and_names_match_swift() {
    assert_eq!(Verb::ALL.len(), 9);
    let expected: [&str; 9] = [
        "capture",
        "reanchor",
        "mutate",
        "withdraw",
        "expunge",
        "recall",
        "propose",
        "associate",
        "learn",
    ];
    for (verb, name) in Verb::ALL.iter().zip(expected.iter()) {
        assert_eq!(verb.name(), *name);
    }
}

/// The flat method-name set the surface publishes equals the Swift
/// `glkMethodNames` array (`VerbSurfaceTests.testGLKMethodNamesMapToLexiconVerbs`).
#[test]
fn surface_verb_names_match_swift() {
    assert_eq!(VERB_NAMES.len(), 9);
    let expected: [&str; 9] = [
        "capture",
        "recall",
        "mutate",
        "withdraw",
        "expunge",
        "reanchor",
        "learn",
        "propose",
        "associate",
    ];
    for (got, want) in VERB_NAMES.iter().zip(expected.iter()) {
        assert_eq!(got, want);
    }
}

/// `Noun` enumerates the eight storage shapes in the same order Swift
/// declares them in `Noun.swift`.
#[test]
fn noun_count_matches_swift() {
    assert_eq!(Noun::ALL.len(), 8);
    assert_eq!(Noun::PRIMARY, Noun::Drawer);
}

/// The §7.2 acceptance matrix encodes the same closed verb sets per
/// noun the Swift `Acceptance.verbs(for:)` returns.
#[test]
fn acceptance_matrix_matches_swift() {
    use Noun::*;
    use Verb::*;
    let table: [(Noun, &[Verb]); 8] = [
        (
            Drawer,
            &[Capture, Reanchor, Mutate, Withdraw, Expunge, Recall],
        ),
        (Tunnel, &[Capture, Mutate, Withdraw, Expunge, Recall]),
        (KgFact, &[Mutate, Withdraw, Expunge, Recall]),
        (Vector, &[]),
        (DiaryEntry, &[Recall]),
        (Proposal, &[Propose, Mutate, Withdraw, Expunge, Recall]),
        (Association, &[Associate, Mutate, Expunge, Recall]),
        (
            LearnedReference,
            &[Learn, Mutate, Withdraw, Expunge, Recall],
        ),
    ];
    for (noun, expected) in table.iter() {
        let got = Acceptance::verbs(*noun);
        assert_eq!(
            got, *expected,
            "acceptance row for {:?} drifted from Swift",
            noun
        );
    }
}

/// Vector accepts no verbs — every (Vector, *) pair is illegal per
/// the matrix. Mirrors
/// `VerbSurfaceTests.testEnumeratedIllegalPairsAreRejected`.
#[test]
fn vector_rejects_every_verb() {
    for verb in Verb::ALL.iter() {
        assert!(
            !Acceptance::accepts(Noun::Vector, *verb),
            "Vector should reject {:?}",
            verb
        );
    }
}

/// Every surface target is accepted by the §7.2 matrix. Mirrors
/// `VerbSurfaceTests.testSurfaceTargetsAreAcceptedByLexicon`.
#[test]
fn surface_targets_are_all_accepted() {
    assert!(SurfaceTarget::every_target_accepted());
    assert_eq!(SurfaceTarget::ALL.len(), 7);
}

// The boundary-guard tests (`reanchor_empty_raises_guard` and
// `expunge_without_confirmation_raises_guard`) are covered by coordinator
// CO-4 and CO-3 respectively in `coordinator.rs`'s inline `#[cfg(test)]`
// block. Those tests carry the Swift parity-name comments and run
// on the live EstateCoordinator, which is the authoritative dispatch
// surface. Duplicating them here against a removed Surface stub would
// test dead code. See `co4_empty_reanchor_is_refused` and
// `co3_expunge_requires_confirmation` in coordinator.rs for the
// retained parity assertions.

/// `propose` is now live — a missing target row produces
/// `UnderlyingEstateFailure("propose", ...)`.
/// Mirrors `VerbSurfaceTests.proposeWithMissingTargetThrows`.
#[test]
fn propose_with_missing_target_produces_underlying_failure() {
    let (coord, h) = open_one();
    let frame = ProposeFrame {
        target: "nonexistent-row".into(),
        kind: ProposalKind::Amend,
        justification: None,
    };
    match coord.propose(&h, frame, 1_700_000_000).unwrap_err() {
        VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure { verb, .. }) => {
            assert_eq!(verb, "propose")
        }
        other => panic!("expected UnderlyingEstateFailure('propose'), got {:?}", other),
    }
}

/// `associate` is now live — missing endpoint rows produce
/// `UnderlyingEstateFailure("associate", ...)`.
/// Mirrors `VerbSurfaceTests.associateWithMissingEndpointsThrows`.
#[test]
fn associate_with_missing_endpoints_produces_underlying_failure() {
    let (coord, h) = open_one();
    let frame = AssociateFrame {
        a: "missing-a".into(),
        b: "missing-b".into(),
        weight: 0.5,
    };
    match coord.associate(&h, frame, 1_700_000_000).unwrap_err() {
        VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure { verb, .. }) => {
            assert_eq!(verb, "associate")
        }
        other => panic!(
            "expected UnderlyingEstateFailure('associate'), got {:?}",
            other
        ),
    }
}

/// A stale handle raises `EstateNotOpen` for `propose` — handle validation
/// runs before any verb dispatch. Mirrors the Swift `estate(for:)` pattern.
#[test]
fn propose_on_closed_handle_raises_estate_not_open() {
    let (mut coord, h) = open_one();
    coord.close(&h).expect("close");
    let frame = ProposeFrame {
        target: "row-1".into(),
        kind: ProposalKind::Amend,
        justification: None,
    };
    assert_eq!(
        coord.propose(&h, frame, 1_700_000_000).unwrap_err(),
        VerbDispatchError::EstateNotOpen {
            estate_uuid: h.estate_uuid
        }
    );
}

/// A stale handle raises `EstateNotOpen` for `associate` — handle validation
/// runs before any verb dispatch.
#[test]
fn associate_on_closed_handle_raises_estate_not_open() {
    let (mut coord, h) = open_one();
    coord.close(&h).expect("close");
    let frame = AssociateFrame {
        a: "row-a".into(),
        b: "row-b".into(),
        weight: 0.5,
    };
    assert_eq!(
        coord.associate(&h, frame, 1_700_000_000).unwrap_err(),
        VerbDispatchError::EstateNotOpen {
            estate_uuid: h.estate_uuid
        }
    );
}
