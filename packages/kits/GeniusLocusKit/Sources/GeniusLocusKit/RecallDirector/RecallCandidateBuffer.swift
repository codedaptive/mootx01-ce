import LocusKit

/// Packed parallel-array union buffer for multi-lane recall candidates.
///
/// Capacity is fixed at init — never reallocates after construction. All
/// score columns are stored as parallel Float arrays indexed by the same
/// position. Lane membership is tracked in a UInt16 bitset (`sourceMask`)
/// where each bit corresponds to a `RecallEvidencePath` case by ordinal:
///   - bit 0: locusBitmap
///   - bit 1: locusGraph
///   - bit 2: corpusBM25
///   - bit 3: vectorHamming
///   - bit 4: vectorDense
///
/// `merge` provides O(1) deduplication via `idToIndex`: if the ID is
/// already in the buffer, the source bit is unioned and per-column scores
/// are replaced by the maximum of the existing and incoming value. If the
/// ID is new, it is appended to the next free slot. Merges beyond capacity
/// are silently dropped — callers must size the buffer with adequate slack.
///
/// `normalizeFinals` min-max scales each score column to [0, 1] across
/// all populated slots before the MMR pass. Columns where all values are
/// equal are set to 0.5 (no information to order by).
struct RecallCandidateBuffer {
    /// Drawer row IDs in insertion order.
    var ids: [String]
    /// Per-slot lane membership bitset. Bit ordinals match RecallEvidencePath case order.
    var sourceMask: [UInt16]
    /// Locus-lane score for each slot.
    var locus: [Float]
    /// BM25 keyword score for each slot.
    var bm25: [Float]
    /// Vector similarity score for each slot.
    var vector: [Float]
    /// Matrix field-presence score for each slot (populated in a future mission).
    var fieldFit: [Float]
    /// Matrix co-occurrence score for each slot (populated in a future mission).
    var coOccurrence: [Float]
    /// Matrix temporal-decay score for each slot (populated in a future mission).
    var temporal: [Float]
    /// Graph coherence score for each slot (populated in a future mission).
    var graph: [Float]
    /// Learned-preference score for each slot (populated in a future mission).
    var preference: [Float]
    /// Dense-float cosine-similarity score for each slot (Lane D), in [0, 1].
    /// Populated by the dense float lane; 0 for slots it did not contribute.
    var dense: [Float]
    /// Combined final score, used as the MMR relevance signal after normalizeFinals.
    var final: [Float]
    /// Raw integer Hamming distance (0…256) for each slot that came from the
    /// vector lane, or `RecallScoreVector.noHammingDistance` (-1) for slots
    /// that did not. Carried verbatim from `VectorMatch.distance` so the dense
    /// signal survives the union merge; never normalised (it is not a score
    /// column — `normalizeFinals` deliberately leaves it untouched).
    var hammingDistance: [Int]
    /// O(1) lookup from drawer ID to slot index.
    var idToIndex: [String: Int]
    /// Number of slots populated so far. Always ≤ capacity.
    var count: Int

    /// Fixed capacity chosen at init. Merges beyond this limit are dropped.
    private let capacity: Int

    /// Source bit ordinals, matching RecallEvidencePath case declaration order.
    static let bitLocusBitmap: UInt16   = 1 << 0
    static let bitLocusGraph: UInt16    = 1 << 1
    static let bitCorpusBM25: UInt16    = 1 << 2
    static let bitVectorHamming: UInt16 = 1 << 3
    static let bitVectorDense: UInt16   = 1 << 4

    /// Initialise a buffer with fixed `capacity`. No reallocation occurs after this call.
    ///
    /// - Parameter capacity: Maximum number of distinct candidates the buffer can hold.
    init(capacity: Int) {
        self.capacity = capacity
        self.count = 0
        self.ids          = Array(repeating: "", count: capacity)
        self.sourceMask   = Array(repeating: 0, count: capacity)
        self.locus        = Array(repeating: 0, count: capacity)
        self.bm25         = Array(repeating: 0, count: capacity)
        self.vector       = Array(repeating: 0, count: capacity)
        self.fieldFit     = Array(repeating: 0, count: capacity)
        self.coOccurrence = Array(repeating: 0, count: capacity)
        self.temporal     = Array(repeating: 0, count: capacity)
        self.graph        = Array(repeating: 0, count: capacity)
        self.preference   = Array(repeating: 0, count: capacity)
        self.dense        = Array(repeating: 0, count: capacity)
        self.final        = Array(repeating: 0, count: capacity)
        // Initialise to the sentinel: a slot only acquires a real distance when a
        // vector-lane hit merges into it. Non-vector slots keep the sentinel.
        self.hammingDistance = Array(repeating: RecallScoreVector.noHammingDistance, count: capacity)
        self.idToIndex    = [:]
        idToIndex.reserveCapacity(capacity)
    }

    /// Merge a `RecallHit` into the buffer, attributed to a single source lane bit.
    ///
    /// If the ID is already present, the `sourceMask` is unioned with `sourceBit`
    /// and each score column is updated to the maximum of its current and incoming
    /// value. If the ID is new and the buffer has remaining capacity, it is appended;
    /// if capacity is exhausted the merge is silently dropped.
    ///
    /// - Parameters:
    ///   - hit:       The recall hit to absorb. `hit.id` is the deduplication key.
    ///   - sourceBit: A single-bit mask identifying the contributing lane.
    mutating func merge(hit: RecallHit, sourceBit: UInt16) {
        if let idx = idToIndex[hit.id] {
            // Existing candidate: union source bits, keep max per column.
            sourceMask[idx]   |= sourceBit
            locus[idx]         = max(locus[idx],        hit.score.locus)
            bm25[idx]          = max(bm25[idx],         hit.score.bm25)
            vector[idx]        = max(vector[idx],        hit.score.vector)
            fieldFit[idx]      = max(fieldFit[idx],      hit.score.fieldFit)
            coOccurrence[idx]  = max(coOccurrence[idx],  hit.score.coOccurrence)
            temporal[idx]      = max(temporal[idx],      hit.score.temporal)
            graph[idx]         = max(graph[idx],         hit.score.graph)
            preference[idx]    = max(preference[idx],    hit.score.preference)
            dense[idx]         = max(dense[idx],         hit.score.dense)
            final[idx]         = max(final[idx],         hit.score.final)
            // Hamming distance is not a score column, so it is not max'd: the
            // vector lane is the only producer of a real distance for a given id,
            // and a drawer has one stored engram, so the distance is the same
            // whichever lane re-merges it. Keep the first real (non-sentinel)
            // value; never let a sentinel from a non-vector lane overwrite it.
            if hit.score.hammingDistance != RecallScoreVector.noHammingDistance {
                hammingDistance[idx] = hit.score.hammingDistance
            }
        } else {
            // New candidate: append if capacity allows.
            guard count < capacity else { return }
            let idx = count
            idToIndex[hit.id] = idx
            ids[idx]          = hit.id
            sourceMask[idx]   = sourceBit
            locus[idx]        = hit.score.locus
            bm25[idx]         = hit.score.bm25
            vector[idx]       = hit.score.vector
            fieldFit[idx]     = hit.score.fieldFit
            coOccurrence[idx] = hit.score.coOccurrence
            temporal[idx]     = hit.score.temporal
            graph[idx]        = hit.score.graph
            preference[idx]   = hit.score.preference
            dense[idx]        = hit.score.dense
            final[idx]        = hit.score.final
            hammingDistance[idx] = hit.score.hammingDistance
            count += 1
        }
    }

    /// Min-max normalise every score column to [0, 1] across the `count` populated slots.
    ///
    /// For each column, finds the minimum and maximum across slots 0..<count, then
    /// scales each slot value to (value - min) / (max - min).
    ///
    /// When all values are identical (range == 0), the treatment depends on the value:
    ///   - All-zero column (lo == 0): no cache was registered; no measurement was taken.
    ///     Slots remain 0.0 — absent evidence contributes nothing to scoring.
    ///   - Non-zero uniform column (lo > 0): real measurements exist but produce no
    ///     relative ordering. Slots are set to 0.5 — "measured but informationally flat."
    ///
    /// NaN values are treated as 0 before normalisation so a pathological embed
    /// failure does not poison the MMR pass.
    ///
    /// Each column is normalised by an extracted copy to avoid Swift's exclusivity
    /// checker rejecting inout on stored properties accessed via `self`.
    mutating func normalizeFinals() {
        guard count > 0 else { return }
        locus        = normalizedCopy(of: locus)
        bm25         = normalizedCopy(of: bm25)
        vector       = normalizedCopy(of: vector)
        fieldFit     = normalizedCopy(of: fieldFit)
        coOccurrence = normalizedCopy(of: coOccurrence)
        temporal     = normalizedCopy(of: temporal)
        graph        = normalizedCopy(of: graph)
        preference   = normalizedCopy(of: preference)
        dense        = normalizedCopy(of: dense)
        final        = normalizedCopy(of: final)
    }

    /// Return a min-max scaled copy of `col` over the first `count` elements.
    ///
    /// - Replaces NaN with 0 before computing min/max.
    /// - All-zero column (absent signal): slots remain 0.0. No cache was registered;
    ///   contributing 0.0 is the correct neutral value for scoring.
    /// - Non-zero uniform column (measured-uniform signal): slots are set to 0.5,
    ///   conveying "measured but no relative ordering information."
    /// - Varying column: standard min-max scale to [0, 1].
    /// - Elements beyond `count` are copied unchanged (they are unpopulated slots).
    private func normalizedCopy(of col: [Float]) -> [Float] {
        // Replace NaN, then scan populated slots for min/max.
        var copy = col
        for i in 0..<count {
            if copy[i].isNaN { copy[i] = 0 }
        }
        var lo = copy[0]
        var hi = copy[0]
        for i in 1..<count {
            if copy[i] < lo { lo = copy[i] }
            if copy[i] > hi { hi = copy[i] }
        }
        let range = hi - lo
        if range == 0 {
            if lo == 0 {
                // All-zero column: no cache was registered; no measurement was taken.
                // Leave at 0.0 — absent evidence contributes nothing to scoring.
            } else {
                // Measured-uniform column: real measurements, no relative ordering.
                // Use 0.5 to convey "measured but informationally flat."
                for i in 0..<count { copy[i] = 0.5 }
            }
        } else {
            for i in 0..<count {
                copy[i] = (copy[i] - lo) / range
            }
        }
        return copy
    }
}
