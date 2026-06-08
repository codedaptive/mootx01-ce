//! Verb input frames for the estate surface. Ports the `CaptureFrame`,
//! `MutationKind`, and `LearnFrame` types from `Frames.swift`.
//!
//! `RecallFrame`, `HydrationLevel`, `Ordering`, and `StateCluster` already
//! live in `filter.rs` (landed LP-1E), so only the capture / mutation /
//! learn types belong here. Callers import from both modules as needed.
//!
//! Per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` §§ 7.1 / 7.8.3.

use crate::adjectives::{AdjectiveSensitivity, Trust};
use crate::drawer_operational::{CaptureChannel, ContentKind};
use crate::estate_types::LatticeAnchor;
use crate::filter::LineageID;
use crate::provenance::{Channel, Sensitivity, SourceType};
use crate::tunnel_operational::{TunnelKind, TunnelOriginClass};

// MARK: - CaptureFrame

/// Slots for the `capture` verb. Per spec § 7.1 and § 7.8.3.
///
/// Every slot is named; no raw bitmap value crosses this boundary.
/// `estate_verbs.rs` translates these slots into a storage `Drawer`
/// and writes it via `DrawerStore::add_drawer`.
#[derive(Debug, Clone)]
pub struct CaptureFrame {
    /// Verbatim content to store (rung 1 — exact bytes preserved).
    pub content: String,

    /// How this content was captured. Lands in bits 0–3 of the
    /// resulting drawer's `operational_bitmap`.
    pub channel: CaptureChannel,

    /// Adjective sensitivity tier. Defaults to `Normal`.
    ///
    /// Scale-gapped raw values (0/4/8/12) are shifted left by 4 in
    /// the adjective bitmap assembly to land in bits 4–7.
    pub sensitivity: AdjectiveSensitivity,

    /// Content kind. Defaults to `Prose`. Lands in bits 4–7 of the
    /// resulting drawer's `operational_bitmap`.
    pub kind: ContentKind,

    /// Provenance Channel (cookbook §2.5, provenance bitmap bits 6–11).
    /// The capture-time origin axis — UI vs MCP agent vs file import vs
    /// federation inbound, etc. Distinct from the operational
    /// `CaptureChannel` above; defaults to `UiTyped` (raw 0) so existing
    /// callers continue to produce zero-provenance drawers as before.
    pub provenance_channel: Channel,

    /// Provenance SourceType (cookbook §2.5, provenance bitmap bits 0–5).
    /// Who/what produced this content. Defaults to `User` (raw 0).
    pub source_type: SourceType,

    /// Provenance Sensitivity (cookbook §2.5, provenance bitmap bits
    /// 30–35). The estate-level access posture at capture time, distinct
    /// from the access-control `sensitivity` adjective above (which is
    /// mutable post-capture). Defaults to `Normal` (raw 0).
    pub provenance_sensitivity: Sensitivity,

    /// Lineage identifier shared with any prior version of this content.
    /// When `Some` and an active predecessor sharing this lineage exists,
    /// `capture` triggers the supersession cascade in `DrawerStore::add_drawer`
    /// (spec § 6.2 / § 6.3). When `None` a fresh UUID is stamped so each
    /// new drawer is its own lineage by default (spec § 5.10).
    pub lineage_id: Option<LineageID>,

    /// Room within the estate the drawer is filed under.
    pub room: String,

    /// Lattice anchor — `udc_code` required per invariant I-5.
    pub lattice_anchor: LatticeAnchor,

    /// Actor identifier written into the drawer's `added_by` field and
    /// into any bitmap-audit row this capture produces.
    pub added_by: String,

    /// Embedding model id for the modelID-tagging contract (I-4).
    /// Required even before vectors are generated so a future model bump
    /// cannot accidentally compare across versions.
    pub embedding_model_id: String,

    /// Feature flags to set on the resulting drawer at capture time.
    /// Encodes directly into bits 12–23 of the drawer's `operational_bitmap`
    /// (cookbook §2.4 feature_flags field). The `DrawerFeatureFlags` constants
    /// are pre-shifted (e.g. `HAS_LINKS` is `1 << 15`), so the merge is a
    /// direct bitwise OR masked to `FIELD_MASK (0xFFF000)` — the inverse of
    /// the `feature_flags()` accessor's `& FIELD_MASK` decoder. Defaults to
    /// `0` (no flags set) so all existing callers continue to produce zero
    /// feature-flag bits. Mirrors Swift `CaptureFrame.featureFlags`.
    pub feature_flags: i64,

    /// When the content happened or was authored in the world. For
    /// streaming capture leave as `None` — the substrate stamps it from
    /// `now`. For bulk historical ingestion supply the original
    /// authorship date as epoch seconds. Mirrors Swift
    /// `CaptureFrame.eventTime: Date?`. (ING-01)
    pub event_time: Option<i64>,
}

impl CaptureFrame {
    /// Construct a `CaptureFrame` with the spec defaults: `Typed` channel,
    /// `Normal` sensitivity, `Prose` kind, no lineage id, no feature flags.
    /// Mirrors `CaptureFrame.init(content:channel:room:latticeAnchor:addedBy:embeddingModelID:)`.
    pub fn new(
        content: impl Into<String>,
        channel: CaptureChannel,
        room: impl Into<String>,
        lattice_anchor: LatticeAnchor,
        added_by: impl Into<String>,
        embedding_model_id: impl Into<String>,
    ) -> Self {
        Self {
            content: content.into(),
            channel,
            sensitivity: AdjectiveSensitivity::Normal,
            kind: ContentKind::Prose,
            provenance_channel: Channel::UiTyped,
            source_type: SourceType::User,
            provenance_sensitivity: Sensitivity::Normal,
            lineage_id: None,
            room: room.into(),
            lattice_anchor,
            added_by: added_by.into(),
            embedding_model_id: embedding_model_id.into(),
            feature_flags: 0,
            event_time: None,
        }
    }
}

// MARK: - TunnelCaptureFrame

/// Slots for the `capture` verb applied to a **tunnel** (a graph edge).
/// Mirrors Swift `TunnelCaptureFrame`. Per spec § 7.1 / § 7.8.3.
///
/// `capture` is legal on exactly two nouns — drawer and tunnel. The drawer
/// path uses `CaptureFrame`; this is the edge-shaped sibling: source +
/// target endpoints (wing + room + optional drawer id), a free-form
/// `label`, and the typed `kind`.
///
/// There are deliberately no content, lattice-anchor, or embedding slots,
/// and the three bitmaps are not exposed — standalone capture zero-inits
/// them, byte-identical to the tunnel the supersession cascade writes in
/// `DrawerStoreCore::add_drawer_with_cascade`. One tunnel shape, two
/// entry points (mission VERB-CAP-01).
#[derive(Debug, Clone)]
pub struct TunnelCaptureFrame {
    /// Wing of the source endpoint.
    pub source_wing: String,
    /// Room of the source endpoint.
    pub source_room: String,
    /// Drawer id at the source endpoint. `None` means "the room itself".
    pub source_drawer_id: Option<String>,
    /// Wing of the target endpoint.
    pub target_wing: String,
    /// Room of the target endpoint.
    pub target_room: String,
    /// Drawer id at the target endpoint. `None` means "the room itself".
    pub target_drawer_id: Option<String>,
    /// Free-form relationship label (matches `Tunnel.label`).
    pub label: String,
    /// Typed relationship kind. The `new` constructor defaults this to
    /// `TunnelKind::References`, matching `Tunnel`'s non-cascade default.
    pub kind: TunnelKind,
    /// Actor identifier written into the tunnel's `added_by` field.
    pub added_by: String,
    /// How this tunnel entered the substrate — user assertion, agent
    /// derivation, import path, sync replication, or schema migration.
    /// Encodes into bits 6–8 of the tunnel's `operational_bitmap` at
    /// capture (via `bit_field::write_field`; decoder is `TunnelOriginClass`
    /// in `tunnel_operational.rs`). Defaults to `UserExplicit` (raw 0)
    /// so all existing callers continue to produce a zero operational
    /// bitmap byte-identically. Mirrors Swift `TunnelCaptureFrame.originClass`.
    pub origin_class: TunnelOriginClass,
}

impl TunnelCaptureFrame {
    /// Construct a `TunnelCaptureFrame` with `kind` defaulting to
    /// `TunnelKind::References`, `origin_class` defaulting to
    /// `TunnelOriginClass::UserExplicit`, and both drawer ids `None`
    /// (a room-level edge). Mirrors the Swift initializer's defaults.
    pub fn new(
        source_wing: impl Into<String>,
        source_room: impl Into<String>,
        target_wing: impl Into<String>,
        target_room: impl Into<String>,
        label: impl Into<String>,
        added_by: impl Into<String>,
    ) -> Self {
        Self {
            source_wing: source_wing.into(),
            source_room: source_room.into(),
            source_drawer_id: None,
            target_wing: target_wing.into(),
            target_room: target_room.into(),
            target_drawer_id: None,
            label: label.into(),
            kind: TunnelKind::References,
            added_by: added_by.into(),
            origin_class: TunnelOriginClass::UserExplicit,
        }
    }
}

// MARK: - MutationKind

/// Named mutation operations for the `mutate` verb. Per spec § 7.8.3.
///
/// Callers express intent in named cases; the evaluator translates each
/// case into the appropriate bitmap mutation. No caller-facing raw bit
/// value participates in this enum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MutationKind {
    /// Move the row's confirmation axis to `.UserConfirmed`.
    Confirm,
    /// Move the row's state to `Rejected` (terminal cluster).
    Reject,
    /// Move the row's state to `Contested` (still currently-believed
    /// cluster, but flagged for resolution).
    Contest,
    /// Resolve a contested row back to `Active` once the contest is settled.
    Resolve,
    /// Explicit supersession (used when the caller knows the new version's
    /// lineage id does not match but the semantic supersession relationship
    /// should still be recorded).
    Supersede,
    /// Move a withdrawn / expired row back to `Active`.
    Revive,
    /// Move the row's state to `Accepted` (terminal cluster — the row
    /// is canonical and will not move again).
    Accept,
    /// Set the row's sensitivity axis to the supplied tier.
    CorrectSensitivity(AdjectiveSensitivity),
    /// Set the row's trust axis to the supplied value.
    CorrectTrust(Trust),
}

// MARK: - LearnFrame

/// Slots for the `learn` verb. Scaffold only — full slot set
/// (`SourceCatalogEntry`, `LearnMode`, `RefreshPolicy`) is declared in
/// the standing-signals mission.
#[derive(Debug, Clone)]
pub struct LearnFrame {
    /// Caller-supplied handle naming the source to learn.
    pub handle: String,
}

impl LearnFrame {
    /// Create a `LearnFrame` with the given source handle.
    pub fn new(handle: impl Into<String>) -> Self {
        Self {
            handle: handle.into(),
        }
    }
}

// MARK: - ProposeFrame

/// Slots for the `propose` verb. Mirrors `LocusKit.ProposeFrame` in Swift.
///
/// `kind` uses `LocusKit.ProposalKind` (Int-based substrate axis) — distinct
/// from the GLK `ProposalKind` (String-based Brain routing labels).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProposeFrame {
    /// The row this proposal is about. Must be non-empty.
    pub target: String,
    /// Substrate-axis proposal kind (cookbook §2.4 bits 0–5).
    /// Uses the `ProposalKind` Int enum from `proposal_operational.rs`.
    pub kind: crate::proposal_operational::ProposalKind,
    /// Optional free-text justification.
    pub justification: Option<String>,
}

impl ProposeFrame {
    /// Create a `ProposeFrame` with a target and kind; justification defaults to None.
    pub fn new(target: impl Into<String>, kind: crate::proposal_operational::ProposalKind) -> Self {
        Self {
            target: target.into(),
            kind,
            justification: None,
        }
    }
}

// MARK: - AssociateFrame

/// Slots for the `associate` verb. Mirrors `LocusKit.AssociateFrame` in Swift.
#[derive(Debug, Clone, PartialEq)]
pub struct AssociateFrame {
    /// One endpoint.
    pub a: String,
    /// The other endpoint.
    pub b: String,
    /// Coarse weight in [0, 1]. The Brain layer interprets this; the substrate
    /// stores it opaquely.
    pub weight: f64,
}

impl AssociateFrame {
    /// Create an `AssociateFrame` with two endpoints and a weight.
    pub fn new(a: impl Into<String>, b: impl Into<String>, weight: f64) -> Self {
        Self {
            a: a.into(),
            b: b.into(),
            weight,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjectives::AdjectiveSensitivity;
    use crate::drawer_operational::CaptureChannel;
    use crate::estate_types::LatticeAnchor;

    #[test]
    fn capture_frame_new_defaults() {
        let f = CaptureFrame::new(
            "hello world",
            CaptureChannel::Typed,
            "kitchen",
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        assert_eq!(f.content, "hello world");
        assert_eq!(f.channel, CaptureChannel::Typed);
        assert_eq!(f.sensitivity, AdjectiveSensitivity::Normal);
        assert_eq!(f.kind, ContentKind::Prose);
        assert!(f.lineage_id.is_none());
        assert_eq!(f.room, "kitchen");
        assert_eq!(f.lattice_anchor.udc_code, "5");
        assert_eq!(f.added_by, "alice");
        assert_eq!(f.embedding_model_id, "test-v1");
    }

    #[test]
    fn mutation_kind_correct_sensitivity_carries_value() {
        let mk = MutationKind::CorrectSensitivity(AdjectiveSensitivity::Restricted);
        match mk {
            MutationKind::CorrectSensitivity(s) => {
                assert_eq!(s, AdjectiveSensitivity::Restricted);
            }
            _ => panic!("expected CorrectSensitivity"),
        }
    }

    #[test]
    fn mutation_kind_cases_distinct() {
        assert_ne!(MutationKind::Confirm, MutationKind::Reject);
        assert_ne!(MutationKind::Contest, MutationKind::Resolve);
    }

    #[test]
    fn learn_frame_stores_handle() {
        let f = LearnFrame::new("source-abc");
        assert_eq!(f.handle, "source-abc");
    }
}
