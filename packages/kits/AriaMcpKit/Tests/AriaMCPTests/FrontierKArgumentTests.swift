// FrontierKArgumentTests.swift
//
// Pins the frontier_k additive argument on moot_memory_search and
// moot_recall_shaped (WIRE 1, P4 study gaps):
//
//   A. Schema exposes frontier_k on both tools.
//   B. frontier_k absent → byte-identical dispatch (no crash, no error).
//   C. frontier_k as integer → dispatches without error.
//   D. frontier_k as non-integer → clear rejection error with the
//      argument name in the message.
//
// These are schema + dispatch boundary tests. They do not assert ranking
// behaviour (the GLK engine's clamping math is covered by GeniusLocusKit
// tests) — they assert that the MCP tool surface correctly threads the
// parameter and correctly rejects bad input.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("frontier_k argument — moot_memory_search and moot_recall_shaped", .serialized)
struct FrontierKArgumentTests {

    // MARK: - Helpers

    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "frontier-k-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    /// Returns the input schema property keys for a named tool.
    private func schemaKeys(for toolName: String) -> Set<String> {
        guard let tool = ToolProjection.tools().first(where: { $0.name == toolName }),
              case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"]
        else { return [] }
        return Set(props.keys)
    }

    /// Return the first text block from a tool result as a String.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Return true when the result carries isError == true.
    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue == true
    }

    // MARK: - A: Schema exposure

    /// moot_memory_search must expose frontier_k in its input schema so MCP clients
    /// can discover the argument. This is a schema-presence gate.
    @Test func schemaExposesFrontierKOnMemorySearch() throws {
        let keys = schemaKeys(for: "moot_memory_search")
        #expect(keys.contains("frontier_k"),
                "moot_memory_search schema must include frontier_k; got keys: \(keys)")
    }

    /// moot_recall_shaped must expose frontier_k in its input schema so MCP clients
    /// can discover the argument. This is a schema-presence gate.
    @Test func schemaExposesFrontierKOnRecallShaped() throws {
        let keys = schemaKeys(for: "moot_recall_shaped")
        #expect(keys.contains("frontier_k"),
                "moot_recall_shaped schema must include frontier_k; got keys: \(keys)")
    }

    // MARK: - B: Absent frontier_k — byte-identical (no error)

    @Test func memorySearchAbsentFrontierKDispatchesWithoutError() async throws {
        let dispatcher = try await makeDispatcher()
        // Empty estate; absent frontier_k returns 0 results without error.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("anything")]))
        #expect(!isError(result),
                "moot_memory_search with no frontier_k must not produce an error")
    }

    @Test func recallShapedAbsentFrontierKDispatchesWithoutError() async throws {
        let dispatcher = try await makeDispatcher()
        // Empty estate; absent frontier_k returns 0 results without error.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object([
                "query": .string("anything"),
                "preset": .string("balanced"),
            ]))
        #expect(!isError(result),
                "moot_recall_shaped with no frontier_k must not produce an error")
    }

    // MARK: - C: Integer frontier_k — accepted without error

    /// An integer frontier_k on moot_memory_search must dispatch without error.
    /// The GLK engine clamps the value internally; the MCP surface passes it through.
    @Test func memorySearchIntegerFrontierKAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("anything"),
                "frontier_k": .integer(128),
            ]))
        #expect(!isError(result),
                "moot_memory_search with integer frontier_k must not produce an error")
    }

    /// An integer frontier_k on moot_recall_shaped must dispatch without error.
    @Test func recallShapedIntegerFrontierKAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object([
                "query": .string("anything"),
                "preset": .string("balanced"),
                "frontier_k": .integer(64),
            ]))
        #expect(!isError(result),
                "moot_recall_shaped with integer frontier_k must not produce an error")
    }

    // MARK: - D: Non-integer frontier_k — clear rejection error
    //
    // optionalInt throws JSONRPCError (code -32602) when the value is present
    // but not an integer, propagating through ToolDispatcher.dispatch as a
    // thrown error (not converted to an isError result). The two tests below
    // assert the error is thrown AND that its message names the argument.

    @Test func memorySearchStringFrontierKRejectedWithClearError() async throws {
        let dispatcher = try await makeDispatcher()
        var caughtMessage = ""
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("anything"),
                    "frontier_k": .string("not-an-integer"),
                ]))
            Issue.record("Expected a throw for non-integer frontier_k on moot_memory_search")
            return
        } catch {
            caughtMessage = String(describing: error)
        }
        #expect(caughtMessage.contains("frontier_k"),
                "Error message must name the frontier_k argument; got: \(caughtMessage)")
    }

    @Test func recallShapedStringFrontierKRejectedWithClearError() async throws {
        let dispatcher = try await makeDispatcher()
        var caughtMessage = ""
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_shaped",
                arguments: .object([
                    "query": .string("anything"),
                    "preset": .string("balanced"),
                    "frontier_k": .string("not-an-integer"),
                ]))
            Issue.record("Expected a throw for non-integer frontier_k on moot_recall_shaped")
            return
        } catch {
            caughtMessage = String(describing: error)
        }
        #expect(caughtMessage.contains("frontier_k"),
                "Error message must name the frontier_k argument; got: \(caughtMessage)")
    }
}
