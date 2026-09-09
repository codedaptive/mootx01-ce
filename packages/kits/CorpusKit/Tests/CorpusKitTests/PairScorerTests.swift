// PairScorerTests.swift
//
// The cross-encoder contract: the packaged profile round-trips column-style,
// the provider pair scorer keeps span order across batch boundaries and
// refuses a seam that returns the wrong count or a non-finite logit, and
// the rerank directive round-trips with the shared key names.
//
// Failure modes: a batch boundary that drops or reorders spans (the stage
// would fuse a logit against the wrong candidate), a NaN that survives into
// fusion, a serialised key that disagrees with the Rust twin.

import Testing
import Foundation
@testable import CorpusKit

/// Records every (query, span batch) the fake seam receives and returns a
/// logit derived from the span text so two spans differ.
private actor PairRecorder {
    var batches: [(String, [String])] = []
    func record(_ query: String, _ spans: [String]) { batches.append((query, spans)) }
}

private struct FakePairInference: PairInference {
    let recorder: PairRecorder
    /// When set, every batch returns this many logits regardless of input.
    var forcedCount: Int? = nil
    /// When set, the logit at this pair index (within a batch) is NaN.
    var poisonIndex: Int? = nil

    var backend: String { "fake" }

    func logits(query: String, spans: [String]) async throws -> [Float] {
        await recorder.record(query, spans)
        let count = forcedCount ?? spans.count
        return (0..<count).map { i in
            if i == poisonIndex { return Float.nan }
            let span = i < spans.count ? spans[i] : ""
            return Float(span.utf8.count) - Float(query.utf8.count) / 10
        }
    }
}

@Suite("CrossEncoderProfile")
struct CrossEncoderProfileTests {

    @Test("the qualified profile carries the lab's values")
    func qualifiedProfile() {
        let p = CrossEncoderProfile.minilmL6
        #expect(p.modelID == "ms-marco-minilm-l6-cross-v1")
        #expect(p.modelVersion == "233902d2")
        #expect(p.tokenizerHash == EncoderModelSpec.floor.tokenizerHash)
        #expect(p.maxSequence == 512)
        #expect(p.pool == 50)
        #expect(p.head == 30)
        #expect(p.spans == 3)
        #expect(p.rrfK == 60)
    }

    @Test("artifactName is the Pascal-cased model id (same string as the Rust twin)")
    func artifactName() {
        #expect(CrossEncoderProfile.minilmL6.artifactName == "MsMarcoMinilmL6CrossV1")
    }

    @Test("a profile serialises with column-style keys and round-trips")
    func roundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(CrossEncoderProfile.minilmL6)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"model_id\":\"ms-marco-minilm-l6-cross-v1\""))
        #expect(json.contains("\"rrf_k\":60"))
        #expect(json.contains("\"max_sequence\":512"))
        #expect(json.contains("\"tokenizer_hash\":"))
        let back = try JSONDecoder().decode(CrossEncoderProfile.self, from: data)
        #expect(back == CrossEncoderProfile.minilmL6)
    }
}

@Suite("ProviderPairScorer over a fake seam")
struct ProviderPairScorerTests {

    @Test("one logit per span, order kept across batch boundaries, same query every batch")
    func orderAcrossBatches() async throws {
        let recorder = PairRecorder()
        let scorer = ProviderPairScorer(
            profile: .minilmL6, inference: FakePairInference(recorder: recorder), batchSize: 2)
        let spans = ["a", "bb", "ccc", "dddd", "eeeee"]
        #expect(scorer.backend == "fake")
        let logits = try await scorer.score(query: "q", spans: spans)
        #expect(logits.count == spans.count)
        // The fake keys the logit off the span length, so order is checkable.
        #expect(logits == spans.map { Float($0.utf8.count) - 0.1 })
        let batches = await recorder.batches
        #expect(batches.map(\.1) == [["a", "bb"], ["ccc", "dddd"], ["eeeee"]])
        #expect(batches.allSatisfy { $0.0 == "q" })
    }

    @Test("an empty span list returns empty without touching the seam")
    func emptySpans() async throws {
        let recorder = PairRecorder()
        let scorer = ProviderPairScorer(profile: .minilmL6, inference: FakePairInference(recorder: recorder))
        let logits = try await scorer.score(query: "q", spans: [])
        #expect(logits.isEmpty)
        #expect(await recorder.batches.isEmpty)
    }

    @Test("a batch size below 1 acts as 1")
    func batchFloor() async throws {
        let recorder = PairRecorder()
        let scorer = ProviderPairScorer(
            profile: .minilmL6, inference: FakePairInference(recorder: recorder), batchSize: 0)
        _ = try await scorer.score(query: "q", spans: ["a", "b", "c"])
        #expect(await recorder.batches.count == 3)
    }

    @Test("a seam that returns the wrong count is inferenceFailed")
    func wrongCount() async throws {
        let recorder = PairRecorder()
        let scorer = ProviderPairScorer(
            profile: .minilmL6, inference: FakePairInference(recorder: recorder, forcedCount: 1), batchSize: 8)
        await #expect(throws: EncoderError.self) {
            _ = try await scorer.score(query: "q", spans: ["a", "b"])
        }
        do {
            _ = try await scorer.score(query: "q", spans: ["a", "b"])
        } catch let error as EncoderError {
            guard case .inferenceFailed(let message) = error else {
                Issue.record("wrong error class: \(error)"); return
            }
            #expect(message.contains("1 logits for 2 pairs"))
        }
    }

    @Test("a non-finite logit is inferenceFailed and names the pair")
    func nonFinite() async throws {
        let recorder = PairRecorder()
        let scorer = ProviderPairScorer(
            profile: .minilmL6, inference: FakePairInference(recorder: recorder, poisonIndex: 1), batchSize: 8)
        do {
            _ = try await scorer.score(query: "q", spans: ["a", "b", "c"])
            Issue.record("expected a throw")
        } catch let error as EncoderError {
            guard case .inferenceFailed(let message) = error else {
                Issue.record("wrong error class: \(error)"); return
            }
            #expect(message.contains("non-finite logit at pair 1"))
        }
    }
}

@Suite("RerankDirective")
struct RerankDirectiveTests {

    @Test("apply and bypass name the qualified profile")
    func factories() {
        #expect(RerankDirective.apply() == RerankDirective(action: .apply, profileID: "ms-marco-minilm-l6-cross-v1"))
        #expect(RerankDirective.bypass(reason: "lab") == RerankDirective(action: .bypass, profileID: "ms-marco-minilm-l6-cross-v1", reason: "lab"))
    }

    @Test("a directive serialises with the shared keys and round-trips")
    func roundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RerankDirective.apply(reason: "explicit"))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == "{\"action\":\"apply\",\"profile_id\":\"ms-marco-minilm-l6-cross-v1\",\"reason\":\"explicit\"}")
        let back = try JSONDecoder().decode(RerankDirective.self, from: data)
        #expect(back == RerankDirective.apply(reason: "explicit"))
        // A reason-less directive decodes from the Rust twin's shape (key absent).
        let rust = Data("{\"action\":\"bypass\",\"profile_id\":\"ms-marco-minilm-l6-cross-v1\"}".utf8)
        #expect(try JSONDecoder().decode(RerankDirective.self, from: rust) == RerankDirective.bypass())
        let strict = try encoder.encode(RerankDirective.strictTranscript())
        #expect(String(decoding: strict, as: UTF8.self).contains("\"requirement\":\"strict_transcript\""))
        #expect(try JSONDecoder().decode(RerankDirective.self, from: strict) == .strictTranscript())
    }
}
