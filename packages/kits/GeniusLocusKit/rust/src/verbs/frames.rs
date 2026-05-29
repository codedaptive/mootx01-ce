// frames.rs — Rust mirror of the verb frames the GLK surface accepts.
//
// Slot sets and field names match the Swift `Frames.swift` in
// `Sources/GeniusLocusKit/Verbs/`. The Rust port stays string-typed
// for ids and content because the LocusKit Rust port has not yet
// shipped a Drawer / RowID nominal type; downstream missions tighten
// the types when the port lands.

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
/// values for `correctSensitivity` and `correctTrust`; the Rust port
/// matches without committing to the sensitivity / trust enum
/// taxonomy until those land in the Rust LocusKit port.
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
    /// imported_file=3, sensor=4). Numeric here so the Rust port can
    /// move forward before the LocusKit Rust `CaptureChannel` enum
    /// lands.
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
/// chain is a free-form string list at this scaffold tier; downstream
/// missions replace it with the Filter enum when the Rust port
/// publishes the Filter taxonomy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecallFrame {
    /// Filter chain — opaque string tokens for now; the Rust LocusKit
    /// port will swap this for the typed Filter sum-type when it lands.
    /// Empty chain is illegal per `LocusKit.BitmapEvaluator` § 7.9.1.
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ordering {
    ByCaptureTimeDesc,
    ByCaptureTimeAsc,
    ByRelevanceDesc,
    ByRoomAsc,
}

/// Learn frame. Mirrors `LocusKit.LearnFrame`. Full slot set lands
/// in the Rust port of LOCI_V035_19.
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
