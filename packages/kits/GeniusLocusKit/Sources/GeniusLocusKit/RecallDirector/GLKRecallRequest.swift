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
    /// When set, the RecallDirector uses this value for `traceLimit` on the
    /// primary locus frame instead of `limit`. This lets precise-recall paths
    /// (PreciseRecall recipe) decouple the coarse candidate pool (`limit =
    /// poolSize`) from the reward-cycle trace budget (`traceLimit = final limit
    /// returned to the caller`). The pool is the scan width; the trace budget
    /// is what the caller actually receives — writing ~500 trace rows for a
    /// limit-20 precise query inflates the trace table ~25× for no benefit.
    ///
    /// When nil, the trace limit falls back to `request.limit` — but ONLY when
    /// `origin == .external`. Internal requests never set `traceLimit` on the
    /// frame regardless of this field (B-10a).
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
    public init(
        frame: LocusKit.RecallFrame,
        mode: GLKRecallMode,
        scoring: GLKRecallScoring,
        limit: Int,
        fallback: RecallFallbackPolicy,
        queryText: String? = nil,
        traceLimit: Int? = nil,
        origin: RecallOrigin,
        recallShape: RecallShape? = nil
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
    }
}
