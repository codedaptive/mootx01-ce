import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Dispatch tests for Tier 3 (Knowledge Graph) and Tier 4 (Journal) tools.
///
/// These tests replace the SWIFT_LEXICON_GAPS_001 lexicon-based tests
/// (MCP-INT-01 surface replacement). The old lexicon surface tools this
/// file covered — `moot_capture_tunnel`, `moot_kgFact_recall`,
/// `moot_diaryEntry_recall`, `moot_proposal_recall`, `moot_association_recall`,
/// `moot_learnedReference_recall` — no longer exist on the AI-client surface.
///
/// Tier 3 KG tools: `moot_file_fact`, `moot_fact_search`, `moot_retire_fact`,
/// `moot_fact_timeline`.
/// Tier 4 Journal tools: `moot_write_journal`, `moot_read_journal`.
///
/// `.serialized`: each live-estate test opens an in-memory estate; preserve
/// one-at-a-time execution to prevent GeniusLocusKit actor contention.
@Suite("KG and Journal dispatch", .serialized)
struct LexiconGapsTests {

    // MARK: - Harness

    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "kg-journal-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    // MARK: - Tier 3: moot_file_fact

    @Test("moot_file_fact without required subject returns invalidParams")
    func fileFactMissingSubjectReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_fact"),
                "arguments": .object([
                    // subject intentionally omitted
                    "predicate": .string("is_a"),
                    "object": .string("element"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing subject must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams)
    }

    // MARK: - Tier 3: moot_fact_search

    @Test("moot_fact_search on empty estate returns success with zero facts")
    func factSearchEmptyEstateReturnsZero() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(3),
            method: "tools/call",
            params: .object([
                "name": .string("moot_fact_search"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_fact_search returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "fact_search must return isError=false on empty estate")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        #expect(text.contains("0"), "empty estate must report zero facts; got: \(text)")
    }

    // MARK: - Tier 3: moot_retire_fact

    // MARK: - Tier 3: moot_fact_timeline

    // MARK: - Tier 4: moot_write_journal

    @Test("moot_write_journal without content returns invalidParams")
    func writeJournalMissingContentReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(8),
            method: "tools/call",
            params: .object([
                "name": .string("moot_write_journal"),
                "arguments": .object([:]),  // entry intentionally omitted
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing content must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams)
    }

    // MARK: - Tier 4: moot_read_journal
}
