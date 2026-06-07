import Foundation
import LocusKit

/// Errors raised by the GeniusLocusKit unified verb surface.
///
/// Sits alongside `GeniusLocusKitError` (lifecycle and routing) so the
/// verb-layer failure modes are distinguishable from coordinator
/// failures. The two enums never overlap: a coordinator failure that
/// occurs while routing a verb (e.g. handle not in registry) raises
/// `GeniusLocusKitError.estateNotOpen` and is rethrown by the verb
/// boundary unchanged, so callers always see the most specific case.
public enum VerbError: Error, Sendable, CustomStringConvertible {

    /// The verb dispatched through the GLK boundary, reached the
    /// LocusKit estate, and the underlying call failed. The associated
    /// value is the textual description of the underlying error so the
    /// concrete `LocusKitError` taxonomy does not leak across the GLK
    /// boundary.
    case underlyingEstateFailure(verb: String, reason: String)

    /// The verb is part of the nine-verb vocabulary but the underlying
    /// estate does not implement it. All nine verbs — and every `mutate`
    /// kind (`.confirm`, `.reject`, `.contest`, `.resolve`, `.accept`,
    /// `.supersede`, `.revive`, `.correctSensitivity`, `.correctTrust`) —
    /// reach a live Estate today, so no current path raises this. It is
    /// the generic dispatch error reserved for an estate type that omits
    /// a verb: the GLK boundary remaps a LocusKit "not yet implemented"
    /// stub error to this case so callers branch on a single case rather
    /// than pattern-matching on LocusKit's internal error strings.
    case notSupportedByEstate(verb: String)

    /// The combination of verb and noun is rejected by the AriaLexicon
    /// acceptance matrix (architecture spec §7.2). Carried so callers
    /// see the same shape whether the rejection comes from the lexicon
    /// (illegal combination) or from the substrate (legal but
    /// unimplemented). Today only the explicit lexicon conformance
    /// checks raise this case; per-verb runtime checks are out of
    /// scope for this scaffold and arrive with the Brain layer.
    case rejectedByLexicon(verb: String, noun: String)

    /// A `reanchor` frame supplied neither `toRoom` nor `toLattice`.
    /// Raised at the GLK boundary before dispatch so an empty reanchor
    /// does not reach the substrate as a no-op write.
    case emptyReanchor(rowID: RowID)

    /// An `expunge` frame's `confirmation` flag was false. Raised at
    /// the GLK boundary because expunge is destructive and the
    /// confirmation is a deliberate two-step protocol.
    case expungeNotConfirmed(rowID: RowID)

    public var description: String {
        switch self {
        case let .underlyingEstateFailure(verb, reason):
            return "verb '\(verb)' failed in underlying estate: \(reason)"
        case let .notSupportedByEstate(verb):
            return "verb '\(verb)' is not yet supported by the underlying estate"
        case let .rejectedByLexicon(verb, noun):
            return "verb '\(verb)' is not accepted on noun '\(noun)' by the AriaLexicon §7.2 acceptance matrix"
        case let .emptyReanchor(rowID):
            return "reanchor on row '\(rowID)' supplied neither toRoom nor toLattice"
        case let .expungeNotConfirmed(rowID):
            return "expunge on row '\(rowID)' requires confirmation=true"
        }
    }
}
