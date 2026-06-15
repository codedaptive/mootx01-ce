// InvertedIndex.swift
//
// Weighted impact-ordered inverted index with WAND and Block-Max WAND
// (BMW) exact top-k retrieval.
//
// Lane D — Sparse Engine (SPLADE generalization).
// Retrieval algorithms reference §2 is the authoritative spec for this file.
//
// Design contract:
// - Postings in each term list are sorted by item_id ascending (the WAND
//   pivoting invariant, §2.1).
// - All impacts are Int32 quantized integers (QUANT_SCALE = 100,
//   round-half-to-even). No float arithmetic on the query path (§2.2).
// - WAND and BMW both return the EXACT same top-k as exhaustive DAAT
//   full-scan. The two algorithms are interchangeable in result (§2.5).
// - Universal tie-break: when scores are equal, smaller item_id wins (§0.3).
// - The index is NOT thread-safe for mutation — callers must serialize
//   build / insert / remove. Read-only search is safe from any concurrent
//   reader once the index is quiescent (the actor wrapper in InvertedIndexStore
//   provides the concurrent-access contract).
//
// BM25 is one weighting scheme that plugs into this index via BM25Weighting.
// The WAND / BMW machinery is identical regardless of where the impacts
// originated (BM25, SPLADE, or any other scheme).
//
// Parity: Rust twin in CorpusKit/rust/src/engine/inverted_index.rs.
// The two must produce bit-identical output on shared test vectors
// (SPARSE-1..4 in the retrieval algorithms reference §2.9).

import Foundation
import OSLog

// MARK: - Configuration

/// Pinned constant from the retrieval algorithms reference §2.2.
/// All float weights are quantized to Int32 via: round_half_even(w * QUANT_SCALE).
public let invertedIndexQuantScale: Int32 = 100

/// Block size for Block-Max WAND (BMW). Pinned config — different values give
/// the same *results* but different trace behavior, so pin it for conformance.
/// Retrieval algorithms reference §2.7: "block_size is pinned config."
public let invertedIndexBlockSize: Int = 128

private let logger = Logger(subsystem: "com.mootx01.kit", category: "InvertedIndex")

// MARK: - Posting cursor (internal)

/// Internal cursor over a posting list for WAND iteration.
/// Maintains position in the sorted-ascending-item_id posting list.
private struct PostingCursor {
    let termID: UInt32
    let termUB: Int32            // global max_impact * query_weight (upper bound)
    let queryWeight: Int32       // the query-side weight for this term
    let postings: [ImpactPosting]
    // BMW augmentation
    let blockMax: [Int32]        // per-block max impact
    let blockLastID: [String]    // per-block last item_id (for skip)
    var position: Int            // current index into postings

    /// Current doc_id (item_id) at the cursor position; nil if exhausted.
    var currentID: String? {
        position < postings.count ? postings[position].itemID : nil
    }

    /// Whether the cursor is exhausted (past the end of postings).
    var isExhausted: Bool { position >= postings.count }

    /// Impact at the current position (caller must check !isExhausted).
    var currentImpact: Int32 { postings[position].impact }

    /// Advance cursor past the current posting.
    mutating func advance() { position += 1 }

    /// Seek to the first posting whose item_id >= target.
    /// This is a linear scan — posting lists are short in practice; a binary
    /// search would also be correct but this keeps the code clear.
    mutating func seek(to target: String) {
        while position < postings.count && postings[position].itemID < target {
            position += 1
        }
    }

    /// Block max upper-bound contribution of this list at the given item_id.
    /// Returns the block-max impact for the block containing item_id,
    /// multiplied by the query weight.
    func blockMaxContribution(at itemID: String) -> Int64 {
        // Find the block that covers itemID: first block whose blockLastID >= itemID.
        for (blockIdx, lastID) in blockLastID.enumerated() {
            if lastID >= itemID {
                let bm = blockIdx < blockMax.count ? blockMax[blockIdx] : 0
                return Int64(bm) * Int64(queryWeight)
            }
        }
        // itemID is past all blocks — no contribution.
        return 0
    }
}

// MARK: - InvertedIndex

/// Weighted impact-ordered inverted index.
///
/// Supports WAND and Block-Max WAND exact top-k retrieval.
/// A query is a set of (termID, queryWeight: Int32) pairs (already quantized).
/// The score of an item is the integer dot product of query weights and per-term
/// impacts over shared terms.
///
/// All impacts are Int32 (quantized). All scoring arithmetic is integer-only.
/// This makes the sparse lane bit-identical across Swift and Rust (retrieval
/// algorithms reference §2.2).
///
/// Lifecycle: build once via `init(postings:numDocs:)`, then query repeatedly
/// via `topK(query:k:algorithm:)`. Mutation (add / remove) is supported but
/// invalidates the block-max structures — caller must call `rebuildBlockMax()`
/// after mutation.
public struct InvertedIndex: Sendable {

    // MARK: - Internal storage

    /// term_id → sorted postings (item_id ascending). The core index.
    private let sortedPostings: [UInt32: [ImpactPosting]]
    /// term_id → global max impact over all postings. WAND upper bound.
    private let globalMaxImpact: [UInt32: Int32]
    /// term_id → block-max array (block_size = invertedIndexBlockSize).
    private let blockMaxImpacts: [UInt32: [Int32]]
    /// term_id → block last item_id (for BMW seek target).
    private let blockLastIDs: [UInt32: [String]]

    /// Number of documents in the corpus (used by BM25Weighting at build time;
    /// stored here for completeness and round-trip through InvertedIndexStore).
    public let numDocs: Int

    // MARK: - Construction

    /// Build an inverted index from pre-computed impact postings.
    ///
    /// - Parameters:
    ///   - postings: term_id → list of ImpactPosting. The caller provides impacts
    ///     already quantized (round-half-even at QUANT_SCALE=100). Postings need
    ///     NOT be pre-sorted — this initializer sorts them by item_id ascending.
    ///   - numDocs: total document count (stored for persistence round-trip).
    public init(postings: [UInt32: [ImpactPosting]], numDocs: Int) {
        self.numDocs = numDocs

        // Sort each posting list by item_id ascending (WAND pivoting invariant).
        var sorted = [UInt32: [ImpactPosting]](minimumCapacity: postings.count)
        var maxImpact = [UInt32: Int32](minimumCapacity: postings.count)
        for (term, posts) in postings {
            let s = posts.sorted { $0.itemID < $1.itemID }
            sorted[term] = s
            maxImpact[term] = s.map(\.impact).max() ?? 0
        }
        self.sortedPostings = sorted
        self.globalMaxImpact = maxImpact
        self.blockMaxImpacts = InvertedIndex.buildBlockMaxImpacts(sorted)
        self.blockLastIDs = InvertedIndex.buildBlockLastIDs(sorted)
    }

    // MARK: - Block-max structures

    private static func buildBlockMaxImpacts(_ sorted: [UInt32: [ImpactPosting]]) -> [UInt32: [Int32]] {
        var result = [UInt32: [Int32]](minimumCapacity: sorted.count)
        for (term, posts) in sorted {
            var blocks = [Int32]()
            var i = 0
            while i < posts.count {
                let end = min(i + invertedIndexBlockSize, posts.count)
                let blockMax = posts[i..<end].map(\.impact).max() ?? 0
                blocks.append(blockMax)
                i = end
            }
            result[term] = blocks
        }
        return result
    }

    private static func buildBlockLastIDs(_ sorted: [UInt32: [ImpactPosting]]) -> [UInt32: [String]] {
        var result = [UInt32: [String]](minimumCapacity: sorted.count)
        for (term, posts) in sorted {
            var ids = [String]()
            var i = 0
            while i < posts.count {
                let end = min(i + invertedIndexBlockSize, posts.count)
                ids.append(posts[end - 1].itemID)
                i = end
            }
            result[term] = ids
        }
        return result
    }

    // MARK: - Query algorithms

    /// Algorithm selector for top-k retrieval.
    public enum Algorithm: Sendable {
        /// WAND with global max-impact upper bounds (§2.3).
        case wand
        /// Block-Max WAND with per-block tighter upper bounds (§2.7).
        case blockMaxWand
    }

    /// Exact top-k retrieval by score descending, tie-break by item_id ascending.
    ///
    /// - Parameters:
    ///   - query: (termID, queryWeight) pairs. queryWeight must already be quantized
    ///     (Int32 at QUANT_SCALE). A natural BM25 query has queryWeight = QUANT_SCALE
    ///     (i.e. 100) per term.
    ///   - k: number of results to return.
    ///   - algorithm: `.wand` or `.blockMaxWand`. Both return identical results.
    /// - Returns: Up to k SparseHit values, score descending, item_id ascending on ties.
    public func topK(
        query: [(termID: UInt32, queryWeight: Int32)],
        k: Int,
        algorithm: Algorithm = .blockMaxWand
    ) -> [SparseHit] {
        guard k > 0, !query.isEmpty else { return [] }

        // Build cursors for all query terms that have posting lists.
        var cursors = buildCursors(for: query)
        guard !cursors.isEmpty else { return [] }

        // Run the chosen algorithm.
        let results: [(itemID: String, score: Int64)]
        switch algorithm {
        case .wand:
            results = runWAND(&cursors, k: k)
        case .blockMaxWand:
            results = runBMW(&cursors, k: k)
        }

        // Convert integer scores to float for the SparseHit surface.
        // The integer score = Σ query_weight * impact; dividing by
        // QUANT_SCALE² recovers approximate BM25 scale, but we expose
        // the raw integer score divided by QUANT_SCALE for consumer
        // convenience. This matches the SparseHit contract in SparseTypes.swift.
        return results.map { hit in
            SparseHit(itemID: hit.itemID, impact: Float(hit.score) / Float(invertedIndexQuantScale))
        }
    }

    /// Exhaustive DAAT full-scan for conformance gating.
    ///
    /// Scores every item that appears in at least one query term's posting list.
    /// Returns top-k by score DESC, item_id ASC. This is the reference oracle
    /// that WAND and BMW must reproduce exactly. Used in tests, not production.
    public func exhaustiveScan(
        query: [(termID: UInt32, queryWeight: Int32)],
        k: Int
    ) -> [SparseHit] {
        guard k > 0, !query.isEmpty else { return [] }

        var scores = [String: Int64]()
        for (termID, qw) in query {
            guard let posts = sortedPostings[termID] else { continue }
            for posting in posts {
                let contribution = Int64(qw) * Int64(posting.impact)
                scores[posting.itemID, default: 0] += contribution
            }
        }
        guard !scores.isEmpty else { return [] }

        var sorted = scores.sorted {
            // score DESC, then item_id ASC
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        if sorted.count > k { sorted.removeLast(sorted.count - k) }
        return sorted.map { SparseHit(itemID: $0.key, impact: Float($0.value) / Float(invertedIndexQuantScale)) }
    }

    // MARK: - WAND core (§2.3)

    private func runWAND(_ cursors: inout [PostingCursor], k: Int) -> [(itemID: String, score: Int64)] {
        // Min-heap of capacity k: root = worst (smallest score, largest id).
        // Eviction key: (score ASC, id DESC) — so we always remove the weakest entry.
        var heap = TopKHeap(capacity: k)
        var threshold: Int64 = 0

        while true {
            // 1. Sort cursors by (current_id ASC, term_id ASC). Drop exhausted ones.
            cursors = cursors.filter { !$0.isExhausted }
            if cursors.isEmpty { break }
            cursors.sort {
                guard let la = $0.currentID, let lb = $1.currentID else {
                    return $0.isExhausted ? false : true
                }
                if la != lb { return la < lb }
                return $0.termID < $1.termID
            }

            // 2. Find pivot: smallest prefix whose cumulative UB > threshold (strict >).
            guard let (pivotIdx, pivotID) = findPivot(cursors: cursors, threshold: threshold) else {
                break // no doc can beat threshold
            }

            // 3. Alignment check.
            if cursors[0].currentID == pivotID {
                // All lists before pivot are aligned on pivot_doc → score it fully.
                let score = scoreAligned(&cursors, pivotID: pivotID)
                heap.offer(itemID: pivotID, score: score, threshold: &threshold)
            } else {
                // Advance the list with smallest term_id among those before pivot
                // that are not yet at pivot_id.
                let pickIdx = choosAdvanceIndex(cursors: cursors, pivotIdx: pivotIdx, pivotID: pivotID)
                cursors[pickIdx].seek(to: pivotID)
            }
        }

        return heap.sorted()
    }

    // MARK: - Block-Max WAND core (§2.7)

    private func runBMW(_ cursors: inout [PostingCursor], k: Int) -> [(itemID: String, score: Int64)] {
        var heap = TopKHeap(capacity: k)
        var threshold: Int64 = 0

        while true {
            // 1. Sort + drop exhausted (same as WAND).
            cursors = cursors.filter { !$0.isExhausted }
            if cursors.isEmpty { break }
            cursors.sort {
                guard let la = $0.currentID, let lb = $1.currentID else {
                    return $0.isExhausted ? false : true
                }
                if la != lb { return la < lb }
                return $0.termID < $1.termID
            }

            // 2. Find pivot (same as WAND, uses global UB).
            guard let (pivotIdx, pivotID) = findPivot(cursors: cursors, threshold: threshold) else {
                break
            }

            // 3. Block-max refinement: compute tighter per-block UB at pivot_id.
            let blockUB = computeBlockUB(cursors: cursors, pivotIdx: pivotIdx, pivotID: pivotID)
            if blockUB <= threshold {
                // Block cannot beat threshold: skip past the min block_last_id.
                // Advance the list with the smallest term_id among involved lists (PIN: §2.7).
                let nextTarget = nextBlockTarget(cursors: cursors, pivotIdx: pivotIdx, pivotID: pivotID)
                let pickIdx = choosAdvanceIndex(cursors: cursors, pivotIdx: pivotIdx, pivotID: pivotID)
                cursors[pickIdx].seek(to: nextTarget)
                continue
            }

            // 4. Alignment check (same as WAND).
            if cursors[0].currentID == pivotID {
                let score = scoreAligned(&cursors, pivotID: pivotID)
                heap.offer(itemID: pivotID, score: score, threshold: &threshold)
            } else {
                let pickIdx = choosAdvanceIndex(cursors: cursors, pivotIdx: pivotIdx, pivotID: pivotID)
                cursors[pickIdx].seek(to: pivotID)
            }
        }

        return heap.sorted()
    }

    // MARK: - Shared WAND / BMW helpers

    private func buildCursors(for query: [(termID: UInt32, queryWeight: Int32)]) -> [PostingCursor] {
        var cursors = [PostingCursor]()
        for (termID, qw) in query {
            guard let posts = sortedPostings[termID], !posts.isEmpty else { continue }
            let maxImp = globalMaxImpact[termID] ?? 0
            let ub = Int32(min(Int64(maxImp) * Int64(qw), Int64(Int32.max)))
            let bm = blockMaxImpacts[termID] ?? []
            let bl = blockLastIDs[termID] ?? []
            cursors.append(PostingCursor(
                termID: termID,
                termUB: ub,
                queryWeight: qw,
                postings: posts,
                blockMax: bm,
                blockLastID: bl,
                position: 0
            ))
        }
        return cursors
    }

    /// Find the pivot: smallest prefix index where cumulative UB > threshold.
    /// Returns (pivotIdx, pivot_item_id) or nil if no pivot found.
    private func findPivot(
        cursors: [PostingCursor],
        threshold: Int64
    ) -> (Int, String)? {
        var acc: Int64 = 0
        for (i, cursor) in cursors.enumerated() {
            guard let cid = cursor.currentID else { continue }
            acc += Int64(cursor.termUB)
            if acc > threshold {
                return (i, cid)
            }
        }
        return nil
    }

    /// Score pivot_id: sum up query_weight * impact for all lists aligned on pivot_id.
    /// Advances those lists past pivot_id.
    private func scoreAligned(_ cursors: inout [PostingCursor], pivotID: String) -> Int64 {
        var score: Int64 = 0
        for i in 0..<cursors.count {
            if cursors[i].currentID == pivotID {
                score += Int64(cursors[i].queryWeight) * Int64(cursors[i].currentImpact)
                cursors[i].advance()
            }
        }
        return score
    }

    /// PIN (§2.4.3): among lists positioned strictly before pivot (current_id < pivot_id),
    /// return the index with the smallest term_id.
    private func choosAdvanceIndex(
        cursors: [PostingCursor],
        pivotIdx: Int,
        pivotID: String
    ) -> Int {
        // All lists before pivotIdx have current_id <= pivot_id by sort invariant.
        // We want those with current_id < pivot_id (need advancing).
        var bestIdx = 0
        var found = false
        for i in 0..<pivotIdx {
            guard let cid = cursors[i].currentID, cid < pivotID else { continue }
            if !found || cursors[i].termID < cursors[bestIdx].termID {
                bestIdx = i
                found = true
            }
        }
        // If none found (all at pivot_id), pick the first one anyway (degenerate case).
        return found ? bestIdx : 0
    }

    /// Compute block-level upper bound at pivot_id.
    private func computeBlockUB(
        cursors: [PostingCursor],
        pivotIdx: Int,
        pivotID: String
    ) -> Int64 {
        var ub: Int64 = 0
        for i in 0...pivotIdx {
            guard let cid = cursors[i].currentID, cid <= pivotID else { continue }
            ub += cursors[i].blockMaxContribution(at: pivotID)
        }
        return ub
    }

    /// Compute the seek target for BMW block-skip: 1 + min block_last_id among
    /// involved lists. Returns the string that is lexicographically one step after
    /// the minimum block boundary covering pivot_id (§2.7).
    private func nextBlockTarget(
        cursors: [PostingCursor],
        pivotIdx: Int,
        pivotID: String
    ) -> String {
        // Find min block_last_id across involved lists (current_id <= pivot_id).
        var minLastID: String? = nil
        for i in 0...pivotIdx {
            guard let cid = cursors[i].currentID, cid <= pivotID else { continue }
            // Block last id covering pivot_id in this list.
            for lastID in cursors[i].blockLastID {
                if lastID >= pivotID {
                    if minLastID == nil || lastID < minLastID! {
                        minLastID = lastID
                    }
                    break
                }
            }
        }
        guard let last = minLastID else { return pivotID + "\u{0001}" }
        // Return the next lexicographic value after last.
        // Append a minimum unicode scalar (U+0001) to safely exceed last.
        return last + "\u{0001}"
    }
}

// MARK: - TopKHeap (internal)

/// Bounded min-heap for WAND top-k collection.
///
/// Keeps the k best (score DESC, itemID ASC) entries seen so far.
/// The root is always the WEAKEST element (smallest score; on tie, largest id).
/// Eviction key: (score ASC, id DESC) → evicts the worst element when full.
private struct TopKHeap {
    typealias Entry = (itemID: String, score: Int64)
    var entries: [Entry]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        entries = []
        entries.reserveCapacity(capacity + 1)
    }

    /// The minimum score in the current top-k (0 if heap has fewer than k entries).
    var minScore: Int64 { entries.first?.score ?? 0 }

    /// True if the given (score, id) would enter the top-k.
    /// Condition: score > threshold, OR (score == threshold AND id < current worst id).
    private func wouldEnter(score: Int64, itemID: String, threshold: Int64) -> Bool {
        guard entries.count >= capacity else { return true }
        if score > threshold { return true }
        if score == threshold {
            // Replace only if this id is smaller than the weakest id at that score.
            return itemID < worstID(at: score)
        }
        return false
    }

    private func worstID(at score: Int64) -> String {
        // Among heap entries with the given score, find the largest id (the weakest).
        entries.filter { $0.score == score }.map(\.itemID).max() ?? ""
    }

    /// Offer a candidate. Updates threshold if the heap fills up or improves.
    mutating func offer(itemID: String, score: Int64, threshold: inout Int64) {
        if entries.count < capacity {
            entries.append((itemID, score))
            siftUp(entries.count - 1)
            if entries.count == capacity { threshold = minScore }
        } else if wouldEnter(score: score, itemID: itemID, threshold: threshold) {
            entries[0] = (itemID, score)
            siftDown(0)
            threshold = minScore
        }
    }

    /// Return all entries sorted (score DESC, itemID ASC).
    func sorted() -> [(itemID: String, score: Int64)] {
        entries.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.itemID < $1.itemID
        }
    }

    // Heap is a min-heap on (score ASC, id DESC) — so root = weakest candidate.
    private func isWeaker(_ a: Entry, _ b: Entry) -> Bool {
        if a.score != b.score { return a.score < b.score }
        return a.itemID > b.itemID  // larger id = weaker
    }

    private mutating func siftUp(_ i: Int) {
        var idx = i
        while idx > 0 {
            let parent = (idx - 1) / 2
            if isWeaker(entries[idx], entries[parent]) {
                entries.swapAt(idx, parent)
                idx = parent
            } else { break }
        }
    }

    private mutating func siftDown(_ start: Int) {
        var i = start
        let n = entries.count
        while true {
            let l = 2 * i + 1, r = 2 * i + 2
            var weakest = i
            if l < n && isWeaker(entries[l], entries[weakest]) { weakest = l }
            if r < n && isWeaker(entries[r], entries[weakest]) { weakest = r }
            if weakest == i { break }
            entries.swapAt(i, weakest)
            i = weakest
        }
    }
}
