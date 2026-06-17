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
//   RecallShape           → RecallShape (RecallShape.swift)
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

use std::collections::{HashMap, HashSet};

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
    /// Dense float-embedding cosine match (Lane D) — the TRUE float vector
    /// lane, distinct from the 256-bit SimHash-Hamming `VectorHamming` lane.
    VectorDense,
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
            Self::VectorDense         => "vectorDense",
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
    /// Normalized cosine similarity from the DENSE FLOAT lane (Lane D), in
    /// `[0, 1]`. The TRUE float-embedding signal: cosine over the pooled
    /// vector, stored as `(cosine + 1) / 2` so 1.0 = identical direction and
    /// the convention matches every other `[0, 1]` column. 0 for hits not from
    /// the dense lane. RRF fusion is rank-based and never reads this magnitude.
    pub dense: f32,
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
            dense: 0.0,
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
        dense: 0.0,
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

    /// Compute adaptive weights from a query sketch and union profile.
    ///
    /// Mirrors Swift `RecallWeights.adaptive(for:profile:)` (RecallWeights+Adaptive.swift).
    ///
    /// Base weights: locus=0.2, bm25=0.2, vector=0.2, matrix=0.1, fieldFit=0.1,
    /// diversity=0.1, graph=0.1. Additive bonuses applied then normalised to sum 1.0:
    ///   - bitmap predicates non-empty: +0.1 to locus and field_fit.
    ///   - query text present: +0.1 to bm25 and vector.
    ///   - redundancy > 0.5: +0.15 to diversity.
    ///   - signal_agreement > 0.6: +0.1 to graph.
    ///
    /// Parameters:
    ///   - has_bitmap_predicates: true when the recall frame has non-empty filter chain.
    ///   - has_query_text: true when the request carries a non-empty query_text.
    ///   - profile: The union profile computed over the merged candidate buffer.
    pub fn adaptive(
        has_bitmap_predicates: bool,
        has_query_text: bool,
        profile: &RecallUnionProfile,
    ) -> Self {
        let mut locus_w: f32   = 0.2;
        let mut bm25_w: f32    = 0.2;
        let mut vector_w: f32  = 0.2;
        let matrix_w: f32      = 0.1;
        let mut field_fit_w: f32 = 0.1;
        let mut diversity_w: f32 = 0.1;
        let mut graph_w: f32   = 0.1;

        // Structural filter bonus.
        if has_bitmap_predicates {
            locus_w    += 0.1;
            field_fit_w += 0.1;
        }
        // Free-text bonus.
        if has_query_text {
            bm25_w   += 0.1;
            vector_w += 0.1;
        }
        // Redundancy bonus.
        if profile.redundancy > 0.5 {
            diversity_w += 0.15;
        }
        // Signal agreement bonus.
        if profile.signal_agreement > 0.6 {
            graph_w += 0.1;
        }

        // Normalise to sum ≈ 1.0.
        let total = locus_w + bm25_w + vector_w + matrix_w + field_fit_w + diversity_w + graph_w;
        let norm = if total > 0.0 { total } else { 1.0 };
        Self {
            locus:     locus_w     / norm,
            bm25:      bm25_w      / norm,
            vector:    vector_w    / norm,
            matrix:    matrix_w    / norm,
            field_fit: field_fit_w / norm,
            diversity: diversity_w / norm,
            graph:     graph_w     / norm,
        }
    }
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

/// Whether a recall request originates from an external consumer or an
/// internal system process.
///
/// Per B-10a (LOCUSKIT_SPEC.md § B-10a): only external-origin requests
/// may write recall-trace rows. Internal reads — maintenance, dreaming,
/// standing signals, recipes/lenses, migration, and benchmarks — MUST use
/// `Internal` so the reward pipeline learns from experience with users,
/// not from the system's own reflective reads.
///
/// The default on `GLKRecallRequest` is `Internal` so that every existing
/// call site is safe unless explicitly overridden to `External`. The
/// ARIA_MCP boundary is the ONLY place where `External` is set.
///
/// Mirrors Swift `RecallOrigin` (GLKRecallRequest.swift).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecallOrigin {
    /// Request originates from an external consumer (human or outside AI)
    /// arriving through the ARIA access surface. May write recall-trace rows.
    External,
    /// Request originates from an internal system process. Must NOT write
    /// recall-trace rows. Default for all non-ARIA callers.
    Internal,
}

impl Default for RecallOrigin {
    fn default() -> Self {
        Self::Internal
    }
}

/// A fully-specified recall request at the GLK surface.
///
/// Callers that do not need explicit mode/scoring control use the legacy
/// `coordinator.recall(handle, frame, now)` method, which returns a plain
/// `Vec<Drawer>`. This type is the richer scored path.
///
/// A SIGNED, per-lane steering vector for the RRF fusion (6b-modifiers).
///
/// Mirrors Swift `RecallShape` (RecallShape.swift). Makes the RecallDirector's
/// reciprocal-rank fusion STEERABLE without changing the fusion algorithm: a
/// lane's rank mass is multiplied by its signed weight before the per-id sum, so
/// a recipe can forward, exclude, or suppress individual signals. This is the
/// ENGINE knob; named presets are a separate layer built on top.
///
/// ## Lane-key scheme
///
/// Weights are keyed by a STABLE lane identifier string. This is the COMPLETE
/// steerable surface (the keys the optimizer and the preset roster target),
/// spanning the retrieval lanes AND — since 6b-modifiers-matrix-steer — the
/// matrix/graph/preference scoring columns:
///   Retrieval lanes (steer the RRF fusion AND the unionBest weighted columns):
///   - `"locus"`           — the LocusKit bitmap lane.
///   - `"bm25"`            — the CorpusKit BM25 keyword lane.
///   - `"hamming"`         — the 256-bit SimHash-Hamming vector lane.
///   - `"dense"`           — the aggregate dense float column in the unionBest
///     weighted score (per-signal `dense:<modelID>` keys steer the consensus
///     fold that builds that column).
///   - `"dense:<modelID>"` — a per-signal DENSE float lane, one key per held
///     embedding provider, mirroring the 6b-core per-signal fan-out.
///   Matrix/graph/preference columns (steer ONLY the unionBest matrixAware
///   weighted score; a no-op under raw/rrf, where the matrix columns are dark):
///   - `"fieldFit"`        — the FDC field-fit column.
///   - `"coOccurrence"`    — the MatrixTier co-occurrence column.
///   - `"temporal"`        — the MatrixTier temporal-relevance column.
///   - `"graph"`           — the connection-graph column.
///   - `"preference"`      — the learned-preference column.
///
/// A lane whose key is ABSENT uses the default weight `1.0`; an empty map
/// reproduces the uniform fusion exactly (the back-compat contract — a `None`
/// shape is byte-identical to the pre-6b-modifiers fusion).
///
/// ## Signed-weight semantics
///
/// `fused(id) = Σ_L w_L · 1/(k + rank_L(id) + 1)`:
///   - `w > 0` — FORWARD; larger `w` amplifies the lane's rank mass (`1.0` neutral).
///   - `w == 0` — EXCLUDE; the lane contributes nothing (votes dropped).
///   - `w < 0`  — SUPPRESS; the lane SUBTRACTS its rank mass, DEMOTING a candidate
///     it ranks high. Distinct from anti-similarity retrieval (which changes which
///     candidates the store returns).
///
/// ## Anti-similarity (`anti_similar_lanes`)
///
/// A DENSE lane key (`"dense:<modelID>"`) in `anti_similar_lanes` flips that
/// lane's OBJECTIVE from nearest to FARTHEST: it surfaces the most DISSIMILAR
/// sources ("find things UNLIKE this") via CorpusKit's
/// `float_farthest_per_signal`, and those dissimilar candidates become the
/// lane's voters in the same RRF/consensus fold. DISTINCT from a negative
/// weight: anti-similarity changes WHICH candidates the store returns (the
/// farthest), then FORWARDS them; a negative weight keeps the NEAREST and
/// SUBTRACTS their mass (demotes the similar). The two compose. An empty set ⇒
/// every lane nearest ⇒ byte-identical to today's fusion. Only
/// `"dense:<modelID>"` keys are honoured.
#[derive(Debug, Clone, PartialEq)]
pub struct RecallShape {
    /// Signed per-lane weights keyed by the stable lane identifier. A missing key
    /// defaults to `1.0`. `0` excludes a lane; a negative value suppresses
    /// (demotes) the lane's high-ranked candidates.
    pub lane_weights: HashMap<String, f32>,
    /// Dense lane keys (`"dense:<modelID>"`) whose objective is FARTHEST rather
    /// than nearest — anti-similarity retrieval. Empty ⇒ every lane nearest ⇒
    /// byte-identical to today's fusion. Distinct from a negative weight; the two
    /// compose. See the type-level "Anti-similarity" note.
    pub anti_similar_lanes: HashSet<String>,
    /// Optional candidate-pool depth override. `None` keeps the coordinator's
    /// computed default `min(max(limit * 4, 64), 256)`. When set, the value is
    /// clamped to `[FRONTIER_K_FLOOR, FRONTIER_K_CEILING]`.
    pub frontier_k: Option<usize>,
}

impl RecallShape {
    /// Inclusive lower bound for any `frontier_k` override (mirrors the
    /// coordinator's `frontier_k` floor).
    pub const FRONTIER_K_FLOOR: usize = 64;
    /// Inclusive upper bound for any `frontier_k` override (mirrors the
    /// coordinator's `frontier_k` ceiling).
    pub const FRONTIER_K_CEILING: usize = 256;

    /// Construct a shape from a signed lane-weight map and optional pool override.
    /// `anti_similar_lanes` defaults to empty (every lane nearest — today's
    /// behaviour); use `with_anti_similar_lanes` to set it.
    pub fn new(lane_weights: HashMap<String, f32>, frontier_k: Option<usize>) -> Self {
        Self {
            lane_weights,
            anti_similar_lanes: HashSet::new(),
            frontier_k,
        }
    }

    /// Builder: set the dense lane keys (`"dense:<modelID>"`) that invert their
    /// objective to FARTHEST (anti-similarity). Distinct from a negative weight;
    /// the two compose. Returns `self` for chaining.
    pub fn with_anti_similar_lanes(mut self, lanes: HashSet<String>) -> Self {
        self.anti_similar_lanes = lanes;
        self
    }

    /// The signed weight for a lane key. Returns `1.0` for any key absent from
    /// `lane_weights` — the neutral default that keeps unweighted lanes voting at
    /// full strength.
    pub fn weight(&self, lane_key: &str) -> f32 {
        self.lane_weights.get(lane_key).copied().unwrap_or(1.0)
    }

    /// Whether the given dense lane key inverts its objective to FARTHEST
    /// (anti-similarity). Returns `false` for any key not in
    /// `anti_similar_lanes` — an empty set keeps every lane nearest (the
    /// back-compat default).
    pub fn is_anti_similar(&self, lane_key: &str) -> bool {
        self.anti_similar_lanes.contains(lane_key)
    }

    /// Resolve the effective candidate-pool depth for a computed engine default.
    /// `None` override returns the default unchanged; a set override is clamped to
    /// `[FRONTIER_K_FLOOR, FRONTIER_K_CEILING]`.
    pub fn effective_frontier_k(&self, engine_default: usize) -> usize {
        match self.frontier_k {
            None => engine_default,
            Some(o) => o.clamp(Self::FRONTIER_K_FLOOR, Self::FRONTIER_K_CEILING),
        }
    }
}

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
    /// How many rows to record as recall-trace rows in the reward cycle.
    ///
    /// When set, the coordinator uses this value for `trace_limit` on the
    /// primary locus frame instead of `limit`. Ignored unless
    /// `origin == External` (B-10a).
    pub trace_limit: Option<usize>,
    /// Whether this recall originates from an external consumer or an
    /// internal system process.
    ///
    /// B-10a enforcement: the coordinator sets `trace_limit` on the
    /// LocusKit `RecallFrame` ONLY when `origin == External`. Internal reads
    /// must not write recall-trace rows. Defaults to `Internal`.
    pub origin: RecallOrigin,
    /// Optional SIGNED per-lane steering for the RRF fusion (6b-modifiers).
    ///
    /// When non-None, the coordinator multiplies each fusion lane's reciprocal-rank
    /// mass by that lane's signed weight from the shape before the per-id sum:
    /// `w > 0` forwards, `w == 0` excludes, `w < 0` suppresses (demotes the lane's
    /// high-ranked candidates). It may also override the candidate-pool depth
    /// (`frontier_k`). See `RecallShape` for the lane-key scheme and semantics.
    ///
    /// When None (the default), fusion uses uniform positive weights — every lane
    /// at weight `1.0` — BYTE-IDENTICAL to the pre-6b-modifiers behaviour.
    pub recall_shape: Option<RecallShape>,
}

impl GLKRecallRequest {
    /// Create a request with explicit lane, scoring, and policy.
    ///
    /// Defaults match Swift: mode=hybrid, scoring=matrixAware, limit=12,
    /// fallback=failClosed, query_text=None, origin=Internal.
    pub fn new(frame: RecallFrame) -> Self {
        Self {
            frame,
            mode: GLKRecallMode::Hybrid,
            scoring: GLKRecallScoring::MatrixAware,
            limit: 12,
            fallback: RecallFallbackPolicy::FailClosed,
            query_text: None,
            trace_limit: None,
            origin: RecallOrigin::Internal,
            recall_shape: None,
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

    /// Builder: set an explicit trace-write budget for the reward cycle.
    ///
    /// When set, the coordinator uses this value for `trace_limit` on the
    /// primary locus frame instead of `limit`. Only applied when
    /// `origin == External` (B-10a).
    pub fn with_trace_limit(mut self, limit: usize) -> Self {
        self.trace_limit = Some(limit);
        self
    }

    /// Builder: mark this request as originating from an external consumer.
    ///
    /// Only the ARIA_MCP boundary should call this method (B-10a enforcement).
    pub fn external(mut self) -> Self {
        self.origin = RecallOrigin::External;
        self
    }

    /// Builder: set the signed per-lane fusion steering (6b-modifiers).
    ///
    /// `None`-equivalent (an empty-map shape) leaves fusion uniform; a populated
    /// shape forwards/excludes/suppresses lanes per `RecallShape`.
    pub fn with_recall_shape(mut self, shape: RecallShape) -> Self {
        self.recall_shape = Some(shape);
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
    /// Dense float lane (Lane D) status for this query.
    ///
    /// Non-None when the lane was dark (did not contribute hits), carrying the
    /// observable reason as a short string. None when the lane ran and returned hits,
    /// or when no corpus was registered for the estate (lane was never attempted).
    ///
    /// Values follow the `dark:<reason>` convention, identical to Swift:
    /// - `"dark:providerOptOut"` — the corpus's embedding provider has no float lane.
    /// - `"dark:noFloatRows"` — no float vectors are stored.
    /// - `"dark:storeError"` — the vector store threw; error already logged by CorpusKit.
    /// - `"dark:emptyQuery"` — query was empty (guard fired before lane was attempted).
    ///
    /// Only populated for `UnionBest` mode (the mode that attempts the dense lane).
    /// `LocusOnly`, `CorpusOnly`, `Hybrid`, and `NodeTreeNative` carry `None`.
    ///
    /// Mirrors Swift `GLKRecallResult.denseLaneStatus` (GLKRecallResult.swift).
    pub dense_lane_status: Option<String>,

    /// Per-stage degradation indicators for this query.
    ///
    /// Each element names a pipeline stage that encountered a recoverable error
    /// and was skipped. The query survived by operating on whatever signals
    /// remained. An empty vec means every attempted stage succeeded.
    ///
    /// Stage identifiers follow the `<lane>.<operation>` convention, matching
    /// the Swift `GLKRecallResult.degradedStages` string vocabulary exactly:
    /// - `"vectorHamming.findNearest"` — `VectorStore.find_nearest` threw; the
    ///   Hamming vector lane contributed no candidates. The query survives on
    ///   locus and BM25 signals; the vector column is absent from hit scores.
    /// - `"corpus.embed"` — the embedding call inside the query-sketch compilation
    ///   threw; the vector lane is dark for this query (same effect as above, but
    ///   the failure occurred one step earlier — before `find_nearest` was called).
    ///
    /// The following Swift stages are absent in the Rust port because the Rust
    /// `recall_scored_multi_lane` path uses `estate.recall()` (non-throwing) for
    /// drawer retrieval — there is no separate by-id `getDrawers` batch load, no
    /// body-free pool step, and no MMR hydration step:
    ///   `pool.getDrawers`, `pool.hydrateBodies.mmr`, `pool.hydrateBodies.return`,
    ///   `hybrid.getDrawers`, `corpusOnly.getDrawers`.
    ///
    /// A second class of identifiers names a SCORING FALLBACK — the caller
    /// requested a scoring strategy that is not a distinct implementation in
    /// that lane, so a simpler combiner was applied. The query succeeded; the
    /// entry names the fallback so the caller knows the requested scoring was
    /// not the one applied. Parity with Swift exactly; genuinely-implemented
    /// combos (`UnionBest` + `MatrixAware`; `Hybrid` / `CorpusOnly` + `Rrf`)
    /// record nothing.
    /// - `"locusOnly.matrixAware"` — `MatrixAware` on `LocusOnly`, no matrix
    ///   pass; raw bitmap-evaluator ordering returned.
    /// - `"corpusOnly.matrixAware"` — `MatrixAware` on `CorpusOnly`, no matrix
    ///   pass; fell back to RRF fusion.
    /// - `"hybrid.matrixAware"` — `MatrixAware` on `Hybrid`, no matrix pass;
    ///   fell back to RRF fusion.
    /// - `"unionBest.rrf"` — `Rrf` on `UnionBest`, no distinct equal-weight RRF
    ///   fusion; fell back to the raw lane-normalised score.
    ///
    /// Scoring-stage failures always DEGRADE (query survives). Estate-unavailable
    /// failures surface as `VerbDispatchError::EstateNotOpen` before any stage runs.
    ///
    /// Counterpart telemetry: each degraded stage emits a counter named by the
    /// corresponding `metric_names::*_DEGRADED` constant, tagged with `estate_id`
    /// and `lane`. Consumers can correlate this field with the Intellectus counter
    /// stream for per-estate health dashboards.
    ///
    /// Mirrors Swift `GLKRecallResult.degradedStages` (GLKRecallResult.swift).
    pub degraded_stages: Vec<String>,
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

    /// Compute a union profile from the populated (and already normalised) parallel
    /// score columns that make up the candidate buffer.
    ///
    /// Mirrors Swift `RecallUnionProfile.compute(from:primarySourceCount:)`
    /// (RecallUnionProfile.swift).
    ///
    /// Parameters:
    ///   - locus_col / bm25_col / vector_col: the normalised per-candidate score columns.
    ///   - co_occurrence_col: the matrix co-occurrence column (after normalization).
    ///   - source_masks: the u16 lane-membership bitset per candidate.
    ///   - final_col: the normalised final score column (for redundancy top-16 selection).
    ///   - count: number of populated slots in every column.
    ///   - primary_source_count: number of lanes that contributed ≥ 1 hit.
    #[allow(clippy::too_many_arguments)]
    pub fn compute(
        locus_col: &[f32],
        bm25_col: &[f32],
        vector_col: &[f32],
        co_occurrence_col: &[f32],
        source_masks: &[u16],
        final_col: &[f32],
        count: usize,
        primary_source_count: usize,
    ) -> Self {
        if count == 0 {
            return Self::ZERO;
        }

        let n = count;
        let divisor = primary_source_count.max(1) as f32;

        // Sharpness: population standard deviation of each score column.
        let locus_sharpness  = Self::std_dev(&locus_col[..n]);
        let bm25_sharpness   = Self::std_dev(&bm25_col[..n]);
        let vector_sharpness = Self::std_dev(&vector_col[..n]);

        // Signal agreement: mean of popcount(source_mask[i]) / primary_source_count.
        let mut agreement_sum: f32 = 0.0;
        for i in 0..n {
            agreement_sum += source_masks[i].count_ones() as f32 / divisor;
        }
        let signal_agreement = agreement_sum / n as f32;

        // Redundancy: mean pairwise sourceMask Jaccard over top-16 by final score.
        let top16_count = n.min(16);
        let mut indexed: Vec<(usize, f32)> = (0..n).map(|i| (i, final_col[i])).collect();
        indexed.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let top_indices: Vec<usize> = indexed[..top16_count].iter().map(|(i, _)| *i).collect();

        let mut pair_sum: f32 = 0.0;
        let mut pair_count: usize = 0;
        for a in 0..top_indices.len() {
            for b in (a + 1)..top_indices.len() {
                let ia = top_indices[a];
                let ib = top_indices[b];
                let and_bits = source_masks[ia] & source_masks[ib];
                let or_bits  = source_masks[ia] | source_masks[ib];
                let jaccard: f32 = if or_bits == 0 {
                    0.0
                } else {
                    and_bits.count_ones() as f32 / or_bits.count_ones() as f32
                };
                pair_sum += jaccard;
                pair_count += 1;
            }
        }
        let redundancy: f32 = if pair_count > 0 {
            pair_sum / pair_count as f32
        } else {
            0.0
        };

        // matrixCoherence: mean co-occurrence score over top-16.
        let mut co_sum: f32 = 0.0;
        for &idx in &top_indices {
            co_sum += co_occurrence_col[idx];
        }
        let matrix_coherence: f32 = if top16_count > 0 {
            co_sum / top16_count as f32
        } else {
            0.0
        };

        Self {
            locus_sharpness,
            bm25_sharpness,
            vector_sharpness,
            signal_agreement,
            redundancy,
            matrix_coherence,
        }
    }

    /// Population standard deviation of a slice.
    fn std_dev(col: &[f32]) -> f32 {
        let n = col.len();
        if n == 0 {
            return 0.0;
        }
        let sum: f32 = col.iter().sum();
        let mean = sum / n as f32;
        let variance: f32 = col.iter().map(|&v| {
            let d = v - mean;
            d * d
        }).sum::<f32>() / n as f32;
        variance.sqrt()
    }
}
