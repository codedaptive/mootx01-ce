// CoreAIPairInference.swift
//
// The cross encoder's pair-logit seam on the Core AI framework (ADR-029 D2).
// Loads the `<artifact>.aimodel` the bundling unit places beside `vocab.txt`
// and scores ONE chunk of pairs per inference: Int32 `input_ids`,
// `attention_mask` and `token_type_ids` of shape `[B, L]`, L the longest
// pair of the chunk, reading the `logits` output of shape `[B]`. The asset is
// exported float32 with the classifier's own pooler and head inside, by
// `tools/encoder-models/export-coreai.py --kind cross-encoder`.
//
// The batch unit is the chunk `ProviderPairScorer` hands over (`batchSize`
// pairs); a chunk above the asset's batch bound is split here. The asset is
// dynamic in both axes, so `fixedLength` reports `nil` and the profile's
// `maxSequence` is the tokenizer's clamp.

import Foundation
import CoreAI
import CorpusKit

/// Core AI-backed pair-logit inference over text pairs.
public final class CoreAIPairInference: PairInference, @unchecked Sendable {

    /// The input and output names the export fixes.
    static let inputIDsName = "input_ids"
    static let attentionMaskName = "attention_mask"
    static let tokenTypeIDsName = "token_type_ids"
    static let logitsName = "logits"
    /// The upper bound of the asset's dynamic batch axis; the export sets 64.
    static let maxBatch = 64

    public let backend = "coreai"
    /// Dynamic asset: no compiled fixed length. The factory clamps to the
    /// profile's `maxSequence` alone.
    public var fixedLength: Int? { nil }

    private let function: InferenceFunction
    /// The pair tokenizer, `maxTokens` = the profile's `maxSequence`.
    public let tokenizer: WordPieceTokenizer
    private let modelID: String

    /// Load `<artifact>.aimodel` from `modelDirectory`.
    ///
    /// - Throws: `EncoderError.modelUnavailable` when the directory holds no
    ///   `.aimodel`, `EncoderError.loadFailed` when the framework rejects it
    ///   or its `main` function lacks the three inputs or the logits output.
    public init(modelDirectory: URL, modelID: String, tokenizer: WordPieceTokenizer) async throws {
        let assetURL = try CoreAISpanInference.locateAsset(in: modelDirectory)
        let model: AIModel
        do {
            // A 22M-parameter classifier with dynamic shapes; the Neural
            // Engine is the preferred unit, the runtime falls back where a
            // graph cannot run there.
            model = try await AIModel(
                contentsOf: assetURL, options: SpecializationOptions(preferredComputeUnitKind: .neuralEngine))
        } catch {
            throw EncoderError.loadFailed("\(assetURL.lastPathComponent): \(error)")
        }
        guard let function = try model.loadFunction(named: "main") else {
            throw EncoderError.loadFailed("\(assetURL.lastPathComponent): no 'main' function")
        }
        let inputs = Set(function.descriptor.inputNames)
        for name in [Self.inputIDsName, Self.attentionMaskName, Self.tokenTypeIDsName] where !inputs.contains(name) {
            throw EncoderError.loadFailed("\(assetURL.lastPathComponent): inputs \(inputs.sorted()) lack '\(name)'")
        }
        guard function.descriptor.outputNames.contains(Self.logitsName) else {
            throw EncoderError.loadFailed(
                "\(assetURL.lastPathComponent): outputs \(function.descriptor.outputNames) lack '\(Self.logitsName)'")
        }
        self.function = function
        self.tokenizer = tokenizer
        self.modelID = modelID
    }

    public func logits(query: String, spans: [String]) async throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(spans.count)
        var start = 0
        while start < spans.count {
            let end = min(start + Self.maxBatch, spans.count)
            let pairs = spans[start..<end].map { tokenizer.tokenizePair(query, $0) }
            let batch = Self.batchInputs(pairs: pairs, padTokenID: tokenizer.padTokenID)
            out += try await run(batch)
            start = end
        }
        return out
    }

    /// The `[B, L]` row-major buffers for one chunk of pairs: every row
    /// padded to the chunk's longest pair with `padTokenID`, attention 1 on
    /// real tokens and 0 on the pad, segment ids 0 on the pad. An empty pair
    /// becomes one masked pad position so every row has a position to read.
    struct BatchInputs: Equatable {
        let rows: Int
        let length: Int
        let ids: [Int32]
        let mask: [Int32]
        let types: [Int32]
    }

    static func batchInputs(pairs: [PairTokens], padTokenID: Int32) -> BatchInputs {
        let length = max(1, pairs.map(\.ids.count).max() ?? 0)
        var ids = [Int32](repeating: padTokenID, count: pairs.count * length)
        var mask = [Int32](repeating: 0, count: pairs.count * length)
        var types = [Int32](repeating: 0, count: pairs.count * length)
        for (row, pair) in pairs.enumerated() {
            let base = row * length
            for (i, token) in pair.ids.enumerated() {
                ids[base + i] = token
                mask[base + i] = 1
                types[base + i] = i < pair.tokenTypeIDs.count ? pair.tokenTypeIDs[i] : 0
            }
        }
        return BatchInputs(rows: pairs.count, length: length, ids: ids, mask: mask, types: types)
    }

    /// One inference: fill the three inputs through their storage, run,
    /// read the `[B]` logits back.
    private func run(_ batch: BatchInputs) async throws -> [Float] {
        let shape = [batch.rows, batch.length]
        var inputs: [String: NDArray] = [:]
        do {
            inputs[Self.inputIDsName] = try makeInput(named: Self.inputIDsName, shape: shape, values: batch.ids)
            inputs[Self.attentionMaskName] = try makeInput(named: Self.attentionMaskName, shape: shape, values: batch.mask)
            inputs[Self.tokenTypeIDsName] = try makeInput(named: Self.tokenTypeIDsName, shape: shape, values: batch.types)
        } catch {
            throw EncoderError.inferenceFailed("\(modelID): building inputs: \(error)")
        }
        let logitsValue: NDArray?
        do {
            var outputs = try await function.run(inputs: inputs)
            logitsValue = outputs.remove(Self.logitsName)?.ndArray
        } catch {
            throw EncoderError.inferenceFailed("\(modelID): prediction: \(error)")
        }
        guard let logits = logitsValue else {
            throw EncoderError.inferenceFailed("\(modelID): prediction returned no '\(Self.logitsName)' output")
        }
        guard logits.scalarType == .float32 else {
            throw EncoderError.inferenceFailed("\(modelID): '\(Self.logitsName)' is \(logits.scalarType), expected float32")
        }
        let values: [Float] = logits.view(as: Float.self).withUnsafePointer { ptr, outShape, strides in
            precondition(outShape.count == 1, "logits output must be rank 1")
            return (0..<outShape[0]).map { ptr[$0 * strides[0]] }
        }
        guard values.count == batch.rows else {
            throw EncoderError.inferenceFailed(
                "\(modelID): '\(Self.logitsName)' holds \(values.count) values for \(batch.rows) pairs")
        }
        return values
    }

    /// An Int32 `[B, L]` input filled through its storage, stride-aware.
    private func makeInput(named name: String, shape: [Int], values: [Int32]) throws -> NDArray {
        guard case .ndArray(let descriptor) = function.descriptor.inputDescriptor(of: name) else {
            throw EncoderError.inferenceFailed("\(modelID): input '\(name)' is not an array")
        }
        let resolved = descriptor.resolvingDynamicDimensions(shape)
        var array = NDArray(descriptor: resolved)
        var view = array.mutableView(as: Int32.self)
        view.withUnsafeMutablePointer { ptr, arrayShape, strides in
            precondition(arrayShape.count == 2 && arrayShape[0] == shape[0] && arrayShape[1] == shape[1],
                         "input '\(name)' resolved to an unexpected shape")
            for r in 0..<shape[0] {
                for c in 0..<shape[1] {
                    ptr[r * strides[0] + c * strides[1]] = values[r * shape[1] + c]
                }
            }
        }
        return array
    }
}
