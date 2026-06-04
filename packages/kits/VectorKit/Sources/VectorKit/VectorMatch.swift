import Foundation

/// Result of a `VectorStore.findNearest` call: one matched drawer,
/// the Hamming distance from the probe engram to the stored engram,
/// and the model that produced the stored engram (spec I-4: every
/// vector is tagged with the model that produced it; the same tag
/// is carried back on every match).
///
/// `VectorMatch` conforms to `Comparable` ordered by `distance`
/// ascending — smaller distance is "closer," so a sorted array of
/// matches reads near → far from front to back. Ties on distance
/// have no defined tiebreak at this layer; `VectorStore.findNearest`
/// applies a secondary sort by `drawerID` ascending for deterministic
/// output. The ordering is stable across equivalent corpora but is
/// intentionally not part of the `VectorMatch` contract.
///
/// `Sendable` — `VectorMatch` is a value type composed of value
/// fields and can be returned across actors / from background
/// tasks without isolation concerns.
public struct VectorMatch: Sendable, Comparable, Equatable {
    /// The drawer this match refers to.
    public let drawerID: String

    /// Hamming distance from the probe to the stored engram, in the
    /// inclusive range 0…256. 0 means identical engrams; 256 means
    /// bit-inverses.
    public let distance: Int

    /// Stable model identifier of the embedding that produced the
    /// stored engram (spec I-4). Callers can read this to confirm
    /// they got a match against the model they asked for.
    public let modelID: String

    public init(drawerID: String, distance: Int, modelID: String) {
        self.drawerID = drawerID
        self.distance = distance
        self.modelID = modelID
    }

    public static func < (lhs: VectorMatch, rhs: VectorMatch) -> Bool {
        lhs.distance < rhs.distance
    }
}
