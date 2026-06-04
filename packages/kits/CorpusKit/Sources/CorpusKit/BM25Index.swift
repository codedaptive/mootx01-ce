// BM25Index.swift
//
// In-memory BM25 inverted index over chunk text. Pure value
// type semantics; the index is rebuilt on demand from the
// underlying bundle store. For an estate with hundreds of
// thousands of chunks this lives in memory at startup; for
// larger estates a persistent IDF/posting-list backed by
// PersistenceKit replaces it (deferred to v1.x).
//
// Parameters match the Robertson-Sparck Jones BM25 defaults:
// k1 = 1.5, b = 0.75. Documented as tunable per estate when
// the substrate's parameter sensitivity work lands.

import Foundation

public struct BM25Parameters: Sendable {
    public var k1: Double
    public var b: Double
    public init(k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }
}

public actor BM25Index {
    private let tokenizer: any Tokenizer
    private let parameters: BM25Parameters
    private var totalDocs: Int = 0
    private var totalLengthSum: Int = 0
    // term -> (docID -> term frequency)
    private var postings: [String: [UUID: Int]] = [:]
    private var docLengths: [UUID: Int] = [:]

    public init(tokenizer: any Tokenizer, parameters: BM25Parameters = BM25Parameters()) {
        self.tokenizer = tokenizer
        self.parameters = parameters
    }

    public func index(_ chunks: [Chunk]) {
        for c in chunks {
            let tokens = tokenizer.keywordTokens(c.text)
            docLengths[c.id] = tokens.count
            totalLengthSum += tokens.count
            totalDocs += 1
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            for (term, freq) in tf {
                postings[term, default: [:]][c.id] = freq
            }
        }
    }

    public func remove(_ chunkID: UUID) {
        guard let len = docLengths.removeValue(forKey: chunkID) else { return }
        totalLengthSum -= len
        totalDocs -= 1
        for term in Array(postings.keys) {
            postings[term]?.removeValue(forKey: chunkID)
            if postings[term]?.isEmpty == true { postings.removeValue(forKey: term) }
        }
    }

    /// Top-k BM25 scoring over the given query string.
    public func search(_ query: String, limit: Int) -> [(UUID, Double)] {
        guard totalDocs > 0, limit > 0 else { return [] }
        let queryTokens = tokenizer.keywordTokens(query)
        guard !queryTokens.isEmpty else { return [] }
        let avgDocLen = Double(totalLengthSum) / Double(totalDocs)
        var scores: [UUID: Double] = [:]

        for term in queryTokens {
            guard let posting = postings[term], !posting.isEmpty else { continue }
            // IDF with the +1 smoothing for non-negative scores.
            let n = Double(posting.count)
            let idf = log(1 + (Double(totalDocs) - n + 0.5) / (n + 0.5))
            for (docID, tf) in posting {
                let dl = Double(docLengths[docID] ?? 0)
                let denom = Double(tf) + parameters.k1 * (1 - parameters.b + parameters.b * dl / max(avgDocLen, 1))
                let contribution = idf * (Double(tf) * (parameters.k1 + 1)) / max(denom, 0.0001)
                scores[docID, default: 0] += contribution
            }
        }

        var ranked = scores.map { ($0.key, $0.value) }
        ranked.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.uuidString < $1.0.uuidString
        }
        if ranked.count > limit { ranked.removeLast(ranked.count - limit) }
        return ranked
    }

    public func documentCount() -> Int { totalDocs }

    /// Top-k BM25 scoring over pre-tokenised keyword tokens using a bounded min-heap.
    ///
    /// Unlike `search(_:limit:)`, which tokenises internally and sorts all scored
    /// documents (O(M log M)), this method:
    /// 1. Accepts pre-tokenised tokens so the caller controls tokenisation and can
    ///    reuse tokens across multiple calls.
    /// 2. Maintains a min-heap of capacity `k` — O(M log k) — so the candidate set
    ///    is bounded at every stage; no unbounded intermediate sort.
    ///
    /// The heap root is the weakest survivor (lowest score; latest UUID on tie,
    /// since tie-break is ascending UUID). Candidates enter only when they outrank
    /// the current root.
    ///
    /// - Parameters:
    ///   - k: Maximum results to return.
    ///   - tokens: Pre-tokenised keyword strings. Must use the same tokeniser
    ///     vocabulary as the indexed chunks (i.e. `tokenizer.keywordTokens(text)`
    ///     from the same tokeniser type). The caller is responsible for producing
    ///     compatible tokens.
    /// - Returns: Up to `k` `(id, score)` pairs, descending by score.
    public func topK(_ k: Int, for tokens: [String]) -> [(id: UUID, score: Float)] {
        guard totalDocs > 0, k > 0, !tokens.isEmpty else { return [] }
        let avgDocLen = Double(totalLengthSum) / Double(totalDocs)

        // Score only documents that appear in postings for the supplied tokens.
        // Documents absent from all posting lists never enter the heap — the
        // candidate set is implicitly bounded by the posting lists, not by N.
        var rawScores: [UUID: Double] = [:]
        for term in tokens {
            guard let posting = postings[term], !posting.isEmpty else { continue }
            let n = Double(posting.count)
            // IDF with +1 smoothing for non-negative scores (same formula as search).
            let idf = log(1 + (Double(totalDocs) - n + 0.5) / (n + 0.5))
            for (docID, tf) in posting {
                let dl = Double(docLengths[docID] ?? 0)
                let denom = Double(tf) + parameters.k1 * (1 - parameters.b + parameters.b * dl / max(avgDocLen, 1))
                let contribution = idf * (Double(tf) * (parameters.k1 + 1)) / max(denom, 0.0001)
                rawScores[docID, default: 0] += contribution
            }
        }
        guard !rawScores.isEmpty else { return [] }

        // Min-heap of capacity k. "Weaker" = lower score; on equal scores,
        // later UUID string (ascending UUID wins ties, so later = weaker).
        // The root is always the weakest of the current top-k survivors.
        typealias Pair = (id: UUID, score: Double)

        func isWeaker(_ a: Pair, _ b: Pair) -> Bool {
            if a.score != b.score { return a.score < b.score }
            return a.id.uuidString > b.id.uuidString
        }

        func siftUp(_ h: inout [Pair], _ i: Int) {
            var idx = i
            while idx > 0 {
                let parent = (idx - 1) / 2
                if isWeaker(h[idx], h[parent]) { h.swapAt(idx, parent); idx = parent }
                else { break }
            }
        }

        func siftDown(_ h: inout [Pair]) {
            let n = h.count
            var i = 0
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var w = i
                if l < n && isWeaker(h[l], h[w]) { w = l }
                if r < n && isWeaker(h[r], h[w]) { w = r }
                guard w != i else { break }
                h.swapAt(i, w); i = w
            }
        }

        var heap = [Pair]()
        heap.reserveCapacity(k + 1)
        for (id, score) in rawScores {
            let candidate = Pair(id: id, score: score)
            if heap.count < k {
                heap.append(candidate)
                siftUp(&heap, heap.count - 1)
            } else if !heap.isEmpty && isWeaker(heap[0], candidate) {
                // candidate outranks the current weakest in the heap — displace.
                heap[0] = candidate
                siftDown(&heap)
            }
        }

        // Final ascending-sort on the small heap (at most k elements), then convert.
        heap.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.id.uuidString < b.id.uuidString
        }
        return heap.map { (id: $0.id, score: Float($0.score)) }
    }
}
