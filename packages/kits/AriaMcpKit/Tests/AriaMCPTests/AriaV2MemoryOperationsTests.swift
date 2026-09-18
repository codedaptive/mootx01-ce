import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
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

    @Test func searchDiscriminationIsStrictlyOptIn() async throws {
        let backend = FakeMemoryBackend(records: [record(firstID), record(hiddenID)])
        let operations = service(backend: backend)
        let omitted = try await operations.search(arguments: .object(["query": .string("find planning")]))
        let disabled = try await operations.search(arguments: .object([
            "query": .string("find planning"), "explain": .bool(false),
        ]))
        let enabled = try await operations.search(arguments: .object([
            "query": .string("find planning"), "explain": .bool(true),
        ]))
        let text: (JSONValue) -> String = { response in
            response.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        }
        #expect(!text(omitted).contains("discrimination:"))
        #expect(!text(disabled).contains("discrimination:"))
        #expect(text(enabled).contains("discrimination:"))
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

    @Test func skimReturnsOnlyPreviewAndPreservesFetchAndAuthorization() async throws {
        let body = (0..<50).map { "Event \($0) occurred in location \($0) with participant \($0)." }.joined(separator: "\n\n")
        let backend = FakeMemoryBackend(records: [record(firstID, content: body), record(hiddenID, content: "PRIVATE_SENTINEL", authorized: false)])
        let response = try await service(backend: backend).get(arguments: .object([
            "memory_ids": .array([.string(firstID.uuidString), .string(hiddenID.uuidString)]), "depth": .string("skim")]))
        let rows = try #require(response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memories"]?.arrayValue)
        #expect(rows.count == 1)
        let row = try #require(rows.first?.objectValue)
        let skim = try #require(row["skim"]?.objectValue)
        #expect(skim["complete"] == .bool(false))
        #expect(skim["budgetHonored"] == .bool(true))
        #expect(try #require(skim["text"]?.stringValue).utf8.count <= 512)
        #expect(skim["savings"]?.stringValue?.contains("🌱") == true)
        let display = try #require(response.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(display.contains(try #require(skim["savings"]?.stringValue)))
        #expect(display.contains("budgetHonored: true"))
        #expect(row["content"] == nil && row["distilled"] == nil && row["tunnels"] == nil)
        #expect(skim["continuation"] == nil && skim["fullText"] == nil)
        #expect(row["fetch"]?.objectValue?["tool"] == .string("moot_memory_get"))
        #expect(!String(describing: response).contains("PRIVATE_SENTINEL"))
    }

    @Test func skimShortAndOversizedGroupsReportTruthfulFlags() throws {
        let short = try RecallSkim(original: "Maya approved the budget.")
        #expect(short.complete && short.budgetHonored)
        let long = try RecallSkim(original: String(repeating: "界", count: 600))
        #expect(long.complete && !long.budgetHonored)
        #expect(long.text.utf8.count > 512)
        #expect(try RecallSkim(original: "").text == "")
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

    /// Injects a record with a 600-character subject via `FakeMemoryBackend` and
    /// asserts that the compact operation truncates both `subject` and `context`
    /// to the 512-scalar compact form and that they are identical.
    ///
    /// Uses the fake backend rather than filing through `moot_file_memory` so the
    /// test bypasses `DrawerStore.subjectLengthContract` (120 chars), which would
    /// otherwise reject any subject longer than 120 chars.  The test directly
    /// exercises `AriaV2MemoryOperations.compact`, the production site that applies
    /// `compactText` to both fields.
    @Test func compact_row_subject_and_context_share_the_512_scalar_form() async throws {
        // 600-character subject cycling through the alphabet: a wrong slice yields a
        // visibly wrong string, unlike a run of identical characters.
        let base = "abcdefghijklmnopqrstuvwxyz"
        let longSubject = String(repeating: base, count: 23) + "ab"  // 23 × 26 + 2 = 600 chars

        // Build a record with the long subject and context directly — no filing gate.
        // The real estate backend populates record.context from the drawer subject;
        // the fake must do the same so compact() wires both fields.
        let longRecord = AriaV2MemoryRecord(
            memoryID: firstID,
            subject: longSubject,
            content: "Content",
            wing: "Agentic Memory",
            room: "Planning",
            filedAt: now,
            eventTime: now,
            lineageID: firstID,
            provenance: "mcp",
            context: longSubject,
            isAuthorized: true
        )
        let backend = FakeMemoryBackend(records: [longRecord])
        let operations = service(backend: backend)
        let response = try await operations.search(arguments: .object(["query": .string("compact-512-form")]))

        let rows = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "search must return a results array")
        let first = try #require(rows.first?.objectValue, "search must return at least one row")

        let subject = try #require(first["subject"]?.stringValue, "row must carry a subject field")
        let context = try #require(first["context"]?.stringValue, "row must carry a context field")
        let compact = AriaV2Envelope.compactText(longSubject)

        #expect(subject == context,
                "subject and context must be identical in the compact search row")
        #expect(subject == compact,
                "subject must equal the 512-scalar compact form of the filed subject")
        #expect(subject.unicodeScalars.count == 512,
                "compact form must be exactly 512 scalars, not the raw 600-char subject")
    }

    /// Drives `moot_memory_search` through `ToolDispatcher` with a real in-memory
    /// estate so the full search path — including `record(for:authorized:tunnels:)` —
    /// is exercised end-to-end. Asserts that the compact search row carries the
    /// drawer's subject in its `context` field.
    @Test func search_row_context_carries_the_filed_subject() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "v2b-context-search")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let subject = "the drawer subject that context must carry"
        _ = try await dispatcher.dispatch(name: "moot_file_memory", arguments: .object([
            "content": .string(subject),
            "subject": .string(subject),
            "location": .string("context-field-tests"),
        ]))

        let result = try await dispatcher.dispatch(name: "moot_memory_search", arguments: .object([
            "query": .string(subject),
        ]))
        let rows = try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "search must return a results array")
        let first = try #require(rows.first?.objectValue, "search must return at least one row")
        #expect(
            first["context"]?.stringValue == subject,
            "compact search row must carry the drawer subject in the context field; got: \(String(describing: first["context"]))")
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
