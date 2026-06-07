//! Recall filter algebra and frames. Ports `Filter.swift` and the
//! `RecallFrame` / `Ordering` / `HydrationLevel` / `StateCluster`
//! types from `Frames.swift`.
//!
//! Per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 7.9.
//!
//! No `Filter` case takes a raw bit position, mask, or threshold
//! integer. Every case is either a named enum value or a domain-
//! meaningful argument. The evaluator (`bitmap_evaluator.rs`)
//! translates `Filter` cases into the bitmap primitives in
//! `bitmap_ops.rs` internally; callers never write `state < 3` or
//! `trust < 4`.
//!
//! ## Scope of the LP-1E port
//!
//! This module ports the types the bitmap evaluator consumes. The
//! `CaptureFrame`, `MutationKind`, and `LearnFrame` types from
//! `Frames.swift` belong to the Estate verb surface and land in
//! LP-1F (see `lib.rs` deferred-list).

use crate::adjectives::{AdjectiveSensitivity, State, Trust};
use crate::drawer_operational::{CaptureChannel, ContentKind};
use crate::estate_types::LatticeAnchor;
use crate::provenance::{Channel, Confidence, SourceType};
use uuid::Uuid;

// MARK: - Supporting types ----------------------------------------------------

/// Stable lineage identifier — the UUID identifying a content lineage.
/// All versions of the same content share one `LineageID` per spec § 5.10.
pub type LineageID = Uuid;

/// Wikidata Q-ID string (e.g. `"Q11165"`).
pub type WikidataQID = String;

// MARK: - StateCluster --------------------------------------------------------

/// State-cluster membership filter. Coarser than `State`; used when the
/// caller cares about the cluster, not the exact state value. Per spec
/// § 6.1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateCluster {
    /// State in {Active, Pending, Contested} — the "know now" cluster.
    KnowNow,
    /// State in {Superseded, Decayed, Withdrawn, Expired} — the
    /// "knew past" cluster.
    KnewPast,
    /// State in {Rejected, Accepted, Tombstoned} — the terminal cluster.
    Terminal,
}

// MARK: - HydrationLevel ------------------------------------------------------

/// How much of a row to include in a recall response. Per spec § 7.3.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HydrationLevel {
    /// Bitmap columns + structured-row fields only. No blob reads.
    Structured,
    /// All rungs hydrated on demand.
    Full,
    /// Bitmap columns only — the lightest tier.
    BitmapOnly,
}

// MARK: - Ordering ------------------------------------------------------------

/// Result ordering for recall. Per spec § 7.8.3.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ordering {
    /// Newest captured first.
    ByCaptureTimeDesc,
    /// Oldest captured first.
    ByCaptureTimeAsc,
    /// Evaluator-determined relevance score, descending. Requires the
    /// vector tier; unavailable until VectorKit ships, so the evaluator
    /// returns the input order as the documented stub behaviour.
    ByRelevanceDesc,
    /// Lexicographic ascending by `room`.
    ByRoomAsc,
}

// MARK: - Filter --------------------------------------------------------------

/// Named recall filter algebra. Per spec § 7.9.1.
///
/// `Filter` is recursive (`All` / `Any` / `Not` carry child filters),
/// so the Rust port boxes the `Not` child and uses `Vec<Filter>` for
/// the n-ary composition cases — same shape as the Swift `indirect
/// enum`.
///
/// A `RecallFrame.filter_chain` is `Vec<Filter>` interpreted as
/// implicit AND — equivalent to `Filter::All(filter_chain)`.
#[derive(Debug, Clone, PartialEq)]
pub enum Filter {
    // ---------- State queries ----------
    /// Rows in the know-now cluster (state < 3). Prepended as the
    /// default when no state filter is present.
    CurrentlyBelieve,
    /// Rows in the knew-past cluster (3 ≤ state < 7).
    UsedToBelieve,
    /// Rows in the terminal cluster (state ≥ 7).
    KnewOnceAndErased,
    /// Rows with exactly this state value.
    State(State),
    /// Rows in this state cluster.
    StateInCluster(StateCluster),

    // ---------- Trust queries ----------
    /// Rows with trust below the action threshold (trust < 4).
    /// Prepended as the default when no trust filter is present.
    Trustworthy,
    /// Rows with trust at or above the action threshold (trust ≥ 4).
    RequiresConfirmation,
    /// Rows with exactly this trust value.
    Trust(Trust),
    /// Rows with trust ≤ this value.
    TrustAtMost(Trust),

    // ---------- Sensitivity queries ----------
    /// Rows with exactly this adjective-sensitivity tier.
    Sensitivity(AdjectiveSensitivity),
    /// Rows with adjective-sensitivity ≤ this tier. Primary use is
    /// access-gate filtering when a caller's clearance is bounded.
    SensitivityAtMost(AdjectiveSensitivity),

    // ---------- Exportability queries ----------
    /// Rows marked as exportable (exportability == Public).
    Exportable,
    /// Rows marked as contained (exportability == Private).
    Contained,

    // ---------- Provenance queries ----------
    /// Rows where confirmation ≥ UserConfirmed. Prepended as the
    /// default when no provenance filter is present.
    UserConfirmed,
    /// Rows where confirmation == AutomatedConfirmed only (not user/peer/actuator).
    /// Mirrors Swift `automatedConfirmedOnly`; was `ModelConfirmedOnly` in v0.35 (F13 rename).
    AutomatedConfirmedOnly,
    /// Rows that are unconfirmed.
    Unconfirmed,
    /// Rows with this source type.
    SourceType(SourceType),
    /// Rows captured via this provenance channel.
    Channel(Channel),
    /// Rows with confidence at least this level.
    ConfidenceAtLeast(Confidence),

    // ---------- Operational queries ----------
    /// Rows captured via this channel (operational bitmap bits 0–3).
    CaptureChannel(CaptureChannel),
    /// Rows with this content kind.
    ContentKind(ContentKind),
    /// Rows where any of the specified feature-flag bits are set.
    /// `flags` is an `i64` bitset already positioned in the
    /// operational bitmap's feature-flag region (bits 8–15) — pass any
    /// of the `DrawerFeatureFlags::*` constants or a bitwise-OR
    /// composition.
    HasFeatureFlag(i64),

    // ---------- Structural queries ----------
    /// Rows filed in this room.
    InRoom(String),
    /// Rows filed in this wing.
    InWing(String),
    /// Rows with this lineage identifier.
    LineageID(LineageID),
    /// Rows captured strictly after this timestamp (epoch seconds).
    CreatedAfter(i64),
    /// Rows captured strictly before this timestamp (epoch seconds).
    CreatedBefore(i64),
    /// Rows with a matching lattice anchor.
    LatticeAnchor(LatticeAnchor),
    /// Rows whose UDC code begins with this prefix (depth-axis subtree).
    LatticeUnder(String),
    /// Rows associated with this Wikidata Q-ID (primary or secondary).
    WikidataConcept(WikidataQID),

    // ---------- Content queries ----------
    /// Rows whose verbatim content contains this string.
    ContentMatches(String),

    // ---------- Composition ----------
    /// All child filters must match (AND).
    All(Vec<Filter>),
    /// At least one child filter must match (OR).
    Any(Vec<Filter>),
    /// Child filter must not match (NOT).
    Not(Box<Filter>),
}

// MARK: - RecallFrame ---------------------------------------------------------

/// Slots for the `recall` verb. Per spec § 7.8.3.
#[derive(Debug, Clone, PartialEq)]
pub struct RecallFrame {
    /// Filter chain interpreted as implicit conjunction (equivalent
    /// to `Filter::All(filter_chain)`). Per spec § 7.9.1. Must contain
    /// at least one filter; an empty chain is an invalid recall and
    /// the evaluator surfaces a typed error.
    pub filter_chain: Vec<Filter>,
    /// How much of each row to hydrate. Per spec § 7.3.
    pub hydration_level: HydrationLevel,
    /// Maximum rows per page. `None` = implementation default.
    pub limit: Option<usize>,
    /// Ordering of results.
    pub ordering: Ordering,
    /// Historical reconstruction — return rows as they were at this
    /// timestamp (epoch seconds). `None` = current state. Per spec
    /// § 6.8.
    pub as_of: Option<substrate_types::hlc::HLC>,
}

impl RecallFrame {
    /// Construct a `RecallFrame` with the spec defaults: `Structured`
    /// hydration, no limit, `ByCaptureTimeDesc` ordering, no `as_of`.
    /// Mirrors the Swift `RecallFrame.init(filterChain:)` shape.
    pub fn new(filter_chain: Vec<Filter>) -> Self {
        Self {
            filter_chain,
            hydration_level: HydrationLevel::Structured,
            limit: None,
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recall_frame_defaults_match_swift_shape() {
        let frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        assert_eq!(frame.hydration_level, HydrationLevel::Structured);
        assert_eq!(frame.ordering, Ordering::ByCaptureTimeDesc);
        assert_eq!(frame.limit, None);
        assert_eq!(frame.as_of, None);
    }

    #[test]
    fn filter_composition_is_recursive() {
        let f = Filter::All(vec![
            Filter::Trustworthy,
            Filter::Not(Box::new(Filter::Unconfirmed)),
            Filter::Any(vec![
                Filter::InRoom("kitchen".to_string()),
                Filter::InRoom("study".to_string()),
            ]),
        ]);
        // Shape check: cloning preserves equality.
        assert_eq!(f.clone(), f);
    }

    #[test]
    fn state_cluster_cases_distinct() {
        assert_ne!(StateCluster::KnowNow, StateCluster::KnewPast);
        assert_ne!(StateCluster::KnewPast, StateCluster::Terminal);
    }

    #[test]
    fn ordering_cases_distinct() {
        let all = [
            Ordering::ByCaptureTimeDesc,
            Ordering::ByCaptureTimeAsc,
            Ordering::ByRelevanceDesc,
            Ordering::ByRoomAsc,
        ];
        for (i, a) in all.iter().enumerate() {
            for (j, b) in all.iter().enumerate() {
                if i == j {
                    assert_eq!(a, b);
                } else {
                    assert_ne!(a, b);
                }
            }
        }
    }
}
