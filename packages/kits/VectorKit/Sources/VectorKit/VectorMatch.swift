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

    /// Shadow-swap generation tag of the row that produced this match.
    /// Equals the model's serving_generation at query time. Callers can
    /// verify this matches the expected generation after a swap completes.
    public let generation: Int64

    /// Metric-native similarity in [0, 1] when the producing metric is
    /// not Hamming (W2.5 M1: Jaccard). nil for Hamming matches — their
    /// score is derived from `distance` by the caller ((256-d)/256), and
    /// `distance` remains the ordering key in both cases (additive-only
    /// rule: defaulted so existing memberwise callers do not break).
    public let score: Double?

    public init(itemID: String, distance: Int, modelID: String, generation: Int64,
                score: Double? = nil) {
        self.itemID = itemID
        self.distance = distance
        self.modelID = modelID
        self.generation = generation
        self.score = score
    }

    public static func < (lhs: VectorMatch, rhs: VectorMatch) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.itemID < rhs.itemID
    }
}
