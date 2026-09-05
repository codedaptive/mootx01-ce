// TermDocumentCounts.swift
//
// Shared term-document count builder used by every distributional-semantics
// provider in CorpusKitProviders (LSA, NMF, Random Indexing, PPMI).
//
// ## What this type owns
//
//   - Tokenization via the canonical `defaultKeywordTokens` function (for
//     the text-consuming providers) or acceptance of an already-tokenized
//     term sequence (for the term-consuming providers, RI and PPMI).
//   - Vocabulary construction in ENCOUNTER ORDER: terms are assigned
//     integer indices as they are first seen across the training sequence.
//     The order is deterministic for a fixed document sequence. This
//     property is a correctness invariant — the downstream SVD and NMF
//     factorizations depend on stable column indices.
//   - Raw per-document term-frequency counts: tfCounts[docIdx][termIdx]
//     (LSA and NMF only).
//   - Per-term document-frequency counts: dfCounts[termIdx] = number of
//     documents that contain the term at least once. Every distributional
//     provider derives its IDF weights from these through the ONE smoothed
//     IDF function below.
//
// ## What this type does NOT own
//
//   - Matrix orientation (documents×terms for LSA, terms×documents for NMF).
//   - Factorization (SVD for LSA, NMF-ALS for NMF).
//   - Pooling (see DistributionalPooling.swift).
//
// ## Rust port
//
//   Rust port: packages/kits/CorpusKit/rust-providers/src/term_document_counts.rs
//   The two implementations must agree on vocab encounter order and raw counts.
//   Downstream conformance vectors pin the bit-identical contract.

import Foundation
import CorpusKit

// MARK: - Smoothed inverse document frequency

/// The one IDF weighting shared by every distributional provider:
///
///     idf(t) = max(0, ln((N + 1) / (df(t) + 1)))
///
/// Add-1 smoothing on both sides keeps the ratio finite for df = 0 (an
/// unseen term is informative, not undefined) and drives a term that
/// appears in every document to exactly 0 (it carries no information about
/// which document it came from). Natural log; `Float` throughout, so the
/// Swift `log` (logf) and Rust `f32::ln` produce identical bits — the LSA
/// canonical vectors pin this.
///
/// - Parameters:
///   - df: documents that contain the term at least once.
///   - N: documents in the training corpus.
public func smoothedInverseDocumentFrequency(documentFrequency df: Int, documentCount N: Int) -> Float {
    max(0, log(Float(N + 1) / Float(df + 1)))
}

// MARK: - TermDocumentCounts

/// Shared term-document count builder for distributional-semantics providers.
///
/// Maintains a vocabulary (term → encounter-order index), per-document
/// raw TF counts, and per-term document-frequency counts across a sequence
/// of training documents.
///
/// After all `addDocument` calls, consumers read:
///   - `vocab` — term → index map (encounter order)
///   - `tfCounts` — tfCounts[docIdx][termIdx] = raw count
///   - `dfCounts` — dfCounts[termIdx] = number of documents with that term
///   - `documentCount` — number of documents added
///   - `vocabularySize` — vocabulary cardinality
///
/// ## Encounter-order vocabulary
///
/// The first call to `addDocument` that contains a new term `t` assigns
/// `vocab[t] = vocab.count` at that moment (before insertion). This ensures
/// indices are contiguous and stable across all subsequent documents.
///
/// ## Thread safety
///
/// `TermDocumentCounts` is NOT thread-safe. All `addDocument` calls must
/// complete before any consumer reads the output fields.
public struct TermDocumentCounts {

    // MARK: - Storage

    /// Term → vocabulary index (encounter order, deterministic for fixed sequence).
    public private(set) var vocab: [String: Int]

    /// tf counts: tfCounts[docIdx][termIdx] = raw count in that document.
    public private(set) var tfCounts: [[Int: Int]]

    /// Document frequency: dfCounts[termIdx] = number of documents containing term.
    /// LSA uses this for IDF weighting. NMF ignores it.
    public private(set) var dfCounts: [Int: Int]

    // MARK: - Initialiser

    public init() {
        self.vocab = [:]
        self.tfCounts = []
        self.dfCounts = [:]
    }

    /// Reconstruct a count builder from a known vocabulary and document
    /// count, WITHOUT re-tokenizing any text (the deserialization path).
    ///
    /// LSA and NMF read only `vocab` (term → index, for query fold-in) and
    /// `documentCount` (for the `documentEmbedding(at:)` range check) from a
    /// finalized provider — the raw per-document TF counts are training-phase
    /// scratch not needed for embedding. A deserialized provider therefore
    /// seeds this builder with the persisted vocab and a placeholder TF row
    /// per document (empty rows: `documentCount` is preserved, but the raw
    /// counts are not — they are not part of the embed-relevant basis).
    ///
    /// - Parameters:
    ///   - vocab: term → encounter-order index, as captured at serialize time.
    ///   - documentCount: number of training documents (drives `documentCount`).
    public init(restoredVocab vocab: [String: Int], documentCount: Int) {
        self.vocab = vocab
        // One empty TF row per document so `documentCount` reports correctly.
        // The raw TF values are intentionally not restored (not embed-relevant).
        self.tfCounts = Array(repeating: [:], count: max(0, documentCount))
        self.dfCounts = [:]
    }

    /// Reconstruct the document-frequency table of a term-consuming provider
    /// (RI, PPMI) from persisted counts: term → df, plus the document count.
    ///
    /// Terms receive indices in ascending UTF-8 byte order of the term — the
    /// order the counts codec writes them in — so the restored table is a
    /// deterministic function of the persisted map on both ports. The TF rows
    /// are placeholders (the providers never kept them). Document frequency is
    /// what the IDF fit reads back.
    ///
    /// - Parameters:
    ///   - documentFrequencies: term → number of documents containing it.
    ///   - documentCount: number of training documents.
    public init(restoredDocumentFrequencies documentFrequencies: [String: Int], documentCount: Int) {
        var vocab: [String: Int] = [:]
        var dfCounts: [Int: Int] = [:]
        vocab.reserveCapacity(documentFrequencies.count)
        dfCounts.reserveCapacity(documentFrequencies.count)
        let orderedTerms = documentFrequencies.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for (index, term) in orderedTerms.enumerated() {
            vocab[term] = index
            dfCounts[index] = documentFrequencies[term]
        }
        self.vocab = vocab
        self.dfCounts = dfCounts
        self.tfCounts = Array(repeating: [:], count: max(0, documentCount))
    }

    // MARK: - Mutation

    /// Tokenize `text` and accumulate TF counts for one document.
    ///
    /// Terms new to the corpus are assigned the next available vocabulary
    /// index in encounter order (vocab[term] = vocab.count before insertion).
    /// Returns without recording the document if `text` tokenizes to nothing.
    ///
    /// - Parameter text: Raw document text. Tokenized by `defaultKeywordTokens`.
    ///
    /// - Note: Does NOT call Date() — determinism invariant.
    public mutating func addDocument(_ text: String) {
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return }

        // Assign vocab indices in encounter order (deterministic for a fixed
        // training sequence). New terms receive the next index atomically so
        // vocab[term] == vocab.count holds at the moment of first insertion.
        var docTF: [Int: Int] = [:]
        for term in terms {
            let idx: Int
            if let existing = vocab[term] {
                idx = existing
            } else {
                idx = vocab.count
                vocab[term] = idx
            }
            docTF[idx, default: 0] += 1
        }

        // Accumulate per-term document-frequency counts.
        // A term contributes exactly 1 to dfCounts regardless of how many
        // times it appears in this document.
        for termIdx in docTF.keys {
            dfCounts[termIdx, default: 0] += 1
        }

        tfCounts.append(docTF)
    }

    /// Fold one document into the maintained COUNTS ANCHOR only: grow the
    /// vocabulary (encounter order) and increment the document count, WITHOUT
    /// retaining the per-document TF row or accumulating document frequency.
    ///
    /// Used by the incremental-counts maintenance path (P3). The heavy TF/DF
    /// inputs the factorization needs are re-derived by re-tokenizing the corpus
    /// at refactor (Bob's re-tokenize-at-refactor decision), so the maintained
    /// table keeps only the lightweight growth anchor — vocabulary size and
    /// document count — current, bounding maintained state to O(vocab) rather
    /// than the O(corpus) a full `addDocument` per chunk would accumulate.
    ///
    /// Vocabulary indices are assigned in the SAME encounter order as
    /// `addDocument`, so the anchor's vocab map is deterministic and matches the
    /// Rust port byte-for-byte. An empty TF row is appended so `documentCount`
    /// reports correctly (the raw counts are intentionally not retained).
    ///
    /// - Note: Does NOT call Date() — determinism invariant.
    public mutating func addDocumentForCountsAnchor(_ text: String) {
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return }
        for term in terms where vocab[term] == nil {
            vocab[term] = vocab.count
        }
        tfCounts.append([:])
    }

    /// Fold one ALREADY-TOKENIZED document into the vocabulary and the
    /// document-frequency table, without retaining a TF row.
    ///
    /// This is the entry point for the term-consuming providers (RI, PPMI),
    /// whose `train(terms:window:)` receives one document's term sequence per
    /// call. Each distinct term counts once toward `dfCounts` no matter how
    /// often it repeats in the document; a document with no terms is not
    /// recorded (same rule as `addDocument`). Vocabulary indices follow the
    /// same encounter order as `addDocument`, so the table is deterministic
    /// for a fixed document sequence on both ports.
    ///
    /// - Parameter terms: one document's lowercased keyword tokens.
    ///
    /// - Note: Does NOT call Date() — determinism invariant.
    public mutating func addDocumentTerms(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        var seen: Set<Int> = []
        for term in terms {
            let idx: Int
            if let existing = vocab[term] {
                idx = existing
            } else {
                idx = vocab.count
                vocab[term] = idx
            }
            if seen.insert(idx).inserted {
                dfCounts[idx, default: 0] += 1
            }
        }
        tfCounts.append([:])
    }

    // MARK: - Accessors

    /// Number of documents added so far.
    public var documentCount: Int { tfCounts.count }

    /// Number of documents that contain `term` at least once; 0 for a term
    /// the corpus never produced.
    public func documentFrequency(of term: String) -> Int {
        guard let idx = vocab[term] else { return 0 }
        return dfCounts[idx] ?? 0
    }

    /// The smoothed IDF weight of `term` over this corpus — see
    /// `smoothedInverseDocumentFrequency(documentFrequency:documentCount:)`.
    public func inverseDocumentFrequency(of term: String) -> Float {
        smoothedInverseDocumentFrequency(
            documentFrequency: documentFrequency(of: term), documentCount: documentCount)
    }

    /// term → document frequency for every term in the vocabulary — the
    /// shape the counts codec persists (`writeStringU32Map`).
    public var documentFrequencies: [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(vocab.count)
        for (term, idx) in vocab {
            out[term] = dfCounts[idx] ?? 0
        }
        return out
    }

    /// Vocabulary cardinality.
    public var vocabularySize: Int { vocab.count }
}
