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

    /// Reads the Nth text block, so the id-map block can be addressed
    /// separately from the prose receipt.
    private func textBlock(_ index: Int, of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              index < content.count,
              case let .object(block) = content[index],
              case let .string(s)? = block["text"]
        else { return "" }
        return s
    }

    private func blockCount(of result: JSONValue) -> Int {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"] else { return 0 }
        return content.count
    }

    @Test("the id map is absent unless asked for, and null is invalid")
    func idMapIsOptInAndNullRejected() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let seed = """
            {"format_version": 1, "name": "opt-in", "records": [
              {"id": "m1", "content": "opt in sentinel", "event_time": "2026-02-01T10:00:00Z", "room": "mcp/optin"}]}
            """

        // Omitted: one block, exactly as before this argument existed.
        let url = try tempSeedFile(seed)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object(["path": .string(url.path)]))
        #expect(!isError(of: plain))
        #expect(blockCount(of: plain) == 1)

        // Explicit null is rejected rather than read as "use the default".
        let url2 = try tempSeedFile(seed.replacingOccurrences(of: "\"m1\"", with: "\"m2\""))
        defer { try? FileManager.default.removeItem(at: url2) }
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_json_import",
                arguments: .object([
                    "path": .string(url2.path),
                    "return_id_map": .null,
                ]))
        }
    }
}
