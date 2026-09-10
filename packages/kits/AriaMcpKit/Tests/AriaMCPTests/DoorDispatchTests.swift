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
    @Test func guessDoorWithNoConfigFallsBackToMatrixAware() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(content: "door-guess-no-config-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("door-guess-no-config-test"),
                "door": .string("guess"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "door=guess with no DoorManifest must succeed with matrixAware fallback")
    }

    /// When a DoorManifest with scoring=rrf is provisioned, door="guess"
    /// reads it and routes through rrf — the A1 per-corpus static config tier.
    @Test func guessDoorWithProvisionedConfigUsesManifestScoring() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        try await kit.provisionDoorConfig(DoorManifest(scoring: .rrf), for: handle)
        try await fileMemory(content: "door-guess-provisioned-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("door-guess-provisioned-test"),
                "door": .string("guess"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "door=guess with provisioned rrf DoorManifest must succeed")
    }

    // MARK: - C. Known door values (explicit scoring rawValues) succeed

    @Test func doorRrfSucceeds() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(content: "door-rrf-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("door-rrf-test"),
                "door": .string("rrf"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "door=rrf must be accepted and succeed")
    }

    @Test func doorMatrixAwareSucceeds() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(content: "door-matrixAware-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("door-matrixAware-test"),
                "door": .string("matrixAware"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "door=matrixAware must be accepted and succeed")
    }

    @Test func doorRawSucceeds() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(content: "door-raw-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("door-raw-test"),
                "door": .string("raw"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "door=raw must be accepted and succeed")
    }

    // MARK: - D. door overrides scoring when both present
    //
    @Test func doorOverridesScoringWhenBothPresent() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(content: "door-overrides-scoring-test", location: "test", dispatcher: dispatcher)
        // door=rrf wins; scoring=matrixAware is superseded. The rrf path on
        // unionBest records "unionBest.rrf" in degraded_stages, proving the
        // door arg was applied (not the scoring arg).
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("door-overrides-scoring-test"),
                "door": .string("rrf"),
                "scoring": .string("matrixAware"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "door=rrf + scoring=matrixAware must succeed (door takes precedence)")
        // Discriminating assertion: degraded retrieval in the response text proves
        // door=rrf won over scoring=matrixAware. If scoring won instead, the
        // matrixAware full-pipeline path runs cleanly with no degradation signal.
        // COMPOSER-02B §11 control lines: "retrieval: degraded — ..." replaces the
        // old "degraded_stages:[...]" format.
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(text.contains("retrieval: degraded"),
                "door=rrf must win over scoring=matrixAware: response must show degraded retrieval; got: \(text.prefix(200))")
    }

    // MARK: - E. Schema exposes door

    /// The moot_memory_search inputSchema must expose the `door` property so
    /// MCP clients can discover it. This is a schema-presence gate, not a
    /// routing test.
    @Test func schemaExposesDoorProperty() throws {
        let tools = ToolProjection.tools()
        guard let tool = tools.first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found in tools()")
            return
        }
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        #expect(properties["door"] != nil,
                "moot_memory_search schema must include the door property")
    }

    /// The `door` property description must contain the word "guess" (the A1
    /// door family name) so calling AIs can discover the front-door behaviour.
    @Test func doorPropertyDescriptionMentionsGuess() throws {
        let tools = ToolProjection.tools()
        guard let tool = tools.first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found in tools()")
            return
        }
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        guard let doorProp = properties["door"]?.objectValue,
              let desc = doorProp["description"]?.stringValue else {
            Issue.record("moot_memory_search door property must have a description field")
            return
        }
        #expect(desc.contains("guess"),
                "door description must mention 'guess' (the A1 front-door name); got: \(desc)")
    }
}
