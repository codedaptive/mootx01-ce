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

/// The three lifecycle clusters a [`RowState`] belongs to, per the
/// scale-gapped raw layout above. Membership is a single
/// shift-and-mask on the state raw: `cluster(s) = (s >> 4) & 0x3`.
/// This is the canonical partition every consumer that needs an
/// active-vs-retired view must derive from — never a hand-rolled
/// raw-value boundary (the gap states 4–15 / 20–31 / 34+ are
/// undefined and a magic boundary misclassifies any state added
/// there).
///
///   A — active / becoming   (currently believed: Active, Pending,
///                            Contested, Accepted)
///   B — superseded / historical (retired but revivable: Superseded,
///                            Decayed, Withdrawn, Expired)
///   C — terminal             (retired, non-revivable: Rejected,
///                            Tombstoned)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum RowStateCluster {
    A = 0, // active / becoming — the currently-believed cluster
    B = 1, // superseded / historical — retired, revivable
    C = 2, // terminal — retired, non-revivable
}

impl RowStateCluster {
    /// `true` when this is the believed/active cluster (A). Every
    /// other cluster is a retired lifecycle stage.
    pub fn is_active(self) -> bool {
        self == RowStateCluster::A
    }
}

impl RowState {
    /// The exclusive upper bound (in raw 6-bit state space, 0..=63) of
    /// the active cluster (A): every defined active state — Active=0,
    /// Pending=1, Contested=2, Accepted=3 — has a raw strictly below
    /// this value, and every retired state (cluster B from 16, cluster
    /// C from 32) has a raw at or above it. It is exactly the cluster-B
    /// floor (`Superseded as u8 == 16`), which the scale-gapped layout
    /// fixes so that `raw < bound` is equivalent to
    /// `cluster_of_raw_state(raw).is_some_and(|c| c.is_active())` for
    /// every defined raw.
    ///
    /// This is the single named boundary a storage-layer predicate uses
    /// to select the active set on the persisted 6-bit state field
    /// (e.g. SQL `WHERE g_state_cluster < ACTIVE_CLUSTER_UPPER_BOUND_RAW`),
    /// where it cannot call `cluster_of_raw_state`. Code paths that hold
    /// a decoded raw must prefer `cluster_of_raw_state(raw)`; this
    /// constant exists so the predicate that cannot call a function
    /// still derives from the same automaton, never a bare magic number.
    pub const ACTIVE_CLUSTER_UPPER_BOUND_RAW: u8 = RowState::Superseded as u8;

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

    /// The lifecycle cluster this state belongs to, computed by the
    /// canonical `(raw >> 4) & 0x3` shift-and-mask. Cluster A is the
    /// currently-believed/active partition; clusters B and C are
    /// retired. This is the single source of the active/retired
    /// partition — consumers must not re-derive it from a raw-value
    /// boundary.
    pub fn cluster(self) -> RowStateCluster {
        // Boundaries 0/16/32 make the cluster a pure shift-and-mask;
        // every defined raw maps into 0..=2.
        match ((self as u8) >> 4) & 0x3 {
            0 => RowStateCluster::A,
            1 => RowStateCluster::B,
            _ => RowStateCluster::C,
        }
    }

    /// `true` when this state is in the believed/active cluster (A).
    pub fn is_active_cluster(self) -> bool {
        self.cluster().is_active()
    }

    /// Classify a raw 6-bit state value (as stored in adjective-bitmap
    /// bits 0–5) into its lifecycle cluster, or `None` if `raw` is not
    /// one of the ten defined scale-gapped states. Callers reading the
    /// state field out of a persisted bitmap use this to derive the
    /// active/retired partition from the same automaton the rest of
    /// the system uses, rather than a hand-rolled boundary.
    pub fn cluster_of_raw_state(raw: u8) -> Option<RowStateCluster> {
        Self::from_raw(raw).map(Self::cluster)
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

impl std::fmt::Display for RowState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // English state names used in user-facing error messages.
        // These are the canonical lowercase names that surface at the ARIA
        // boundary, consistent with the moot tool descriptions and cookbook §9.1.
        let name = match self {
            RowState::Active     => "active",
            RowState::Pending    => "pending",
            RowState::Contested  => "contested",
            RowState::Accepted   => "accepted",
            RowState::Superseded => "superseded",
            RowState::Decayed    => "decayed",
            RowState::Withdrawn  => "withdrawn",
            RowState::Expired    => "expired",
            RowState::Rejected   => "rejected",
            RowState::Tombstoned => "tombstoned",
        };
        write!(f, "{name}")
    }
}

impl std::fmt::Display for RowVerb {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // English verb names used in user-facing error messages.
        // Match the token() strings in substrate_types exactly so log messages
        // and MCP error text agree.
        let name = match self {
            RowVerb::Capture        => "capture",
            RowVerb::Observe        => "observe",
            RowVerb::Mutate         => "mutate",
            RowVerb::Retract        => "retract",
            RowVerb::Promote        => "promote",
            RowVerb::Reject         => "reject",
            RowVerb::Supersede      => "supersede",
            RowVerb::Decay          => "decay",
            RowVerb::Expire         => "expire",
            RowVerb::Contest        => "contest",
            RowVerb::ResolveContest => "resolveContest",
            RowVerb::Tombstone      => "tombstone",
        };
        write!(f, "{name}")
    }
}

impl std::fmt::Display for RowStateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IllegalTransition(s, v) => {
                // Emit the compact state-and-verb descriptor only — no "illegal"
                // prefix here. GateViolation::BasisViolation(e) wraps this with
                // "illegal state transition: {e}", producing the canonical form
                // "illegal state transition: active --reject-->". Keeping the prefix
                // out of RowStateError::Display avoids the doubled-prefix problem
                // ("illegal state transition: illegal transition: active --reject-->")
                // that broke the describe_gate_rejection parser.
                //
                // Display tokens are lowercase English via RowState/RowVerb::Display
                // (same casing as the ARIA verb surface / RowVerb::token()).
                write!(f, "{s} --{v}-->")
            }
            Self::ViolatesInvariant(msg) => {
                write!(f, "safety invariant violation: {msg}")
            }
        }
    }
}

impl std::error::Error for RowStateError {}

#[cfg(test)]
mod cluster_tests {
    use super::*;

    /// The public `cluster()` accessor must equal the canonical
    /// shift-and-mask `(raw>>4)&0x3` for every defined state, and the
    /// believed/active partition must be exactly Cluster A. Parity with
    /// the Swift `RowState.cluster` accessor.
    #[test]
    fn cluster_matches_shift_and_mask_for_every_state() {
        let all = [
            RowState::Active,
            RowState::Pending,
            RowState::Contested,
            RowState::Accepted,
            RowState::Superseded,
            RowState::Decayed,
            RowState::Withdrawn,
            RowState::Expired,
            RowState::Rejected,
            RowState::Tombstoned,
        ];
        for s in all {
            let expected = match ((s as u8) >> 4) & 0x3 {
                0 => RowStateCluster::A,
                1 => RowStateCluster::B,
                _ => RowStateCluster::C,
            };
            assert_eq!(s.cluster(), expected, "{s:?} cluster mismatch");
        }
        for s in [RowState::Active, RowState::Pending, RowState::Contested, RowState::Accepted] {
            assert_eq!(s.cluster(), RowStateCluster::A);
            assert!(s.is_active_cluster());
        }
        for s in [RowState::Superseded, RowState::Decayed, RowState::Withdrawn, RowState::Expired] {
            assert_eq!(s.cluster(), RowStateCluster::B);
            assert!(!s.is_active_cluster());
        }
        for s in [RowState::Rejected, RowState::Tombstoned] {
            assert_eq!(s.cluster(), RowStateCluster::C);
            assert!(!s.is_active_cluster());
        }
    }

    /// `cluster_of_raw_state` classifies every defined 6-bit raw and
    /// returns None for every undefined gap raw (4–15, 20–31, 34–63).
    /// A gap raw is explicitly None, never silently bucketed as active.
    #[test]
    fn cluster_of_raw_state_covers_all_raws() {
        for raw in 0u8..=63 {
            let got = RowState::cluster_of_raw_state(raw);
            match RowState::from_raw(raw) {
                Some(state) => assert_eq!(got, Some(state.cluster())),
                None => assert_eq!(got, None, "gap raw {raw} must be None, not a cluster"),
            }
        }
    }

    /// The named active boundary equals the cluster-B floor (16), and a
    /// `raw < ACTIVE_CLUSTER_UPPER_BOUND_RAW` storage predicate agrees
    /// with the automaton (`cluster_of_raw_state(raw).is_active()`) on
    /// every defined raw. Storage predicates use this constant because
    /// they cannot call the classifier; this test pins them to the same
    /// automaton boundary. (Undefined gap raws 4–15 are the only place
    /// the two could diverge — there the automaton is authoritative and
    /// no real row ever carries such a raw.)
    #[test]
    fn active_boundary_matches_cluster_for_defined_raws() {
        assert_eq!(RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW, 16);
        assert_eq!(
            RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW,
            RowState::Superseded as u8
        );
        for raw in 0u8..=63 {
            if let Some(cluster) = RowState::cluster_of_raw_state(raw) {
                let predicate = raw < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW;
                assert_eq!(
                    predicate,
                    cluster.is_active(),
                    "defined raw {raw}: storage predicate (< {}) must match automaton active-cluster",
                    RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW
                );
            }
        }
    }
}
