import Foundation

/// Result of a `VectorStore.findNearest` call: one matched item,
/// the Hamming distance from the probe engram to the stored engram,
/// and the model that produced the stored engram (spec I-4: every
/// vector is tagged with the model that produced it; the same tag
/// is carried back on every match).
///
/// Lane F rename: `drawerID` → `itemID` (mirrors the `drawer_id` →
/// `item_id` column rename in the vectors table schema, arch spec §4.1).
///
/// `VectorMatch` conforms to `Comparable` ordered by `distance`
/// ascending — smaller distance is "closer," so a sorted array of
/// matches reads near → far from front to back. Ties on distance
/// use `itemID` ascending for deterministic output (universal tie-break
/// rule, retrieval algorithms reference §0.3).
///
/// `Sendable` — value type, safe across actor boundaries.
public struct VectorMatch: Sendable, Comparable, Equatable {
    /// The item this match refers to (drawer UUID or chunk UUID string).
    ///
    /// Previously named `drawerID`; renamed to `itemID` to match the
    /// `item_id` column rename. CorpusKit callers that use
    /// `VectorMatch.drawerID` must update to `VectorMatch.itemID`.
    public let itemID: String

    /// Hamming distance from the probe to the stored engram, in the
    /// inclusive range 0…256. 0 means identical engrams; 256 means
    /// bit-inverses.
    public let distance: Int

    /// Stable model identifier of the embedding that produced the
    /// stored engram (spec I-4). Callers can read this to confirm
    /// they got a match against the model they asked for.
    public let modelID: String

    public init(itemID: String, distance: Int, modelID: String) {
        self.itemID = itemID
        self.distance = distance
        self.modelID = modelID
    }

    public static func < (lhs: VectorMatch, rhs: VectorMatch) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.itemID < rhs.itemID
    }
}
