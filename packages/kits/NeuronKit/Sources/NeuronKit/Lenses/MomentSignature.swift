import EngramLib
import SubstrateML
import SubstrateTypes

// MomentSignature lens — shapes a time window of fingerprinted rows into
// a single OR-reduced signature and ranks a candidate set by Hamming
// proximity (SPEC § 8.2, Lens 1 Topics+Time).
//
// Delegates entirely to MomentSummary.orReduce (OR-reduction over Fingerprint256)
// and EngramLib.distance (Hamming distance). Owns no math (I-17).
// Pure, stateless, no estate access (I-18). Total over edge inputs (B-8, C-16).

/// One candidate ranked against the window signature.
public struct WindowRank: Sendable, Equatable {
    /// Candidate fingerprint being ranked.
    public let candidate: Fingerprint256
    /// Hamming distance from the window signature; 0 = identical, 256 = fully inverted.
    public let hammingDistance: Int

    public init(candidate: Fingerprint256, hammingDistance: Int) {
        self.candidate = candidate
        self.hammingDistance = hammingDistance
    }
}

/// OR-reduced window signature together with the ranked candidate set.
public struct MomentSignatureResult: Sendable, Equatable {
    /// OR-reduced fingerprint over the input window rows.
    public let signature: Fingerprint256
    /// Candidates sorted ascending by Hamming distance to `signature` (nearest first).
    public let ranking: [WindowRank]

    public init(signature: Fingerprint256, ranking: [WindowRank]) {
        self.signature = signature
        self.ranking = ranking
    }
}

extension NeuronKit {
    /// Shapes a time window of fingerprinted rows into an OR-reduced signature
    /// and ranks a candidate set by Hamming proximity, nearest first.
    ///
    /// - Parameters:
    ///   - fingerprints: Lightweight rows from the window, each carrying a
    ///     `Fingerprint256` and its capture timestamp. Supply in any order.
    ///   - candidates: Fingerprints to rank against the window signature.
    /// - Returns: `MomentSignatureResult` with the OR-reduced window signature
    ///   and candidates sorted nearest-first. Empty `fingerprints` or empty
    ///   `candidates` yields a zero signature and empty ranking (B-8).
    public static func momentSignature(
        fingerprints: [RowLite],
        candidates: [Fingerprint256]
    ) -> MomentSignatureResult {
        guard !fingerprints.isEmpty, !candidates.isEmpty else {
            return MomentSignatureResult(signature: .zero, ranking: [])
        }
        let sig = MomentSummary.orReduce(fingerprints.map(\.fingerprint))
        let ranked = candidates
            .map { WindowRank(candidate: $0, hammingDistance: EngramLib.distance(sig, $0)) }
            .sorted { $0.hammingDistance < $1.hammingDistance }
        return MomentSignatureResult(signature: sig, ranking: ranked)
    }
}
