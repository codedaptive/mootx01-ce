// DeterministicTokenizer.swift
//
// Deterministic, model-agnostic tokenizer used as a test fixture
// and as the v1.0 stand-in until model-specific tokenizers
// (BERT WordPiece, SentencePiece) land. Maps each whitespace-and-
// punctuation token to a stable hash-folded id in [2, vocabSize)
// (IDs 0 and 1 are reserved for PAD/UNK; empty input returns padTokenID).
//
// The MiniLM, MPNet, and EmbeddingGemma provider initializers already
// default to DeterministicTokenizer; no further migration is pending.

import Foundation
import CorpusKit
import SubstrateTypes

public struct DeterministicTokenizer: Tokenizer {
    public let vocabID: String
    public let vocabSize: Int32
    public let maxTokens: Int
    public let padTokenID: Int32 = 0
    public let unknownTokenID: Int32 = 1

    public init(
        vocabID: String = "deterministic-v1",
        vocabSize: Int32 = 30522,
        maxTokens: Int = 128
    ) {
        self.vocabID = vocabID
        self.vocabSize = vocabSize
        self.maxTokens = maxTokens
    }

    public func tokenize(_ text: String) -> [Int32] {
        let words = keywordTokens(text)
        var out: [Int32] = []
        out.reserveCapacity(min(words.count, maxTokens))
        for word in words {
            // FNV-1a 32-bit (SubstrateLib, I-25), modded into the
            // tokenizer's id range with ids 0/1 reserved for PAD/UNK.
            let hash = FNV.hash32(word)
            let id = Int32(hash % UInt32(vocabSize - 2)) + 2
            out.append(id)
            if out.count >= maxTokens { break }
        }
        if out.isEmpty { out.append(padTokenID) }
        return out
    }
}
