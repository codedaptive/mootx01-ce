// PairScorerFactory.swift
//
// Builds the `PairScorer` for a cross-encoder profile from a model
// directory. The factory lives in CorpusKitProviders (not the CorpusKit
// core target) because it instantiates the Core AI runtime; the contract
// types it returns live in the core target so the rerank stage never
// imports the providers.
//
// Mirror: rust-providers/src/pair_scorer_factory.rs.

import Foundation
import CorpusKit

/// Model-directory → `PairScorer`.
public enum PairScorerFactory {

    // MARK: - Public production API

    /// Build the scorer for `profile` from `modelDirectory`.
    ///
    /// Order of checks, each with its own failure class so the one log line
    /// the lifecycle emits names the real cause:
    /// 1. directory and `vocab.txt` present → else `modelUnavailable`;
    /// 2. `sha256(vocab.txt) == profile.tokenizerHash` → else `tokenizerMismatch`;
    /// 3. vocabulary parses (four special tokens) → else `loadFailed`;
    /// 4. the `.aimodel` classifier present and loadable through the Core AI
    ///    seam (ADR-029) → else `modelUnavailable` / `loadFailed`.
    ///
    /// `maxTokens` for the tokenizer is clamped to the smaller of
    /// `profile.maxSequence` and the inference's compiled fixed length. The
    /// Core AI asset is dynamic (`fixedLength` nil), so the profile alone
    /// clamps in production; the Rust factory reads its ceiling from
    /// `max_position_embeddings` in `config.json`.
    ///
    /// - Parameter batchSize: pairs per scorer batch.
    public static func make(
        profile: CrossEncoderProfile,
        modelDirectory: URL,
        batchSize: Int = ProviderPairScorer.defaultBatchSize
    ) async throws -> any PairScorer {
        try await _make(profile: profile, modelDirectory: modelDirectory,
                        batchSize: batchSize, makeInference: nil)
    }

#if DEBUG
    // MARK: - Test seam (DEBUG only — not product API)

    /// Build the scorer using an injectable inference constructor.
    ///
    /// Test seam. Not product API. Gated `#if DEBUG` to match the Rust port
    /// (which carries no unconditional public seam on the factory).
    ///
    /// An injected inference brings its own tokenizer, so the directory and
    /// vocabulary guards are bypassed. The seam takes precedence over the
    /// resolver: when this overload is used the production Core AI path is
    /// never reached. The closure is called once with a probe tokenizer to
    /// read `fixedLength`; if clamping applies it is called a second time with
    /// a tokenizer whose `maxTokens` equals the clamped value.
    ///
    /// Production callers use `make(profile:modelDirectory:batchSize:)`.
    public static func make(
        profile: CrossEncoderProfile,
        modelDirectory: URL,
        batchSize: Int = ProviderPairScorer.defaultBatchSize,
        makeInference: @escaping (URL, WordPieceTokenizer) throws -> any PairInference
    ) async throws -> any PairScorer {
        try await _make(profile: profile, modelDirectory: modelDirectory,
                        batchSize: batchSize, makeInference: makeInference)
    }
#endif

    // MARK: - Implementation

    private static func _make(
        profile: CrossEncoderProfile,
        modelDirectory: URL,
        batchSize: Int,
        makeInference: ((URL, WordPieceTokenizer) throws -> any PairInference)?
    ) async throws -> any PairScorer {
        // Two constructors, one clamp path. Each constructor yields the initial
        // inference plus a rebuild closure that produces the same inference over
        // a tokenizer with a different `maxTokens`; everything after that is
        // shared, so the clamp is computed and applied in exactly one place.
        let initial: any PairInference
        let rebuild: (Int) async throws -> any PairInference
        if let inject = makeInference {
            // Injected constructor: the inference brings its own tokenizer, so
            // the directory and vocabulary guards apply only to the Core AI path
            // below. The seam takes precedence over the resolver.
            let minimal = ["[PAD]", "[UNK]", "[CLS]", "[SEP]"]
            let probe = { (maxTokens: Int) throws -> any PairInference in
                try inject(modelDirectory,
                           try WordPieceTokenizer(vocabularyLines: minimal,
                                                  vocabID: profile.modelID,
                                                  maxTokens: maxTokens))
            }
            initial = try probe(profile.maxSequence)
            rebuild = { try probe($0) }
        } else {
            // Production path (ADR-029): the Core AI seam over the `.aimodel`.
            // The asset is dynamic in both axes, so `fixedLength` is nil and
            // the clamp below never fires; the branch stays for an injected
            // inference that reports a compiled length.
            let vocabURL = try verifiedVocabulary(modelDirectory: modelDirectory, profile: profile)
            initial = try await CoreAIPairInference(
                modelDirectory: modelDirectory, modelID: profile.modelID,
                tokenizer: try buildTokenizer(vocabURL: vocabURL, profile: profile, fixedLength: nil))
            rebuild = { maxTokens in
                try await CoreAIPairInference(
                    modelDirectory: modelDirectory, modelID: profile.modelID,
                    tokenizer: try buildTokenizer(vocabURL: vocabURL, profile: profile, fixedLength: maxTokens))
            }
        }
        // The one clamp: the model's position limit caps the profile's nominal
        // pair budget. Mutation gate: removing this branch leaves every scorer at
        // `profile.maxSequence`; the clamp test asserts the clamped value.
        let effectiveMax = initial.fixedLength.map { min(profile.maxSequence, $0) } ?? profile.maxSequence
        let inference = effectiveMax < profile.maxSequence ? try await rebuild(effectiveMax) : initial
        return ProviderPairScorer(profile: profile, inference: inference, batchSize: batchSize)
    }

    /// The directory and vocabulary guards of the production path: the model
    /// directory must exist and its `vocab.txt` must hash to the profile's
    /// `tokenizerHash`; returns the vocabulary URL.
    private static func verifiedVocabulary(modelDirectory: URL, profile: CrossEncoderProfile) throws -> URL {
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
        return vocabURL
    }

    private static func buildTokenizer(
        vocabURL: URL, profile: CrossEncoderProfile, fixedLength: Int?
    ) throws -> WordPieceTokenizer {
        let maxTokens = fixedLength ?? profile.maxSequence
        do {
            return try WordPieceTokenizer(contentsOf: vocabURL, vocabID: profile.modelID, maxTokens: maxTokens)
        } catch {
            throw EncoderError.loadFailed("\(vocabURL.path): \(error)")
        }
    }
}
