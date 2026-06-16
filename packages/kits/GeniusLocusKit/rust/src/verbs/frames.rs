// frames.rs — Rust mirror of the verb frames the GLK surface accepts.
//
// Slot sets and field names match the Swift `Frames.swift` in
// `Sources/GeniusLocusKit/Verbs/`. These GLK-level frames use
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

/// Named mutation operations for `mutate`. Mirrors
/// `LocusKit.MutationKind`. The Swift variant carries associated
/// values for `correctSensitivity` and `correctTrust`; this GLK
/// frame keeps them as raw i64 values to stay independent of the
/// locus_kit adjective enum types — the coordinator maps these to
/// the LocusKit `MutationKind` enum at the dispatch boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MutationKind {
    Confirm,
    Reject,
    Contest,
    Resolve,
    Supersede,
    Revive,
    Accept,
    /// Carries a raw sensitivity value (Swift uses an enum); the
    /// numeric domain is fixed by the scale-gapped layout 0/4/8/12.
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
    /// Sensitivity raw value (scale-gapped 0/4/8/12; default 0).
    pub sensitivity: i64,
    pub lineage_id: Option<String>,
    pub room: RoomId,
    pub lattice_anchor: LatticeAnchor,
    pub added_by: String,
    pub embedding_model_id: String,
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
    /// As-of HLC timestamp for historical reconstruction. ISO-8601 in
    /// scaffold form; replaced by HLC type when SubstrateLib Rust
    /// publishes one.
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

/// Learn frame. Mirrors `LocusKit.LearnFrame`. The GLK learn verb
/// body is wired through to locus_kit in coordinator.rs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LearnFrame {
    pub handle: String,
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

/// Reanchor frame. Mirrors Swift `ReanchorFrame`. At least one of
/// `to_room` or `to_lattice` must be present; an empty reanchor
/// raises `VerbError::EmptyReanchor`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReanchorFrame {
    pub row_id: RowId,
    pub to_room: Option<RoomId>,
    pub to_lattice: Option<LatticeAnchor>,
}

/// Propose frame. Mirrors Swift `ProposeFrame`. The `kind` field
/// carries the typed `ProposalKind` vocabulary; the surface boundary
/// uses `kind.raw_value()` when writing to persistent storage.
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
