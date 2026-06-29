import SubstrateML

// Complexity lens — Shannon entropy and mutual information over topic-count
// distributions (SPEC § 8.2, Lens 4 Topics).
//
// Input is raw count distributions; the lens normalises them into probability
// distributions (input shaping per I-17 "owns no math") before delegating to
// InformationTheory.entropy and InformationTheory.mutualInformation.
// InformationTheory requires normalised distributions; the lens supplies them.
// Pure, stateless, no estate access (I-18, B-5). Total over edge inputs (B-8, C-16).

/// Shannon entropy and mutual information over topic-count distributions.
public struct ComplexityResult: Sendable, Equatable {
    /// Shannon entropy of distribution A in bits.
    public let entropyA: Float32
    /// Shannon entropy of distribution B in bits; nil when `countsB` is not provided.
    public let entropyB: Float32?
    /// Mutual information between A and B in bits; nil when `joint` is not provided.
    public let mutualInformation: Float32?

    public init(entropyA: Float32, entropyB: Float32?, mutualInformation: Float32?) {
        self.entropyA = entropyA
        self.entropyB = entropyB
        self.mutualInformation = mutualInformation
    }
}

extension NeuronKit {
    /// Computes Shannon entropy and (optionally) mutual information over topic-count
    /// distributions.
    ///
    /// - Parameters:
    ///   - countsA: Raw observation counts for distribution A.
    ///   - countsB: Optional raw counts for distribution B.
    ///   - joint: Optional joint count matrix for mutual information; rows index A,
    ///     columns index B.
    /// - Returns: `ComplexityResult` containing `entropyA`, `entropyB` (when
    ///   `countsB` is provided), and `mutualInformation` (when `joint` is provided).
    ///   All-zero or empty input yields entropy 0.0 and nil for omitted arguments (B-8).
    public static func complexity(
        countsA: [Float32],
        countsB: [Float32]? = nil,
        joint: [[Float32]]? = nil
    ) -> ComplexityResult {
        let normA = normalise(countsA)
        let eA = InformationTheory.entropy(normA)

        let eB: Float32? = countsB.map { InformationTheory.entropy(normalise($0)) }

        let mi: Float32?
        if let j = joint {
            // Guard: reject empty, ragged, or zero-column joint matrices. (NK-10 planned hardening)
            // A ragged matrix (rows with different column counts) would cause
            // undefined MI computation — stride-slicing misaligns rows and
            // InformationTheory.mutualInformation receives inconsistent input.
            // An empty or zero-column matrix carries no joint information.
            // Returning nil for invalid input follows the B-8 "all-zero → nil"
            // convention and prevents a silent wrong-answer path.
            // Mirrors Rust complexity() square-matrix guard.
            let cols = j.first?.count ?? 0
            if j.isEmpty || cols == 0 || !j.allSatisfy({ $0.count == cols }) {
                mi = nil
            } else {
                // Normalise the joint matrix as a flat probability distribution,
                // then reshape into the [[Float32]] form InformationTheory expects.
                let flat = j.flatMap { $0 }
                let total = flat.reduce(0.0, +)
                let normJ: [[Float32]]
                if total > 0 {
                    let normFlat = flat.map { $0 / total }
                    normJ = stride(from: 0, to: normFlat.count, by: cols)
                        .map { Array(normFlat[$0..<min($0 + cols, normFlat.count)]) }
                } else {
                    normJ = j.map { $0.map { _ in Float32(0) } }
                }
                mi = InformationTheory.mutualInformation(joint: normJ)
            }
        } else {
            mi = nil
        }

        return ComplexityResult(entropyA: eA, entropyB: eB, mutualInformation: mi)
    }

    // Normalises a raw count array to a probability distribution.
    // Returns all-zeros when the sum is zero (B-8: InformationTheory.entropy
    // treats a zero distribution as zero bits, which is correct — an empty
    // or all-zero count distribution carries no information).
    private static func normalise(_ counts: [Float32]) -> [Float32] {
        let total = counts.reduce(0.0, +)
        guard total > 0 else { return counts }
        return counts.map { $0 / total }
    }
}
