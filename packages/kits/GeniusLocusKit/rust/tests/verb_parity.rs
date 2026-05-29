// verb_parity.rs — conformance gate for the Rust verb surface.
//
// Shared vectors below mirror the Swift `VerbSurfaceTests.swift`
// AriaLexicon assertions. The unit of conformance is the (verb, noun)
// acceptance matrix and the nine-verb method-name set, not the
// per-drawer dispatch payload — the LocusKit Rust port has not
// shipped, so per-drawer parity is out of scope here. When the Swift
// surface changes a verb name, an acceptance row, or the surface
// target list, this file must change in lock-step.

use genius_locus_kit::{
    Acceptance, AssociateFrame, ExpungeFrame, Noun, ProposeFrame,
    ReanchorFrame, SchedulerProposalKind as ProposalKind, Surface, SurfaceTarget,
    Verb, VerbError, VERB_NAMES,
};

/// `Verb` enumerates exactly the nine cases the Swift mirror does, in
/// the same order. Swift declares the cases in `Verb.swift`; the Rust
/// `Verb::ALL` array mirrors that declaration order.
#[test]
fn verb_count_and_names_match_swift() {
    assert_eq!(Verb::ALL.len(), 9);
    let expected: [&str; 9] = [
        "capture", "reanchor", "mutate", "withdraw", "expunge",
        "recall", "propose", "associate", "learn",
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
        "capture", "recall", "mutate", "withdraw", "expunge",
        "reanchor", "learn", "propose", "associate",
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
        (Drawer, &[Capture, Reanchor, Mutate, Withdraw, Expunge, Recall]),
        (Tunnel, &[Capture, Mutate, Withdraw, Expunge, Recall]),
        (KgFact, &[Mutate, Withdraw, Expunge, Recall]),
        (Vector, &[]),
        (DiaryEntry, &[Recall]),
        (Proposal, &[Mutate, Withdraw, Expunge, Recall]),
        (Association, &[Mutate, Expunge, Recall]),
        (LearnedReference, &[Learn, Mutate, Withdraw, Expunge, Recall]),
    ];
    for (noun, expected) in table.iter() {
        let got = Acceptance::verbs(*noun);
        assert_eq!(got, *expected,
            "acceptance row for {:?} drifted from Swift", noun);
    }
}

/// Vector accepts no verbs — every (Vector, *) pair is illegal per
/// the matrix. Mirrors
/// `VerbSurfaceTests.testEnumeratedIllegalPairsAreRejected`.
#[test]
fn vector_rejects_every_verb() {
    for verb in Verb::ALL.iter() {
        assert!(!Acceptance::accepts(Noun::Vector, *verb),
            "Vector should reject {:?}", verb);
    }
}

/// Every surface target is accepted by the §7.2 matrix. Mirrors
/// `VerbSurfaceTests.testSurfaceTargetsAreAcceptedByLexicon`.
#[test]
fn surface_targets_are_all_accepted() {
    assert!(SurfaceTarget::every_target_accepted());
    assert_eq!(SurfaceTarget::ALL.len(), 7);
}

/// The boundary-side `EmptyReanchor` guard fires before any dispatch
/// when neither `to_room` nor `to_lattice` is supplied. Matches
/// `VerbSurfaceTests.testReanchorEmptyRaisesGuard`.
#[test]
fn reanchor_empty_raises_guard() {
    let s = Surface::new();
    let frame = ReanchorFrame {
        row_id: "row-1".into(),
        to_room: None,
        to_lattice: None,
    };
    let err = s.reanchor(frame).unwrap_err();
    match err {
        VerbError::EmptyReanchor { row_id } => assert_eq!(row_id, "row-1"),
        other => panic!("expected EmptyReanchor, got {:?}", other),
    }
}

/// The boundary-side `ExpungeNotConfirmed` guard fires when
/// `confirmation = false`. Matches
/// `VerbSurfaceTests.testExpungeWithoutConfirmationRaisesGuard`.
#[test]
fn expunge_without_confirmation_raises_guard() {
    let s = Surface::new();
    let frame = ExpungeFrame {
        row_id: "row-1".into(),
        reason: "test".into(),
        confirmation: false,
    };
    let err = s.expunge(frame).unwrap_err();
    match err {
        VerbError::ExpungeNotConfirmed { row_id } => assert_eq!(row_id, "row-1"),
        other => panic!("expected ExpungeNotConfirmed, got {:?}", other),
    }
}

/// `propose` raises `NotSupportedByEstate("propose")` on this
/// scaffold. Matches `VerbSurfaceTests.testProposeRaisesNotSupported`.
#[test]
fn propose_raises_not_supported() {
    let s = Surface::new();
    let frame = ProposeFrame {
        target: "row-1".into(),
        kind: ProposalKind::Amend,
        justification: None,
    };
    match s.propose(frame).unwrap_err() {
        VerbError::NotSupportedByEstate { verb } => assert_eq!(verb, "propose"),
        other => panic!("expected NotSupportedByEstate('propose'), got {:?}", other),
    }
}

/// `associate` raises `NotSupportedByEstate("associate")` on this
/// scaffold. Matches `VerbSurfaceTests.testAssociateRaisesNotSupported`.
#[test]
fn associate_raises_not_supported() {
    let s = Surface::new();
    let frame = AssociateFrame {
        a: "row-a".into(),
        b: "row-b".into(),
        weight: 0.5,
    };
    match s.associate(frame).unwrap_err() {
        VerbError::NotSupportedByEstate { verb } => assert_eq!(verb, "associate"),
        other => panic!("expected NotSupportedByEstate('associate'), got {:?}", other),
    }
}
