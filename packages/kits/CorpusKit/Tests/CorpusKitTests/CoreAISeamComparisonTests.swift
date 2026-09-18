// CoreAISeamComparisonTests.swift
//
// Real-asset comparison of the two Apple seams for one model id (ADR-028
// E4's gate): the CoreML floor (one `[1, L]` prediction per text) against
// the Core AI seam (one `[B, L]` inference per chunk). Runs only when the
// caller supplies two model directories that differ by the `.aimodel`, and
// writes a JSON report: per-sentence cosine and max abs difference between
// the seams, plus the wall clock of encoding the sample spans through each.
// The ordinary kit suite never loads model weights.

import Foundation
import Testing
@testable import CorpusKit
@testable import CorpusKitProviders

private let comparisonEnabled =
    ProcessInfo.processInfo.environment["MOOT_COREAI_COMPARE"] == "1"

private struct AppleManifest: Decodable {
    let modelID: String
    let modelVersion: String
    let dim: Int
    let pooling: String
    let queryPrefix: String
    let docPrefix: String
    let windowWords: Int
    let overlapDivisor: Int
    let maxSpans: Int
    let maxSequence: Int
    let tokenizerHash: String

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id", modelVersion = "model_version", dim, pooling
        case queryPrefix = "query_prefix", docPrefix = "doc_prefix"
        case windowWords = "window_words", overlapDivisor = "overlap_divisor"
        case maxSpans = "max_spans", maxSequence = "max_sequence", tokenizerHash = "tokenizer_hash"
    }

    var spec: EncoderModelSpec {
        EncoderModelSpec(
            modelID: modelID, modelVersion: modelVersion, dim: dim,
            queryPrefix: queryPrefix, docPrefix: docPrefix,
            pooling: pooling == "cls" ? .cls : .mean, tokenizerHash: tokenizerHash,
            windowWords: windowWords, overlapDivisor: overlapDivisor,
            maxSpans: maxSpans, maxSequence: maxSequence)
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<min(a.count, b.count) {
        dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i])
    }
    return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
}

private func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Double {
    zip(a, b).map { Double(abs($0 - $1)) }.max() ?? 0
}

@Suite("Core AI seam vs CoreML floor", .enabled(if: comparisonEnabled))
struct CoreAISeamComparisonTests {

    @Test("the two seams agree on the fixture and the clock is recorded")
    func seamsAgreeAndClockIsRecorded() async throws {
        let env = ProcessInfo.processInfo.environment
        let coremlDir = URL(fileURLWithPath: try #require(env["MOOT_COREML_MODEL_DIR"]))
        let coreaiDir = URL(fileURLWithPath: try #require(env["MOOT_COREAI_MODEL_DIR"]))
        let manifestPath = try #require(env["MOOT_ENCODER_MANIFEST"])
        let outputPath = try #require(env["MOOT_COREAI_COMPARE_OUTPUT"])
        let manifest = try JSONDecoder().decode(
            AppleManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let spec = manifest.spec

        let floor = try await SpanEncoderFactory.make(spec: spec, modelDirectory: coremlDir)
        let batched = try await SpanEncoderFactory.make(spec: spec, modelDirectory: coreaiDir)
        #expect(String(describing: type(of: (floor as! ProviderSpanEncoder).inference)).contains("EmbeddingProviderSpanInference"))
        #expect(String(describing: type(of: (batched as! ProviderSpanEncoder).inference)).contains("CoreAISpanInference"))

        // The sentences of the export's fixture plus a spread of lengths, so
        // the padded rows of a batch are compared, not only the longest.
        let texts = [
            "what is the capital of france",
            "the api timeout is 30 seconds",
            "grocery list apples and oranges and a long tail of words to make this row the longest of the three so the other two rows are padded with mask zeros behind their tokens",
            "a",
            String(repeating: "the quick brown fox jumps over the lazy dog ", count: 40),
        ]
        let floorVectors = try await floor.encodeSpans(texts)
        let batchedVectors = try await batched.encodeSpans(texts)
        var perText: [[String: Any]] = []
        for (i, text) in texts.enumerated() {
            let cos = cosine(floorVectors[i], batchedVectors[i])
            let diff = maxAbsDiff(floorVectors[i], batchedVectors[i])
            perText.append(["text": String(text.prefix(48)), "cosine": cos, "max_abs_diff": diff])
            #expect(cos > 0.999, "text \(i): cosine \(cos)")
        }
        let query = "what is the capital of france"
        let queryCos = cosine(try await floor.encodeQuery(query), try await batched.encodeQuery(query))

        // Clock: 64 spans of 60 words, the span duty's chunk on macOS, three
        // rounds each, the median kept.
        let words = String(repeating: "memory estate drawer chest room wing tunnel fact ", count: 8)
        let spans = (0..<64).map { "\($0) " + words }
        func medianMS(_ encoder: any SpanEncoder) async throws -> Double {
            var runs: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                _ = try await encoder.encodeSpans(spans)
                let elapsed = ContinuousClock.now - start
                runs.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
            return runs.sorted()[1]
        }
        _ = try await floor.encodeSpans(spans.prefix(4).map { $0 })      // warm both
        _ = try await batched.encodeSpans(spans.prefix(4).map { $0 })
        let floorMS = try await medianMS(floor)
        let batchedMS = try await medianMS(batched)

        let report: [String: Any] = [
            "model_id": spec.modelID,
            "per_text": perText,
            "query_cosine": queryCos,
            "spans_per_round": spans.count,
            "coreml_median_ms": floorMS,
            "coreai_median_ms": batchedMS,
            "speedup": floorMS / max(batchedMS, 0.001),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath))
    }
}
