import CognitionKit
import CorpusKit
import Foundation
import GeniusLocusKit
import Testing
@testable import AriaMCP

@Suite("ARIA v2 strict transcript recall")
struct AriaV2TranscriptRecallTests {
    private let estateID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let memoryID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    @Test func unavailableStrictOutcomeRefusesWithoutGenericResults() async throws {
        let output = TranscriptRecall.Output(
            matches: [PreciseMatch(id: memoryID.uuidString, room: "Transcript", content: "must not surface", score: 0.9)],
            outcome: unavailableOutcome())
        let response = try await service(output).recall(arguments: .object([
            "query": .string("what did we decide?"),
        ]))
        let structured = response.objectValue?["structuredContent"]?.objectValue
        #expect(response.objectValue?["isError"] == .bool(true))
        #expect(structured?["error"]?.objectValue?["code"] == .string("rerank_unavailable"))
        #expect(structured?["data"] == nil)
        #expect(structured?["error"]?.objectValue?["recovery"]?.objectValue?["strict_rerank"]?.objectValue?["status"] == .string("unavailable"))
    }

    @Test func appliedTypedOutputProjectsMatchesEvidenceAndActualFetchID() async throws {
        let output = TranscriptRecall.Output(
            matches: [PreciseMatch(id: memoryID.uuidString.uppercased(), room: "Transcript", content: "Decision: ship strict recall.", score: 0.75)],
            outcome: StrictTranscriptRerankOutcome(
                status: .applied, reason: nil, encoderModelID: "arctic", encoderModelVersion: "1", queryDimension: 384,
                freshHeadCandidates: 1, scoredHeadCandidates: 1,
                classifierProfileID: CrossEncoderProfile.minilmL6.modelID,
                classifierModelRevision: CrossEncoderProfile.minilmL6Revision))
        let response = try await service(output).recall(arguments: .object([
            "query": .string("decision"), "estate_id": .string(estateID.uuidString),
        ]))
        let structured = response.objectValue?["structuredContent"]?.objectValue
        let row = structured?["data"]?.objectValue?["matches"]?.arrayValue?.first?.objectValue
        #expect(response.objectValue?["isError"] == .bool(false))
        #expect(structured?["data"]?.objectValue?["strict_rerank"]?.objectValue?["status"] == .string("applied"))
        #expect(structured?["data"]?.objectValue?["strict_rerank"]?.objectValue?["classifier_model_revision"]
            == .string(CrossEncoderProfile.minilmL6Revision))
        #expect(row?["memory_id"] == .string(memoryID.uuidString.lowercased()))
        #expect(row?["fetch"]?.objectValue?["tool"] == .string("moot_memory_get"))
        #expect(row?["fetch"]?.objectValue?["arguments"]?.objectValue?["memory_id"] == .string(memoryID.uuidString.lowercased()))
    }

    @Test func requestRejectsUnknownArguments() {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2TranscriptRecallRequest(arguments: .object([
                "query": .string("decision"), "limit": .integer(1),
            ]))
        }
    }

    @Test func requestValidationPreservesOriginalClassifierQuery() throws {
        let query = "  decision with caller spacing\n"
        let request = try AriaV2TranscriptRecallRequest(arguments: .object([
            "query": .string(query),
        ]))
        #expect(request.query == query)
    }

    private func service(_ output: TranscriptRecall.Output) -> AriaV2TranscriptRecallService {
        AriaV2TranscriptRecallService(
            backend: FakeTranscriptBackend(output: output),
            context: .init(estateID: estateID, callerID: "test", serverIdentity: "test"))
    }

    private func unavailableOutcome() -> StrictTranscriptRerankOutcome {
        StrictTranscriptRerankOutcome(
            status: .unavailable, reason: .activeEncoderUnavailable,
            encoderModelID: nil, encoderModelVersion: nil, queryDimension: nil,
            freshHeadCandidates: 0, scoredHeadCandidates: 0)
    }
}

private struct FakeTranscriptBackend: AriaV2TranscriptRecallBackend {
    let output: TranscriptRecall.Output

    func recall(
        _ request: AriaV2TranscriptRecallRequest,
        context: AriaV2MemoryOperationContext
    ) async throws -> TranscriptRecall.Output {
        _ = (request, context)
        return output
    }
}
