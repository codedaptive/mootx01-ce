// PairScorerFactory.swift
//
// Builds the `PairScorer` for a cross-encoder profile from a model
// directory. The factory lives in CorpusKitProviders (not the CorpusKit
// core target) because it instantiates the CoreML runtime; the contract
// types it returns live in the core target so the rerank stage never
// imports the providers.
//
// Mirror: rust-providers/src/pair_scorer_factory.rs.

import Foundation
import CorpusKit

/// Model-directory → `PairScorer`.
public enum PairScorerFactory {

    /// Build the scorer for `profile` from `modelDirectory`.
    ///
    /// Order of checks, each with its own failure class so the one log line
    /// the lifecycle emits names the real cause:
    /// 1. directory and `vocab.txt` present → else `modelUnavailable`;
    /// 2. `sha256(vocab.txt) == profile.tokenizerHash` → else `tokenizerMismatch`;
    /// 3. vocabulary parses (four special tokens) → else `loadFailed`;
    /// 4. CoreML classifier present and loadable → else `modelUnavailable` /
    ///    `loadFailed`; on a platform without CoreML → `modelUnavailable`.
    ///
    /// - Parameter batchSize: pairs per scorer batch.
    public static func make(
        profile: CrossEncoderProfile,
        modelDirectory: URL,
        batchSize: Int = ProviderPairScorer.defaultBatchSize
    ) throws -> any PairScorer {
        let vocabURL = modelDirectory.appendingPathComponent(SpanEncoderFactory.vocabularyFileName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EncoderError.modelUnavailable("\(modelDirectory.path): no such directory")
        }
        guard let vocabData = FileManager.default.contents(atPath: vocabURL.path) else {
            throw EncoderError.modelUnavailable("\(vocabURL.path): missing")
        }
        let actual = SpanEncoderFactory.hexDigest(of: vocabData)
        guard actual == profile.tokenizerHash else {
            throw EncoderError.tokenizerMismatch(expected: profile.tokenizerHash, actual: actual)
        }
        let tokenizer: WordPieceTokenizer
        do {
            tokenizer = try WordPieceTokenizer(
                contentsOf: vocabURL, vocabID: profile.modelID, maxTokens: profile.maxSequence)
        } catch {
            throw EncoderError.loadFailed("\(vocabURL.path): \(error)")
        }
#if canImport(CoreML)
        let inference = try CoreMLPairInference.make(modelDirectory: modelDirectory, tokenizer: tokenizer)
        return ProviderPairScorer(profile: profile, inference: inference, batchSize: batchSize)
#else
        throw EncoderError.modelUnavailable("\(profile.modelID): no CoreML runtime on this platform")
#endif
    }
}
