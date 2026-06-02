// verbs/mod.rs — Rust mirror of the GeniusLocusKit unified verb
// surface and AriaLexicon conformance.
//
// Parity gate: the (Verb, Noun) acceptance enumeration and the
// nine-verb method-name set are conformance-tested against the Swift
// reference. The shared vectors live in `tests/verb_parity.rs` and
// the Swift counterparts are asserted in `VerbSurfaceTests.swift`.
// Whenever the Swift surface changes a verb name, a frame slot set,
// or an acceptance row, the Rust mirror must follow.
//
// What this scaffold does NOT do: dispatch verbs against a live
// locus_kit::Estate. LocusKit Rust is fully shipped (503 tests);
// the `Surface` type here is a no-op placeholder that the parity
// test inspects by name rather than by behavior. Downstream missions
// wire the verb dispatch through to a live Estate.

pub mod frames;
pub mod lexicon;
pub mod surface;

pub use frames::{
    AssociateFrame, CaptureFrame, ExpungeFrame, LatticeAnchor, LearnFrame, MutateFrame,
    MutationKind, ProposeFrame, ReanchorFrame, RecallFrame, WithdrawFrame,
};
pub use lexicon::{Acceptance, Adjective, Noun, NounRole, SurfaceTarget, Verb, VerbFlow};
pub use surface::{Surface, VerbError, VERB_NAMES};
