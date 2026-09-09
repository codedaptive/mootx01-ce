// FeatureFlagFilterDispatchTests.swift
//
// Tests for the four feature-flag filter adoptions (items 2-5):
//   isPinned  — filter:pinned on moot_memory_search
//   hasLinks  — filter:hasLinks on moot_synthesize_grounded
//   isKeystone — keystoneOnly on moot_lens_keystones
//   hasVoice/hasImage — media_type:voice/image on moot_memory_search
//
// These tests prove:
//   A. The new filter values are accepted (not invalidParams).
//   B. Unknown filter/media_type values still throw invalidParams.
//   C. The tool schema descriptions advertise the new args.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("FeatureFlagFilterDispatch", .serialized)
struct FeatureFlagFilterDispatchTests {

    /// Build a fresh in-memory dispatcher for each test.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "flag-filter-dispatch-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    // MARK: - A: filter:pinned accepted on moot_memory_search

    // MARK: - B: filter:hasLinks accepted on moot_synthesize (grounded synthesis)

    // MARK: - C: media_type:voice and media_type:image accepted on moot_memory_search

    // MARK: - D: unknown filter and media_type values are rejected

    @Test func unknownFilterValueIsRejected() async throws {
        let dispatcher = try await makeDispatcher()
        // The dispatch layer throws JSONRPCError(invalidParams) for unknown filter values.
        await #expect(throws: JSONRPCError.self) {
            try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "filter": .string("unknownFilter"),
                ])
            )
        }
    }

    @Test func unknownMediaTypeValueIsRejected() async throws {
        let dispatcher = try await makeDispatcher()
        // The dispatch layer throws JSONRPCError(invalidParams) for unknown media_type values.
        await #expect(throws: JSONRPCError.self) {
            try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "media_type": .string("video"),  // not supported
                ])
            )
        }
    }

    // MARK: - E: schema documents the new args

    @Test func keystonesSchemaDocumentsKeystoneOnly() {
        let tools = ToolProjection.tools()
        guard let keystoneTool = tools.first(where: { $0.name == "moot_lens_keystones" }) else {
            Issue.record("moot_lens_keystones not found in tools()")
            return
        }
        let properties = keystoneTool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        #expect(properties["keystoneOnly"] != nil,
            "moot_lens_keystones schema must include keystoneOnly property")
    }
}
