// verbs/mod.rs — Rust vocabulary and frame types for the GeniusLocusKit
// verb surface.
//
// Parity gate: the (Verb, Noun) acceptance enumeration and the
// nine-verb method-name set are conformance-tested against the Swift
// reference. The shared vectors live in `tests/verb_parity.rs` and
// the Swift counterparts are asserted in `VerbSurfaceTests.swift`.
// Whenever the Swift surface changes a verb name, a frame slot set,
// or an acceptance row, the Rust mirror must follow.
//
// The live verb dispatch surface is `EstateCoordinator` in
// `coordinator.rs`, the faithful Rust analog of the Swift
// `extension GeniusLocusKit` blocks in `Verbs/VerbSurface.swift`.
// The parity taxonomy (VerbError, VERB_NAMES, Verb, Noun, SurfaceTarget)
// lives here in `lexicon.rs` and is imported by both the coordinator
// and the parity tests.

pub mod frames;
pub mod lexicon;

pub use frames::{
    AssociateFrame, CaptureFrame, ExpungeFrame, LatticeAnchor, LearnFrame, MutateFrame,
    MutationKind, ProposeFrame, ReanchorFrame, RecallFrame, WithdrawFrame,
};
pub use lexicon::{
    Acceptance, Adjective, Noun, NounRole, SurfaceTarget, Verb, VerbError, VerbFlow, VERB_NAMES,
};
