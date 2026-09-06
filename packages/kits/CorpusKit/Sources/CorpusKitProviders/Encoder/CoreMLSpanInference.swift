// CoreMLSpanInference.swift
//
// Host-side CoreML inference for a span encoder: loads the compiled model
// in a model directory and returns the `([Int32]) async throws -> [Float]`
// closure `MiniLMTextProvider` takes. The kit does not bundle weights; the
// bundling unit places `<model>.mlmodelc` (or an `.mlpackage` to compile on
// first use) and `vocab.txt` in the directory the estate's model-directory
// resolver hands back.
//
// Compiled only where CoreML exists. Elsewhere `SpanEncoderFactory.make`
// reports `EncoderError.modelUnavailable` and recall stays lexical-only.

#if canImport(CoreML)
import Foundation
import CoreML
import CorpusKit

/// CoreML-backed pooled inference over token ids.
public enum CoreMLSpanInference {

    /// The inference closure shape the host satisfies: token ids in, ONE
    /// pooled `spec.dim` vector out (not yet L2-normalised).
    public typealias Inference = @Sendable ([Int32]) async throws -> [Float]

    /// Input feature names the converted model may expose. Whichever of the
    /// three exist on the loaded model are filled; the rest are ignored.
    static let inputIDsName = "input_ids"
    static let attentionMaskName = "attention_mask"
    static let tokenTypeIDsName = "token_type_ids"

    /// `MLModel` is documented thread-safe for `prediction(from:)` but is
    /// not marked `Sendable`; the box states that guarantee to the compiler.
    private final class ModelBox: @unchecked Sendable {
        let model: MLModel
        let inputNames: Set<String>
        /// Fixed sequence length when the model's `input_ids` shape is
        /// static (`[1, L]`); `nil` when the model accepts any length.
        let fixedLength: Int?
        init(model: MLModel, inputNames: Set<String>, fixedLength: Int?) {
            self.model = model
            self.inputNames = inputNames
            self.fixedLength = fixedLength
        }
    }

    /// Load the compiled model in `modelDirectory` and return the inference
    /// closure. The closure pads or truncates to the model's fixed sequence
    /// length when it has one, runs one prediction per call and pools the
    /// output per `spec.pooling` when the model returns the token matrix.
    ///
    /// - Parameters:
    ///   - modelDirectory: directory holding `*.mlmodelc` (preferred) or
    ///     `*.mlpackage` / `*.mlmodel` (compiled on first use).
    ///   - spec: the registry row; supplies `dim`, `pooling`, `maxSequence`.
    ///   - padTokenID: the tokenizer's `[PAD]` id used to fill a fixed shape.
    /// - Throws: `EncoderError.modelUnavailable` when no model file exists,
    ///   `EncoderError.loadFailed` when CoreML rejects it or it exposes no
    ///   `input_ids` input.
    public static func make(modelDirectory: URL, spec: EncoderModelSpec, padTokenID: Int32) throws -> Inference {
        let modelURL = try locateModel(in: modelDirectory)
        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL, configuration: MLModelConfiguration())
        } catch {
            throw EncoderError.loadFailed("\(modelURL.lastPathComponent): \(error)")
        }
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let idsInput = inputs[inputIDsName] else {
            throw EncoderError.loadFailed(
                "\(modelURL.lastPathComponent): no '\(inputIDsName)' input (inputs: \(inputs.keys.sorted()))")
        }
        // A static shape ([1, L]) means every call must be exactly L long;
        // flexible (enumerated / range) shapes take the real token count.
        var fixedLength: Int? = nil
        if let constraint = idsInput.multiArrayConstraint,
           constraint.shapeConstraint.type == .unspecified,
           let last = constraint.shape.last?.intValue, last > 1 {
            fixedLength = last
        }
        let box = ModelBox(model: model, inputNames: Set(inputs.keys), fixedLength: fixedLength)
        let dim = spec.dim
        let pooling = spec.pooling
        return { tokenIDs in
            try predict(box: box, tokenIDs: tokenIDs, padTokenID: padTokenID, dim: dim, pooling: pooling)
        }
    }

    /// First `*.mlmodelc` in the directory; otherwise compile the first
    /// `*.mlpackage` / `*.mlmodel`. Directory listing failures and an empty
    /// directory are both "model unavailable".
    static func locateModel(in directory: URL) throws -> URL {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw EncoderError.modelUnavailable("\(directory.path): \(error)")
        }
        if let compiled = entries.first(where: { $0.pathExtension == "mlmodelc" }) {
            return compiled
        }
        if let source = entries.first(where: { $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodel" }) {
            do {
                return try MLModel.compileModel(at: source)
            } catch {
                throw EncoderError.loadFailed("compiling \(source.lastPathComponent): \(error)")
            }
        }
        throw EncoderError.modelUnavailable("\(directory.path): no .mlmodelc / .mlpackage / .mlmodel")
    }

    /// One prediction. Builds the `[1, L]` Int32 inputs the model declares,
    /// runs it, and reduces the first multi-array output to `dim` floats.
    private static func predict(
        box: ModelBox, tokenIDs: [Int32], padTokenID: Int32, dim: Int, pooling: EncoderModelSpec.Pooling
    ) throws -> [Float] {
        let length = box.fixedLength ?? max(1, tokenIDs.count)
        var ids = Array(tokenIDs.prefix(length))
        let realCount = ids.count
        if ids.count < length { ids += [Int32](repeating: padTokenID, count: length - ids.count) }

        var features: [String: MLFeatureValue] = [:]
        do {
            let idsArray = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            let maskArray = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            let typesArray = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            for i in 0..<length {
                idsArray[i] = NSNumber(value: ids[i])
                maskArray[i] = NSNumber(value: i < realCount ? 1 : 0)
                typesArray[i] = 0
            }
            features[inputIDsName] = MLFeatureValue(multiArray: idsArray)
            if box.inputNames.contains(attentionMaskName) {
                features[attentionMaskName] = MLFeatureValue(multiArray: maskArray)
            }
            if box.inputNames.contains(tokenTypeIDsName) {
                features[tokenTypeIDsName] = MLFeatureValue(multiArray: typesArray)
            }
        } catch {
            throw EncoderError.inferenceFailed("building inputs: \(error)")
        }

        let output: MLFeatureProvider
        do {
            output = try box.model.prediction(from: try MLDictionaryFeatureProvider(dictionary: features))
        } catch {
            throw EncoderError.inferenceFailed("prediction: \(error)")
        }
        guard let name = output.featureNames.sorted().first(where: { output.featureValue(for: $0)?.multiArrayValue != nil }),
              let array = output.featureValue(for: name)?.multiArrayValue else {
            throw EncoderError.inferenceFailed("prediction returned no multi-array output")
        }
        // MLShapedArray converts float16 / double outputs to Float uniformly.
        let shaped = MLShapedArray<Float>(array)
        let shape = shaped.shape
        let scalars = shaped.scalars
        if shape.count == 3, shape[2] == dim {
            // Token matrix [1, L, dim]: pool here per the spec.
            let seq = shape[1]
            switch pooling {
            case .cls:
                return Array(scalars[0..<dim])
            case .mean:
                var sum = [Float](repeating: 0, count: dim)
                let positions = min(realCount, seq)
                for p in 0..<positions {
                    let base = p * dim
                    for d in 0..<dim { sum[d] += scalars[base + d] }
                }
                let divisor = Float(max(1, positions))
                return sum.map { $0 / divisor }
            }
        }
        if shape.count == 2, shape[1] == dim {
            return Array(scalars[0..<dim])    // already pooled [1, dim]
        }
        if scalars.count == dim {
            return scalars                    // flat [dim]
        }
        throw EncoderError.inferenceFailed("output shape \(shape) does not carry dim \(dim)")
    }
}
#endif
