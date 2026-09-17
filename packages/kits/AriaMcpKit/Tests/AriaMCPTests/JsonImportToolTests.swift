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

    @Test("the id map is absent for omitted or false, and null is invalid")
    func idMapOmittedFalseAndNullAreContractual() async throws {
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

        // Explicit false is identical to omission: accepted, with no id-map block.
        let falseURL = try tempSeedFile(seed.replacingOccurrences(of: "\"m1\"", with: "\"m-false\""))
        defer { try? FileManager.default.removeItem(at: falseURL) }
        let explicitFalse = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object([
                "path": .string(falseURL.path),
                "return_id_map": .bool(false),
            ]))
        #expect(!isError(of: explicitFalse))
        #expect(blockCount(of: explicitFalse) == 1,
                "return_id_map:false must not add an id-map content block")

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

    /// A record missing `event_time` is a decode failure of the caller's file: an
    /// `invalid_argument` refusal carrying the bridge's message, which names the
    /// record (ruling 2026-09-17). Nothing is written. Rust twin:
    /// selected_json_import_missing_event_time_is_an_invalid_argument_refusal.
    @Test("a record lacking event_time is an invalid_argument refusal naming the record")
    func missingEventTimeIsInvalidArgument() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        // The provisioned estate carries its charter drawers; the theorem is
        // that the refused import adds none.
        let before = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100)).count
        let url = try tempSeedFile("""
            {"format_version": 1, "name": "missing-event-time", "records": [
              {"id": "r1", "content": "no event time", "room": "handoff/room"}]}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await dispatcher.dispatch(
            name: "moot_json_import", arguments: .object(["path": .string(url.path)]))
        #expect(isError(of: result), "a seed decode failure must be refused; got: \(result)")
        let error = try #require(result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("invalid_argument"), "got: \(error)")
        #expect(error["retryable"] == .bool(false))
        let message = try #require(error["message"]?.stringValue)
        for fragment in ["record[0]", "\"r1\"", "event_time is missing"] {
            #expect(message.contains(fragment), "message must name the record and field; got: \(message)")
        }
        let after = try await kit.recall(
            handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100)).count
        #expect(after == before, "a refused import must write zero drawers")
    }

    /// A path that does not resolve stays the availability refusal: the no-oracle
    /// rule for paths is unchanged by the decode-class ruling.
    @Test("a nonexistent seed path stays a mobility_unavailable refusal")
    func nonexistentPathStaysMobilityUnavailable() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-json-import-absent-\(UUID().uuidString).json")
        let result = try await dispatcher.dispatch(
            name: "moot_json_import", arguments: .object(["path": .string(absent.path)]))
        #expect(isError(of: result), "an absent seed must be refused; got: \(result)")
        let error = try #require(result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("mobility_unavailable"), "got: \(error)")
        #expect(error["message"] == .string("The requested data-mobility operation is unavailable in the selected estate."))
    }
}
