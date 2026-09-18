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

use std::collections::HashMap;
use std::collections::HashSet;

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
///   `CorpusOnly`  — BM25 + vector lanes via registered CorpusKit/SynapseKit.
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
/// `Raw` returns hits in the order the active lane produced them with no
/// reranking. `Rrf` applies Reciprocal Rank Fusion across lanes.
/// `MatrixAware` enables the full weighted pipeline (matrix co-occurrence
/// + temporal, fieldFit, graph, preference signals) mirroring the Swift
/// `RecallDirector`'s step-9 path. `Discriminative` is RRF-based scoring
/// with the dense-lane saturation discount applied to the composite score;
/// no matrix steer, fieldFit, graph, or preference signals are applied.
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
    /// RRF composite score scaled by the dense-lane saturation discount
    /// (`dense_discrimination_factor` ∈ [0, 1]). No matrix steer applied.
    /// When the dense lane is absent or contrastive (spread ≥ 0.15) the
    /// factor is 1.0 and the result is byte-identical to `Rrf`.
    Discriminative,
}

impl GLKRecallScoring {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Self::Raw           => "raw",
            Self::Rrf           => "rrf",
            Self::MatrixAware   => "matrixAware",
            Self::Discriminative => "discriminative",
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
// GraphCache / PreferenceStore (recall-scoring accelerators)
// ---------------------------------------------------------------------------

/// Cache of pre-built graph projections for one estate.
///
/// Implementations hold pre-computed per-drawer graph centrality scores
/// (e.g. random-walk stationary distributions, eigenvalue centrality) built
/// during the dreaming cycle. The director queries this cache for candidate-
/// frontier lookups only — no synchronous estate-wide analytics are performed at
/// recall time (spec §15).
///
/// When no implementation is registered for an estate the graph column remains
/// 0.0, which is correct and not an error.
///
/// Mirrors the Swift `GeniusLocusKit.GraphCache` protocol
/// (Sources/GeniusLocusKit/GeniusLocusKit.swift). `Send + Sync` is the Rust
/// equivalent of Swift's `Sendable` requirement, so a registered cache can be
/// shared across the recall path.
pub trait GraphCache: Send + Sync {
    /// Return the graph centrality score for the given drawer ID.
    ///
    /// Returns 0.0 when the drawer is not in the cache. Must not perform any
    /// synchronous estate-wide graph traversal. Mirrors Swift
    /// `GraphCache.graphScore(for:)`.
    fn graph_score(&self, drawer_id: &str) -> f32;
}

/// Store of learned per-drawer preference scores for one estate.
///
/// Implementations hold pre-trained Bradley-Terry or RecallTrace preference
/// weights built by the training daemon. The director queries this store for
/// candidate-frontier lookups only — no synchronous model retraining occurs at
/// recall time (spec §15).
///
/// When no implementation is registered for an estate the preference column
/// remains 0.0, which is correct and not an error.
///
/// Mirrors the Swift `GeniusLocusKit.PreferenceStore` protocol
/// (Sources/GeniusLocusKit/GeniusLocusKit.swift). `Send + Sync` mirrors Swift's
/// `Sendable` requirement.
pub trait PreferenceStore: Send + Sync {
    /// Return the preference score for the given drawer ID.
    ///
    /// Returns 0.0 when the drawer is not in the store. Must not trigger any
    /// synchronous preference model update. Mirrors Swift
    /// `PreferenceStore.preferenceScore(for:)`.
    fn preference_score(&self, drawer_id: &str) -> f32;
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
    /// Human-readable explanation lines. UnionBest hits carry the
    /// `recall_explainer` block (`sources:`, `score:`, `mode: … | scoring: …`,
    /// `why:`) plus a `denseSignals:` line when the dense lane voted; Hybrid and
    /// CorpusOnly hits carry the sorted source raw values; the locus-only
    /// fallbacks carry `["locusBitmap"]`. Byte-identical to Swift `RecallHit.explanation`.
    pub explanation: Vec<String>,
    /// The span rerank hit for this drawer (best span index, word bounds, cosine
    /// and lexical rank under the active encoder), when the UnionBest span stage
    /// scored it (contract sheet §8). None for every other lane and for drawers
    /// with no span rows under the active model; the composer renders the evidence
    /// snippet from the bounds when present (sheet §9). Twin of Swift
    /// `RecallHit.spanHit`.
    pub span_hit: Option<crate::span_rerank::SpanRerankHit>,
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
///   Column-budget keys, namespace `signal:` (COL-1; steer ONLY the unionBest
///   MatrixAware weighted score). Where the per-lane keys SCALE a column's
///   term, a `signal:*` key at 0 EXCLUDES the whole column and REDISTRIBUTES
///   its `RecallWeights` budget over the remaining columns (see
///   `recall_signal_budget::RecallSignalBudget`). `1.0`/absent neutral, `<0`
///   suppresses, other positive values scale without redistribution:
///   - `"signal:locus"`, `"signal:bm25"`, `"signal:vector"` (Hamming + dense),
///     `"signal:fieldFit"`, `"signal:matrix"` (coOccurrence + temporal),
///     `"signal:graph"`, `"signal:preference"`, `"signal:agreement"`.
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
    /// Binary-lane metric selector (W2.5 M1): "hamming" (default) or
    /// "jaccard". Unknown values degrade to Hamming (shape contract).
    /// Twin of Swift `RecallShape.binaryMetric` (which is Codable-additive;
    /// this port's shape is constructed in-process, not deserialized).
    pub binary_metric: String,
    /// Float-lane metric selector (W2.5 M1 float unlock): "cosine" (default),
    /// "l2", or "dot". Unknown values degrade to cosine (shape contract — a
    /// shape must degrade, never fail). Twin of Swift `RecallShape.floatMetric`.
    ///
    /// Semantics:
    /// - "cosine": 1 − cos(a,b). Scale-invariant; the historical default.
    /// - "l2": Euclidean distance √Σ(aᵢ−bᵢ)². Magnitude-sensitive.
    /// - "dot": negative dot product −Σ(aᵢbᵢ). For dot-product-trained embeddings.
    pub float_metric: String,
    /// Matrix-signal weighting selector (W2.5 S4-C): "counts" (default —
    /// the canonical i64 count matrices) or "decayed" (the §8.13
    /// exp-decayed projections). Unknown values degrade to counts.
    /// Twin of Swift `RecallShape.matrixWeighting`.
    pub matrix_weighting: String,
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
            binary_metric: "hamming".to_string(),
            float_metric: "cosine".to_string(),
            matrix_weighting: "counts".to_string(),
        }
    }

    /// Builder: select the matrix-signal weighting ("counts" | "decayed",
    /// W2.5 S4-C). Unknown values degrade to counts at the read site.
    pub fn with_matrix_weighting(mut self, weighting: &str) -> Self {
        self.matrix_weighting = weighting.to_string();
        self
    }

    /// Builder: select the binary-lane metric ("hamming" | "jaccard",
    /// W2.5 M1). Unknown values degrade to Hamming at the read site.
    pub fn with_binary_metric(mut self, metric: &str) -> Self {
        self.binary_metric = metric.to_string();
        self
    }

    /// Builder: select the float-lane metric ("cosine" | "l2" | "dot",
    /// W2.5 M1 float unlock). Unknown values degrade to cosine at the read
    /// site. Twin of Swift `RecallShape.floatMetric`.
    pub fn with_float_metric(mut self, metric: &str) -> Self {
        self.float_metric = metric.to_string();
        self
    }

    /// Builder: set the dense lane keys (`"dense:<modelID>"`) that invert their
    /// objective to FARTHEST (anti-similarity). Distinct from a negative weight;
    /// the two compose. Returns `self` for chaining.
    pub fn with_anti_similar_lanes(mut self, lanes: HashSet<String>) -> Self {
        self.anti_similar_lanes = lanes;
        self
    }

    /// The signed weight for a lane key. Returns `default_weight(lane_key)` for
    /// any key absent from `lane_weights` — `1.0` for every key except
    /// `SIGNAL_VECTOR`, whose default is `0`. Mirrors Swift `weight(for:)`.
    pub fn weight(&self, lane_key: &str) -> f32 {
        self.lane_weights
            .get(lane_key)
            .copied()
            .unwrap_or_else(|| Self::default_weight(lane_key))
    }

    /// The weight a lane key carries when no shape and no provisioned default
    /// names it. `1.0` (neutral) for every key except `SIGNAL_VECTOR`, which
    /// defaults to `0`: the whole-record vector column (Hamming + dense) is out
    /// of the fused score by ruling (Encoder Rerank Program — the span rerank
    /// stage carries the semantic signal) and a shape brings it back by setting
    /// the key explicitly. The coordinator's weight resolvers and `weight` both
    /// read this, so they agree. Mirrors Swift `RecallShape.defaultWeight(for:)`.
    pub fn default_weight(lane_key: &str) -> f32 {
        if lane_key == Self::SIGNAL_VECTOR { 0.0 } else { 1.0 }
    }

    /// The signed weight for `lane_key` from an optional shape: the shape's
    /// weight when present, `default_weight` otherwise. The one resolver every
    /// coordinator read site uses so a `None` shape and an empty shape agree.
    pub fn weight_or_default(shape: &Option<RecallShape>, lane_key: &str) -> f32 {
        match shape {
            Some(s) => s.weight(lane_key),
            None => Self::default_weight(lane_key),
        }
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

    // ----- Named preset roster (mirrors Swift `RecallShape.preset`) -----

    /// The per-signal DENSE lane key for a held embedding provider, by its
    /// `model_id`. These are the exact `model_id` strings the CorpusKit providers
    /// ship (`dense:<model_id>`); the roster targets them by these constants so a
    /// typo surfaces at compile time, not as a silent no-op. Mirrors Swift
    /// `RecallShape.DenseSignal`.
    pub const DENSE_RANDOM_INDEXING: &'static str = "dense:random-indexing-v1";
    /// The span rerank encoder lane, keyed by the floor model's registry id
    /// (contract sheet §1: `<model>-w<window_words>`). The stage reads the key
    /// for whichever model is ACTIVE via `dense_key_for_model`; this constant is
    /// the floor model's spelling for presets and docs. Mirrors Swift
    /// `RecallShape.DenseSignal.encoder`.
    pub const DENSE_ENCODER: &'static str = "dense:minilm-l6-v2-w60";
    /// The span rerank stage switch (contract sheet §8): `0` skips the stage,
    /// any other value runs it. Not a scoring column — it has no budget slice
    /// and never redistributes. Mirrors Swift `RecallShape.SignalKey.encoder`.
    pub const SIGNAL_ENCODER: &'static str = "signal:encoder";

    /// The lane key for a model id: `"dense:<model_id>"`. One spelling for the
    /// dense consensus fold and the span rerank weight alike.
    pub fn dense_key_for_model(model_id: &str) -> String {
        format!("dense:{model_id}")
    }
    /// Latent-Semantic-Analysis provider dense lane key (always-on).
    pub const DENSE_LSA: &'static str = "dense:lsa-v1";
    /// The distributional dense lane keys in stable order: RI and LSA, both
    /// always-on. Mirrors Swift `RecallShape.DenseSignal.all`.
    pub const DENSE_SIGNALS: [&'static str; 2] = [Self::DENSE_RANDOM_INDEXING, Self::DENSE_LSA];


    /// Default preset roster (35 names): RI, LSA, and all whole-record float
    /// presets are always active. Mirrors Swift `RecallShape.presetNames`.
    pub const PRESET_NAMES: [&'static str; 35] = [
        "balanced",
        "precise",
        "conceptual",
        "broad",
        "lexical",
        "jaccard",
        "float-l2",
        "float-dot",
        "matrix_decayed",
        "not_lexical",
        "associative",
        "consensus",
        "ri_forward",
        "fast",
        "structural",
        "temporal",
        "connection",
        "field",
        "preference",
        "anti_redundant",
        "anti_redundant_ri",
        "lsa_forward",
        "anti_redundant_lsa",
        "session_hybrid",
        "temporal_connection",
        "field_preference",
        "no_locus",
        "no_field_fit",
        "no_matrix",
        "no_graph",
        "no_preference",
        "no_agreement",
        "no_bm25",
        "no_vector",
        "no_encoder",
    ];


    pub const SIGNAL_LOCUS: &'static str = "signal:locus";
    /// BM25 column budget key.
    pub const SIGNAL_BM25: &'static str = "signal:bm25";
    /// Vector budget key (Hamming + dense share it).
    pub const SIGNAL_VECTOR: &'static str = "signal:vector";
    /// Field-fit column budget key.
    pub const SIGNAL_FIELD_FIT: &'static str = "signal:fieldFit";
    /// Matrix budget key (coOccurrence + temporal share it).
    pub const SIGNAL_MATRIX: &'static str = "signal:matrix";
    /// Graph column budget key.
    pub const SIGNAL_GRAPH: &'static str = "signal:graph";
    /// Preference column budget key.
    pub const SIGNAL_PREFERENCE: &'static str = "signal:preference";
    /// Fixed signal-agreement bonus key.
    pub const SIGNAL_AGREEMENT: &'static str = "signal:agreement";

    /// Resolve a named preset to its documented signed-weight shape. Mirrors
    /// Swift `RecallShape.preset`.
    ///
    /// Returns the shape for a known preset name, or `None` when the name is not
    /// in `PRESET_NAMES`. `"balanced"` deliberately resolves to `None` too — the
    /// uniform, unsteered fusion is the absence of a shape, so a `None` return for
    /// `"balanced"` and for an unknown name are the SAME thing at the call site
    /// (run recall with no steering). Callers that must distinguish check
    /// `PRESET_NAMES.contains(&name)` first.
    ///
    /// The weights are SENSIBLE, DEFENSIBLE starting points the optimizer tunes
    /// later — NOT canon. A preset's contract is its DIRECTION (which lanes it
    /// forwards/zeroes/suppresses/inverts and how it bounds the frontier), not
    /// the literal float. Every key a preset sets is a key the coordinator reads,
    /// so no preset is a silent no-op.
    ///
    /// Leave-one-out is reachable WITHOUT a dedicated preset: take a forward shape
    /// and zero one `dense:<model_id>` lane to ablate that distributional signal.
    pub fn preset(name: &str) -> Option<RecallShape> {
        // Helper: build a shape from (key, weight) pairs + optional frontier.
        fn shape(pairs: &[(&str, f32)], frontier_k: Option<usize>) -> RecallShape {
            let mut weights = HashMap::new();
            for (k, w) in pairs {
                weights.insert((*k).to_string(), *w);
            }
            RecallShape::new(weights, frontier_k)
        }

        match name {
            // Uniform fusion — the absence of steering. None ⇒ every lane at 1.0
            // ⇒ byte-identical to today's behaviour.
            "balanced" => None,

            // Exactness: amplify keyword (bm25) + field-coding (fdc), forward the
            // dense consensus, NARROW the frontier so suppression reshapes a tight
            // high-precision pool. The "find the exact answer" shape.
            "precise" => {
                // `mut` is used only when the dark families are compiled in.
                #[allow(unused_mut)]
                let mut pairs: Vec<(&str, f32)> = vec![("bm25", 1.5), ("dense", 1.2)];
                Some(shape(&pairs, Some(Self::FRONTIER_K_FLOOR)))
            }

            // Concepts over keywords: amplify the distributional dense lanes and
            // damp the literal keyword lane.
            "conceptual" => {
                let mut pairs: Vec<(&str, f32)> =
                    Self::DENSE_SIGNALS.iter().map(|k| (*k, 1.5)).collect();
                pairs.push(("bm25", 0.5));
                Some(shape(&pairs, None))
            }

            // Cast wide: forward every retrieval lane above neutral and WIDEN the
            // frontier to the ceiling. The "don't miss anything" shape.
            "broad" => Some(shape(
                &[
                    ("locus", 1.3),
                    ("bm25", 1.3),
                    ("hamming", 1.3),
                    ("dense", 1.3),
                ],
                Some(Self::FRONTIER_K_CEILING),
            )),

            // Keyword/field only: amplify bm25 + fdc, ZERO the vector lanes.
            "lexical" => {
                // `mut` is used only when the dark families are compiled in.
                #[allow(unused_mut)]
                let mut pairs: Vec<(&str, f32)> = vec![("bm25", 1.5), ("dense", 0.0), ("hamming", 0.0)];
                Some(shape(&pairs, None))
            }

            // Binary-lane metric swap (W2.5 M1): identical fusion, but the
            // engram lanes score Jaccard set-overlap instead of Hamming.
            "jaccard" => Some(
                shape(&[], None).with_binary_metric("jaccard")
            ),

            // Float-lane metric presets: identical fusion to balanced, but the
            // dense float embedding lane uses L2 or dot-product distance instead
            // of the default cosine. Mirrors the jaccard/binary_metric pattern:
            // only the distance function changes; all lane weights remain neutral.
            "float-l2" => Some(
                shape(&[], None).with_float_metric("l2")
            ),

            // Negative dot product (−Σaᵢbᵢ) as the float-lane distance. Useful
            // for embeddings trained with a dot-product objective.
            "float-dot" => Some(
                shape(&[], None).with_float_metric("dot")
            ),

            // W2.5 S4-C arm: matrixAware O/T signals read the §8.13
            // exp-decayed projections instead of the counts.
            "matrix_decayed" => Some(shape(&[], None).with_matrix_weighting("decayed")),

            // Suppress the literal lanes: ZERO bm25 + fdc. Complement of lexical.
            "not_lexical" => {
                // `mut` is used only when the dark families are compiled in.
                #[allow(unused_mut)]
                let mut pairs: Vec<(&str, f32)> = vec![("bm25", 0.0)];
                Some(shape(&pairs, None))
            }

            // Loose association: amplify RI + NMF and widen the frontier.
            "associative" => {
                // `mut` is used only when the dark families are compiled in.
                #[allow(unused_mut)]
                let mut pairs: Vec<(&str, f32)> = vec![(Self::DENSE_RANDOM_INDEXING, 1.5)];
                Some(shape(&pairs, Some(Self::FRONTIER_K_CEILING)))
            }

            // Dense consensus: forward EVERY per-signal dense lane at full
            // strength and narrow the frontier. "Where the embedding models agree."
            "consensus" => {
                // `mut` is used only when the dark families are compiled in.
                #[allow(unused_mut)]
                let mut pairs: Vec<(&str, f32)> =
                    Self::DENSE_SIGNALS.iter().map(|k| (*k, 1.0)).collect();
                Some(shape(&pairs, Some(Self::FRONTIER_K_FLOOR)))
            }

            // Single-signal forwarding: amplify ONE dense lane, ZERO its siblings.
            // With the dense families dark only `ri_forward` exists and it has no
            // siblings to zero.
            "ri_forward" => Some(single_dense_forward(Self::DENSE_RANDOM_INDEXING)),
            "lsa_forward" => Some(single_dense_forward(Self::DENSE_LSA)),

            // Cheapest vote: keep ONLY the 256-bit Hamming lane, ZERO float-dense.
            "fast" => Some(shape(&[("hamming", 1.5), ("dense", 0.0)], None)),

            // Structure-led: amplify the LocusKit bitmap lane.
            "structural" => Some(shape(&[("locus", 1.5)], None)),

            // Time-led: amplify the temporal column (matrixAware-only).
            "temporal" => Some(shape(&[("temporal", 1.5)], None)),

            // Connection-led: amplify the connection-graph column (matrixAware-only).
            "connection" => Some(shape(&[("graph", 1.5)], None)),

            // Field-led: amplify the co-occurrence column (matrixAware-only).
            "field" => Some(shape(&[("coOccurrence", 1.5)], None)),

            // Preference-led: amplify the learned-preference column (matrixAware-only).
            "preference" => Some(shape(&[("preference", 1.5)], None)),

            // Diversity: invert the FDC dense lane to FARTHEST (anti-similarity) +
            // suppress BM25/Hamming (-0.5) so lexical near-duplicates cannot dominate
            // the fused ranking. Frontier narrowed to the floor (64) to avoid hauling
            // a wide pool of duplicates. Mirrors Swift `RecallShape.preset("anti_redundant")`.
            // With the dense families dark there is no FDC lane to invert: the
            // preset keeps the suppression and the narrow frontier;
            // `anti_redundant_ri` is the inversion that stays live.
            // FDC is dark: nothing is inverted; the suppression and the narrow
            // frontier remain.
            "anti_redundant" => Some(shape(
                &[("bm25", -0.5), ("hamming", -0.5)],
                Some(Self::FRONTIER_K_FLOOR),
            )),

            // Session-granularity hybrid recall: amplify bm25 (keyword match for
            // conversation fragments), dense (semantic similarity within the session
            // context), and temporal (recency within the session window). The
            // CognitionKit ShapedRecall recipe special-cases this name to route
            // through the hybridRecall scoredLane seam with post-processing boosts
            // (temporal window + speaker-aware weighting). Mirrors Swift
            // RecallShape.preset("session_hybrid").
            "session_hybrid" => Some(shape(
                &[("bm25", 1.3), ("dense", 1.2), ("temporal", 1.2)],
                None,
            )),

            // Per-signal anti-similarity: same suppression shape as anti_redundant
            // (bm25/hamming at -0.5, frontier narrowed to the floor) but inverts
            // the RI, LSA, or NMF dense lane to FARTHEST. Each variant targets
            // diversity in the corresponding distributional semantic space.
            "anti_redundant_ri" => {
                let mut anti = HashSet::new();
                anti.insert(Self::DENSE_RANDOM_INDEXING.to_string());
                let s = shape(
                    &[("bm25", -0.5), ("hamming", -0.5)],
                    Some(Self::FRONTIER_K_FLOOR),
                );
                Some(s.with_anti_similar_lanes(anti))
            }

            "anti_redundant_lsa" => {
                let mut anti = HashSet::new();
                anti.insert(Self::DENSE_LSA.to_string());
                let s = shape(
                    &[("bm25", -0.5), ("hamming", -0.5)],
                    Some(Self::FRONTIER_K_FLOOR),
                );
                Some(s.with_anti_similar_lanes(anti))
            }


            // Multi-column matrix presets: amplify two matrixAware columns together.
            // These are no-ops under .raw/.rrf (the matrix columns are dark there).

            // Temporal + co-occurrence: surfaces memories that are BOTH recently
            // relevant AND frequently filed together with the query's neighbourhood.
            "temporal_connection" => Some(shape(
                &[("temporal", 1.5), ("coOccurrence", 1.5)],
                None,
            )),

            // Field-fit + preference: surfaces memories that BOTH match the query's
            // filing facets AND have been historically favoured by the user.
            "field_preference" => Some(shape(
                &[("fieldFit", 1.5), ("preference", 1.5)],
                None,
            )),

            // Column-exclusion presets (COL-1): one `signal:*` key at 0 each; the
            // excluded column's budget is redistributed (RecallSignalBudget).
            "no_locus" => Some(shape(&[(Self::SIGNAL_LOCUS, 0.0)], None)),
            "no_field_fit" => Some(shape(&[(Self::SIGNAL_FIELD_FIT, 0.0)], None)),
            "no_matrix" => Some(shape(&[(Self::SIGNAL_MATRIX, 0.0)], None)),
            "no_graph" => Some(shape(&[(Self::SIGNAL_GRAPH, 0.0)], None)),
            "no_preference" => Some(shape(&[(Self::SIGNAL_PREFERENCE, 0.0)], None)),
            "no_agreement" => Some(shape(&[(Self::SIGNAL_AGREEMENT, 0.0)], None)),
            "no_bm25" => Some(shape(&[(Self::SIGNAL_BM25, 0.0)], None)),
            "no_vector" => Some(shape(&[(Self::SIGNAL_VECTOR, 0.0)], None)),
            // Span rerank ablation (sheet §8): the stage is skipped and the
            // lexical list enters the pool in BM25 order. No budget slice.
            "no_encoder" => Some(shape(&[(Self::SIGNAL_ENCODER, 0.0)], None)),

            _ => None,
        }
    }

    /// A one-line, human-readable description of what a preset emphasises — the
    /// text the ARIA tool surfaces when it lists the roster. Mirrors Swift
    /// `RecallShape::preset_description` byte-for-byte. Returns `""` for an
    /// unknown name (not in `PRESET_NAMES`).
    pub fn preset_description(name: &str) -> &'static str {
        match name {
            "balanced" => "Uniform fusion — every lane votes equally. The unsteered default.",
            "precise" => "Exactness — amplify keyword (bm25) + dense consensus (+ field-coding when the dense families are compiled in) over a narrow frontier.",
            "conceptual" => "Concepts over keywords — amplify the distributional dense lanes (RI and LSA), damp bm25.",
            "broad" => "Cast wide — forward every retrieval lane and widen the candidate frontier to the ceiling.",
            "lexical" => "Keyword/field only — amplify bm25 (+ fdc when compiled in), exclude the dense and Hamming vector lanes.",
            "jaccard" => "Jaccard binary metric — the engram lanes score set-overlap/union instead of Hamming distance; length-normalized similarity.",
            "float-l2" => "L2 float metric — the dense float embedding lane scores Euclidean L2 distance instead of cosine; useful when absolute vector magnitude differences matter.",
            "float-dot" => "Dot-product float metric — the dense float embedding lane scores negative dot product instead of cosine; useful for embeddings trained with a dot-product objective.",
            "matrix_decayed" => "Decayed matrix signals — the co-occurrence and temporal matrix columns read the §8.13 exp-decayed projections (recent evidence outweighs stale) instead of raw counts.",
            "not_lexical" => "Suppress the literal lanes — exclude bm25 (+ fdc when compiled in) so distributional and structural signals decide.",
            "associative" => "Loose association — amplify the RI (+ NMF when compiled in) distributional lanes over a wide frontier.",
            "consensus" => "Dense consensus — forward every per-signal dense lane over a narrow frontier; where the embedding models agree.",
            "ri_forward" => "Isolate Random-Indexing — amplify the RI dense lane, exclude the other distributional signals.",
            "lsa_forward" => "Isolate LSA — amplify the LSA dense lane, exclude the other distributional signals.",
            "fast" => "Cheapest vote — keep only the 256-bit Hamming lane, skip the float-dense cosine pass.",
            "structural" => "Structure-led — amplify the LocusKit bitmap lane so filed structure drives ranking.",
            "temporal" => "Time-led — amplify the temporal-relevance column (matrixAware scoring only).",
            "connection" => "Connection-led — amplify the connection-graph column (matrixAware scoring only).",
            "field" => "Field-led — amplify the co-occurrence column (matrixAware scoring only).",
            "preference" => "Preference-led — amplify the learned-preference column (matrixAware scoring only).",
            "anti_redundant" => "Diversity — suppress BM25/Hamming (-0.5) so lexical near-duplicates cannot dominate, invert FDC to farthest when the dense families are compiled in; narrow frontier to 64.",
            "anti_redundant_ri" => "Diversity (RI space) — invert the RI dense lane to farthest + suppress BM25/Hamming (-0.5); narrow frontier to 64. Targets distributional diversity in the random-indexing semantic space.",
            "anti_redundant_lsa" => "Diversity (LSA space) — invert the LSA dense lane to farthest + suppress BM25/Hamming (-0.5); narrow frontier to 64. Targets distributional diversity in the latent-semantic space.",
            "session_hybrid" => "Session-granularity — hybridRecall scoredLane + bounded temporal-window boost + speaker-aware weighting; amplify bm25 + dense + temporal.",
            "temporal_connection" => "Recent + co-filed — amplify temporal (recency) + coOccurrence (shared filing neighbourhood) together; matrixAware scoring only.",
            "field_preference" => "Filed + preferred — amplify fieldFit (FDC facet match) + preference (learned user preference) together; matrixAware scoring only.",
            "no_locus" => "Ablation — exclude the locus (bitmap recency-rank) column and redistribute its budget; matrixAware scoring only.",
            "no_field_fit" => "Ablation — exclude the fieldFit column and redistribute its budget; matrixAware scoring only.",
            "no_matrix" => "Ablation — exclude the coOccurrence + temporal matrix columns and redistribute their budget; matrixAware scoring only.",
            "no_graph" => "Ablation — exclude the graph column and redistribute its budget; matrixAware scoring only.",
            "no_preference" => "Ablation — exclude the preference column and redistribute its budget; matrixAware scoring only.",
            "no_agreement" => "Ablation — drop the fixed signal-agreement bonus; matrixAware scoring only.",
            "no_bm25" => "Ablation — exclude the BM25 column and redistribute its budget; candidates from the lexical lane still enter the pool; matrixAware scoring only.",
            "no_vector" => "Ablation — exclude the vector column (Hamming + dense) and redistribute its budget; candidates from the excluded lane still enter the pool; matrixAware scoring only. The vector column is already out by default, so this names the default explicitly.",
            "no_encoder" => "Ablation — skip the span rerank stage; the lexical list enters the pool in BM25 order. Fuses identically to no_vector.",
            _ => "",
        }
    }
}

/// A shape that forwards exactly one dense lane and zeroes the other three
/// distributional siblings — the `*_forward` preset body. Mirrors Swift
/// `RecallShape.singleDenseForward`.
fn single_dense_forward(forward_key: &str) -> RecallShape {
    let mut weights = HashMap::new();
    for key in RecallShape::DENSE_SIGNALS {
        weights.insert(
            key.to_string(),
            if key == forward_key { 1.5 } else { 0.0 },
        );
    }
    RecallShape::new(weights, None)
}

// ---------------------------------------------------------------------------
// GLKSubSpanScoring
// ---------------------------------------------------------------------------

/// Whether the unionBest matrixAware pipeline runs the step 5.8 sub-span
/// dense refinement (`CorpusContentEngine::score_sub_spans`) for a request.
///
/// Sub-span scoring is an additive-cost stage: transient sentence-window
/// embeddings for every candidate the `SubSpanBudget` admits, under the
/// coordinator lock. Ruling 2026-09-07: every non-minimum feature is a call
/// parameter with an explicit default chosen by the caller, and
/// additive-cost features default off. `GLKRecallRequest::new` sets `Off`;
/// every internal caller names its choice at the call site, and the switch
/// is not an ARIA argument. Mirrors Swift `GLKSubSpanScoring`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GLKSubSpanScoring {
    /// Step 5.8 does not run: the dense column keeps the dense lane's
    /// whole-record cosine (0 for candidates the dense lane never ranked).
    Off,
    /// Step 5.8 runs when the other conditions hold (matrixAware scoring, a
    /// registered CorpusContentEngine, non-empty query text): the dense
    /// column becomes `max(dense, sub_span_max_cosine)` for every candidate
    /// scored inside the budget.
    On,
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
    /// Door identity for the reward-cycle trace rows (W2.5 Track R(a)):
    /// the tool or recipe that issued this recall (e.g. "memory_search").
    /// Recorded verbatim into `recall_trace.door` for external-origin
    /// requests. None writes a NULL door. No query text is ever stored
    /// (privacy ruling 2026-08-20). Mirrors Swift `GLKRecallRequest.door`.
    pub door: Option<String>,
    /// Composition identity for the reward-cycle trace rows: the caller's
    /// composition name where the caller knows one. When None the
    /// coordinator records "<mode>/<scoring>". Mirrors Swift
    /// `GLKRecallRequest.composition`.
    pub composition: Option<String>,
    /// Optional per-call candidate-pool depth override.
    ///
    /// When non-None this overrides BOTH the coordinator's computed default AND
    /// any `RecallShape.frontier_k` the request carries — the precedence is:
    ///
    ///   request.frontier_k > recall_shape.frontier_k > engine formula
    ///
    /// Clamped to `[RecallShape::FRONTIER_K_FLOOR, RecallShape::FRONTIER_K_CEILING]`
    /// (`[64, 256]`). None falls through to the shape override or the formula
    /// `min(max(limit * 4, 64), 256)`. Mirrors Swift `GLKRecallRequest.frontierK`.
    pub frontier_k: Option<usize>,

    // ── Anomalous-flag admission gate (§11.18, 2026-08-20) ──────────────────

    /// Optional anomalous-flag admission gate (§11.18 anomalous-flag recall
    /// prefilter).
    ///
    /// Applied BEFORE scoring at candidate admission in the coordinator:
    /// - `None`  — no filtering; all candidates admitted (default, back-compat,
    ///   byte-identical to requests without this parameter).
    /// - `Some(true)`  — admit ONLY anomalous drawers (bit 26 set).
    /// - `Some(false)` — EXCLUDE anomalous drawers (bit 26 clear).
    ///
    /// Mirrors Swift `GLKRecallRequest.anomalousFilter`.
    pub anomalous_filter: Option<bool>,

    /// ADR-027 D3: the per-call override of the `chest_recall_diversity`
    /// estate preference. `Some(true)` makes the diversity rerank treat two
    /// candidates in one container as one topic for this call, `Some(false)`
    /// switches that off for this call, `None` (the default) reads the
    /// preference. Set from ARIA's `chest_diversity` global modifier.
    pub chest_diversity: Option<bool>,

    /// Whether the step 5.8 sub-span dense refinement runs for this request.
    ///
    /// `Off` (what `new()` sets) leaves the dense column as the dense lane
    /// produced it. `On` runs `score_sub_spans` on the unionBest matrixAware
    /// pipeline when a corpus is registered and the request carries query
    /// text, and blends `max(dense, sub_span_max_cosine)`. Every internal
    /// caller sets this explicitly. Mirrors Swift
    /// `GLKRecallRequest.subSpanScoring`.
    pub sub_span_scoring: GLKSubSpanScoring,

    /// The cross-encoder portion of the caller's recall strategy decision.
    ///
    /// `None` (what `new()` sets) and `Bypass` leave the final order as fused
    /// and produce byte-identical hits; `None` also leaves
    /// `GLKRecallResult::cross_encoder` None. `Apply` runs the retrieval-time
    /// cross-encoder stage over the head of the authorized final list
    /// (`cross_encoder_stage`) under the estate's manifest limits, or
    /// degrades with a reason when it cannot. The ARIA verb surface does not
    /// carry it yet; internal callers set it explicitly. Mirrors Swift
    /// `GLKRecallRequest.rerankDirective`.
    pub rerank_directive: Option<corpus_kit::encoder::RerankDirective>,
}

impl GLKRecallRequest {
    /// Create a request with all five control parameters required explicitly.
    ///
    /// Every caller names mode, scoring, limit, fallback, and origin at the
    /// call site — the signature enforces completeness at compile time.
    /// Optional fields (query_text, trace_limit, recall_shape) are set via
    /// the retained builders below.
    pub fn new(
        frame: RecallFrame,
        mode: GLKRecallMode,
        scoring: GLKRecallScoring,
        limit: usize,
        fallback: RecallFallbackPolicy,
        origin: RecallOrigin,
    ) -> Self {
        Self {
            frame,
            mode,
            scoring,
            limit,
            fallback,
            query_text: None,
            trace_limit: None,
            origin,
            recall_shape: None,
            door: None,
            composition: None,
            frontier_k: None,
            anomalous_filter: None,
            chest_diversity: None,
            sub_span_scoring: GLKSubSpanScoring::Off,
            rerank_directive: None,
        }
    }

    /// Builder: set the cross-encoder directive. `new()` sets `None`, which
    /// is bypass with no report. Mirrors Swift's defaulted
    /// `rerankDirective:` init parameter.
    pub fn with_rerank_directive(mut self, directive: corpus_kit::encoder::RerankDirective) -> Self {
        self.rerank_directive = Some(directive);
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

    /// Builder: set the signed per-lane fusion steering (6b-modifiers).
    ///
    /// `None`-equivalent (an empty-map shape) leaves fusion uniform; a populated
    /// shape forwards/excludes/suppresses lanes per `RecallShape`.
    pub fn with_recall_shape(mut self, shape: RecallShape) -> Self {
        self.recall_shape = Some(shape);
        self
    }

    /// Builder: set the trace-row door identity (W2.5 Track R(a)).
    /// Mirrors Swift's defaulted `door:` init parameter.
    pub fn with_door(mut self, door: impl Into<String>) -> Self {
        self.door = Some(door.into());
        self
    }

    /// Builder: set the trace-row composition identity (W2.5 Track R(a)).
    /// Mirrors Swift's defaulted `composition:` init parameter.
    pub fn with_composition(mut self, composition: impl Into<String>) -> Self {
        self.composition = Some(composition.into());
        self
    }

    /// Builder: set an optional per-call candidate-pool depth override.
    ///
    /// Takes precedence over `recall_shape.frontier_k` and the coordinator's
    /// computed default `min(max(limit * 4, 64), 256)`. Clamped to
    /// `[RecallShape::FRONTIER_K_FLOOR, RecallShape::FRONTIER_K_CEILING]` at
    /// the coordinator; setting an out-of-range value is not an error — the
    /// value is silently clamped so shapes degrade rather than fail (shape
    /// contract). Mirrors Swift `GLKRecallRequest.frontierK`.
    pub fn with_frontier_k(mut self, frontier_k: usize) -> Self {
        self.frontier_k = Some(frontier_k);
        self
    }

    /// Builder: set the anomalous-flag admission gate (§11.18).
    ///
    /// `true`  = admit ONLY anomalous drawers (bit 26 set).
    /// `false` = EXCLUDE anomalous drawers (bit 26 clear).
    ///
    /// Not calling this builder (the default) leaves `anomalous_filter` as
    /// `None`, which is byte-identical to a request without any filter.
    /// Mirrors Swift `GLKRecallRequest.anomalousFilter`.
    pub fn with_anomalous_filter(mut self, filter: bool) -> Self {
        self.anomalous_filter = Some(filter);
        self
    }

    /// Builder: set the step 5.8 sub-span scoring switch.
    ///
    /// `new()` sets `Off`. Every internal caller calls this builder (or sets
    /// the field in a struct literal) so the choice is visible at the call
    /// site; the ARIA surface does not expose the switch. Mirrors Swift's
    /// defaulted `subSpanScoring:` init parameter.
    pub fn with_sub_span_scoring(mut self, sub_span_scoring: GLKSubSpanScoring) -> Self {
        self.sub_span_scoring = sub_span_scoring;
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
    /// Primary rows excluded only by LocusKit's default-injected sensitivity
    /// ceiling. An explicit sensitivity filter disables that default, so the
    /// value is then zero. Excluded rows never leave LocusKit.
    pub withheld_by_sensitivity: usize,
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

    /// Per-lane 1-based rank of every candidate the active lane(s) surfaced,
    /// keyed by drawer id, then by lane key ("locus", "bm25", "hamming",
    /// "dense" — `RecallTraceItem::LANE_RANK_ORDER`). Rank is the candidate's
    /// position in that lane's final ranked candidate list BEFORE fusion.
    /// Consumed by `recall_scored`'s external-origin trace write (W2.5 Track
    /// R(a)). Mirrors Swift `GLKRecallResult.laneRanks`.
    pub lane_ranks: std::collections::HashMap<String, std::collections::HashMap<String, i64>>,

    /// The query's §8.3 lattice anchor, derived exactly ONCE inside the
    /// recall director during sketch compilation (M4 single-derivation doctrine).
    ///
    /// Mirrors Swift `GLKRecallResult.queryLatticeAnchor`.
    ///
    /// `Some((udc_code, qid))` when the query anchors — `udc_code` is the FDC
    /// code for noun-anchored queries (empty for phrase-anchored queries which
    /// carry a QID but no FDC code); `qid` is the Wikidata QID ("" if none).
    ///
    /// `None` when:
    ///   - The query was empty or unanchorable (no anchor found by `query_anchor`).
    ///   - The lane compiled no sketch (`LocusOnly`).
    ///
    /// Callers — including CognitionKit's PreciseRecall and TemporalRecall —
    /// MUST read the anchor here. Do NOT call `brain::enrichment_stage::query_anchor`
    /// on the same text a second time; the single-derivation doctrine means the
    /// director's result is the authoritative anchor for the whole recall pipeline.
    pub query_lattice_anchor: Option<(String, String)>,

    /// What the cross-encoder stage did for this request
    /// (`cross_encoder_stage`), or `None` when the request carried no
    /// `rerank_directive`. Bypass and degrade are reported here too; a
    /// degraded apply also pushes `recall.cross_encoder_degraded` onto
    /// `degraded_stages`. Mirrors Swift `GLKRecallResult.crossEncoder`.
    pub cross_encoder: Option<crate::cross_encoder_stage::CrossEncoderReport>,

    /// The preference key of the recall route that transformed this request,
    /// or `None` when no route fired. Day one: `"cross_encoder_routing"` when
    /// Route 1 applied its degradable rerank directive; `None` for all other
    /// recalls.
    /// Mirrors Swift `GLKRecallResult.route`.
    pub route: Option<String>,
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

// ── UnionBest step 9.5: the MMR shingle view under a budget ─────────────────

/// Scalars of one body the step 9.5 shingler reads at most. A body longer
/// than the cap is shingled over its first 4,096 scalars: the character-3-gram
/// Jaccard the MMR penalises near-duplicates with is a measure of the
/// opening of the body, which is where a near-duplicate declares itself, and
/// a set of at most 4,094 3-grams bounds every pairwise intersection in
/// step 10. Swift `GeniusLocusKit.unionBestMMRBodyCapScalars` twin.
pub const UNION_BEST_MMR_BODY_CAP_SCALARS: usize = 4_096;

/// Aggregate scalars the step 9.5 shingler reads per query across the whole
/// candidate view. The budget is split evenly: every body is shingled over
/// the same prefix length, `min(cap, budget / bodies)`, so the shingle
/// memory and the step 10 work (picks × the shingled scalars) are a
/// constant of the build, not of the estate. An even split keeps one
/// similarity measure for the whole pool. A body without a set in a pool of
/// bodies with sets would fall to the sourceMask proxy, which reads a
/// same-lane neighbour as an exact duplicate and a cross-lane neighbour as
/// unrelated, and the MMR then drops the lane's real hits for the
/// unrelated-looking ones; a shorter prefix on every body keeps the
/// comparison symmetric. One million scalars is 244 full-cap bodies, or
/// about 600 scalars each across the widest fused pool the lanes can
/// supply (the lexical, locus and fingerprint lanes at the 256 frontier
/// ceiling plus the 4x over-fetched dense lanes). Swift
/// `GeniusLocusKit.unionBestMMRShingleBudgetScalars` twin.
pub const UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS: usize = 1_000_000;

/// The shingle sets of the MMR body view under the budget. `bodies[i]` is the
/// body of slot i (`None` when the slot has none: a body-free tier or a
/// candidate outside the frame-admissible pool). Every non-empty body is
/// shingled over the same prefix, `min(UNION_BEST_MMR_BODY_CAP_SCALARS,
/// UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS / non-empty bodies)` scalars.
/// Returns one set per slot (`None` where the slot has no body or an empty
/// body) and whether the aggregate budget shortened the prefix below the cap
/// for at least one body longer than the prefix (the cap alone shortening a
/// body is the measure, not a truncation). Swift
/// `GeniusLocusKit.unionBestMMRShingles` twin; the two ports build the same
/// sets for the same inputs.
pub fn union_best_mmr_shingles(
    bodies: &[Option<&str>],
) -> (Vec<Option<std::collections::BTreeSet<String>>>, bool) {
    let non_empty = bodies.iter().filter(|b| b.map_or(false, |b| !b.is_empty())).count();
    let prefix = if non_empty == 0 {
        UNION_BEST_MMR_BODY_CAP_SCALARS
    } else {
        UNION_BEST_MMR_BODY_CAP_SCALARS.min(UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS / non_empty)
    };
    let mut sets: Vec<Option<std::collections::BTreeSet<String>>> = vec![None; bodies.len()];
    let mut truncated = false;
    for (i, body) in bodies.iter().enumerate() {
        let Some(body) = body else { continue };
        if body.is_empty() {
            continue;
        }
        // `nth(prefix)` walks at most prefix + 1 scalars, so a long body is
        // never scanned whole.
        let longer_than_prefix = body.chars().nth(prefix).is_some();
        if longer_than_prefix && prefix < UNION_BEST_MMR_BODY_CAP_SCALARS {
            truncated = true;
        }
        let capped: String = if longer_than_prefix {
            body.chars().take(prefix).collect()
        } else {
            (*body).to_string()
        };
        sets[i] = Some(substrate_ml::shingle_similarity::shingles(&capped));
    }
    (sets, truncated)
}
