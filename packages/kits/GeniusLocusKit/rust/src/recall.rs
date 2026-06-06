// recall.rs — GeniusLocusKit Rust scored recall type system.
//
// Mirrors the Swift RecallDirector types in
// Sources/GeniusLocusKit/RecallDirector/. Every type here has a 1:1
// Swift counterpart; field names follow Rust snake_case convention.
//
// Type mapping (Swift → Rust):
//   GLKRecallMode         → GLKRecallMode
//   GLKRecallScoring      → GLKRecallScoring
//   RecallEvidencePath    → RecallEvidencePath
//   RecallFallbackPolicy  → RecallFallbackPolicy
//   RecallScoreVector     → RecallScoreVector
//   RecallWeights         → RecallWeights
//   RecallPlan            → RecallPlan (RecallWeights.swift)
//   RecallHit             → RecallHit
//   GLKRecallRequest      → GLKRecallRequest
//   GLKRecallResult       → GLKRecallResult
//   RecallUnionProfile    → RecallUnionProfile
//   RecallLane            (utility enum — not a separate Swift file;
//                          distilled from RecallDirector mode dispatch)
//   NodeTopologyProvider  → NodeTopologyProvider (node_topology.rs)
//
// Conformance note: the scoring math (RRF, MMR, normalisation) that the
// Swift RecallDirector performs inside GeniusLocusKit actor extensions is
// implemented in EstateCoordinator::recall_scored (coordinator.rs). The
// types here carry data shapes only; algorithms live in the coordinator.
//
// G3 — sanctioned async/sync asymmetry: Swift NodeTopologyProvider is async
// (actor-friendly); the Rust NodeTopologyProvider trait is synchronous (no
// async runtime). Conformance compares edge OUTPUT, not call shape. This
// mirrors the NeuronKit policy-store precedent where value-level results agree
// across both ports despite different async shapes.

use locus_kit::drawer::Drawer;
use locus_kit::filter::RecallFrame;

// ---------------------------------------------------------------------------
// GLKRecallMode
// ---------------------------------------------------------------------------

/// The recall lane a GLKRecallRequest routes through.
///
/// Five modes are defined. The Rust coordinator's `recall_scored`
/// implementation executes the mode semantics:
///
///   `LocusOnly`   — bitmap-index scan through LocusKit.
///   `CorpusOnly`  — BM25 + vector lanes via registered CorpusKit/VectorKit.
///   `Hybrid`      — locus + BM25 + vector lanes, RRF-fused (k=60).
///   `UnionBest`   — all lanes with union profile and greedy MMR deduplication.
///   `NodeTreeNative` — host-tree topology path (see below).
///
/// For CorpusOnly/Hybrid/UnionBest: lanes activate only when a `Corpus` or
/// `VectorStore` is registered via `EstateCoordinator::register_corpus` /
/// `register_vector_store`. Without registrations, falls back to rank-normalised
/// locus-only scoring.
///
/// `NodeTreeNative` activates the host-tree topology path: a registered
/// `NodeTopologyProvider` is called once per recall start (G1), the result
/// frozen, and the containment edges unioned with estate tunnel edges
/// before the StructureGraph is handed to the structural lenses.
///
/// Mirrors Swift `GLKRecallMode` (GLKRecallMode.swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GLKRecallMode {
    /// Bitmap-index scan through LocusKit only.
    LocusOnly,
    /// BM25 keyword scan through CorpusKit only.
    CorpusOnly,
    /// Combined LocusKit bitmap + CorpusKit BM25 + vector lane.
    Hybrid,
    /// Union results from all available lanes, greedy MMR deduplication.
    UnionBest,
    /// Host tree topology path. The coordinator calls the registered
    /// NodeTopologyProvider's tree_edges(scope=None) exactly once at
    /// recall start (G1), freezes the result, and unions containment
    /// edges with estate tunnel edges. For drawer retrieval, delegates
    /// to the LocusOnly bitmap lane (tree edges feed the structural lens
    /// path via the recall_tunnels surface, not the scored drawer path).
    /// When no provider is registered, behaves identically to LocusOnly.
    NodeTreeNative,
}

impl GLKRecallMode {
    /// String tag matching the Swift rawValue convention (camelCase).
    pub fn raw_value(&self) -> &'static str {
        match self {
            Self::LocusOnly      => "locusOnly",
            Self::CorpusOnly     => "corpusOnly",
            Self::Hybrid         => "hybrid",
            Self::UnionBest      => "unionBest",
            Self::NodeTreeNative => "nodeTreeNative",
        }
    }
}

// ---------------------------------------------------------------------------
// GLKRecallScoring
// ---------------------------------------------------------------------------

/// Scoring strategy applied after lane recall completes.
///
/// `.raw` returns hits in the order the active lane produced them with no
/// reranking. `.rrf` applies Reciprocal Rank Fusion across lanes.
/// `.matrixAware` enables the full weighted pipeline (matrix co-occurrence
/// + temporal, fieldFit, graph, preference signals) mirroring the Swift
/// `RecallDirector`'s step-9 path.
///
/// Mirrors Swift `GLKRecallScoring` (GLKRecallScoring.swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GLKRecallScoring {
    /// No reranking: hits returned in the order the active lane produced them.
    Raw,
    /// Reciprocal Rank Fusion across multiple lanes.
    Rrf,
    /// Full weighted pipeline with matrix, fieldFit, graph, and preference signals.
    MatrixAware,
}

impl GLKRecallScoring {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Self::Raw         => "raw",
            Self::Rrf         => "rrf",
            Self::MatrixAware => "matrixAware",
        }
    }
}

// ---------------------------------------------------------------------------
// RecallEvidencePath
// ---------------------------------------------------------------------------

/// The evidence lane that contributed a hit to a recall result.
///
/// Mirrors Swift `RecallEvidencePath` (RecallEvidencePath.swift).
/// Used as a bit-set key in `RecallHit.sources` and in the
/// coordinator's source-mask book-keeping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RecallEvidencePath {
    /// Bitmap-index scan through LocusKit (locusOnly lane).
    LocusBitmap,
    /// Knowledge-graph traversal through LocusKit.
    LocusGraph,
    /// BM25 keyword score from CorpusKit.
    CorpusBm25,
    /// Hamming-distance vector match.
    VectorHamming,
    /// Matrix field-presence signal.
    MatrixFieldPresence,
    /// Matrix co-occurrence signal.
    MatrixCorrelation,
    /// Matrix co-occurrence count.
    MatrixCoOccurrence,
    /// Matrix temporal decay signal.
    MatrixTemporal,
    /// Graph coherence across the association graph.
    GraphCoherence,
    /// Learned-preference signal from Bradley-Terry training.
    LearnedPreference,
}

impl RecallEvidencePath {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Self::LocusBitmap         => "locusBitmap",
            Self::LocusGraph          => "locusGraph",
            Self::CorpusBm25          => "corpusBM25",
            Self::VectorHamming       => "vectorHamming",
            Self::MatrixFieldPresence => "matrixFieldPresence",
            Self::MatrixCorrelation   => "matrixCorrelation",
            Self::MatrixCoOccurrence  => "matrixCoOccurrence",
            Self::MatrixTemporal      => "matrixTemporal",
            Self::GraphCoherence      => "graphCoherence",
            Self::LearnedPreference   => "learnedPreference",
        }
    }
}

// ---------------------------------------------------------------------------
// RecallFallbackPolicy
// ---------------------------------------------------------------------------

/// What the director does when a lane is unavailable.
///
/// Mirrors Swift `RecallFallbackPolicy` (RecallFallbackPolicy.swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RecallFallbackPolicy {
    /// Return an error immediately if the requested lane is unavailable.
    FailClosed,
    /// Return a degraded result from an available lane instead of failing.
    AllowDegraded,
}

// ---------------------------------------------------------------------------
// RecallLane
// ---------------------------------------------------------------------------

/// Internal lane discriminant used during multi-lane candidate merging.
///
/// Not a separate Swift file; distilled from the RecallDirector's
/// `RecallCandidateBuffer` source-bit constants. Provides a named
/// vocabulary for the coordinator's source-mask book-keeping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RecallLane {
    Locus,
    Corpus,
    Vector,
}

// ---------------------------------------------------------------------------
// RecallScoreVector
// ---------------------------------------------------------------------------

/// Per-hit score decomposition across all evidence lanes.
///
/// Fields not populated by the active lane are 0.0. The locusOnly lane
/// sets `locus` to 1.0 for every returned hit.
///
/// Mirrors Swift `RecallScoreVector` (RecallScoreVector.swift).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecallScoreVector {
    /// Score contribution from the LocusKit bitmap lane.
    pub locus: f32,
    /// Score contribution from BM25 keyword matching (CorpusKit lane).
    pub bm25: f32,
    /// Score contribution from Hamming-distance vector matching.
    pub vector: f32,
    /// Score contribution from matrix field-presence signal.
    pub field_fit: f32,
    /// Score contribution from matrix co-occurrence signal.
    pub co_occurrence: f32,
    /// Score contribution from matrix temporal decay signal.
    pub temporal: f32,
    /// Score contribution from graph coherence signal.
    pub graph: f32,
    /// Score contribution from learned-preference (Bradley-Terry) signal.
    pub preference: f32,
    /// Redundancy penalty subtracted during MMR deduplication.
    pub redundancy_penalty: f32,
    /// Final combined score after all lane contributions and deduplication.
    pub final_score: f32,
}

impl RecallScoreVector {
    /// Pure locus-lane hit at full confidence. All non-locus fields are 0.0;
    /// `final_score` equals the supplied `value`.
    ///
    /// Mirrors Swift `RecallScoreVector.locus(_:)`.
    pub fn locus(value: f32) -> Self {
        Self {
            locus: value,
            bm25: 0.0,
            vector: 0.0,
            field_fit: 0.0,
            co_occurrence: 0.0,
            temporal: 0.0,
            graph: 0.0,
            preference: 0.0,
            redundancy_penalty: 0.0,
            final_score: value,
        }
    }

    /// Zero score vector. All fields 0.0.
    pub const ZERO: Self = Self {
        locus: 0.0,
        bm25: 0.0,
        vector: 0.0,
        field_fit: 0.0,
        co_occurrence: 0.0,
        temporal: 0.0,
        graph: 0.0,
        preference: 0.0,
        redundancy_penalty: 0.0,
        final_score: 0.0,
    };
}

// ---------------------------------------------------------------------------
// RecallWeights
// ---------------------------------------------------------------------------

/// Per-lane weights for the scored recall combiner.
///
/// Mirrors Swift `RecallWeights` (RecallWeights.swift).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecallWeights {
    /// Weight for the LocusKit bitmap lane.
    pub locus: f32,
    /// Weight for the BM25 keyword lane (CorpusKit).
    pub bm25: f32,
    /// Weight for the vector similarity lane.
    pub vector: f32,
    /// Weight for the matrix (co-occurrence / temporal) lane.
    pub matrix: f32,
    /// Weight for the matrix field-presence signal.
    pub field_fit: f32,
    /// Weight for the diversity / redundancy-penalty term.
    pub diversity: f32,
    /// Weight for the graph coherence signal.
    pub graph: f32,
}

impl RecallWeights {
    /// Uniform weights — all four primary lanes contribute equally at 0.25.
    ///
    /// `field_fit`, `diversity`, and `graph` are 0.0. Mirrors Swift
    /// `RecallWeights.uniform`.
    pub const UNIFORM: Self = Self {
        locus: 0.25,
        bm25: 0.25,
        vector: 0.25,
        matrix: 0.25,
        field_fit: 0.0,
        diversity: 0.0,
        graph: 0.0,
    };
}

// ---------------------------------------------------------------------------
// RecallPlan
// ---------------------------------------------------------------------------

/// The director's execution plan for a single request. Computed before
/// lane recall runs.
///
/// Mirrors Swift `RecallPlan` (RecallWeights.swift — declared there
/// alongside RecallWeights for co-location).
#[derive(Debug, Clone)]
pub struct RecallPlan {
    /// The mode the director resolved to (may differ from request.mode
    /// when fallback degrades the request).
    pub effective_mode: GLKRecallMode,
    /// Candidate retrieval count before scoring.
    ///
    /// Formula: `min(max(limit * 4, 64), 256)`. Mirrors Swift
    /// `RecallDirector` frontier-K computation.
    pub frontier_k: usize,
    /// Weights in effect for this plan.
    pub weights: RecallWeights,
}

// ---------------------------------------------------------------------------
// RecallHit
// ---------------------------------------------------------------------------

/// A single drawer returned by the scored recall path, with score
/// decomposition and evidence provenance.
///
/// Mirrors Swift `RecallHit` (RecallHit.swift).
#[derive(Debug, Clone)]
pub struct RecallHit {
    /// The drawer's stable row identifier.
    pub id: String,
    /// The hydrated drawer. None if the drawer was not found in the estate
    /// (e.g. a BM25/vector hit whose row was tombstoned).
    pub drawer: Option<Drawer>,
    /// Evidence lanes that contributed this hit.
    pub sources: Vec<RecallEvidencePath>,
    /// Score decomposition across all evidence lanes.
    pub score: RecallScoreVector,
    /// Human-readable explanation tokens, one per active evidence lane.
    pub explanation: Vec<String>,
}

// ---------------------------------------------------------------------------
// GLKRecallRequest
// ---------------------------------------------------------------------------

/// A fully-specified recall request at the GLK surface.
///
/// Callers that do not need explicit mode/scoring control use the legacy
/// `coordinator.recall(handle, frame, now)` method, which returns a plain
/// `Vec<Drawer>`. This type is the richer scored path.
///
/// Mirrors Swift `GLKRecallRequest` (GLKRecallRequest.swift).
#[derive(Debug, Clone)]
pub struct GLKRecallRequest {
    /// The LocusKit filter chain, hydration level, ordering, and limit.
    pub frame: RecallFrame,
    /// Which recall lane to use.
    pub mode: GLKRecallMode,
    /// Scoring strategy to apply after lane recall.
    pub scoring: GLKRecallScoring,
    /// Maximum number of hits to return.
    pub limit: usize,
    /// What to do if the requested lane is unavailable.
    pub fallback: RecallFallbackPolicy,
    /// Optional free-text query for BM25 and vector lanes.
    ///
    /// When non-None, the BM25 and vector lanes use this text. When None,
    /// both lanes return empty candidate sets and the result falls back to
    /// the locus lane (for hybrid) or empty (for corpusOnly). Defaults to
    /// None for backward compatibility with locusOnly callers.
    pub query_text: Option<String>,
}

impl GLKRecallRequest {
    /// Create a request with explicit lane, scoring, and policy.
    ///
    /// Defaults match Swift: mode=hybrid, scoring=matrixAware, limit=12,
    /// fallback=failClosed, query_text=None.
    pub fn new(frame: RecallFrame) -> Self {
        Self {
            frame,
            mode: GLKRecallMode::Hybrid,
            scoring: GLKRecallScoring::MatrixAware,
            limit: 12,
            fallback: RecallFallbackPolicy::FailClosed,
            query_text: None,
        }
    }

    /// Builder: set the recall mode.
    pub fn with_mode(mut self, mode: GLKRecallMode) -> Self {
        self.mode = mode;
        self
    }

    /// Builder: set the scoring strategy.
    pub fn with_scoring(mut self, scoring: GLKRecallScoring) -> Self {
        self.scoring = scoring;
        self
    }

    /// Builder: set the maximum hits to return.
    pub fn with_limit(mut self, limit: usize) -> Self {
        self.limit = limit;
        self
    }

    /// Builder: set the fallback policy.
    pub fn with_fallback(mut self, fallback: RecallFallbackPolicy) -> Self {
        self.fallback = fallback;
        self
    }

    /// Builder: set an optional free-text query for BM25 and vector lanes.
    pub fn with_query_text(mut self, text: impl Into<String>) -> Self {
        self.query_text = Some(text.into());
        self
    }
}

// ---------------------------------------------------------------------------
// GLKRecallResult
// ---------------------------------------------------------------------------

/// The complete output of a `GLKRecallRequest` routed through the scored
/// recall director.
///
/// Mirrors Swift `GLKRecallResult` (GLKRecallResult.swift).
#[derive(Debug, Clone)]
pub struct GLKRecallResult {
    /// The original request that produced this result.
    pub request: GLKRecallRequest,
    /// The plan the director computed before lane recall ran.
    pub plan: RecallPlan,
    /// Cross-lane union profile. Populated by `UnionBest` mode only.
    /// None for `LocusOnly`, `CorpusOnly`, and `Hybrid` results.
    pub union_profile: Option<RecallUnionProfile>,
    /// Hits in the order the active lane and scoring returned them.
    pub hits: Vec<RecallHit>,
}

impl GLKRecallResult {
    /// Convenience: the drawer for each hit that has one (non-None).
    ///
    /// Mirrors Swift `GLKRecallResult.drawers`.
    pub fn drawers(&self) -> Vec<&Drawer> {
        self.hits.iter().filter_map(|h| h.drawer.as_ref()).collect()
    }
}

// ---------------------------------------------------------------------------
// RecallUnionProfile
// ---------------------------------------------------------------------------

/// Diagnostic statistics over a multi-lane candidate buffer after the
/// union pass completes.
///
/// Describes signal sharpness, lane agreement, redundancy, and matrix
/// coherence. Used by the adaptive weights computation to tune per-lane
/// weights toward the signals most informative for the current query.
///
/// Mirrors Swift `RecallUnionProfile` (RecallUnionProfile.swift).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecallUnionProfile {
    /// Population standard deviation of the locus score column.
    /// High sharpness → locus lane is confidently discriminating.
    pub locus_sharpness: f32,
    /// Population standard deviation of the BM25 score column.
    pub bm25_sharpness: f32,
    /// Population standard deviation of the vector score column.
    pub vector_sharpness: f32,
    /// Mean of popcount(source_mask[i]) / primary_source_count across
    /// all candidates. Near 1.0 → most candidates confirmed by every lane;
    /// near 0.0 → lanes found disjoint sets.
    pub signal_agreement: f32,
    /// Mean pairwise shingle similarity over the top-16 candidates.
    /// Values > 0.5 indicate near-duplicate content dominance.
    pub redundancy: f32,
    /// Mean co-occurrence score over the top-16 candidates by final score.
    /// Non-zero only when a MatrixTier is registered for the estate.
    pub matrix_coherence: f32,
}

impl RecallUnionProfile {
    /// Zero profile — all fields 0.0. Returned when the candidate buffer
    /// is empty. Mirrors the Swift guard branch in `compute(from:primarySourceCount:)`.
    pub const ZERO: Self = Self {
        locus_sharpness: 0.0,
        bm25_sharpness: 0.0,
        vector_sharpness: 0.0,
        signal_agreement: 0.0,
        redundancy: 0.0,
        matrix_coherence: 0.0,
    };
}
