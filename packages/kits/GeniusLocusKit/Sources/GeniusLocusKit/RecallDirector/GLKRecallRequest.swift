import LocusKit

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

    /// Create a recall request with explicit lane, scoring, and policy.
    ///
    /// - Parameters:
    ///   - frame: LocusKit filter chain, hydration level, ordering, and limit.
    ///   - mode: Which recall lane to route through. Defaults to `.hybrid`.
    ///   - scoring: Scoring strategy applied after lane recall. Defaults to `.matrixAware`.
    ///   - limit: Maximum hits to return. Defaults to `12`.
    ///   - fallback: Behavior when the requested lane is unavailable. Defaults to `.failClosed`.
    ///   - queryText: Optional free-text query for BM25 and vector lanes. Defaults to `nil`.
    public init(
        frame: LocusKit.RecallFrame,
        mode: GLKRecallMode = .hybrid,
        scoring: GLKRecallScoring = .matrixAware,
        limit: Int = 12,
        fallback: RecallFallbackPolicy = .failClosed,
        queryText: String? = nil
    ) {
        self.frame = frame
        self.mode = mode
        self.scoring = scoring
        self.limit = limit
        self.fallback = fallback
        self.queryText = queryText
    }
}
