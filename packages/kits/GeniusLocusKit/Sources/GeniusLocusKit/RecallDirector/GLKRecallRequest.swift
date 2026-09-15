import CorpusKit
import LocusKit

/// Whether a recall request originates from an external consumer or from
/// an internal system process.
///
/// Per B-10a (LOCUSKIT_SPEC.md § B-10a): only external-origin requests
/// may write recall-trace rows. Internal reads — maintenance, dreaming,
/// standing signals, recipes/lenses, migration, and benchmarks — MUST use
/// `.internal` so the reward pipeline learns from experience with users,
/// not from the system's own reflective reads.
///
/// All callers must supply this explicitly. The ARIA_MCP boundary is the
/// ONLY place that passes `.external`.
public enum RecallOrigin: Sendable {
    /// Request originates from an external consumer (human or outside AI)
    /// arriving through the ARIA access surface. May write recall-trace rows.
    case external
    /// Request originates from an internal system process. Must NOT write
    /// recall-trace rows. All non-ARIA callers pass this explicitly.
    case `internal`
}

/// Whether the unionBest matrixAware pipeline runs the step 5.8 sub-span
/// dense refinement (`CorpusContentEngine.scoreSubSpans`) for a request.
///
/// Sub-span scoring is an additive-cost stage: transient sentence-window
/// embeddings for every candidate the `SubSpanBudget` admits, under the
/// coordinator lock. Ruling 2026-09-07: every non-minimum feature is a call
/// parameter with an explicit default chosen by the caller, and
/// additive-cost features default off. The request default is `.off`;
/// every internal caller names its choice at the call site, and the switch
/// is not an ARIA argument. The Rust twin is `recall::GLKSubSpanScoring`.
public enum GLKSubSpanScoring: Sendable, Equatable {
    /// Step 5.8 does not run: the dense column keeps the dense lane's
    /// whole-record cosine (0 for candidates the dense lane never ranked).
    case off
    /// Step 5.8 runs when the other conditions hold (matrixAware scoring, a
    /// registered CorpusContentEngine, non-empty query text): the dense
    /// column becomes `max(dense, subSpanMaxCosine)` for every candidate
    /// scored inside the budget.
    case on
}

/// A fully-specified recall request at the GLK surface.
///
/// `GLKRecallRequest` is the primary entry point for the Recall Director
/// introduced in RECALL-DIRECTOR-001. All five behavioural parameters
/// (`mode`, `scoring`, `limit`, `fallback`, `origin`) are required — every
/// caller names its lane explicitly. The legacy shim `recall(_ handle:, _ frame:)`
/// routes through this type with `mode: .locusOnly, scoring: .raw,
/// fallback: .failClosed, origin: .internal` stated explicitly at the call site.
public struct GLKRecallRequest: Sendable {
    /// The LocusKit filter chain, hydration level, ordering, and limit.
    public let frame: LocusKit.RecallFrame
    /// Which recall lane to use.
    public let mode: GLKRecallMode
    /// Scoring strategy to apply after lane recall.
    public let scoring: GLKRecallScoring
    /// Maximum number of hits to return.
    public let limit: Int
    /// What to do if the requested lane is unavailable.
    public let fallback: RecallFallbackPolicy
    /// Optional free-text query for the BM25 and vector lanes.
    ///
    /// When non-nil, the BM25 lane tokenises this text and scores against the
    /// registered corpus; the vector lane embeds it to find Hamming-nearest
    /// engrams. When nil, both lanes return empty candidate sets and the result
    /// falls back to the locus lane (for hybrid) or empty (for corpusOnly).
    public let queryText: String?
    /// How many rows to record as recall-trace rows in the reward cycle.
    ///
    /// When set, the RecallDirector's central trace writer caps the write to
    /// this many of the result's leading hits instead of `limit`. This lets
    /// pool-fetching callers decouple the coarse candidate pool (`limit =
    /// poolSize`) from the reward-cycle trace budget (`traceLimit = final limit
    /// returned to the caller`). The pool is the scan width; the trace budget
    /// is what the caller actually receives — writing ~500 trace rows for a
    /// limit-20 query inflates the trace table ~25× for no benefit.
    ///
    /// When nil, the trace budget falls back to `request.limit` — but ONLY
    /// when `origin == .external`. Internal requests write zero trace rows
    /// regardless of this field (B-10a).
    public let traceLimit: Int?
    /// Whether this recall originates from an external consumer or an internal
    /// system process.
    ///
    /// B-10a enforcement: the RecallDirector sets `traceLimit` on the
    /// LocusKit `RecallFrame` ONLY when `origin == .external`. Internal reads
    /// (dreaming, standing signals, recipes, migration, etc.) must not write
    /// recall-trace rows. The ARIA_MCP boundary is the ONLY place that passes
    /// `.external`; all other callers pass `.internal` explicitly.
    public let origin: RecallOrigin
    /// Optional SIGNED per-lane steering for the RRF fusion (6b-modifiers).
    ///
    /// When non-nil, the RecallDirector multiplies each fusion lane's
    /// reciprocal-rank mass by that lane's signed weight from the shape before the
    /// per-id sum: `w > 0` forwards, `w == 0` excludes, `w < 0` suppresses
    /// (demotes the lane's high-ranked candidates). It may also override the
    /// candidate-pool depth (`frontierK`). See `RecallShape` for the lane-key
    /// scheme and the exact signed-weight semantics.
    ///
    /// When nil (the default), fusion uses uniform positive weights — every lane
    /// at weight `1.0` — which is BYTE-IDENTICAL to the pre-6b-modifiers behaviour.
    /// This is the back-compat contract: an absent shape changes nothing.
    public let recallShape: RecallShape?

    /// Door identity for the reward-cycle trace rows (W2.5 Track R(a)):
    /// the tool or recipe that issued this recall (e.g. "memory_search",
    /// "recall_precise"). Recorded verbatim into `recall_trace.door` for
    /// external-origin requests. `nil` (the default) writes a NULL door —
    /// honest for callers with no door identity. Never derived from the
    /// query; no query text is ever stored (privacy ruling 2026-08-20).
    public let door: String?

    /// Composition identity for the reward-cycle trace rows: the caller's
    /// composition name where the caller knows one (a reduction
    /// composition such as "text", a shaped preset name). When nil the
    /// director records "<mode>/<scoring>" so every attributed trace row
    /// carries at least the lane-composition identity.
    public let composition: String?

    /// Optional per-call candidate-pool depth override.
    ///
    /// When non-nil this overrides BOTH the engine's computed default AND
    /// any `RecallShape.frontierK` the request carries — the precedence is:
    ///
    ///   request.frontierK > recallShape.frontierK > engine formula
    ///
    /// The value is clamped to `[RecallShape.frontierKFloor, RecallShape.frontierKCeiling]`
    /// (`[64, 256]`) so a call site cannot request an unbounded scan. A nil value
    /// falls through to the shape override (if any) or the engine's computed
    /// default `min(max(limit * 4, 64), 256)`.
    ///
    /// Use this to set the pool depth per-call without constructing a full
    /// `RecallShape` — for example, when a recipe drives the pool size from a
    /// runtime parameter but does not need to steer the lane weights.
    public let frontierK: Int?

    /// Optional anomalous-flag admission gate (§11.18 anomalous-flag recall
    /// prefilter).
    ///
    /// Applied BEFORE scoring at candidate admission in `RecallDirector`:
    /// - `nil`   — no filtering; all candidates admitted (default, back-compat).
    /// - `true`  — admit ONLY anomalous drawers (bit 26 set). Surfaces
    ///   low-cohesion outliers for review or triage workflows.
    /// - `false` — EXCLUDE anomalous drawers (bit 26 clear). Returns only
    ///   cohesive, room-typical candidates.
    ///
    /// The filter reads `DrawerHit.drawer.isAnomalous` (bit 26 of
    /// `operationalBitmap`), which is populated by GeniusLocusKit's
    /// room-cohesion maintenance sweep. Drawers in rooms with fewer than 3
    /// members always have bit 26 clear (the sweep skips small rooms).
    ///
    /// A `nil` value produces byte-identical results to requests without
    /// this parameter — no performance cost when unused.
    public let anomalousFilter: Bool?

    /// Whether the step 5.8 sub-span dense refinement runs for this request.
    ///
    /// `.off` (the request default) leaves the dense column as the dense lane
    /// produced it. `.on` runs `CorpusContentEngine.scoreSubSpans` on the
    /// unionBest matrixAware pipeline when a corpus is registered and the
    /// request carries query text, and blends `max(dense, subSpanMaxCosine)`.
    /// Every internal caller sets this explicitly; see `GLKSubSpanScoring`.
    public let subSpanScoring: GLKSubSpanScoring

    /// The cross-encoder portion of the caller's recall strategy decision.
    ///
    /// `nil` (the default) and `.bypass` leave the final order as fused and
    /// produce byte-identical hits; `nil` also leaves
    /// `GLKRecallResult.crossEncoder` nil. `.apply` runs the retrieval-time
    /// cross-encoder stage over the head of the authorized final list
    /// (`CrossEncoderStage`) under the estate's manifest limits, or degrades
    /// with a reason when it cannot. The ARIA verb surface does not carry it
    /// yet; internal callers pass it explicitly.
    public let rerankDirective: RerankDirective?

    /// Create a recall request with explicit lane, scoring, and policy.
    ///
    /// All five behavioural parameters are required — there are no defaults.
    /// Omitting any of the first five arguments is a compile error, which is
    /// the enforcement mechanism: every caller must name its lane, scoring,
    /// limit, fallback, and origin.
    ///
    /// - Parameters:
    ///   - frame: LocusKit filter chain, hydration level, ordering, and limit.
    ///   - mode: Which recall lane to route through.
    ///   - scoring: Scoring strategy applied after lane recall.
    ///   - limit: Maximum hits to return.
    ///   - fallback: Behavior when the requested lane is unavailable.
    ///   - queryText: Optional free-text query for BM25 and vector lanes. Nil means
    ///     BM25 and vector lanes return empty candidate sets.
    ///   - traceLimit: Override for the reward-cycle trace write budget. When nil the
    ///     trace limit falls back to `limit`, but only when `origin == .external`
    ///     (B-10a). Set by the PreciseRecall recipe to decouple the coarse pool from
    ///     the reward-cycle write budget.
    ///   - origin: Whether the request originates externally (ARIA boundary) or
    ///     internally (system process). Only the ARIA_MCP boundary passes `.external`
    ///     (B-10a enforcement); all other callers pass `.internal`.
    ///   - recallShape: Optional signed per-lane fusion steering. Nil means uniform
    ///     positive weights — byte-identical to pre-6b-modifiers behaviour. See
    ///     `RecallShape` for the signed-weight semantics and lane-key scheme.
    ///   - door: Trace-row door identity (tool/recipe name) for external-origin
    ///     requests; nil writes a NULL door. W2.5 Track R(a).
    ///   - composition: Trace-row composition identity where the caller knows
    ///     one; nil lets the director record "<mode>/<scoring>".
    ///   - frontierK: Optional per-call candidate-pool depth override, clamped
    ///     to `[RecallShape.frontierKFloor, RecallShape.frontierKCeiling]`.
    ///     Takes precedence over `recallShape.frontierK` and the engine default.
    ///     Nil (the default) defers to the shape override or the engine formula.
    ///   - anomalousFilter: Optional anomalous-flag admission gate (§11.18).
    ///     `nil` = no filter (byte-identical to omitting the parameter); `true` =
    ///     anomalous only; `false` = exclude anomalous. Applied BEFORE scoring.
    ///   - subSpanScoring: Whether step 5.8 sub-span dense refinement runs.
    ///     `.off` (the default) skips the step; `.on` runs it on the unionBest
    ///     matrixAware pipeline when a corpus is registered and query text is
    ///     present. Internal callers state the value; the ARIA surface does not
    ///     expose it.
    ///   - rerankDirective: The cross-encoder directive. `nil` (the default)
    ///     is bypass with no report; `.apply` runs the stage.
    public init(
        frame: LocusKit.RecallFrame,
        mode: GLKRecallMode,
        scoring: GLKRecallScoring,
        limit: Int,
        fallback: RecallFallbackPolicy,
        queryText: String? = nil,
        traceLimit: Int? = nil,
        origin: RecallOrigin,
        recallShape: RecallShape? = nil,
        door: String? = nil,
        composition: String? = nil,
        frontierK: Int? = nil,
        anomalousFilter: Bool? = nil,
        subSpanScoring: GLKSubSpanScoring = .off,
        rerankDirective: RerankDirective? = nil
    ) {
        self.frame = frame
        self.mode = mode
        self.scoring = scoring
        self.limit = limit
        self.fallback = fallback
        self.queryText = queryText
        self.traceLimit = traceLimit
        self.origin = origin
        self.recallShape = recallShape
        self.door = door
        self.composition = composition
        self.frontierK = frontierK
        self.anomalousFilter = anomalousFilter
        self.subSpanScoring = subSpanScoring
        self.rerankDirective = rerankDirective
    }

    /// This request with `limit` replaced and every other field kept. The
    /// director uses it to widen the lanes' presentation cut to the
    /// cross-encoder pool; the caller's own limit is re-applied after the
    /// stage.
    func replacing(limit: Int) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: frame, mode: mode, scoring: scoring, limit: limit, fallback: fallback,
            queryText: queryText, traceLimit: traceLimit, origin: origin,
            recallShape: recallShape, door: door, composition: composition,
            frontierK: frontierK, anomalousFilter: anomalousFilter,
            subSpanScoring: subSpanScoring, rerankDirective: rerankDirective)
    }

    /// This request with `rerankDirective` replaced and every other field kept.
    /// The recall router uses it to apply a route's transform without altering
    /// any other caller-specified parameter.
    func replacing(rerankDirective: RerankDirective?) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: frame, mode: mode, scoring: scoring, limit: limit, fallback: fallback,
            queryText: queryText, traceLimit: traceLimit, origin: origin,
            recallShape: recallShape, door: door, composition: composition,
            frontierK: frontierK, anomalousFilter: anomalousFilter,
            subSpanScoring: subSpanScoring, rerankDirective: rerankDirective)
    }
}
