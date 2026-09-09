import AriaMCPWire
import Foundation
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed knowledge and journal service")
struct AriaV2KnowledgeJournalTests {
    private let estateID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let factID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let sourceID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

    @Test func fileFactProjectsTypedRecordWithCanonicalIdentifiers() async throws {
        let response = try await service().fileFact(arguments: .object([
            "subject": .string("decision"),
            "predicate": .string("is"),
            "object": .string("ship"),
            "source_memory_id": .string(sourceID.uuidString.uppercased()),
            "event_time": .string("2026-09-08T00:00:00Z"),
        ]))

        let structured = response.objectValue?["structuredContent"]?.objectValue
        let data = structured?["data"]?.objectValue
        #expect(response.objectValue?["isError"] == .bool(false))
        #expect(structured?["tool"] == .string("moot_file_fact"))
        #expect(data?["fact_id"] == .string(factID.uuidString.lowercased()))
        #expect(data?["source_memory_id"] == .string(sourceID.uuidString.lowercased()))
        #expect(data?["event_time"] == .string("2026-09-08T00:00:00Z"))
    }

    @Test func accessGateRefusesBeforeBackendAndDoesNotExposeResults() async throws {
        let response = try await AriaV2KnowledgeJournalService(
            backend: FakeKnowledgeBackend(fact: fact()), context: context,
            accessGate: RefusingGate()).factSearch(arguments: .object([:]))

        let structured = response.objectValue?["structuredContent"]?.objectValue
        #expect(response.objectValue?["isError"] == .bool(true))
        #expect(structured?["error"]?.objectValue?["code"] == .string("knowledge_not_authorized"))
        #expect(structured?["data"] == nil)
    }

    @Test func unavailableLowerReferencesAreOmittedWithoutSentinelUUIDs() async throws {
        let tunnelID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let backend = FakeKnowledgeBackend(
            fact: .init(
                factID: factID, subject: "decision", predicate: "is", object: "ship",
                sourceMemoryID: nil,
                eventTime: ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!, state: "active"),
            tunnels: [.init(tunnelID: tunnelID, fromID: sourceID, toID: nil, kind: "references")]
        )
        let service = AriaV2KnowledgeJournalService(backend: backend, context: context)

        let facts = try await service.factSearch(arguments: .object([:]))
        let fact = facts.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["facts"]?.arrayValue?.first?.objectValue
        #expect(fact?["source_memory_id"] == nil)

        let connections = try await service.connectionSearch(arguments: .object([
            "memory_id": .string(sourceID.uuidString),
        ]))
        let edge = connections.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["edges"]?.arrayValue?.first?.objectValue
        #expect(edge?["from_id"] == .string(sourceID.uuidString.lowercased()))
        #expect(edge?["to_id"] == nil)
    }

    @Test func requestRejectsUnknownArgumentAndInvalidJournalWindow() {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2FactSearchRequest(arguments: .object(["source_id": .string("not-declared")]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2ReadJournalRequest(arguments: .object([
                "after": .string("2026-09-09T00:00:00Z"),
                "before": .string("2026-09-08T00:00:00Z"),
            ]))
        }
    }

    private var context: AriaV2MemoryOperationContext {
        .init(estateID: estateID, callerID: "test", serverIdentity: "test", now: {
            ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!
        })
    }

    private func service() -> AriaV2KnowledgeJournalService {
        .init(backend: FakeKnowledgeBackend(fact: fact()), context: context)
    }

    private func fact() -> AriaV2KnowledgeFact {
        .init(
            factID: factID, subject: "decision", predicate: "is", object: "ship",
            sourceMemoryID: sourceID,
            eventTime: ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!, state: "active")
    }
}

private struct RefusingGate: AriaV2KnowledgeJournalAccessGate {
    func admit(
        _ operation: AriaV2KnowledgeJournalOperation,
        context: AriaV2MemoryOperationContext
    ) async -> AriaV2OperationalRefusal? {
        _ = operation
        _ = context
        return .init(code: "knowledge_not_authorized", message: "Knowledge access is not authorized for this caller.", retryable: false)
    }
}

private struct FakeKnowledgeBackend: AriaV2KnowledgeJournalBackend {
    let fact: AriaV2KnowledgeFact
    var tunnels: [AriaV2KnowledgeTunnel] = []

    func connectionSearch(_ request: AriaV2ConnectionSearchRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeTunnel] { tunnels }
    func connectionMap(_ request: AriaV2ConnectionMapRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeTunnel] { tunnels }
    func fileFact(_ request: AriaV2FileFactRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2KnowledgeFact { fact }
    func factSearch(_ request: AriaV2FactSearchRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeFact] { [fact] }
    func retireFact(_ request: AriaV2RetireFactRequest, context: AriaV2MemoryOperationContext) async throws {}
    func factTimeline(_ request: AriaV2FactTimelineRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeFact] { [fact] }
    func writeJournal(_ request: AriaV2WriteJournalRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2KnowledgeJournalEntry {
        .init(agentName: "mcp-agent", entry: request.content, writtenAt: request.entryTime ?? context.now())
    }
    func readJournal(_ request: AriaV2ReadJournalRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeJournalEntry] { [] }
}
