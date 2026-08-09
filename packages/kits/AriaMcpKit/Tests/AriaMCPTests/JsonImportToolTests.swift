// JsonImportToolTests — `moot_json_import` over the MCP dispatch surface.
//
// Part 5 of MXE-JI-1: the seed-file JSON lane (VaultKit JsonImportBridge)
// registered on the ARIA surface. Verifies the tool round-trips a seed
// fixture through a real dispatch call, and that the zero-partial-write
// contract surfaces as an isError tool result (not a protocol throw) with
// the offending element named.

import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("moot_json_import dispatch")
struct JsonImportToolTests {

    /// Provision a GLK estate and build a ToolDispatcher on its handle,
    /// with vault explicitly enabled so moot_json_import is routable.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "json-import-tool-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "JsonImport Tool Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        let dispatcher = ToolDispatcher(
            kit: kit, handle: handle,
            environment: ["MOOTX01_VAULT": "1"])
        return (dispatcher, kit, handle)
    }

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    private func isError(of result: JSONValue) -> Bool {
        guard case let .object(obj) = result,
              case let .bool(flag)? = obj["isError"] else { return false }
        return flag
    }

    private func tempSeedFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-json-import-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test("a seed fixture round-trips through a real moot_json_import call")
    func seedRoundTripsOverMCP() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let url = try tempSeedFile("""
            {"format_version": 1, "name": "mcp-round-trip", "records": [
              {"id": "m1", "content": "mcp round trip sentinel one", "event_time": "2026-02-01T10:00:00Z", "room": "mcp/roundtrip"},
              {"id": "m2", "content": "mcp round trip sentinel two", "event_time": "2026-02-01T11:00:00Z", "room": "mcp/roundtrip"}],
             "facts": [{"subject": "sentinel", "predicate": "counted", "object": "two", "record_id": "m1"}],
             "tunnels": [{"from": "m2", "to": "m1", "kind": "references"}]}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object(["path": .string(url.path)]))

        #expect(!isError(of: result), "import must succeed; got: \(text(of: result))")
        let body = text(of: result)
        #expect(body.contains("2 drawers"))
        #expect(body.contains("1 facts"))
        #expect(body.contains("1 tunnels"))
        #expect(body.contains("seedSha256="))

        // The records are really in the estate the dispatcher served.
        // Provisioned estates pre-seed charter-hint drawers, so filter to
        // this lane's addedBy stamp.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full, limit: 100))
        let imported = drawers.filter { $0.addedBy == "jsonimportbridge-import" }
        #expect(imported.count == 2)
        #expect(imported.contains { $0.content == "mcp round trip sentinel one" })
    }

    @Test("an invalid seed is an isError result naming the element, zero writes")
    func invalidSeedIsErrorResultWithZeroWrites() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let url = try tempSeedFile("""
            {"format_version": 1, "name": "bad", "records": [
              {"id": "m1", "content": "c", "event_time": "2026-02-01T10:00:00Z", "room": "rm"}],
             "tunnels": [{"from": "m1", "to": "m999", "kind": "references"}]}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object(["path": .string(url.path)]))

        #expect(isError(of: result), "validation failure must be an isError result")
        #expect(text(of: result).contains("\"m999\""),
                "the offending element must be named; got: \(text(of: result))")

        // Zero writes — never a partial estate. (Provisioned estates
        // pre-seed charter-hint drawers; none may carry this lane's stamp.)
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100))
        #expect(!drawers.contains { $0.addedBy == "jsonimportbridge-import" })
    }
}
