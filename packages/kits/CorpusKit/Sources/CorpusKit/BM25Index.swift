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
}
