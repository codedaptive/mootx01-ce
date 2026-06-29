// frames.rs — Rust mirror of the verb frames the GLK surface accepts.
//
// This file defines the Rust GLK verb boundary frames. Field names
// broadly follow `Frames.swift` in `Sources/GeniusLocusKit/Verbs/`,
// but several frames are intentional subsets of the current Swift
// surfaces: `CaptureFrame` omits the newer provenance adjective slots,
// `MutationKind` omits `correctExportability`, `LearnFrame` is
// handle-only (Swift carries source/mode/refreshPolicy), and
// `ReanchorFrame` has no wing field. These GLK-level frames use
// string-typed ids and i64 raw enum values by design: the GLK boundary
// layer is intentionally decoupled from locus_kit nominal types so the
// coordinator can translate at the boundary (see coordinator.rs verb
// dispatch methods). All nine verbs are wired through to
// locus_kit::Estate in coordinator.rs.

/// A row's stable identifier. Mirrors `LocusKit.RowID = String` in
/// Swift.
pub type RowId = String;

/// A room identifier within an estate. Mirrors `LocusKit.RoomID`.
pub type RoomId = String;

/// Lattice anchor — UDC code plus optional Wikidata enrichment.
/// Mirrors `LocusKit.LatticeAnchor`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LatticeAnchor {
    pub udc_code: String,
    pub udc_facets: Option<String>,
    pub wikidata_qid: Option<String>,
    pub wikidata_qids_secondary: Option<String>,
}

impl LatticeAnchor {
    /// Convenience constructor for a bare UDC code with no enrichment.
    pub fn udc(code: impl Into<String>) -> Self {
        Self {
            udc_code: code.into(),
            udc_facets: None,
            wikidata_qid: None,
            wikidata_qids_secondary: None,
        }
    }
}

/// Named mutation operations for `mutate`. Mirrors the core cases of
/// `LocusKit.MutationKind`. The Swift variant also carries
/// `correctExportability`; that case is not yet present at this Rust
/// boundary. `correctSensitivity` and `correctTrust` carry raw i64
/// values to stay independent of the locus_kit adjective enum types —
/// the coordinator maps them to the LocusKit `MutationKind` enum at
/// the dispatch boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MutationKind {
    Confirm,
    Reject,
    Contest,
    Resolve,
    Supersede,
    Revive,
    Accept,
    /// Carries a raw sensitivity value (Swift uses `AdjectiveSensitivity`);
    /// the numeric domain is the scale-gapped layout 0/16/32/48
    /// (normal=0, elevated=16, restricted=32, secret=48).
    CorrectSensitivity(i64),
    /// Carries a raw trust value (Swift uses an enum); domain is
    /// 0..=5 per `Adjectives.swift`.
    CorrectTrust(i64),
}

/// Capture frame. Slot names mirror Swift `CaptureFrame`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureFrame {
    pub content: String,
    /// Capture channel raw value (typed=0, voiced=1, ocr=2,
    /// imported_file=3, sensor=4). Kept as i64 raw value at the GLK
    /// boundary; the coordinator maps it to locus_kit::CaptureChannel
    /// at dispatch.
    pub channel: i64,
    /// Content kind raw value (prose=0, code=1, transcript=2, list=3,
    /// structured_json=4, image_caption=5).
    pub kind: i64,
    /// Sensitivity raw value (scale-gapped 0/16/32/48 per `AdjectiveSensitivity`;
    /// normal=0, elevated=16, restricted=32, secret=48; default 0).
    pub sensitivity: i64,
    pub lineage_id: Option<String>,
    pub room: RoomId,
    pub lattice_anchor: LatticeAnchor,
    pub added_by: String,
    pub embedding_model_id: String,
    /// Wing to file the drawer into (ADR-016). `None` falls through to the
    /// estate default ("Agentic Memory"). Supply `Some(name)` to route a
    /// drawer into a specific wing at capture time (e.g. "User Canon",
    /// "Personal"). Mirrors Swift `CaptureFrame.wing: String?`.
    pub wing: Option<String>,
}

/// Recall frame. Slot names mirror Swift `RecallFrame`. The filter
/// chain is a free-form string list at the GLK boundary layer; the
/// coordinator maps these tokens to `locus_kit::filter::Filter` values
/// at dispatch (see `coordinator.rs recall` dispatch method).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecallFrame {
    /// Filter chain — opaque string tokens at the GLK boundary;
    /// the coordinator maps these to `locus_kit::filter::Filter`
    /// values at dispatch. Empty chain is illegal per spec § 7.9.1.
    pub filter_chain: Vec<String>,
    pub hydration_level: HydrationLevel,
    pub limit: Option<i64>,
    pub ordering: Ordering,
    /// As-of HLC timestamp for historical reconstruction. Kept as an
    /// ISO-8601 string at this Rust GLK boundary layer; a native Rust
    /// HLC type is available in SubstrateLib but this boundary field
    /// intentionally stays string-typed so the coordinator can accept
    /// the raw string from callers and parse it internally at dispatch.
    pub as_of: Option<String>,
}

/// Hydration level for recall. Mirrors `LocusKit.HydrationLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HydrationLevel {
    Structured,
    Full,
    BitmapOnly,
}

/// Result ordering for recall. Mirrors `LocusKit.Ordering`.
///
/// `ByRelevanceDesc` is not present on this enum — LocusKit is a bitmap
/// filter engine with no scoring signal. Relevance ranking is provided by
/// the GLK RecallDirector's scoring mode (UnionBest + query_text), not by
/// the LocusKit page order. The case was removed to match the Swift removal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ordering {
    ByCaptureTimeDesc,
    ByCaptureTimeAsc,
    ByRoomAsc,
}

/// Learn frame. Full mirror of `LocusKit.LearnFrame`, aligned with
/// the Swift `LearnFrame` surface (`source`, `handle`, `mode`, `refreshPolicy`).
///
/// The GLK boundary previously exposed only `handle`, requiring callers to
/// construct `LocusLearnFrame` (the locus_kit internal type) directly —
/// bypassing the GLK verb abstraction. This struct now carries the complete
/// slot set so the coordinator can map it to `LocusLearnFrame` at the
/// dispatch boundary (same pattern as `ProposeFrame` → `LocusProposeFrame`).
///
/// Field semantics mirror Swift's `LearnFrame`:
///   - `source`: the catalog entry whose lattice anchor the learned reference
///     inherits. `Estate::learn` catalogs it if not already present.
///   - `handle`: the URI / locator of the reference. Must be non-empty.
///   - `mode`: by-reference (pointer only) vs by-ingestion (content stored).
///   - `refresh_policy`: how often the reference is re-grounded.
#[derive(Debug, Clone)]
pub struct LearnFrame {
    /// The source this reference is learned from. Carries the genuine lattice
    /// anchor the learned reference inherits.
    pub source: locus_kit::source_catalog_entry::SourceCatalogEntry,
    /// The reference handle — the URI / locator the learned reference points at.
    /// Must be non-empty; `estate.learn` rejects empty handles.
    pub handle: String,
    /// Whether the reference is held by pointer (ByReference) or its content
    /// was ingested (ByIngestion). Defaults to ByReference.
    pub mode: locus_kit::learned_reference::LearnMode,
    /// How often the reference is re-grounded against its source. Defaults to Weekly.
    pub refresh_policy: locus_kit::learned_reference::RefreshPolicy,
}

impl LearnFrame {
    /// Create a `LearnFrame` with defaults matching the Swift initializer:
    /// `mode = .byReference`, `refreshPolicy = .weekly`.
    pub fn new(
        source: locus_kit::source_catalog_entry::SourceCatalogEntry,
        handle: impl Into<String>,
    ) -> Self {
        Self {
            source,
            handle: handle.into(),
            mode: locus_kit::learned_reference::LearnMode::ByReference,
            refresh_policy: locus_kit::learned_reference::RefreshPolicy::Weekly,
        }
    }
}

/// Withdraw frame. Mirrors Swift `WithdrawFrame`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WithdrawFrame {
    pub row_id: RowId,
    pub reason: Option<String>,
}

/// Mutate frame. Mirrors Swift `MutateFrame`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MutateFrame {
    pub row_id: RowId,
    pub kind: MutationKind,
    pub payload: Option<String>,
}

/// Expunge frame. Mirrors Swift `ExpungeFrame`. Confirmation is a
/// required precondition: a false value raises
/// `VerbError::ExpungeNotConfirmed` at the surface before dispatch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpungeFrame {
    pub row_id: RowId,
    pub reason: String,
    pub confirmation: bool,
}

/// Reanchor frame. Partial mirror of Swift `ReanchorFrame` — supports
/// room and lattice targets only. Wing moves (`to_wing`) are not yet
/// wired at this Rust boundary. At least one of `to_room` or
/// `to_lattice` must be present; an empty frame raises
/// `VerbError::EmptyReanchor`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReanchorFrame {
    pub row_id: RowId,
    pub to_room: Option<RoomId>,
    pub to_lattice: Option<LatticeAnchor>,
}

/// Propose frame. Mirrors Swift `ProposeFrame`. The coordinator maps
/// the Brain-layer `ProposalKind` to the substrate `ProposalKind`
/// before persistence; the substrate-axis enum's raw value is what
/// is written to storage, not the GLK `ProposalKind` raw value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProposeFrame {
    pub target: RowId,
    /// Typed proposal taxonomy. See `ProposalKind` for the full
    /// vocabulary including production labels and test cases.
    pub kind: crate::brain::scheduler::api::ProposalKind,
    pub justification: Option<String>,
}

/// Associate frame. Mirrors Swift `AssociateFrame`. `weight` is in
/// [0, 1]; the surface does not validate the range — the Brain layer
/// owns that decision.
#[derive(Debug, Clone, PartialEq)]
pub struct AssociateFrame {
    pub a: RowId,
    pub b: RowId,
    pub weight: f64,
}

// f64 does not derive Eq, so AssociateFrame's PartialEq is the
// strongest equality the type carries; downstream usage that needs
// total equality must canonicalise the weight first.
