//! Verb input frames for the estate surface. Ports the `CaptureFrame`,
//! `MutationKind`, and `LearnFrame` types from `Frames.swift`.
//!
//! `RecallFrame`, `HydrationLevel`, `Ordering`, and `StateCluster` already
//! live in `filter.rs` (landed LP-1E), so only the capture / mutation /
//! learn types belong here. Callers import from both modules as needed.
//!
//! Per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` §§ 7.1 / 7.8.3.

use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity, Trust};
use crate::drawer_operational::{CaptureChannel, ContentKind};
use crate::estate_types::LatticeAnchor;
use crate::filter::LineageID;
use crate::provenance::{Channel, Confidence, Confirmation, Sensitivity, SourceType};
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

    /// How this content was captured. Lands in bits 0–5 of the
    /// resulting drawer's `operational_bitmap` (6-bit field).
    pub channel: CaptureChannel,

    /// Adjective sensitivity tier. Defaults to `Normal`.
    ///
    /// Scale-gapped raw values (0/16/32/48) are packed into bits 6–11
    /// of the adjective bitmap via `bit_field::write_field`.
    pub sensitivity: AdjectiveSensitivity,

    /// Content kind. Defaults to `Prose`. Lands in bits 6–11 of the
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

    /// Provenance Confirmation (cookbook §2.5, provenance bitmap bits
    /// 18–23). Review status at capture time — a daemon or agent that
    /// captures already-confirmed content (e.g. `UserConfirmed`,
    /// `AutomatedConfirmed`) records it here rather than relying on a
    /// later `confirm` mutation. Defaults to `Unconfirmed` (raw 0) so
    /// existing callers stay byte-identical to before this slot existed.
    /// Mirrors Swift `CaptureFrame.confirmation`.
    pub confirmation: Confirmation,

    /// Provenance Confidence (cookbook §2.5, provenance bitmap bits
    /// 24–29). System posterior at capture time — a daemon capturing with
    /// a known confidence band (e.g. `High`, `Verified`) records it at
    /// birth rather than leaving the field at `Null` for a later
    /// enrichment pass. Defaults to `Null` (raw 0) so existing callers
    /// stay byte-identical. Mirrors Swift `CaptureFrame.confidence`.
    pub confidence: Confidence,

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
    /// authorship date as epoch milliseconds. Mirrors Swift
    /// `CaptureFrame.eventTime: Date?`. (ING-01)
    pub event_time: Option<i64>,

    /// Exportability of the resulting drawer at capture time.
    /// Encodes into bits 12–17 of the drawer's `adjective_bitmap`
    /// (cookbook §2.3, 6-bit scale-gapped field; raw 0 = Private,
    /// raw 32 = Public). Defaults to `Private` (non-exportable) so all
    /// existing callers continue to produce private drawers — the
    /// privacy-preserving default. Supply `Public` to birth a drawer
    /// that is immediately visible to `Filter::Exportable` recall
    /// (DEBT-1 write-side fix). Mirrors Swift `CaptureFrame.exportability`.
    pub exportability: AdjectiveExportability,
    /// Wing to file the drawer into (ADR-016). `None` falls through to
    /// `DEFAULT_WING_NAME` ("Agentic Memory") in `estate_verbs.rs`,
    /// keeping all existing callers byte-identical. Supply `Some(name)`
    /// to route a drawer into a specific wing at capture time.
    /// Mirrors Swift `CaptureFrame.wing: String?`.
    pub wing: Option<String>,
}

impl CaptureFrame {
    /// Construct a `CaptureFrame` with the spec defaults: `Typed` channel,
    /// `Normal` sensitivity, `Prose` kind, `Private` exportability,
    /// no lineage id, no feature flags.
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
            confirmation: Confirmation::Unconfirmed,
            confidence: Confidence::Null,
            lineage_id: None,
            room: room.into(),
            lattice_anchor,
            added_by: added_by.into(),
            embedding_model_id: embedding_model_id.into(),
            feature_flags: 0,
            event_time: None,
            // Privacy-preserving default: drawers are born private.
            // Use AdjectiveExportability::Public to produce a born-public
            // drawer, or correctExportability post-capture.
            exportability: AdjectiveExportability::Private,
            // ADR-016: default None → estate_verbs falls through to
            // DEFAULT_WING_NAME, keeping existing callers byte-identical.
            wing: None,
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
    /// Restore a historical (Cluster-B) row to `Active`. Legal from
    /// `Decayed`, `Withdrawn`, and `Expired` unconditionally; legal from
    /// `Superseded` only when no living successor holds the lineage head
    /// (otherwise it raises `DisciplineViolation` naming the lineage
    /// conflict). Refused from live (Cluster-A) and terminal (`Rejected`
    /// / `Tombstoned`) states. See `Estate::mutate`.
    Revive,
    /// Move the row's state to `Accepted` (terminal cluster — the row
    /// is canonical and will not move again).
    Accept,
    /// Set the row's sensitivity axis to the supplied tier.
    CorrectSensitivity(AdjectiveSensitivity),
    /// Set the row's trust axis to the supplied value.
    CorrectTrust(Trust),
    /// Set the row's exportability axis to the supplied value.
    ///
    /// Exportability lives in `adjective_bitmap` bits 12–17 (cookbook §2.3,
    /// 6-bit scale-gapped field; raw 0 = Private, raw 32 = Public).
    /// Default is `Private` (non-exportable) — this mutation is the
    /// only path to mark a drawer public after capture, completing the
    /// exportability write side (DEBT-1). Mirrors Swift
    /// `MutationKind.correctExportability`.
    CorrectExportability(AdjectiveExportability),
}

// MARK: - LearnFrame

/// Slots for the `learn` verb. Per spec § 7.8.2
/// (`LearnFrame { source, handle, mode, refresh_policy }`). Mirrors the
/// Swift `LearnFrame`.
///
/// `learn` brings an authoritative external reference into the estate. The
/// reference's genuine lattice anchor comes from `source` — a
/// `SourceCatalogEntry` carries the source's classified lattice position,
/// which every reference learned from it inherits. This is how `learn`
/// derives a real anchor instead of fabricating a sentinel from a bare
/// handle (P1 mandate).
#[derive(Debug, Clone)]
pub struct LearnFrame {
    /// The source this reference is learned from. Carries the genuine
    /// lattice anchor the learned reference inherits. `Estate::learn`
    /// catalogs it (keyed by `source.handle`) if no entry exists yet.
    pub source: crate::source_catalog_entry::SourceCatalogEntry,

    /// The reference handle — the URI / locator the learned reference
    /// points at. Distinct from `source.handle`. Must be non-empty;
    /// `Estate::learn` rejects an empty handle with
    /// `LocusKitError::InvalidContent`.
    pub handle: String,

    /// Whether the reference is held by pointer or its content was
    /// ingested. Encoded into the operational bitmap (cookbook § 2.4
    /// bit 12).
    pub mode: crate::learned_reference::LearnMode,

    /// How often the reference is re-grounded against its source. Encoded
    /// into the operational bitmap (cookbook § 2.4 bits 0–5).
    pub refresh_policy: crate::learned_reference::RefreshPolicy,
}

impl LearnFrame {
    /// Create a `LearnFrame` from a source and reference handle, defaulting
    /// `mode` to `ByReference` and `refresh_policy` to `Weekly` (matching
    /// the Swift initializer's defaults).
    pub fn new(
        source: crate::source_catalog_entry::SourceCatalogEntry,
        handle: impl Into<String>,
    ) -> Self {
        Self {
            source,
            handle: handle.into(),
            mode: crate::learned_reference::LearnMode::ByReference,
            refresh_policy: crate::learned_reference::RefreshPolicy::Weekly,
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
    /// Who or what confirms this proposal (cookbook §2.4 bits 12–17). Defaults
    /// to `Human` (raw 0) — the value the operational bitmap held implicitly
    /// before this slot existed, so frames that omit it stay byte-identical.
    pub confirmation: crate::proposal_operational::ProposalConfirmationSource,
    /// What class of producer generated this proposal (cookbook §2.4 bits
    /// 18–23). Defaults to `DreamingDaemon` (raw 0) — the implicit pre-slot
    /// value. Daemon-emitted proposals should set their true producer class so
    /// provenance reflects reality rather than the zero fallback.
    pub generated_by: crate::proposal_operational::ProposalGeneratedByClass,
    /// Coarse confidence bucket for this proposal (cookbook §2.4 bits 24–29).
    /// Defaults to `Null` (raw 0) — the implicit pre-slot value.
    pub confidence: crate::proposal_operational::ProposalConfidenceBucket,
}

impl ProposeFrame {
    /// Create a `ProposeFrame` with a target and kind. `justification` defaults
    /// to `None`; the three provenance axes default to their raw-0 values
    /// (`Human` / `DreamingDaemon` / `Null`), reproducing the exact operational
    /// bitmap the propose verb wrote before these slots were wired.
    pub fn new(target: impl Into<String>, kind: crate::proposal_operational::ProposalKind) -> Self {
        Self {
            target: target.into(),
            kind,
            justification: None,
            confirmation: crate::proposal_operational::ProposalConfirmationSource::Human,
            generated_by: crate::proposal_operational::ProposalGeneratedByClass::DreamingDaemon,
            confidence: crate::proposal_operational::ProposalConfidenceBucket::Null,
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
    fn learn_frame_stores_source_and_handle() {
        use crate::estate_types::LatticeAnchor;
        use crate::learned_reference::{LearnMode, RefreshPolicy};
        use crate::source_catalog_entry::{SourceCatalogEntry, SourceKind};
        let source = SourceCatalogEntry::new(
            "src-1",
            SourceKind::User,
            "https://example.com",
            LatticeAnchor::udc("004"),
            1_700_000_000,
            "cataloger",
        );
        let f = LearnFrame::new(source, "https://example.com/page");
        assert_eq!(f.handle, "https://example.com/page");
        assert_eq!(f.source.id, "src-1");
        // Defaults mirror the Swift initializer.
        assert_eq!(f.mode, LearnMode::ByReference);
        assert_eq!(f.refresh_policy, RefreshPolicy::Weekly);
    }
}
