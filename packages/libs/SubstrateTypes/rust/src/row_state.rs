//! Row lifecycle data types per cookbook §2.3 / §9.1 / §10.
//!
//! Moved from substrate-lib in Phase 6.4 of the pre-ship refactor
//! (decision 2026-05-28 §6.6).
//!
//! Only the value types live here: `RowState`, `RowVerb`,
//! `RowStateError`, plus the small data-side accessors
//! (`RowState::from_raw`, `RowVerb::token`). The transition
//! table itself and the `validate` / `check_forbidden_combinations`
//! logic remain in substrate-lib's row_state.rs (compute, not
//! data — moves to substrate-kernel when the algebra/kernel split
//! lands).

/// The ten row states per cookbook §9.1 / §2.3 with explicit
/// scale-gapped raw values per the §2.8 verification table. The
/// cluster boundaries at 0 / 16 / 32 are chosen so cluster
/// membership is a single shift-and-mask:
/// `cluster(s) = (s >> 4) & 0x3`.
///
///   Cluster A (active / becoming):       Active=0, Pending=1,
///                                        Contested=2, Accepted=3
///   Cluster B (superseded / historical): Superseded=16, Decayed=17,
///                                        Withdrawn=18, Expired=19
///   Cluster C (terminal):                Rejected=32, Tombstoned=33
#[cfg_attr(feature = "serde-support", derive(serde_repr::Serialize_repr, serde_repr::Deserialize_repr))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum RowState {
    Active     = 0,   // visible and current (most rows start here)
    Pending    = 1,   // freshly captured proposal awaiting confirmation
    Contested  = 2,   // multiple replicas disagree
    Accepted   = 3,   // captured AND explicitly accepted (audit-grade)
    Superseded = 16,  // replaced by a successor row
    Decayed    = 17,  // matrix decay reduced confidence below threshold
    Withdrawn  = 18,  // explicit retraction by user/agent
    Expired    = 19,  // TTL elapsed
    Rejected   = 32,  // captured but explicitly rejected on review
    Tombstoned = 33,  // hard-deleted (rare; legal compliance only)
}

impl RowState {
    /// Construct from a raw u8, returning None if the value is not
    /// one of the ten cookbook §2.3 scale-gapped raws.
    pub fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Active),
            1 => Some(Self::Pending),
            2 => Some(Self::Contested),
            3 => Some(Self::Accepted),
            16 => Some(Self::Superseded),
            17 => Some(Self::Decayed),
            18 => Some(Self::Withdrawn),
            19 => Some(Self::Expired),
            32 => Some(Self::Rejected),
            33 => Some(Self::Tombstoned),
            _ => None,
        }
    }
}

/// Mutations recognized by the automaton. Maps onto cookbook
/// § 10 verbs plus a few internal events.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde-support", serde(rename_all = "camelCase"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RowVerb {
    Capture,
    Observe,
    Mutate,
    Retract,
    Promote,
    Reject,
    Supersede,
    Decay,
    Expire,
    Contest,
    ResolveContest,
    Tombstone,
}

impl RowVerb {
    /// Verb name, matching the Swift `RowVerb: String` rawValue exactly,
    /// so the audit-gate content-ID hashes the same verb bytes on both
    /// ports (M8 / Appendix C name-keyed identity).
    pub fn token(&self) -> &'static str {
        match self {
            RowVerb::Capture => "capture",
            RowVerb::Observe => "observe",
            RowVerb::Mutate => "mutate",
            RowVerb::Retract => "retract",
            RowVerb::Promote => "promote",
            RowVerb::Reject => "reject",
            RowVerb::Supersede => "supersede",
            RowVerb::Decay => "decay",
            RowVerb::Expire => "expire",
            RowVerb::Contest => "contest",
            RowVerb::ResolveContest => "resolveContest",
            RowVerb::Tombstone => "tombstone",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowStateError {
    IllegalTransition(RowState, RowVerb),
    ViolatesInvariant(&'static str),
}

impl std::fmt::Display for RowStateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IllegalTransition(s, v) => {
                write!(f, "illegal transition: {s:?} --{v:?}-->")
            }
            Self::ViolatesInvariant(msg) => {
                write!(f, "safety invariant violation: {msg}")
            }
        }
    }
}

impl std::error::Error for RowStateError {}
