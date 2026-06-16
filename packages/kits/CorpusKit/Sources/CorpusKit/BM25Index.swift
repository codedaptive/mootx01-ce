// BM25Index.swift
//
// BM25 inverted index — actor wrapper over the Engine layer.
//
// REFACTORED (Lane D): this actor now delegates to BM25Weighting (which
// builds an InvertedIndex with quantized per-posting impacts) and queries
// via WAND / Block-Max WAND. The original float-at-query-time path is
// replaced by the integer-only path mandated by retrieval algorithms
// reference §2.6.
//
// Public API is unchanged:
//   - init(tokenizer:parameters:)
//   - index(_:)          — index a batch of Chunks
//   - remove(_:)         — remove by UUID
//   - documentCount()    — total indexed docs
//   - topK(_:for:)       — top-k (id: UUID, score: Float), descending
//
// Internally the UUID primary keys are stored as their lowercased UUID string
// representation (UUID.uuidString). The UUID string sort order matches the
// spec's universal tie-break rule: "smaller id wins" (§0.3). UUID strings are
// uppercase hexadecimal with dashes; lexicographic order on the string is NOT
// the same as numeric order on the UUID. Both the old and new implementations
// used UUID.uuidString ascending as the tie-break — the refactored version
// preserves this by using String itemIDs consistently.
//
// Parameters: Robertson-Sparck Jones defaults k1=1.5, b=0.75. Tunable per estate.

import Foundation

// BM25Parameters is defined in Engine/BM25Weighting.swift (same module).
// Re-export here for callers that only import CorpusKit and know BM25Parameters
// as the top-level name (no source break).

public actor BM25Index {
    private let tokenizer: any Tokenizer
    private let parameters: BM25Parameters

    // MARK: - In-memory index state

    // term → (itemID string → term frequency)
    private var termFreqs: BM25Weighting.TermFreqTable = [:]
    // itemID string → document length in tokens
    private var docLengths: [String: Int] = [:]
    // Cached InvertedIndex + term mapping; invalidated on every write.
    private var cachedIndexPair: (index: InvertedIndex, termMapping: [String: UInt32])? = nil

    // MARK: - Init

    public init(tokenizer: any Tokenizer, parameters: BM25Parameters = BM25Parameters()) {
        self.tokenizer = tokenizer
        self.parameters = parameters
    }

    // MARK: - Indexing

    /// Index a batch of Chunks. Re-indexing an already-indexed chunk is safe
    /// (the old entry is replaced).
    public func index(_ chunks: [Chunk]) {
        for chunk in chunks {
            let itemID = chunk.id.uuidString
            // Remove existing state before re-indexing.
            removeMem(itemID: itemID)

            let tokens = tokenizer.keywordTokens(chunk.text)
            let docLen = tokens.count
            docLengths[itemID] = docLen

            var tf = [String: Int]()
            for t in tokens { tf[t, default: 0] += 1 }
            for (term, freq) in tf {
                termFreqs[term, default: [:]][itemID] = freq
            }
        }
        cachedIndexPair = nil
    }

    /// Remove a document by UUID.
    public func remove(_ chunkID: UUID) {
        let itemID = chunkID.uuidString
        removeMem(itemID: itemID)
        cachedIndexPair = nil
    }

    private func removeMem(itemID: String) {
        docLengths.removeValue(forKey: itemID)
        for term in Array(termFreqs.keys) {
            termFreqs[term]?.removeValue(forKey: itemID)
            if termFreqs[term]?.isEmpty == true { termFreqs.removeValue(forKey: term) }
        }
    }

    // MARK: - Query

    /// Total indexed documents.
    public func documentCount() -> Int { docLengths.count }

    /// Top-k BM25 scoring over pre-tokenised keyword tokens.
    ///
    /// Routes through the new InvertedIndex (WAND / Block-Max WAND) engine.
    /// Integer-only on the query path; BM25 float math happens once at build.
    ///
    /// - Parameters:
    ///   - k: Maximum results to return.
    ///   - tokens: Pre-tokenised keyword strings compatible with indexed chunks.
    /// - Returns: Up to k (id: UUID, score: Float) pairs, score descending,
    ///   UUID.uuidString ascending on ties.
    public func topK(_ k: Int, for tokens: [String]) -> [(id: UUID, score: Float)] {
        guard docLengths.count > 0, k > 0, !tokens.isEmpty else { return [] }

        // Build or reuse the cached InvertedIndex.
        let (index, termMapping) = buildIndex()
        let query = BM25Weighting.queryPairs(queryTerms: tokens, termMapping: termMapping)
        guard !query.isEmpty else { return [] }

        let hits = index.topK(query: query, k: k, algorithm: .blockMaxWand)

        // Convert String itemID back to UUID and Float score.
        // Items with un-parseable UUIDs are silently dropped (should not occur
        // in normal operation since BM25Index only ingests Chunk.id.uuidString).
        return hits.compactMap { hit -> (id: UUID, score: Float)? in
            guard let uuid = UUID(uuidString: hit.itemID) else { return nil }
            return (id: uuid, score: hit.impact)
        }
    }

    // MARK: - Internal index build (with caching)

    private func buildIndex() -> (index: InvertedIndex, termMapping: [String: UInt32]) {
        if let cached = cachedIndexPair { return cached }
        let pair = BM25Weighting.build(
            termFreqs: termFreqs,
            docLengths: docLengths,
            parameters: parameters
        )
        cachedIndexPair = pair
        return pair
    }
}
