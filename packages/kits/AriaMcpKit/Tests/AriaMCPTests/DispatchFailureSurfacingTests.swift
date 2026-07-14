// DispatchFailureSurfacingTests.swift
//
// Unexpected runner errors must surface as tool results (isError:true), not
// as thrown JSON-RPC protocol errors. MCP clients render a thrown protocol
// error as a bare "failed to call tool" and discard the message — the model
// never sees WHY the call failed and cannot react or relay it. Substrate
// refusals (VerbError, GeniusLocusKitError) already come back as isError
// results; these tests pin the same discipline for the catch-all path
// (e.g. a CocoaError from the filesystem, a VaultKitError from an adapter).
//
// Trigger: `moot_palace_import` against a palace directory containing a
// malformed tunnels.json. PalaceBridge throws VaultKitError.adapterError —
// neither a VerbError nor a GeniusLocusKitError — which exercises the
// generic catch in ToolDispatcher.dispatch.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Dispatch failure surfacing — unexpected errors are isError results")
struct DispatchFailureSurfacingTests {

    /// Provision a GLK estate and build a ToolDispatcher on its handle,
    /// with vault explicitly enabled so moot_palace_import is routable.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dispatch-failure-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "Dispatch Failure Test Estate",
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

    /// Extract the text payload from a tool-result JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// The isError flag of a tool-result JSONValue.
    private func isError(of result: JSONValue) -> Bool {
        guard case let .object(obj) = result,
              case let .bool(flag)? = obj["isError"] else { return false }
        return flag
    }

    /// A palace directory whose tunnels.json is not valid JSON.
    /// "tunnels.json" is the MemPalaceChromaAdapter layout contract.
    private func makeBrokenPalace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-palace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not valid json".utf8).write(
            to: dir.appendingPathComponent("tunnels.json"))
        return dir
    }

    /// An unexpected runner error (VaultKitError from a malformed palace)
    /// comes back as a tool result with isError:true — dispatch must NOT
    /// throw a JSON-RPC protocol error for it.
    @Test func unexpectedRunnerErrorIsAnErrorResultNotAThrow() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let palace = try makeBrokenPalace()
        defer { try? FileManager.default.removeItem(at: palace) }

        let result = try await dispatcher.dispatch(
            name: "moot_palace_import",
            arguments: .object(["palace_path": .string(palace.path)]))

        #expect(isError(of: result),
            "a failed palace import must be an isError result; got: \(result)")
    }

    /// The underlying error description reaches the client so the model can
    /// see WHY the call failed — the message names the failing file.
    @Test func unexpectedRunnerErrorMessageReachesTheClient() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let palace = try makeBrokenPalace()
        defer { try? FileManager.default.removeItem(at: palace) }

        let result = try await dispatcher.dispatch(
            name: "moot_palace_import",
            arguments: .object(["palace_path": .string(palace.path)]))

        #expect(text(of: result).contains("tunnels.json"),
            "the underlying error description must be in the result text; got: \(text(of: result))")
    }

    /// Protocol-level faults keep their JSON-RPC error shape: an unknown
    /// tool still THROWS methodNotFound — the isError conversion is only
    /// for failures of a call that reached its runner.
    @Test func unknownToolStillThrowsMethodNotFound() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_no_such_tool", arguments: .object([:]))
        }
    }
}
