// CoreMLPairInference.swift
//
// Host-side CoreML inference for a cross encoder: loads the compiled
// sequence classifier in a model directory, tokenizes every (query, span)
// pair with the directory's WordPiece vocabulary and returns one relevance
// logit per pair. The kit does not bundle weights; the packaging pipeline
// (`tools/encoder-models`, profile `minilm-cross`) places
// `<artifactName>.mlmodelc` and `vocab.txt` in the directory the model
// directory resolver hands back.
//
// Compiled only where CoreML exists. Elsewhere `PairScorerFactory.make`
// reports `EncoderError.modelUnavailable` and the rerank stage degrades.
//
// Mirror: rust-providers/src/candle_pair_scorer.rs.

#if canImport(CoreML)
import Foundation
import CoreML
import CorpusKit

/// CoreML-backed pair-logit inference over text pairs.
public struct CoreMLPairInference: PairInference {

    /// Input feature names the converted classifier exposes. Whichever
    /// exist on the loaded model are filled; the rest are ignored.
    static let inputIDsName = "input_ids"
    static let attentionMaskName = "attention_mask"
    static let tokenTypeIDsName = "token_type_ids"
    /// The output the converter names; when absent the first multi-array
    /// output is read, so a converter rename does not silently break.
    static let logitsName = "logits"

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

    private let box: ModelBox
    /// The pair tokenizer, built over the directory's `vocab.txt` with
    /// `maxTokens` = the profile's `maxSequence`.
    public let tokenizer: WordPieceTokenizer

    public var backend: String { "coreml" }

    /// The fixed sequence length this model was compiled for, when its
    /// `input_ids` shape is static (`[1, L]`); `nil` when the model
    /// accepts variable-length inputs.
    ///
    /// Swift derives this value from the CoreML `input_ids` shape constraint
    /// (enumerated or range). The Rust candle backend derives the same ceiling
    /// from `max_position_embeddings` in `config.json`. The factory uses
    /// whichever value it has to clamp `maxTokens` on the tokenizer so encoded
    /// pairs never exceed the model's positional embedding ceiling.
    public var fixedLength: Int? { box.fixedLength }

    /// Load the compiled classifier in `modelDirectory`.
    ///
    /// - Throws: `EncoderError.modelUnavailable` when no model file exists,
    ///   `EncoderError.loadFailed` when CoreML rejects it or it exposes no
    ///   `input_ids` input.
    public static func make(modelDirectory: URL, tokenizer: WordPieceTokenizer) throws -> CoreMLPairInference {
        let modelURL = try CoreMLSpanInference.locateModel(in: modelDirectory)
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
        var fixedLength: Int? = nil
        if let constraint = idsInput.multiArrayConstraint {
            switch constraint.shapeConstraint.type {
            case .enumerated:
                fixedLength = CoreMLSpanInference.fixedSequenceLength(
                    enumeratedShapes: constraint.shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) })
            case .range:
                fixedLength = CoreMLSpanInference.fixedSequenceLength(
                    sizeRanges: constraint.shapeConstraint.sizeRangeForDimension.map(\.rangeValue))
            case .unspecified:
                break
            @unknown default:
                break
            }
        }
        return CoreMLPairInference(
            box: ModelBox(model: model, inputNames: Set(inputs.keys), fixedLength: fixedLength),
            tokenizer: tokenizer)
    }

    private init(box: ModelBox, tokenizer: WordPieceTokenizer) {
        self.box = box
        self.tokenizer = tokenizer
    }

    /// Return a new `CoreMLPairInference` that shares this instance's loaded
    /// `ModelBox` but uses a different tokenizer.
    ///
    /// Used by `PairScorerFactory` to rebuild the tokenizer with a clamped
    /// `maxTokens` when `fixedLength < profile.maxSequence`, without loading
    /// the model binary a second time.
    func rebuilding(tokenizer newTokenizer: WordPieceTokenizer) -> CoreMLPairInference {
        CoreMLPairInference(box: box, tokenizer: newTokenizer)
    }

    /// One prediction per pair. CoreML's converted classifier takes a fixed
    /// `[1, L]` shape, so the batch unit is the pair; the caller's
    /// `batchSize` only bounds how many pairs are tokenized at once.
    public func logits(query: String, spans: [String]) async throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(spans.count)
        for span in spans {
            out.append(try Self.predict(box: box, pair: tokenizer.tokenizePair(query, span), padTokenID: tokenizer.padTokenID))
        }
        return out
    }

    /// The `[1, L]` inputs for one pair: ids, mask and segment ids, padded
    /// or truncated to the model's fixed length when it has one.
    struct PreparedInputs: Equatable {
        let ids: [Int32]
        let attentionMask: [Int32]
        let tokenTypeIDs: [Int32]
    }

    static func prepareInputs(pair: PairTokens, padTokenID: Int32, fixedLength: Int?) -> PreparedInputs {
        let length = fixedLength ?? pair.ids.count
        var ids = Array(pair.ids.prefix(length))
        var types = Array(pair.tokenTypeIDs.prefix(length))
        let realCount = ids.count
        if ids.count < length {
            ids += [Int32](repeating: padTokenID, count: length - ids.count)
            types += [Int32](repeating: 0, count: length - types.count)
        }
        return PreparedInputs(
            ids: ids,
            attentionMask: (0..<length).map { $0 < realCount ? 1 : 0 },
            tokenTypeIDs: types)
    }

    /// One prediction: build the declared Int32 inputs, run, read the single
    /// logit. A classifier output that is not exactly one scalar is a
    /// mis-converted model and fails loudly.
    private static func predict(box: ModelBox, pair: PairTokens, padTokenID: Int32) throws -> Float {
        let prepared = prepareInputs(pair: pair, padTokenID: padTokenID, fixedLength: box.fixedLength)
        let length = prepared.ids.count
        var features: [String: MLFeatureValue] = [:]
        do {
            let idsArray = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            let maskArray = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            let typesArray = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            for i in 0..<length {
                idsArray[i] = NSNumber(value: prepared.ids[i])
                maskArray[i] = NSNumber(value: prepared.attentionMask[i])
                typesArray[i] = NSNumber(value: prepared.tokenTypeIDs[i])
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
        let name = output.featureValue(for: logitsName)?.multiArrayValue != nil
            ? logitsName
            : output.featureNames.sorted().first(where: { output.featureValue(for: $0)?.multiArrayValue != nil })
        guard let name, let array = output.featureValue(for: name)?.multiArrayValue else {
            throw EncoderError.inferenceFailed("prediction returned no multi-array output")
        }
        let scalars = MLShapedArray<Float>(array).scalars
        guard scalars.count == 1 else {
            throw EncoderError.inferenceFailed("classifier output carries \(scalars.count) values, expected 1")
        }
        return scalars[0]
    }
}
#endif
