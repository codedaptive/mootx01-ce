import Foundation
import FactExtractionKit
import FactExtractionKitProviders
import Testing

@Suite("Source-grounded fact extraction contract")
struct FactGroundingTests {
    private struct OffsetVector: Decodable {
        let source: String
        let evidenceQuote: String
        let subject: String
        let predicate: String
        let object: String
        let expectedStart: Int
        let expectedEnd: Int
        let expectedStartUtf8Byte: Int
        let expectedEndUtf8Byte: Int
    }

    let spec = FactExtractorModelSpec(
        providerID: "test", modelID: "fixture", modelVersion: "1",
        schemaVersion: "fact-v1", extractorKind: .specializedModel,
        maximumInputCharacters: 4096, maximumFactsPerSource: 8)

    @Test("accepts one uniquely grounded fact and builds its projection")
    func acceptsGroundedFact() {
        let source = "Meeting notes. Jack's birthday is June 20th. Bring cake."
        let request = FactExtractionRequest(
            sourceID: "drawer-1", sourceDigest: "digest", sourceText: source,
            eligibleSourceSpans: [FactSourceSpan(
                start: 0, end: source.unicodeScalars.count,
                startUTF8Byte: 0, endUTF8Byte: source.utf8.count)],
            maximumFacts: 4)
        let response = FactExtractionResponse(
            sourceDigest: "digest", providerID: "test", modelID: "fixture",
            modelVersion: "1", schemaVersion: "fact-v1",
            candidates: [FactCandidate(
                subject: "Jack", predicate: "birthday", object: "June 20th",
                evidenceQuote: "Jack's birthday is June 20th.", confidence: 0.98,
                searchAliases: ["Jack birthday", "date of birth"])])

        let report = FactGroundingValidator.validate(
            response: response, request: request, originalSource: source, expectedSpec: spec)

        #expect(report.rejected.isEmpty)
        #expect(report.accepted.count == 1)
        #expect(report.accepted[0].evidenceSpan.start == 15)
        #expect(report.accepted[0].searchProjection == "Jack birthday June 20th Jack birthday date of birth")
    }

    @Test("rejects fabricated, ambiguous, and out-of-selection evidence")
    func rejectsUngroundedEvidence() {
        let source = "Alice likes tea. Alice likes tea. Bob likes coffee."
        let selected = FactSourceSpan(start: 0, end: 33, startUTF8Byte: 0, endUTF8Byte: 33)
        let request = FactExtractionRequest(
            sourceID: "drawer-2", sourceDigest: "digest", sourceText: source,
            eligibleSourceSpans: [selected], maximumFacts: 4)
        let response = FactExtractionResponse(
            sourceDigest: "digest", providerID: "test", modelID: "fixture",
            modelVersion: "1", schemaVersion: "fact-v1",
            candidates: [
                FactCandidate(subject: "Alice", predicate: "likes", object: "tea", evidenceQuote: "Alice likes tea.", confidence: 0.9),
                FactCandidate(subject: "Bob", predicate: "likes", object: "coffee", evidenceQuote: "Bob likes coffee.", confidence: 0.9),
                FactCandidate(subject: "Carol", predicate: "likes", object: "water", evidenceQuote: "Carol likes water.", confidence: 0.9),
            ])

        let report = FactGroundingValidator.validate(
            response: response, request: request, originalSource: source, expectedSpec: spec)

        #expect(report.accepted.isEmpty)
        #expect(report.rejected == [.ambiguousEvidence, .evidenceOutsideSelectedSpans, .evidenceNotFound])
    }

    @Test("rejects a real quote paired with a hallucinated subject or object")
    func rejectsUnsupportedValues() {
        let source = "Jack's birthday is June 20th."
        let request = FactExtractionRequest(
            sourceID: "drawer-values", sourceDigest: "digest", sourceText: source,
            eligibleSourceSpans: [FactSourceSpan(
                start: 0, end: source.unicodeScalars.count,
                startUTF8Byte: 0, endUTF8Byte: source.utf8.count)],
            maximumFacts: 2)
        let response = FactExtractionResponse(
            sourceDigest: "digest", providerID: "test", modelID: "fixture",
            modelVersion: "1", schemaVersion: "fact-v1",
            candidates: [
                FactCandidate(
                    subject: "Jill", predicate: "birthday", object: "June 20th",
                    evidenceQuote: source, confidence: 0.99),
                FactCandidate(
                    subject: "Jack", predicate: "birthday", object: "July 4th",
                    evidenceQuote: source, confidence: 0.99),
            ])

        let report = FactGroundingValidator.validate(
            response: response, request: request, originalSource: source, expectedSpec: spec)
        #expect(report.accepted.isEmpty)
        #expect(report.rejected == [.unsupportedValues, .unsupportedValues])
    }

    @Test("provider refuses oversized work before inference")
    func providerBoundsInput() async {
        let provider = ClosureFactExtractor(spec: spec) { request in
            FactExtractionResponse(
                sourceDigest: request.sourceDigest, providerID: "test", modelID: "fixture",
                modelVersion: "1", schemaVersion: "fact-v1", candidates: [])
        }
        let request = FactExtractionRequest(
            sourceID: "drawer", sourceDigest: "digest",
            sourceText: String(repeating: "x", count: 4097),
            eligibleSourceSpans: [], maximumFacts: 1)
        await #expect(throws: FactExtractionError.self) {
            _ = try await provider.extract(request)
        }
    }

    @Test("source offsets distinguish Unicode scalars from UTF-8 bytes")
    func unicodeOffsets() {
        let source = "📝 Zoë's birthday is June 20th."
        let request = FactExtractionRequest(
            sourceID: "drawer-unicode", sourceDigest: "digest", sourceText: source,
            eligibleSourceSpans: [FactSourceSpan(
                start: 0, end: source.unicodeScalars.count,
                startUTF8Byte: 0, endUTF8Byte: source.utf8.count)],
            maximumFacts: 1)
        let response = FactExtractionResponse(
            sourceDigest: "digest", providerID: "test", modelID: "fixture",
            modelVersion: "1", schemaVersion: "fact-v1",
            candidates: [FactCandidate(
                subject: "Zoë", predicate: "birthday", object: "June 20th",
                evidenceQuote: "Zoë's birthday is June 20th.", confidence: 1)])

        let report = FactGroundingValidator.validate(
            response: response, request: request, originalSource: source, expectedSpec: spec)
        #expect(report.rejected.isEmpty)
        #expect(report.accepted[0].evidenceSpan.start == 2)
        #expect(report.accepted[0].evidenceSpan.startUTF8Byte == 5)
        #expect(report.accepted[0].evidenceSpan.endUTF8Byte == source.utf8.count)
    }

    @Test("non-BMP grounding offsets match the shared scalar vector")
    func sharedNonBMPOffsetVector() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/fact_grounding_offsets.json")
        let vector = try JSONDecoder().decode(
            OffsetVector.self, from: Data(contentsOf: fixtureURL))
        let request = FactExtractionRequest(
            sourceID: "drawer-shared-vector", sourceDigest: "digest", sourceText: vector.source,
            eligibleSourceSpans: [FactSourceSpan(
                start: 0, end: vector.source.unicodeScalars.count,
                startUTF8Byte: 0, endUTF8Byte: vector.source.utf8.count)],
            maximumFacts: 1)
        let response = FactExtractionResponse(
            sourceDigest: "digest", providerID: "test", modelID: "fixture",
            modelVersion: "1", schemaVersion: "fact-v1",
            candidates: [FactCandidate(
                subject: vector.subject, predicate: vector.predicate, object: vector.object,
                evidenceQuote: vector.evidenceQuote, confidence: 1)])

        let report = FactGroundingValidator.validate(
            response: response, request: request, originalSource: vector.source, expectedSpec: spec)

        #expect(report.rejected.isEmpty)
        let span = try #require(report.accepted.first?.evidenceSpan)
        #expect(span.start == vector.expectedStart)
        #expect(span.end == vector.expectedEnd)
        #expect(span.startUTF8Byte == vector.expectedStartUtf8Byte)
        #expect(span.endUTF8Byte == vector.expectedEndUtf8Byte)
    }
}
