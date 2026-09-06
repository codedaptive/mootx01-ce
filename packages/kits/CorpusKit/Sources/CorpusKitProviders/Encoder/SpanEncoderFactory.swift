// SpanEncoderFactory.swift
//
// Builds the `SpanEncoder` for a registry row from a model directory. The
// factory lives in CorpusKitProviders (not the CorpusKit core target)
// because it instantiates the concrete provider (`MiniLMTextProvider` over
// CoreML inference); the contract types it returns live in the core target
// so the recall stage and the duty never import the providers.
//
// Mirror: rust-providers/src/span_encoder_factory.rs.

import Foundation
import CorpusKit
import SubstrateKernel

/// Model-directory → `SpanEncoder`.
public enum SpanEncoderFactory {

    /// The vendored vocabulary file every model directory carries; its
    /// SHA-256 hex digest must equal `EncoderModelSpec.tokenizerHash`.
    public static let vocabularyFileName = "vocab.txt"

    /// Build the encoder for `spec` from `modelDirectory`.
    ///
    /// Order of checks, each with its own failure class so the one log line
    /// the lifecycle emits names the real cause:
    /// 1. directory and `vocab.txt` present → else `modelUnavailable`;
    /// 2. `sha256(vocab.txt) == spec.tokenizerHash` → else `tokenizerMismatch`;
    /// 3. vocabulary parses (four special tokens) → else `loadFailed`;
    /// 4. CoreML model present and loadable → else `modelUnavailable` /
    ///    `loadFailed`; on a platform without CoreML → `modelUnavailable`.
    ///
    /// - Parameter batchSize: spans per inference batch (`encoder_batch`).
    public static func make(
        spec: EncoderModelSpec,
        modelDirectory: URL,
        batchSize: Int = ProviderSpanEncoder.defaultBatchSize
    ) throws -> any SpanEncoder {
        let vocabURL = modelDirectory.appendingPathComponent(vocabularyFileName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EncoderError.modelUnavailable("\(modelDirectory.path): no such directory")
        }
        guard let vocabData = FileManager.default.contents(atPath: vocabURL.path) else {
            throw EncoderError.modelUnavailable("\(vocabURL.path): missing")
        }
        let actual = hexDigest(of: vocabData)
        guard actual == spec.tokenizerHash else {
            throw EncoderError.tokenizerMismatch(expected: spec.tokenizerHash, actual: actual)
        }
        let tokenizer: WordPieceTokenizer
        do {
            tokenizer = try WordPieceTokenizer(
                contentsOf: vocabURL, vocabID: spec.modelID, maxTokens: spec.maxSequence)
        } catch {
            throw EncoderError.loadFailed("\(vocabURL.path): \(error)")
        }
#if canImport(CoreML)
        let inference = try CoreMLSpanInference.make(
            modelDirectory: modelDirectory, spec: spec, padTokenID: tokenizer.padTokenID)
        let provider = MiniLMTextProvider(
            modelID: spec.modelID,
            modelVersion: spec.modelVersion,
            tokenizer: tokenizer,
            inference: inference)
        return ProviderSpanEncoder(
            spec: spec,
            inference: EmbeddingProviderSpanInference(provider),
            batchSize: batchSize)
#else
        throw EncoderError.modelUnavailable("\(spec.modelID): no CoreML runtime on this platform")
#endif
    }

    /// Lowercase SHA-256 hex of `data`, through the substrate's SHA256 so
    /// both ports hash the vocabulary with the same conformance-gated
    /// primitive.
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
}
