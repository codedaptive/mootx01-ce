// Real-artifact proof for the registry-driven Arctic span encoder.
// Enabled only when the parent task supplies the pinned model, ONNX reference,
// and an output path. The ordinary kit suite never loads model weights.

import Foundation
import Testing
import SubstrateKernel
@testable import CorpusKit
@testable import CorpusKitProviders

private let arcticFactoryProofEnabled =
    ProcessInfo.processInfo.environment["MOOT_ENCODER_PROOF"] == "1"

private struct ArcticReference: Decodable {
    let modelID: String
    let revision: String
    let dim: Int
    let pooling: String
    let queryPrefix: String
    let docPrefix: String
    let maxSequence: Int
    let tokenizerHash: String
    let entries: [ArcticReferenceEntry]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case revision, dim, pooling
        case queryPrefix = "query_prefix"
        case docPrefix = "doc_prefix"
        case maxSequence = "max_sequence"
        case tokenizerHash = "tokenizer_hash"
        case entries
    }
}

private struct ArcticReferenceEntry: Decodable {
    let kind: String
    let text: String
    let encodedText: String
    let vector: [Float]

    enum CodingKeys: String, CodingKey {
        case kind, text, vector
        case encodedText = "encoded_text"
    }
}

private struct ArcticTimingInput: Decodable {
    let sourcePoolSHA256: String
    let samples: [ArcticTimingSample]

    enum CodingKeys: String, CodingKey {
        case sourcePoolSHA256 = "source_pool_sha256"
        case samples
    }
}

private struct ArcticTimingSample: Decodable {
    let query: String
    let windows: [String]
}

private struct ArcticProofOutput: Encodable {
    let port: String
    let modelID: String
    let revision: String
    let coldLoadMS: Double
    let timingScope: String
    let timingSourcePoolSHA256: String
    let queryMS20: [Double]
    let windows750MS20: [Double]
    let queryPlusWindowsMS20: [Double]
    let medianQueryMS20: Double
    let medianWindows750MS20: Double
    let medianQueryPlusWindowsMS20: Double
    let auditionTotalMS: Double?
    let queryToSpanInt8Dot: [Float]
    let entries: [ArcticProofEntry]

    enum CodingKeys: String, CodingKey {
        case port, revision, entries
        case modelID = "model_id"
        case coldLoadMS = "cold_load_ms"
        case timingScope = "timing_scope"
        case timingSourcePoolSHA256 = "timing_source_pool_sha256"
        case queryMS20 = "query_ms_20"
        case windows750MS20 = "windows_750_ms_20"
        case queryPlusWindowsMS20 = "query_plus_windows_ms_20"
        case medianQueryMS20 = "median_query_ms_20"
        case medianWindows750MS20 = "median_windows_750_ms_20"
        case medianQueryPlusWindowsMS20 = "median_query_plus_windows_ms_20"
        case auditionTotalMS = "audition_total_ms"
        case queryToSpanInt8Dot = "query_to_span_int8_dot"
    }
}

private struct ArcticProofEntry: Encodable {
    let kind: String
    let text: String
    let cosineToONNX: Double
    let norm: Double
    let vector: [Float]
    let int8Q: [Int8]
    let int8Scale: Float
    let int8ReconstructionL2: Double

    enum CodingKeys: String, CodingKey {
        case kind, text, norm, vector
        case cosineToONNX = "cosine_to_onnx"
        case int8Q = "int8_q"
        case int8Scale = "int8_scale"
        case int8ReconstructionL2 = "int8_reconstruction_l2"
    }
}

private func dot(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count)
    return zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
}

private func norm(_ vector: [Float]) -> Double {
    dot(vector, vector).squareRoot()
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    dot(a, b) / (norm(a) * norm(b))
}

private func elapsedMS(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: .now).components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

@Suite(
    "Arctic shipped-factory proof",
    .enabled(if: arcticFactoryProofEnabled, "requires pinned Arctic weights and ONNX reference")
)
struct ArcticFactoryProofTests {
    @Test("Core AI factory matches ONNX and records timing")
    func factoryMatchesONNX() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelPath = try #require(environment["MOOT_ENCODER_MODEL_DIR"])
        let dataPath = try #require(environment["MOOT_ENCODER_DATA_DIR"])
        let bundlePath = try #require(environment["MOOT_ENCODER_BUNDLE_PATH"])
        let referencePath = try #require(environment["MOOT_ENCODER_REFERENCE_JSON"])
        let outputPath = try #require(environment["MOOT_ENCODER_PROOF_OUTPUT"])
        let timingPath = try #require(environment["MOOT_ENCODER_TIMING_JSON"])
        let reference = try JSONDecoder().decode(
            ArcticReference.self,
            from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
        let timing = try JSONDecoder().decode(
            ArcticTimingInput.self,
            from: Data(contentsOf: URL(fileURLWithPath: timingPath)))

        #expect(timing.samples.count == 20)
        #expect(timing.sourcePoolSHA256.count == 64)
        let timingHashIsHex = timing.sourcePoolSHA256.allSatisfy { $0.isHexDigit }
        #expect(timingHashIsHex)
        #expect(timing.samples.allSatisfy { $0.windows.count == 750 })

        #expect(reference.entries.count == 6)
        #expect(reference.entries.first?.kind == "query")
        #expect(reference.entries.dropFirst().allSatisfy { $0.kind == "span" })
        #expect(reference.modelID == EncoderModelSeed.modelID)
        #expect(reference.revision == EncoderModelSeed.modelVersion)
        #expect(reference.dim == EncoderModelSeed.dim)
        #expect(reference.pooling == EncoderModelSeed.pooling)
        #expect(reference.queryPrefix == EncoderModelSeed.queryPrefix)
        #expect(reference.docPrefix == EncoderModelSeed.docPrefix)
        #expect(reference.maxSequence == EncoderModelSeed.maxSequence)
        #expect(reference.tokenizerHash == EncoderModelSeed.tokenizerHash)

        let pooling = try #require(EncoderModelSpec.Pooling(rawValue: reference.pooling))
        let spec = EncoderModelSpec(
            modelID: reference.modelID,
            modelVersion: reference.revision,
            dim: reference.dim,
            queryPrefix: reference.queryPrefix,
            docPrefix: reference.docPrefix,
            pooling: pooling,
            tokenizerHash: reference.tokenizerHash,
            windowWords: EncoderModelSeed.windowWords,
            overlapDivisor: EncoderModelSeed.overlapDivisor,
            maxSpans: EncoderModelSeed.maxSpans,
            maxSequence: reference.maxSequence)

        let dataDirectory = URL(fileURLWithPath: dataPath, isDirectory: true)
        let downloadSlot = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(EncoderModelSeed.modelID, isDirectory: true)
        #expect(
            !FileManager.default.fileExists(atPath: downloadSlot.path),
            "real proof must exercise bundle discovery, not the download slot")
        let bundle = try #require(Bundle(path: bundlePath))
        let resolvedModelDirectory = try #require(
            ModelDirectoryResolver.encoderModelDirectory(
                for: EncoderModelSeed.modelID,
                dataDirectory: dataDirectory,
                bundle: bundle))
        #expect(
            resolvedModelDirectory.resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: modelPath, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL)

        let loadStarted = ContinuousClock.now
        let encoder = try await SpanEncoderFactory.make(
            spec: spec,
            modelDirectory: resolvedModelDirectory)
        let coldLoadMS = elapsedMS(since: loadStarted)

        let queryReference = reference.entries[0]
        #expect(queryReference.encodedText == reference.queryPrefix + queryReference.text)
        let spanReferences = Array(reference.entries.dropFirst())
        for entry in spanReferences {
            #expect(entry.encodedText == reference.docPrefix + entry.text)
        }
        let query = try await encoder.encodeQuery(queryReference.text)
        let spans = try await encoder.encodeSpans(spanReferences.map(\.text))
        try #require(spans.count == spanReferences.count)
        let vectors = [query] + spans
        try #require(vectors.count == reference.entries.count)

        var proofEntries: [ArcticProofEntry] = []
        for (actual, expected) in zip(vectors, reference.entries) {
            #expect(actual.count == reference.dim)
            #expect(expected.vector.count == reference.dim)
            let actualNorm = norm(actual)
            #expect(abs(actualNorm - 1) <= 1e-5)
            let cosineToONNX = cosine(actual, expected.vector)
            #expect(cosineToONNX >= 0.999)
            let quantized = Int8Vec.quantize(actual)
            let reconstructed = Int8Vec.dequantize(quantized.q, scale: quantized.scale)
            let reconstructionL2 = zip(actual, reconstructed)
                .reduce(Double.zero) {
                    let delta = Double($1.0) - Double($1.1)
                    return $0 + delta * delta
                }
                .squareRoot()
            let reconstructionBound = Double(reference.dim).squareRoot()
                * Double(quantized.scale) / 2 + 1e-5
            #expect(reconstructionL2 <= reconstructionBound)
            proofEntries.append(ArcticProofEntry(
                kind: expected.kind,
                text: expected.text,
                cosineToONNX: cosineToONNX,
                norm: actualNorm,
                vector: actual,
                int8Q: quantized.q,
                int8Scale: quantized.scale,
                int8ReconstructionL2: reconstructionL2))
        }
        let queryToSpanInt8Dot = proofEntries.dropFirst().map {
            Int8Vec.dotQuery(query, q: $0.int8Q, scale: $0.int8Scale)
        }

        var querySamples: [Double] = []
        var windowsSamples: [Double] = []
        var queryPlusWindowsSamples: [Double] = []
        for sample in timing.samples {
            let totalStarted = ContinuousClock.now
            let queryStarted = ContinuousClock.now
            _ = try await encoder.encodeQuery(sample.query)
            querySamples.append(elapsedMS(since: queryStarted))

            let windowsStarted = ContinuousClock.now
            let encodedWindows = try await encoder.encodeSpans(sample.windows)
            windowsSamples.append(elapsedMS(since: windowsStarted))
            queryPlusWindowsSamples.append(elapsedMS(since: totalStarted))
            #expect(encodedWindows.count == 750)
        }

        let output = ArcticProofOutput(
            port: "swift-coreml",
            modelID: reference.modelID,
            revision: reference.revision,
            coldLoadMS: coldLoadMS,
            timingScope: "factory_encode_only_excludes_audition_dot_matrix",
            timingSourcePoolSHA256: timing.sourcePoolSHA256,
            queryMS20: querySamples,
            windows750MS20: windowsSamples,
            queryPlusWindowsMS20: queryPlusWindowsSamples,
            medianQueryMS20: median(querySamples),
            medianWindows750MS20: median(windowsSamples),
            medianQueryPlusWindowsMS20: median(queryPlusWindowsSamples),
            auditionTotalMS: nil,
            queryToSpanInt8Dot: queryToSpanInt8Dot,
            entries: proofEntries)
        let encoderJSON = JSONEncoder()
        encoderJSON.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoderJSON.encode(output).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
