// CoreAISpanInference.swift
//
// The batched span-encoder seam on the Core AI framework (ADR-028 E3, E4).
// Loads the `<artifact>.aimodel` the bundling unit places beside `vocab.txt`
// and runs ONE inference per chunk of texts: Int32 `input_ids` and
// `attention_mask` of shape `[B, L]`, L the longest tokenised text of the
// chunk (E3), and reads the `pooled` output of shape `[B, dim]` (E4). The
// asset is exported float32 with the profile's pooling (CLS for Arctic,
// masked mean for MiniLM) baked in, by
// `tools/encoder-models/export-coreai.py`, so a padded row cannot be pooled
// wrongly here and nothing is reduced on this side.
//
// The one Apple seam (ADR-029): the product floor is macOS 27 and iOS 27,
// where Core AI is present. ADR-028 records the measured agreement with the
// retired CoreML seam (float32 noise) and the clock.

import Foundation
import CorpusKit

import CoreAI

/// Core AI-backed pooled inference over a batch of texts.
public final class CoreAISpanInference: SpanInference, @unchecked Sendable {

    /// The input and output names the export fixes (`export-coreai.py`).
    static let inputIDsName = "input_ids"
    static let attentionMaskName = "attention_mask"
    static let pooledName = "pooled"
    /// The upper bound of the asset's dynamic batch axis; the export sets 64.
    /// A chunk above it is split, so `encoder_batch` may exceed it safely.
    static let maxBatch = 64

    private let function: InferenceFunction
    private let tokenizer: any Tokenizer
    private let dim: Int
    private let modelID: String

    /// Load `<artifact>.aimodel` from `modelDirectory`.
    ///
    /// - Throws: `EncoderError.modelUnavailable` when the directory holds no
    ///   `.aimodel`, `EncoderError.loadFailed` when the framework rejects it
    ///   or its `main` function lacks the two inputs and the pooled output.
    public init(modelDirectory: URL, spec: EncoderModelSpec, tokenizer: any Tokenizer) async throws {
        let assetURL = try Self.locateAsset(in: modelDirectory)
        let model: AIModel
        do {
            // A 33M-parameter encoder with dynamic shapes; the Neural Engine is
            // the preferred unit, the runtime falls back where a graph cannot
            model = try await AIModel(
                contentsOf: assetURL, options: SpecializationOptions(preferredComputeUnitKind: .neuralEngine))
        } catch {
            throw EncoderError.loadFailed("\(assetURL.lastPathComponent): \(error)")
        }
        guard let function = try model.loadFunction(named: "main") else {
            throw EncoderError.loadFailed("\(assetURL.lastPathComponent): no 'main' function")
        }
        let inputs = Set(function.descriptor.inputNames)
        guard inputs.contains(Self.inputIDsName), inputs.contains(Self.attentionMaskName) else {
            throw EncoderError.loadFailed(
                "\(assetURL.lastPathComponent): inputs \(inputs.sorted()) lack '\(Self.inputIDsName)' and '\(Self.attentionMaskName)'")
        }
        guard function.descriptor.outputNames.contains(Self.pooledName) else {
            throw EncoderError.loadFailed(
                "\(assetURL.lastPathComponent): outputs \(function.descriptor.outputNames) lack '\(Self.pooledName)'")
        }
        self.function = function
        self.tokenizer = tokenizer
        self.dim = spec.dim
        self.modelID = spec.modelID
    }

    /// The `.aimodel` in `directory`, if any.
    static func locateAsset(in directory: URL) throws -> URL {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw EncoderError.modelUnavailable("\(directory.path): \(error)")
        }
        guard let asset = entries.first(where: { $0.pathExtension == "aimodel" }) else {
            throw EncoderError.modelUnavailable("\(directory.path): no .aimodel")
        }
        return asset
    }

    public func pooledBatch(_ texts: [String]) async throws -> [[Float]] {
        var out = [[Float]](repeating: [], count: texts.count)
        // Empty text has no vector (the `SpanInference` contract); only the
        // rest is tokenised and sent.
        var live: [(index: Int, tokens: [Int32])] = []
        for (index, text) in texts.enumerated() where !text.isEmpty {
            live.append((index, tokenizer.tokenize(text)))
        }
        var start = 0
        while start < live.count {
            let end = min(start + Self.maxBatch, live.count)
            let chunk = live[start..<end]
            let batch = Self.batchInputs(tokenLists: chunk.map(\.tokens), padTokenID: tokenizer.padTokenID)
            let vectors = try await run(batch)
            for (offset, entry) in chunk.enumerated() {
                out[entry.index] = vectors[offset]
            }
            start = end
        }
        return out
    }

    /// The `[B, L]` row-major buffers for one chunk: every row padded to the
    /// chunk's longest token list with `padTokenID`, attention 1 on real
    /// tokens and 0 on the pad. A token list that is empty (text with no
    /// tokens) becomes one masked pad token, so
    /// every row has a position for the model to read.
    struct BatchInputs: Equatable {
        let rows: Int
        let length: Int
        let ids: [Int32]
        let mask: [Int32]
    }

    static func batchInputs(tokenLists: [[Int32]], padTokenID: Int32) -> BatchInputs {
        let length = max(1, tokenLists.map(\.count).max() ?? 0)
        var ids = [Int32](repeating: padTokenID, count: tokenLists.count * length)
        var mask = [Int32](repeating: 0, count: tokenLists.count * length)
        for (row, tokens) in tokenLists.enumerated() {
            let base = row * length
            for (i, token) in tokens.enumerated() {
                ids[base + i] = token
                mask[base + i] = 1
            }
        }
        return BatchInputs(rows: tokenLists.count, length: length, ids: ids, mask: mask)
    }

    /// One inference: fill the two inputs through their storage, run, read
    /// `[B, dim]` back row by row.
    private func run(_ batch: BatchInputs) async throws -> [[Float]] {
        let shape = [batch.rows, batch.length]
        var inputs: [String: NDArray] = [:]
        do {
            inputs[Self.inputIDsName] = try makeInput(named: Self.inputIDsName, shape: shape, values: batch.ids)
            inputs[Self.attentionMaskName] = try makeInput(named: Self.attentionMaskName, shape: shape, values: batch.mask)
        } catch {
            throw EncoderError.inferenceFailed("\(modelID): building inputs: \(error)")
        }
        let pooledValue: NDArray?
        do {
            var outputs = try await function.run(inputs: inputs)
            pooledValue = outputs.remove(Self.pooledName)?.ndArray
        } catch {
            throw EncoderError.inferenceFailed("\(modelID): prediction: \(error)")
        }
        guard let pooled = pooledValue else {
            throw EncoderError.inferenceFailed("\(modelID): prediction returned no '\(Self.pooledName)' output")
        }
        guard pooled.scalarType == .float32 else {
            throw EncoderError.inferenceFailed("\(modelID): '\(Self.pooledName)' is \(pooled.scalarType), expected float32")
        }
        let flat: [Float] = pooled.view(as: Float.self).withUnsafePointer { ptr, shape, strides in
            precondition(shape.count == 2, "pooled output must be rank 2")
            var values = [Float](repeating: 0, count: shape[0] * shape[1])
            for r in 0..<shape[0] {
                for c in 0..<shape[1] {
                    values[r * shape[1] + c] = ptr[r * strides[0] + c * strides[1]]
                }
            }
            return values
        }
        guard flat.count == batch.rows * dim else {
            throw EncoderError.inferenceFailed(
                "\(modelID): '\(Self.pooledName)' holds \(flat.count) floats for \(batch.rows) rows of \(dim)")
        }
        return (0..<batch.rows).map { row in Array(flat[(row * dim)..<((row + 1) * dim)]) }
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
