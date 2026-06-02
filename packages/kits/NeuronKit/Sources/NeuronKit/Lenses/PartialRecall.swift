import Foundation
import SubstrateML
import SubstrateTypes

// Partial-cue recall — per-block fingerprint matching (SPEC § 7.6,
// Lens 7 Associative): the NeuronKit reasoning surface over
// SubstrateML's `PartialStateRecall`. The 256-bit drawer fingerprint is
// FOUR independent 64-bit similarity blocks — structure (0),
// concept/lattice (1), lineage-temporal (2), channel/source (3).
// Querying one block instead of the whole fingerprint gives "memories
// that FEEL structurally like this" vs "memories ABOUT this concept" vs
// "memories FROM this period" — three different recalls from one cue.
// The match/differ split scores "similar in X, different in Y."
// Surfaces the gated block-Hamming math; owns no math (I-17). Pure and
// total (I-18, B-8). CognitionKit sequences it (compute the
// fingerprints, pick blocks).

/// One of the four 64-bit fingerprint families (cookbook § 2.x
/// fingerprint layout). The raw value is the block index.
public enum FingerprintBlock: Int, Sendable, Equatable, Codable, CaseIterable {
    case structure = 0
    case concept = 1
    case temporal = 2
    case channel = 3
}

/// One partial-cue match: the row and its match/differ score.
public struct PartialMatch: Sendable, Equatable, Codable {
    public let rowID: UUID
    public let score: Double
    public init(rowID: UUID, score: Double) {
        self.rowID = rowID
        self.score = score
    }
}

extension NeuronKit {
    /// Top-`k` rows by partial-match score: high similarity to `anchor`
    /// over `matchBlocks` AND high difference over `differBlocks`
    /// ("feels like X in these facets, but unlike it in those"). Thin
    /// surface over SubstrateML's `PartialStateRecall.topK`. The caller
    /// excludes the anchor row if present.
    public static func partialRecall(
        anchor: Fingerprint256,
        rows: [(rowID: UUID, fingerprint: Fingerprint256)],
        matchBlocks: Set<FingerprintBlock>,
        differBlocks: Set<FingerprintBlock>,
        k: Int
    ) -> [PartialMatch] {
        let ranked = PartialStateRecall.topK(
            anchor: anchor,
            rows: rows.map { (rowId: $0.rowID, fingerprint: $0.fingerprint) },
            matchBlocks: Set(matchBlocks.map(\.rawValue)),
            differBlocks: Set(differBlocks.map(\.rawValue)),
            k: k)
        return ranked.map { PartialMatch(rowID: $0.rowId, score: $0.score) }
    }
}
