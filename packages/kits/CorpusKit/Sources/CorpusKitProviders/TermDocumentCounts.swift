// TermDocumentCounts.swift
//
// Shared term-document count builder used by distributional-semantics
// providers (LSA, NMF) in CorpusKitProviders.
//
// ## What this type owns
//
//   - Tokenization via the canonical `defaultKeywordTokens` function.
//   - Vocabulary construction in ENCOUNTER ORDER: terms are assigned
//     integer indices as they are first seen across the training sequence.
//     The order is deterministic for a fixed document sequence. This
//     property is a correctness invariant — the downstream SVD and NMF
//     factorizations depend on stable column indices.
//   - Raw per-document term-frequency counts: tfCounts[docIdx][termIdx].
//   - Per-term document-frequency counts: dfCounts[termIdx] = number of
//     documents that contain the term at least once.  Used by LSA for
//     IDF weighting; NMF ignores it.
//
// ## What this type does NOT own
//
//   - Weighting (TF-IDF vs. raw TF vs. PPMI).
//   - Matrix orientation (documents×terms for LSA, terms×documents for NMF).
//   - Factorization (SVD for LSA, NMF-ALS for NMF).
//
// ## Rust port
//
//   Rust port: packages/kits/CorpusKit/rust-providers/src/term_document_counts.rs
//   The two implementations must agree on vocab encounter order and raw counts.
//   Downstream conformance vectors pin the bit-identical contract.

import CorpusKit

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

    // MARK: - Accessors

    /// Number of documents added so far.
    public var documentCount: Int { tfCounts.count }

    /// Vocabulary cardinality.
    public var vocabularySize: Int { vocab.count }
}
