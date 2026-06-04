/// What the director does when a lane is unavailable.
public enum RecallFallbackPolicy: String, Sendable, Codable, CaseIterable {
    /// Throw immediately if the requested lane is unavailable.
    case failClosed
    /// Return a degraded result set from an available lane instead of throwing.
    ///
    /// When the requested lane is unavailable (no corpus registered for
    /// `corpusOnly`, no data for `hybrid`), the director falls back to the
    /// nearest available lane — typically `locusOnly` — rather than throwing.
    case allowDegraded
}
