import LocusKit
import SubstrateTypes

/// Computes per-candidate matrix scores from the estate's MatrixTier.
///
/// Implements sparse F/C/O/T scoring per spec §14. All methods perform
/// keyed lookups into pre-built sparse dictionaries — never a full-matrix
/// scan. The caller (RecallDirector.recallUnionBest) drives the scorer
/// over the candidate buffer after buffer population and before the MMR
/// pass, so matrix signals influence the greedy selection order.
///
/// Key type correspondence (mission spec label → actual MatrixTier property):
///   F (field presence)  → MatrixTier.fieldPresence: [MatrixFieldCell: Int64]
///   C (correlation)     → MatrixTier.correlation(for:) = F[cell] / liveRowCount
///   O (co-occurrence)   → MatrixTier.coOccurrence: [MatrixCoOccurKey: Int64]
///   T (temporal)        → MatrixTier.temporalCausality: [MatrixTemporalKey: Int64]
struct RecallMatrixScorer {

    // MARK: - fieldFit

    /// F-based field-presence score for a candidate's query coordinates.
    ///
    /// For each query coord with a `.bitmap` value, decomposes the bitmap
    /// into its set bits and sums the correlation C[field, bit] =
    /// F[field, bit] / liveRowCount for each set bit. This is a sparse
    /// keyed lookup per bit — never a full-matrix scan.
    ///
    /// Returns 0.0 when queryCoords is empty, all coords carry non-bitmap
    /// values, or the estate has no live rows.
    ///
    /// - Parameters:
    ///   - queryCoords: MatrixValueCoords representing the reference
    ///                  candidate's field-value pairs (bitmap fields only).
    ///   - matrix:      The in-memory MatrixTier for this estate.
    func fieldFit(queryCoords: [MatrixValueCoord], matrix: MatrixTier) -> Float {
        guard matrix.liveRowCount > 0, !queryCoords.isEmpty else { return 0 }
        var sum: Double = 0
        for coord in queryCoords {
            // Only bitmap coords contribute to F; non-bitmap coords feed O/T only.
            guard case .bitmap(let bitmap) = coord.value, bitmap != 0 else { continue }
            // Walk set bits via trailing-zero-count; mirrors MatrixTier.applyCapture
            // and avoids the 0..<64 scan for sparse bitmaps.
            var b = bitmap
            while b != 0 {
                let bitPos = b.trailingZeroBitCount
                let cell = MatrixFieldCell(fieldPath: coord.fieldPath, bitPosition: bitPos)
                sum += matrix.correlation(for: cell)
                b &= b &- 1
            }
        }
        return Float(sum)
    }

    // MARK: - coOccurrence

    /// O-matrix co-occurrence score between query and candidate coordinates.
    ///
    /// For each (queryCoord, candidateCoord) pair, looks up
    /// O[MatrixCoOccurKey(queryCoord, candidateCoord)]. Missing key pairs
    /// return 0 — sparse storage means only seen co-occurrences are stored.
    /// The raw count sum is normalized by liveRowCount.
    ///
    /// Access count is bounded by |queryCoords| × |candidateCoords| —
    /// never a full-matrix scan.
    ///
    /// Returns 0.0 when either coord set is empty or the estate has no live rows.
    ///
    /// - Parameters:
    ///   - queryCoords:     Coords of the reference candidate (query point).
    ///   - candidateCoords: Coords of the candidate being scored.
    ///   - matrix:          The in-memory MatrixTier for this estate.
    func coOccurrence(queryCoords: [MatrixValueCoord],
                      candidateCoords: [MatrixValueCoord],
                      matrix: MatrixTier) -> Float {
        guard matrix.liveRowCount > 0,
              !queryCoords.isEmpty,
              !candidateCoords.isEmpty else { return 0 }
        var sum: Int64 = 0
        for q in queryCoords {
            for c in candidateCoords {
                let key = MatrixCoOccurKey(q, c)
                // Keyed lookup: 0 when the pair has never co-appeared.
                sum += matrix.coOccurrence[key] ?? 0
            }
        }
        return Float(sum) / Float(matrix.liveRowCount)
    }

    // MARK: - temporal

    /// T-matrix temporal-causality score for active lag buckets.
    ///
    /// For each (queryCoord, candidateCoord, lagBucket) triple where
    /// lagBucket is in activeLags, looks up
    /// T[MatrixTemporalKey(source: queryCoord, target: candidateCoord, lagBucket)].
    /// Missing entries return 0. Normalized by liveRowCount.
    ///
    /// Access count is bounded by |queryCoords| × |candidateCoords| × |activeLags|
    /// — never a full-matrix scan.
    ///
    /// Returns 0.0 when any input set is empty or the estate has no live rows.
    ///
    /// - Parameters:
    ///   - queryCoords:     Coords of the reference candidate (source of temporal event).
    ///   - candidateCoords: Coords of the candidate being scored (target).
    ///   - activeLags:      Log-spaced lag buckets to query (e.g. MatrixTier.lagBuckets).
    ///   - matrix:          The in-memory MatrixTier for this estate.
    func temporal(queryCoords: [MatrixValueCoord],
                  candidateCoords: [MatrixValueCoord],
                  activeLags: [Int],
                  matrix: MatrixTier) -> Float {
        guard matrix.liveRowCount > 0,
              !queryCoords.isEmpty,
              !candidateCoords.isEmpty,
              !activeLags.isEmpty else { return 0 }
        var sum: Int64 = 0
        for q in queryCoords {
            for c in candidateCoords {
                for lag in activeLags {
                    let key = MatrixTemporalKey(source: q, target: c, lagBucket: lag)
                    sum += matrix.temporalCausality[key] ?? 0
                }
            }
        }
        return Float(sum) / Float(matrix.liveRowCount)
    }
}
