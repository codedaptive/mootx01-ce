// surface.rs — Rust mirror of the GLK unified verb surface.
//
// The Rust scaffold cannot actually dispatch verbs against an estate
// because the LocusKit Rust port has not yet shipped. What the
// scaffold delivers is the *shape* of the surface: a Surface type
// that owns the per-handle dispatch site, the VerbError taxonomy
// callers must branch on, the boundary-side guards (empty reanchor,
// unconfirmed expunge), and the identity-by-name mapping the
// AriaLexicon conformance gates on. Downstream missions wire the
// dispatch to a real Rust Estate when that port lands.
//
// The Swift surface lives in
// `Sources/GeniusLocusKit/Verbs/VerbSurface.swift`; verb method names
// and error case names must match the Swift side bit for bit, because
// the parity test asserts the name set.

use crate::verbs::frames::{
    AssociateFrame, CaptureFrame, ExpungeFrame, LearnFrame, MutateFrame, ProposeFrame,
    ReanchorFrame, RecallFrame, RowId, WithdrawFrame,
};

/// The nine verb method names the GLK surface publishes. Order
/// matters: the parity test compares this list against the Swift
/// `glkMethodNames` array, which is the authoritative method-name
/// enumeration on the Swift side.
pub const VERB_NAMES: [&str; 9] = [
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

/// Errors raised by the GeniusLocusKit unified verb surface. Mirrors
/// the Swift `VerbError` enum, case-for-case. Carries the same data
/// the Swift side does so callers consuming both ports can branch on
/// matching shapes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerbError {
    /// The verb dispatched, reached the estate, and the underlying
    /// call failed. The associated value is the textual description
    /// of the underlying error so concrete error taxonomies do not
    /// leak across the GLK boundary.
    UnderlyingEstateFailure { verb: String, reason: String },

    /// The verb is part of the nine-verb vocabulary but the
    /// underlying estate does not yet support it. Today this is the
    /// case for the same six verbs as on the Swift side: mutate,
    /// expunge, reanchor, learn, propose, associate.
    NotSupportedByEstate { verb: String },

    /// The combination of verb and noun is rejected by the §7.2
    /// acceptance matrix. Reserved for future per-verb runtime
    /// checks; today only the matrix data lookup raises this.
    RejectedByLexicon { verb: String, noun: String },

    /// A reanchor frame supplied neither `to_room` nor `to_lattice`.
    EmptyReanchor { row_id: RowId },

    /// An expunge frame had `confirmation = false`.
    ExpungeNotConfirmed { row_id: RowId },
}

/// The GLK unified verb surface (Rust scaffold).
///
/// `Surface` does not own an estate registry today; it is a function
/// surface that operates on caller-supplied handles. When the Rust
/// LocusKit port lands, downstream missions wire `Surface` into a
/// coordinator that owns the per-handle Estate state, matching the
/// Swift `extension GeniusLocusKit`.
pub struct Surface;

impl Surface {
    /// Construct a new surface. Stateless today; the constructor
    /// exists so call sites read the same as the Swift `GeniusLocusKit()`
    /// initialiser.
    pub fn new() -> Self {
        Self
    }

    // MARK: - capture

    /// File a new drawer. Scaffold: the LocusKit Rust port is not
    /// present so the call shape exists but the dispatch raises
    /// `NotSupportedByEstate("capture")`. Downstream missions
    /// replace this body with a live dispatch when the port ships.
    pub fn capture(&self, _frame: CaptureFrame) -> Result<RowId, VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "capture".into(),
        })
    }

    // MARK: - recall

    /// Recall rows. Scaffold returns an empty vector under
    /// `NotSupportedByEstate("recall")` for the same reason as
    /// `capture`.
    pub fn recall(&self, _frame: RecallFrame) -> Result<Vec<RowId>, VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "recall".into(),
        })
    }

    // MARK: - mutate

    pub fn mutate(&self, _frame: MutateFrame) -> Result<(), VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "mutate".into(),
        })
    }

    // MARK: - withdraw

    pub fn withdraw(&self, _frame: WithdrawFrame) -> Result<(), VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "withdraw".into(),
        })
    }

    // MARK: - expunge

    pub fn expunge(&self, frame: ExpungeFrame) -> Result<(), VerbError> {
        if !frame.confirmation {
            return Err(VerbError::ExpungeNotConfirmed {
                row_id: frame.row_id,
            });
        }
        Err(VerbError::NotSupportedByEstate {
            verb: "expunge".into(),
        })
    }

    // MARK: - reanchor

    pub fn reanchor(&self, frame: ReanchorFrame) -> Result<(), VerbError> {
        if frame.to_room.is_none() && frame.to_lattice.is_none() {
            return Err(VerbError::EmptyReanchor {
                row_id: frame.row_id,
            });
        }
        Err(VerbError::NotSupportedByEstate {
            verb: "reanchor".into(),
        })
    }

    // MARK: - learn

    pub fn learn(&self, _frame: LearnFrame) -> Result<(), VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "learn".into(),
        })
    }

    // MARK: - propose

    /// Brain-layer verb. Always raises `NotSupportedByEstate` on this
    /// scaffold, matching the Swift surface's behavior until the
    /// Brain layer ships.
    pub fn propose(&self, _frame: ProposeFrame) -> Result<(), VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "propose".into(),
        })
    }

    // MARK: - associate

    /// Brain-layer verb. Always raises `NotSupportedByEstate`.
    pub fn associate(&self, _frame: AssociateFrame) -> Result<(), VerbError> {
        Err(VerbError::NotSupportedByEstate {
            verb: "associate".into(),
        })
    }
}

impl Default for Surface {
    fn default() -> Self {
        Self::new()
    }
}
