import Foundation
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed memory operations")
struct AriaV2MemoryOperationsTests {
    private let estateID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let firstID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let hiddenID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func strictRequestsRejectUnknownConflictsAndInvalidBounds() throws {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemorySearchRequest(arguments: .object([
                "query": .string("x"), "near": .string(firstID.uuidString),
            ]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemorySearchRequest(arguments: .object([:]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemorySearchRequest(arguments: .object([
                "query": .string("x"), "limit": .integer(501),
            ]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemoryGetRequest(arguments: .object([
                "memory_ids": .array([.string(firstID.uuidString), .string(firstID.uuidString)]),
            ]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemoryGetRequest(arguments: .object([:]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemoryGetRequest(arguments: .object([
                "memory_id": .string(firstID.uuidString),
                "memory_ids": .array([.string(firstID.uuidString)]),
            ]))
        }
    }

    @Test func fileUsesTypedBackendAndCanonicalReceipt() async throws {
        let backend = FakeMemoryBackend(records: [record(firstID)])
        let operations = service(backend: backend)
        let response = try await operations.file(arguments: .object([
            "content": .string("A durable fact."), "subject": .string("Durable fact."), "location": .string("Planning"),
        ]))
        let fileCalls = await backend.fileCalls
        #expect(fileCalls == 1)
        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect(data?["memory_id"]?.stringValue == firstID.uuidString.lowercased())
        #expect(data?["fetch"]?.objectValue?["arguments"]?.objectValue?["memory_id"]?.stringValue == firstID.uuidString.lowercased())
    }

    @Test func filingReadbackFailureRetainsReceiptIdentityWithoutRefiling() async throws {
        let backend = FakeMemoryBackend(records: [record(firstID)], readbackRecords: [])
        let operations = service(backend: backend)
        let filed = try await operations.file(arguments: .object([
            "content": .string("retained receipt"), "subject": .string("receipt"),
            "location": .string("handoff/room"),
        ]))
        let data = try #require(filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        let retainedID = try #require(data["memory_id"]?.stringValue)
        #expect(data["placement"]?.objectValue?["room"] == .string("Planning"))
        #expect(data["fetch"]?.objectValue?["tool"] == .string("moot_memory_get"))
        let readback = try await operations.get(arguments: .object(["memory_id": .string(retainedID)]))
        #expect(readback.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("memory_not_found"))
        #expect(await backend.fileCalls == 1)
        #expect(retainedID == firstID.uuidString.lowercased())
    }

    @Test func searchProjectsCompactRowsAndNeverLeaksUnauthorizedContent() async throws {
        let visible = record(firstID, content: String(repeating: "🙂", count: 513))
        let hidden = record(hiddenID, content: "secret", authorized: false)
        let backend = FakeMemoryBackend(records: [visible, hidden])
        let ledger = FakeLedger()
        let operations = service(backend: backend, ledger: ledger)
        let response = try await operations.search(arguments: .object(["query": .string("find planning")]))
        let rows = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue
        #expect(rows?.count == 1)
        #expect(rows?.first?.objectValue?["excerpt"]?.stringValue?.unicodeScalars.count == 512)
        let surfaced = await ledger.surfaced
        #expect(surfaced == [firstID])
    }

    // ITEM 6: `subject` key must be present in compact search result rows.
    //
    // MootMemoryTools.swift:127-129 documents "subject" as part of the live key
    // set for v2 compact rows, but the claim was held only by a comment rather
    // than a gate. If AriaV2MemoryOperations.compact renames or removes the
    // "subject" key, renderRows() silently returns nil for every row and the
    // recall tool falls back to compact text — the model stops receiving
    // structured row content. This gate discriminates that regression.
    //
    // To prove discrimination: rename "subject" to something else in
    // AriaV2MemoryOperations.compact (line 778), run this case, watch it go red.
    @Test func searchCompactRowsIncludeSubjectKey() async throws {
        let backend = FakeMemoryBackend(records: [record(firstID)])
        let operations = service(backend: backend)
        let response = try await operations.search(arguments: .object(["query": .string("find subject")]))
        let rows = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue
        #expect(rows?.count == 1)
        // `subject` is the only field renderRows() renders for the model. A missing
        // or renamed key here means every recall row reaches the model as nil.
        #expect(rows?.first?.objectValue?["subject"] == .string("Subject"))
    }

    @Test func searchEnforcesPublicLimitAfterAuthorizationWhenLowerOverReturns() async throws {
        let ids = (0..<4).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
        }
        let backend = FakeMemoryBackend(records: ids.map { record($0) })
        let ledger = FakeLedger()
        let response = try await service(backend: backend, ledger: ledger).search(arguments: .object([
            "query": .string("bounded"), "limit": .integer(2),
        ]))
        let rows = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue
        #expect(rows?.count == 2)
        #expect(await ledger.surfaced == Array(ids.prefix(2)))
    }

    @Test func getUsesSingleAuthorizedProjectionAndCollapsesMissingAndHidden() async throws {
        let backend = FakeMemoryBackend(records: [record(hiddenID, authorized: false)])
        let operations = service(backend: backend)
        let response = try await operations.get(arguments: .object(["memory_id": .string(hiddenID.uuidString.uppercased())]))
        #expect(response.objectValue?["isError"] == .bool(true))
        #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("memory_not_found"))
    }

    @Test func getProjectsFullRowsWithCanonicalFetchReference() async throws {
        let backend = FakeMemoryBackend(records: [record(firstID, content: "Verbatim body")])
        let response = try await service(backend: backend).get(arguments: .object([
            "memory_id": .string(firstID.uuidString.uppercased()), "depth": .string("full"),
        ]))
        let row = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memories"]?.arrayValue?.first?.objectValue
        #expect(row?["memory_id"]?.stringValue == firstID.uuidString.lowercased())
        #expect(row?["content"]?.stringValue == "Verbatim body")
        #expect(row?["fetch"]?.objectValue?["tool"]?.stringValue == "moot_memory_get")
    }

    @Test func productionGetAcceptsSwiftAndRustStorageUUIDSpellings() {
        let spellings = AriaV2ArgumentDecoder.storageIdentitySpellings(firstID)
        #expect(spellings == [firstID.uuidString, firstID.uuidString.lowercased()])
    }

    @Test func productionProjectionRawProvenancePolicyFailsClosed() {
        #expect(AriaV2GeniusLocusMemoryBackend.provenanceVisible(0 << 30))
        #expect(AriaV2GeniusLocusMemoryBackend.provenanceVisible(16 << 30))
        #expect(!AriaV2GeniusLocusMemoryBackend.provenanceVisible(32 << 30))
        #expect(!AriaV2GeniusLocusMemoryBackend.provenanceVisible(48 << 30))
        #expect(!AriaV2GeniusLocusMemoryBackend.provenanceVisible(63 << 30))
    }

    private func service(backend: FakeMemoryBackend, ledger: FakeLedger = FakeLedger()) -> AriaV2MemoryOperations {
        AriaV2MemoryOperations(backend: backend, context: .init(
            estateID: estateID, callerID: "test", serverIdentity: "test-server",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }, usageLedger: ledger))
    }

    private func record(_ id: UUID, content: String = "Content", authorized: Bool = true) -> AriaV2MemoryRecord {
        AriaV2MemoryRecord(memoryID: id, subject: "Subject", content: content, wing: "Agentic Memory", room: "Planning", filedAt: now, eventTime: now, lineageID: id, provenance: "mcp", isAuthorized: authorized)
    }
}

private actor FakeMemoryBackend: AriaV2MemoryBackend {
    let records: [AriaV2MemoryRecord]
    let readbackRecords: [AriaV2MemoryRecord]
    private(set) var fileCalls = 0

    init(records: [AriaV2MemoryRecord], readbackRecords: [AriaV2MemoryRecord]? = nil) {
        self.records = records
        self.readbackRecords = readbackRecords ?? records
    }

    func file(_ request: AriaV2FileMemoryRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2MemoryRecord {
        fileCalls += 1
        return records[0]
    }

    func search(_ request: AriaV2MemorySearchRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2SearchResult {
        // Test fake skips synthesis and packager; no answer block is produced.
        let pairs = records.map { ($0, 0.75) }
        return AriaV2SearchResult(records: pairs, answerBlock: nil, totalCount: pairs.count)
    }

    func get(_ request: AriaV2MemoryGetRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2MemoryRecord] {
        readbackRecords.filter { request.memoryIDs.contains($0.memoryID) }
    }
}

private actor FakeLedger: AriaV2MemoryUsageLedger {
    private(set) var surfaced: [UUID] = []
    private(set) var dereferenced: [UUID] = []

    func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async { surfaced = memoryIDs }
    func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async { dereferenced = memoryIDs }
}
