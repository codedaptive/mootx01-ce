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

/// The single canonical keyword tokenizer for CorpusKit: lowercase, keep runs
/// of Unicode-alphabetic + ASCII-digit scalars, split on everything else.
///
/// Used by BM25 (via the `Tokenizer.keywordTokens` default below) AND by every
/// distributional embedding provider (RI/PPMI/LSA/NMF) so the lexical and dense
/// lanes can never tokenize differently. Parity with the Rust port's public
/// `corpus_kit::default_keyword_tokens`. Changing this invalidates the
/// providers' committed conformance vectors (regenerate on both ports).
public func defaultKeywordTokens(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    for scalar in text.lowercased().unicodeScalars {
        if scalar.properties.isAlphabetic || scalar.value >= 0x30 && scalar.value <= 0x39 {
            // Unicode case folding maps both Greek sigma forms to U+03C3.
            // Normalizing the contextual final form after lowercasing preserves
            // whole-string lowercase behavior while making the canonical token
            // bytes independent of the platform Unicode engine.
            current.unicodeScalars.append(
                scalar.value == 0x03C2 ? Unicode.Scalar(0x03C3)! : scalar)
        } else if !current.isEmpty {
            out.append(current)
            current = ""
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}

public extension Tokenizer {
    /// Default keyword tokenization — delegates to `defaultKeywordTokens` so
    /// there is exactly one tokenizer definition in the module.
    func keywordTokens(_ text: String) -> [String] {
        defaultKeywordTokens(text)
    }
}
