// SpanEncoderFactory.swift
//
// Builds the `SpanEncoder` for a registry row from a model directory. The
// factory lives in CorpusKitProviders (not the CorpusKit core target)
// because it instantiates the concrete seam (`CoreAISpanInference`); the
// contract types it returns live in the core target
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
    /// 4. the `.aimodel` present and loadable through the Core AI seam
    ///    (ADR-028 E4, ADR-029) → else `modelUnavailable` / `loadFailed`.
    ///
    /// - Parameter batchSize: spans per inference batch (`encoder_batch`).
    public static func make(
        spec: EncoderModelSpec,
        modelDirectory: URL,
        batchSize: Int = ProviderSpanEncoder.defaultBatchSize
    ) async throws -> any SpanEncoder {
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
        // ADR-029: one runtime. The Core AI seam batches a chunk through the
        // `.aimodel` beside `vocab.txt`; a directory without it is
        // `modelUnavailable`, named by the seam.
        let inference = try await CoreAISpanInference(
            modelDirectory: modelDirectory, spec: spec, tokenizer: tokenizer)
        return ProviderSpanEncoder(spec: spec, inference: inference, batchSize: batchSize)
    }

    /// Lowercase SHA-256 hex of `data`, through the substrate's SHA256 so
    /// both ports hash the vocabulary with the same conformance-gated
    /// primitive.
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
}
