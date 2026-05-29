// Tokenizer.swift
//
// Tokenization protocol shared by every embedding provider.
// Concrete tokenizers (BERT WordPiece for MiniLM, BERT WordPiece
// for mpnet, SentencePiece for EmbeddingGemma) live in
// CorpusKitProviders.

import Foundation

public protocol Tokenizer: Sendable {
    /// Stable identifier for the tokenizer's vocabulary. Bumped
    /// whenever the vocab changes. Pairs with the embedding
    /// provider's model version so cross-version tokens are not
    /// confused.
    var vocabID: String { get }

    /// Maximum sequence length the upstream model accepts.
    var maxTokens: Int { get }

    /// ID assigned to the [PAD] / padding token.
    var padTokenID: Int32 { get }

    /// ID assigned to the [UNK] / unknown token.
    var unknownTokenID: Int32 { get }

    /// Tokenize text into model-ready IDs. Implementations are
    /// responsible for truncation to maxTokens.
    func tokenize(_ text: String) -> [Int32]

    /// Split text into BM25-style keyword tokens. This is the
    /// surface BM25Index calls; tokenizers can choose whether
    /// to share the WordPiece path or fall back to a simpler
    /// whitespace split.
    func keywordTokens(_ text: String) -> [String]
}

public extension Tokenizer {
    /// Default keyword tokenization: lowercase and split on
    /// Unicode word boundaries. Suitable for tokenizers that
    /// don't define a separate BM25 path.
    func keywordTokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.value >= 0x30 && scalar.value <= 0x39 {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
