import Foundation

/// Diagnostic statistics computed over a `RecallCandidateBuffer` after the
/// multi-lane union pass completes.
///
/// The profile describes how concentrated vs. dispersed each signal column
/// is (sharpness), how consistently candidates were confirmed by multiple
/// lanes (signalAgreement), how redundant the top candidates are
/// (redundancy), and a reserved field for the future matrix coherence
/// signal (matrixCoherence).
///
/// Used by `RecallWeights.adaptive` to tune per-lane weights toward the
/// signals that are most informative for the current query.
public struct RecallUnionProfile: Sendable {
    /// Standard deviation of the locus score column across candidates.
    /// High sharpness means the locus lane is confidently discriminating.
    public let locusSharpness: Float
    /// Standard deviation of the BM25 score column across candidates.
    public let bm25Sharpness: Float
    /// Standard deviation of the vector score column across candidates.
    public let vectorSharpness: Float
    /// Mean of (popcount(sourceMask[i]) / primarySourceCount) across all
    /// candidates, where primarySourceCount is the number of lanes that
    /// contributed at least one hit. Values near 1.0 mean most candidates
    /// were confirmed by every active lane; near 0.0 means each lane
    /// found disjoint sets.
    public let signalAgreement: Float
    /// Mean pairwise shingle similarity over the top-16 candidates (by
    /// final score). Values > 0.5 indicate the buffer is dominated by
    /// near-duplicate content; the diversity weight should be raised.
    public let redundancy: Float
    /// Mean co-occurrence score over the top-16 candidates by final score.
    ///
    /// Non-zero only when a MatrixTier is registered for the estate and the
    /// matrix scoring pass has populated `buffer.coOccurrence`. Values near
    /// 1.0 indicate the top candidates share strong co-occurrence priors with
    /// the reference candidate (query point), suggesting a tight semantic
    /// cluster. Values near 0.0 indicate no matrix priors are present or the
    /// top candidates are drawn from unrelated co-occurrence neighborhoods.
    public let matrixCoherence: Float
}

// MARK: - Internal factory

extension RecallUnionProfile {
    /// Compute a `RecallUnionProfile` from a populated `RecallCandidateBuffer`.
    ///
    /// Called immediately after `normalizeFinals()` so all score columns are
    /// in [0, 1]. Returns a zero-initialized profile if the buffer is empty.
    ///
    /// - Parameters:
    ///   - buffer:             The populated, normalized candidate buffer.
    ///   - primarySourceCount: The number of lanes that contributed at least
    ///                         one hit (used to normalize sourceMask popcounts).
    static func compute(
        from buffer: RecallCandidateBuffer,
        primarySourceCount: Int
    ) -> RecallUnionProfile {
        guard buffer.count > 0 else {
            return RecallUnionProfile(
                locusSharpness: 0,
                bm25Sharpness: 0,
                vectorSharpness: 0,
                signalAgreement: 0,
                redundancy: 0,
                matrixCoherence: 0
            )
        }

        let n = buffer.count
        let divisor = Float(max(primarySourceCount, 1))

        // Sharpness: population standard deviation of each score column.
        let locusSharpness   = stdDev(buffer.locus,  count: n)
        let bm25Sharpness    = stdDev(buffer.bm25,   count: n)
        let vectorSharpness  = stdDev(buffer.vector, count: n)

        // Signal agreement: mean of popcount(sourceMask[i]) / primarySourceCount.
        var agreementSum: Float = 0
        for i in 0..<n {
            agreementSum += Float(buffer.sourceMask[i].nonzeroBitCount) / divisor
        }
        let signalAgreement = agreementSum / Float(n)

        // Redundancy: mean pairwise shingle similarity over top-16 by final score.
        let top16Count = min(16, n)
        // Gather (index, finalScore) and sort descending to get top-16.
        var indexed = (0..<n).map { (idx: $0, score: buffer.final[$0]) }
        indexed.sort { $0.score > $1.score }
        let topIndices = indexed.prefix(top16Count).map(\.idx)

        var pairSum: Float = 0
        var pairCount = 0
        for a in 0..<topIndices.count {
            for b in (a + 1)..<topIndices.count {
                let ia = topIndices[a]
                let ib = topIndices[b]
                // Use sourceMask Jaccard as the pre-hydration similarity proxy.
                // Post-hydration shingle similarity can replace this in a future mission.
                let andBits = buffer.sourceMask[ia] & buffer.sourceMask[ib]
                let orBits  = buffer.sourceMask[ia] | buffer.sourceMask[ib]
                let jaccard: Float = orBits == 0 ? 0 : Float(andBits.nonzeroBitCount) / Float(orBits.nonzeroBitCount)
                pairSum += jaccard
                pairCount += 1
            }
        }
        let redundancy: Float = pairCount > 0 ? pairSum / Float(pairCount) : 0

        // matrixCoherence: mean coOccurrence score over top-16 candidates by
        // final score. Non-zero only when the matrix scoring pass (RecallDirector
        // step 5.6) has populated buffer.coOccurrence before normalizeFinals().
        var coSumTop16: Float = 0
        for idx in topIndices { coSumTop16 += buffer.coOccurrence[idx] }
        let matrixCoherence: Float = top16Count > 0 ? coSumTop16 / Float(top16Count) : 0

        return RecallUnionProfile(
            locusSharpness: locusSharpness,
            bm25Sharpness: bm25Sharpness,
            vectorSharpness: vectorSharpness,
            signalAgreement: signalAgreement,
            redundancy: redundancy,
            matrixCoherence: matrixCoherence
        )
    }

    /// Population standard deviation of the first `count` elements of `col`.
    private static func stdDev(_ col: [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += col[i] }
        let mean = sum / Float(count)
        var variance: Float = 0
        for i in 0..<count {
            let d = col[i] - mean
            variance += d * d
        }
        return (variance / Float(count)).squareRoot()
    }
}
