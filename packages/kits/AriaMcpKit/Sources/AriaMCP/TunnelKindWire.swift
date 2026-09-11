import LocusKit

/// Explicit ARIA v2 wire-string vocabulary for `TunnelKind`.
///
/// The ten strings are a fixed contract: callers that decode ARIA v2 tunnel
/// responses depend on them not changing between releases.  An exhaustive
/// switch with no `default` or `@unknown default` arm enforces this: adding
/// an eleventh case to `TunnelKind` is a compile error here rather than a
/// silently-accepted new wire value from `String(describing:)`.
///
/// Wire values (must not change):
///   supersedes · references · blocks · validates · contradicts
///   derivesFrom · covers · elaborates · respondsTo · parent
extension TunnelKind {
    /// The ARIA v2 wire string for this relationship kind.
    var wireString: String {
        switch self {
        case .supersedes:  return "supersedes"
        case .references:  return "references"
        case .blocks:      return "blocks"
        case .validates:   return "validates"
        case .contradicts: return "contradicts"
        case .derivesFrom: return "derivesFrom"
        case .covers:      return "covers"
        case .elaborates:  return "elaborates"
        case .respondsTo:  return "respondsTo"
        case .parent:      return "parent"
        }
    }
}
