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
/// The default on `GLKRecallRequest` is `.internal` so that every existing
/// call site is safe unless explicitly overridden to `.external`. The
/// ARIA_MCP boundary is the ONLY place where `.external` is set.
public enum RecallOrigin: Sendable {
    /// Request originates from an external consumer (human or outside AI)
    /// arriving through the ARIA access surface. May write recall-trace rows.
    case external
    /// Request originates from an internal system process. Must NOT write
    /// recall-trace rows. Default for all non-ARIA callers.
    case `internal`
}

/// A fully-specified recall request at the GLK surface.
///
/// `GLKRecallRequest` is the primary entry point for the Recall Director
/// introduced in RECALL-DIRECTOR-001. Callers that do not need explicit
/// mode/scoring control use the legacy shim `recall(_ handle:, _ frame:)`,
/// which routes through this type with `mode: .locusOnly, scoring: .raw`.
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
    /// Defaults to nil for backward compatibility with locusOnly callers.
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
    /// When nil (the default), the trace limit falls back to `request.limit`
    /// — but ONLY when `origin == .external`. Internal requests never set
    /// `traceLimit` on the frame regardless of this field (B-10a).
    public let traceLimit: Int?
    /// Whether this recall originates from an external consumer or an internal
    /// system process.
    ///
    /// B-10a enforcement: the RecallDirector sets `traceLimit` on the
    /// LocusKit `RecallFrame` ONLY when `origin == .external`. Internal reads
    /// (dreaming, standing signals, recipes, migration, etc.) must not write
    /// recall-trace rows. Defaults to `.internal` so every existing call site
    /// is safe unless explicitly overridden. The ARIA_MCP boundary is the
    /// ONLY place that sets `.external`.
    public let origin: RecallOrigin

    /// Create a recall request with explicit lane, scoring, and policy.
    ///
    /// - Parameters:
    ///   - frame: LocusKit filter chain, hydration level, ordering, and limit.
    ///   - mode: Which recall lane to route through. Defaults to `.hybrid`.
    ///   - scoring: Scoring strategy applied after lane recall. Defaults to `.matrixAware`.
    ///   - limit: Maximum hits to return. Defaults to `12`.
    ///   - fallback: Behavior when the requested lane is unavailable. Defaults to `.failClosed`.
    ///   - queryText: Optional free-text query for BM25 and vector lanes. Defaults to `nil`.
    ///   - traceLimit: Override for the reward-cycle trace write budget. Nil defaults to
    ///     `limit`. Set by the PreciseRecall recipe to thread the caller's final limit
    ///     through when the pool (scan width) is larger than what the caller receives.
    ///     Ignored unless `origin == .external` (B-10a).
    ///   - origin: Whether the request originates externally (ARIA boundary) or
    ///     internally (system process). Defaults to `.internal`. Only the ARIA_MCP
    ///     boundary passes `.external` (B-10a enforcement).
    public init(
        frame: LocusKit.RecallFrame,
        mode: GLKRecallMode = .hybrid,
        scoring: GLKRecallScoring = .matrixAware,
        limit: Int = 12,
        fallback: RecallFallbackPolicy = .failClosed,
        queryText: String? = nil,
        traceLimit: Int? = nil,
        origin: RecallOrigin = .internal
    ) {
        self.frame = frame
        self.mode = mode
        self.scoring = scoring
        self.limit = limit
        self.fallback = fallback
        self.queryText = queryText
        self.traceLimit = traceLimit
        self.origin = origin
    }
}
