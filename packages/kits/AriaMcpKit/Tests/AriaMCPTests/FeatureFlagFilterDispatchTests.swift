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

    @Test func pinnedFilterIsAcceptedByMemorySearch() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("test"),
                "filter": .string("pinned"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? false
        // No memories are pinned in the empty estate, but the call must NOT
        // throw invalidParams — the filter is recognised and produces 0 results.
        #expect(!isError)
    }

    // MARK: - B: filter:hasLinks accepted on moot_synthesize (grounded synthesis)

    @Test func hasLinksFilterIsAcceptedByGroundedSynthesis() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object([
                "filter": .string("hasLinks"),
            ])
        )
        // Empty estate → 0 drawers synthesized; not an invalidParams error.
        let isError = result.objectValue?["isError"]?.boolValue ?? false
        let text = result.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue ?? ""
        #expect(!isError || text.contains("0 drawer"))
    }

    // MARK: - C: media_type:voice and media_type:image accepted on moot_memory_search

    @Test func mediaTypeVoiceIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("voice test"),
                "media_type": .string("voice"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? false
        #expect(!isError)
    }

    @Test func mediaTypeImageIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("image test"),
                "media_type": .string("image"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? false
        #expect(!isError)
    }

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

    @Test func memorySearchSchemaDocumentsNewArgs() {
        let tools = ToolProjection.tools()
        guard let searchTool = tools.first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found in tools()")
            return
        }
        let properties = searchTool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        // filter description must mention "pinned"
        let filterDesc = properties["filter"]?.objectValue?["description"]?.stringValue ?? ""
        #expect(filterDesc.contains("pinned"),
            "moot_memory_search filter description must mention 'pinned'")
        // media_type must be present in the schema
        #expect(properties["media_type"] != nil,
            "moot_memory_search schema must include media_type property")
    }

    @Test func groundedSynthesisSchemaDocumentsHasLinks() {
        let tools = ToolProjection.tools()
        guard let synthTool = tools.first(where: { $0.name == "moot_synthesize" }) else {
            Issue.record("moot_synthesize not found in tools()")
            return
        }
        let properties = synthTool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        let filterDesc = properties["filter"]?.objectValue?["description"]?.stringValue ?? ""
        #expect(filterDesc.contains("hasLinks"),
            "moot_synthesize filter description must mention 'hasLinks'")
    }

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
