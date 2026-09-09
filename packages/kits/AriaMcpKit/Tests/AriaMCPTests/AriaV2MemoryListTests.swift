import CryptoKit
import Foundation
import PersistenceKit
import Testing
@testable import AriaMCP

@Suite("ARIA v2 memory-list cursor session")
struct AriaV2MemoryListTests {
    private let estateID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let firstID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func authorization(_ context: String = "context") -> AriaV2MemoryListAuthorization {
        .init(callerID: "caller", contextID: context, policyVersion: "memory-list-v1")
    }

    private func row(_ id: UUID, subject: String) -> AriaV2MemoryListRow {
        .init(
            memoryID: id,
            ancestryIDs: [], ancestryNames: ["Agentic Memory", "Planning"],
            eligibilityState: "current", visibilityState: "authorized",
            projection: ["subject": .string(subject)])
    }

    private func service(
        provider: FakeSnapshotProvider,
        session: AriaV2MemoryListCursorSession = .init(),
        now: Date? = nil,
        authorization: AriaV2MemoryListAuthorization? = nil
    ) -> AriaV2MemoryListService {
        let instant = now ?? self.now
        return AriaV2MemoryListService(
            provider: provider, cursorSession: session, defaultEstateID: estateID,
            authorization: authorization ?? self.authorization(), now: { instant })
    }

    private func fixture(named name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Conformance/\(name)")
            .standardizedFileURL
        return try JSONValue.parse(Data(contentsOf: url))
    }

    @Test func revisionMatchesTheFrozenCrossPortVector() async throws {
        let fixture = try fixture(named: "aria_v2_memory_list_revision_vectors.json")
        let expected = try #require(fixture.objectValue?["expected_sha256"]?.stringValue)
        let canonical = try #require(fixture.objectValue?["canonical_json"]?.stringValue)
        let fixtureDigest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(fixtureDigest == expected)

        let parentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let wingID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let first = AriaV2MemoryListRow(
            memoryID: UUID(uuidString: "10000000-0000-4000-8000-000000000000")!,
            ancestryIDs: [parentID, wingID], ancestryNames: ["Agentic Memory", "inbox"],
            eligibilityState: "current", visibilityState: "bulk_exportable",
            projection: ["context": .null, "provenance": .string("agent"),
                         "subject": .null, "weight": .integer(7)])
        let last = AriaV2MemoryListRow(
            memoryID: UUID(uuidString: "f0000000-0000-4000-8000-000000000000")!,
            ancestryIDs: [parentID, wingID], ancestryNames: ["Agentic Memory", "inbox"],
            eligibilityState: "current", visibilityState: "bulk_exportable",
            projection: ["context": .string("planning"), "provenance": .null,
                         "subject": .null, "weight": .integer(8)])
        let provider = FakeSnapshotProvider(snapshot: .init(
            estateID: estateID, authorizationGeneration: "authorization-generation-7",
            rows: [last, first]))
        let result = try await service(
            provider: provider,
            authorization: .init(callerID: "caller-binding-a", contextID: "context-42", policyVersion: "policy-v3")
        ).list(arguments: .object([
            "wing": .string("Agentic Memory"), "filter": .string("missing_subject"),
        ]))
        let revision = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["revision"]?.stringValue)
        #expect(revision == expected)
    }

    @Test func listSortsUUIDBytesAndContinuesOnlyAgainstTheSameFullRevision() async throws {
        let provider = FakeSnapshotProvider(snapshot: .init(
            estateID: estateID, authorizationGeneration: "g1",
            rows: [row(thirdID, subject: "third"), row(firstID, subject: "first"), row(secondID, subject: "second")]))
        let session = AriaV2MemoryListCursorSession()
        let first = try await service(provider: provider, session: session).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1),
        ]))
        let firstData = try #require(first.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(firstData["memories"]?.arrayValue?.first?.objectValue?["memory_id"] == .string(firstID.uuidString.lowercased()))
        #expect(firstData["has_more"] == .bool(true))
        let cursor = try #require(firstData["next_cursor"]?.stringValue)
        let revision = try #require(firstData["revision"]?.stringValue)

        let second = try await service(provider: provider, session: session).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1), "cursor": .string(cursor),
        ]))
        let secondData = try #require(second.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(secondData["memories"]?.arrayValue?.first?.objectValue?["memory_id"] == .string(secondID.uuidString.lowercased()))
        #expect(secondData["revision"] == .string(revision))
        #expect(secondData["has_more"] == .bool(true))
        let finalCursor = try #require(secondData["next_cursor"]?.stringValue)

        let final = try await service(provider: provider, session: session).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1), "cursor": .string(finalCursor),
        ]))
        let finalData = try #require(final.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(finalData["memories"]?.arrayValue?.first?.objectValue?["memory_id"] == .string(thirdID.uuidString.lowercased()))
        #expect(finalData["has_more"] == .bool(false))
        #expect(finalData["next_cursor"] == nil)
    }

    @Test func changedFullStateAndScopeMismatchesRefuseWithoutAPartialPage() async throws {
        let provider = FakeSnapshotProvider(snapshot: .init(
            estateID: estateID, authorizationGeneration: "g1",
            rows: [row(firstID, subject: "first"), row(secondID, subject: "second")]))
        let session = AriaV2MemoryListCursorSession()
        let first = try await service(provider: provider, session: session).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1),
        ]))
        let cursor = try #require(first.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["next_cursor"]?.stringValue)

        await provider.replace(.init(
            estateID: estateID, authorizationGeneration: "g2",
            rows: [row(firstID, subject: "first changed"), row(secondID, subject: "second")]))
        let stale = try await service(provider: provider, session: session).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1), "cursor": .string(cursor),
        ]))
        let staleStructured = stale.objectValue?["structuredContent"]?.objectValue
        #expect(staleStructured?["error"]?.objectValue?["code"] == .string("cursor_stale"))
        #expect(staleStructured?["data"] == nil)

        await provider.replace(.init(
            estateID: estateID, authorizationGeneration: "g1",
            rows: [row(firstID, subject: "first"), row(secondID, subject: "second")]))
        let mismatch = try await service(provider: provider, session: session).list(arguments: .object([
            "wing": .string("Other wing"), "limit": .integer(1), "cursor": .string(cursor),
        ]))
        #expect(mismatch.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("cursor_mismatch"))

        let authorizationMismatch = try await service(
            provider: provider, session: session, authorization: authorization("other-context")
        ).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1), "cursor": .string(cursor),
        ]))
        #expect(authorizationMismatch.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("cursor_mismatch"))
    }

    @Test func cursorExpiryAndRetentionCapsUseAbsoluteTTLThenLRU() async throws {
        let session = AriaV2MemoryListCursorSession()
        let scope = AriaV2MemoryListCursorSession.Scope(
            estateID: estateID, wing: "Agentic Memory", room: nil, filter: nil)
        let auth = authorization()
        for index in 0..<33 {
            _ = try await session.retain(
                scope: scope, authorization: auth, revision: "r\(index)",
                lastMemoryID: firstID, now: now.addingTimeInterval(TimeInterval(index)))
        }
        #expect(await session.retainedReferenceCount() == 32)

        for index in 0..<257 {
            _ = try await session.retain(
                scope: scope, authorization: authorization("context-\(index)"), revision: "s\(index)",
                lastMemoryID: secondID, now: now.addingTimeInterval(TimeInterval(100 + index)))
        }
        #expect(await session.retainedReferenceCount() == 256)

        let oversizedScope = AriaV2MemoryListCursorSession.Scope(
            estateID: estateID, wing: "Agentic Memory", room: nil,
            filter: String(repeating: "x", count: AriaV2MemoryListCursorSession.maximumRetainedBytes))
        await #expect(throws: AriaV2MemoryListCursorError.retainedStateLimit) {
            _ = try await session.retain(
                scope: oversizedScope, authorization: auth, revision: "too-large",
                lastMemoryID: thirdID, now: now)
        }

        let provider = FakeSnapshotProvider(snapshot: .init(
            estateID: estateID, authorizationGeneration: "g1",
            rows: [row(firstID, subject: "first"), row(secondID, subject: "second")]))
        let expirySession = AriaV2MemoryListCursorSession()
        let initial = try await service(provider: provider, session: expirySession).list(arguments: .object([
            "wing": .string("Agentic Memory"), "limit": .integer(1),
        ]))
        let cursor = try #require(initial.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["next_cursor"]?.stringValue)
        let expired = try await service(
            provider: provider, session: expirySession,
            now: now.addingTimeInterval(AriaV2MemoryListCursorSession.absoluteTTL)).list(arguments: .object([
                "wing": .string("Agentic Memory"), "limit": .integer(1), "cursor": .string(cursor),
            ]))
        #expect(expired.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("cursor_expired"))
    }

    @Test func requestIsStrictAndSnapshotLimitFailureHasNoPage() async throws {
        let emptyRoom = try AriaV2MemoryListRequest(arguments: .object([
            "wing": .string("Agentic Memory"), "room": .string(""), "filter": .string("missing_subject"),
        ]))
        #expect(emptyRoom.room == nil)
        #expect(emptyRoom.filter == "missing_subject")
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemoryListRequest(arguments: .object([
                "wing": .string("Agentic Memory"), "unexpected": .bool(true),
            ]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2MemoryListRequest(arguments: .object([
                "wing": .string("Agentic Memory"), "filter": .string("all"),
            ]))
        }
        let provider = FakeSnapshotProvider(error: .rowLimitExceeded(table: "drawers", limit: 250_000))
        let result = try await service(provider: provider).list(arguments: .object([
            "wing": .string("Agentic Memory"),
        ]))
        let structured = result.objectValue?["structuredContent"]?.objectValue
        #expect(structured?["error"]?.objectValue?["code"] == .string("inventory_too_large"))
        #expect(structured?["data"] == nil)
    }
}

private actor FakeSnapshotProvider: AriaV2MemoryListSnapshotProvider {
    private var snapshot: AriaV2MemoryListSnapshot?
    private let error: InventorySnapshotError?

    init(snapshot: AriaV2MemoryListSnapshot) {
        self.snapshot = snapshot
        error = nil
    }

    init(error: InventorySnapshotError) {
        snapshot = nil
        self.error = error
    }

    func replace(_ snapshot: AriaV2MemoryListSnapshot) { self.snapshot = snapshot }

    func immutableAuthorizedSnapshot(
        estateID: UUID,
        wing: String,
        room: String?,
        filter: String?,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListSnapshot {
        _ = (estateID, wing, room, filter, authorization)
        if let error { throw error }
        return snapshot!
    }
}
