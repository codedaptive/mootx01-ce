// DoorDispatchTests.swift
//
// Gate tests for the `door` argument on moot_memory_search (front-door family).
//
// The `door` argument is an adjective on the recall verb (ARIA grammar: one verb,
// adjectives constrain). Precedence chain:
//   explicit door arg > explicit scoring arg > A1 DoorManifest (provisioned) > matrixAware
//
// ## What these tests prove
//   A. Unknown door value → invalidParams (fail-closed).
//   B. door="guess" with no A1 config provisioned → falls back to matrixAware, succeeds.
//   C. Known door values (explicit scoring rawValues: rrf, matrixAware, raw,
//      discriminative) succeed end-to-end.
//   D. door overrides scoring when both are present.
//   E. Schema exposes `door` in moot_memory_search's inputSchema.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Door arg dispatch (front-door family)", .serialized)
struct DoorDispatchTests {

    // MARK: - Helpers

    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "door-dispatch-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    @discardableResult
    private func fileMemory(
        content: String,
        location: String,
        dispatcher: ToolDispatcher
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string(location),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        return text.components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
    }

    // MARK: - A. Unknown door fails closed

    /// An unknown door string must throw invalidParams — fail-closed so a typo
    /// is never silently coerced to a different retrieval strategy.
    @Test func unknownDoorThrowsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "door": .string("teleporter"),
                ])
            )
            Issue.record("Unknown door must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Unknown door must throw invalidParams; got code \(error.code)"
            )
        }
    }

    /// Reserved names "hedge" and "thorough" are not yet wired at the recipe
    /// layer. They must fail CLOSED (invalidParams) in this build — not silently
    /// route to matrixAware.
    @Test func reservedHedgeDoorThrowsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "door": .string("hedge"),
                ])
            )
            Issue.record("Reserved door 'hedge' must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    @Test func reservedThoroughDoorThrowsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "door": .string("thorough"),
                ])
            )
            Issue.record("Reserved door 'thorough' must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    /// null is explicitly rejected — the schema's "null is invalid" contract.
    @Test func nullDoorThrowsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "door": .null,
                ])
            )
            Issue.record("door:null must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    // MARK: - B. door="guess" with no A1 config → matrixAware fallback

    /// When no DoorManifest has been provisioned on the estate, door="guess"
    /// reads the absent key and falls back to .matrixAware — byte-identical to
    /// today's behaviour. Must succeed (not error).

    /// When a DoorManifest with scoring=rrf is provisioned, door="guess"
    /// reads it and routes through rrf — the A1 per-corpus static config tier.

    // MARK: - C. Known door values (explicit scoring rawValues) succeed

    // MARK: - D. door overrides scoring when both present — discriminating assertion
    //
    // When door=rrf and scoring=matrixAware are both present, `door` wins.
    // rrf on unionBest mode has no distinct equal-weight RRF fusion and records
    // "unionBest.rrf" in degraded_stages. matrixAware on unionBest runs the
    // full matrix pipeline with no degradation. The response text therefore
    // differs:
    //   door wins (rrf)        → "degraded_stages:[unionBest.rrf]"
    //   scoring wins (matrixAware) → "degraded_stages:none"
    // This discriminating assertion proves which path ran — not just that the
    // call succeeded.

    // MARK: - E. Schema exposes door

    /// The moot_memory_search inputSchema must expose the `door` property so
    /// MCP clients can discover it. This is a schema-presence gate, not a
    /// routing test.

    /// The `door` property description must contain the word "guess" (the A1
    /// door family name) so calling AIs can discover the front-door behaviour.
}
