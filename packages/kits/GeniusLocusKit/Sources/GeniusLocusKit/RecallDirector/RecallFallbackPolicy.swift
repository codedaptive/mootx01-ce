/// What the director does when a lane is unavailable.
public enum RecallFallbackPolicy: String, Sendable, Codable, CaseIterable {
    /// Throw immediately if the requested lane is unavailable.
    case failClosed
    /// Return a degraded result set from an available lane instead of throwing.
    ///
    /// When `corpusOnly` is requested but no corpus is registered for the
    /// estate, the director falls back to the nearest available lane —
    /// typically `locusOnly` — rather than throwing. The `hybrid` lane does
    /// not consult this policy: it fuses locus results with empty BM25/vector
    /// lists when corpus data is absent, never treating the missing corpus as
    /// an unavailable lane.
    case allowDegraded
}
