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

    /// filter:pinned on moot_memory_search must be accepted and dispatch without error.
    /// Before this change, filter:pinned threw "Argument is not available in the
    /// incomplete v2 memory service." Now it routes to .hasFeatureFlag(.isPinned).
    @Test func pinnedFilterIsAcceptedByMemorySearch() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("test"),
                "filter": .string("pinned"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "filter:pinned must be accepted by moot_memory_search")
    }

    // MARK: - B: filter:hasLinks accepted on moot_synthesize (grounded synthesis)

    /// filter:hasLinks on moot_synthesize must be accepted and NOT throw invalidParams.
    /// Synthesis may produce isError:true on an empty estate (no content to synthesise),
    /// but that is a tool-level error, not an argument-rejection error. The gate here
    /// is that filter:hasLinks is not rejected as an unknown argument.
    @Test func hasLinksFilterIsAcceptedByGroundedSynthesis() async throws {
        let dispatcher = try await makeDispatcher()
        // Must not throw JSONRPCError.invalidParams — filter:hasLinks is a valid arg.
        // isError:true in the result is acceptable: empty estate has nothing to synthesise.
        _ = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object([
                "query": .string("test"),
                "filter": .string("hasLinks"),
            ])
        )
        // If dispatch threw invalidParams the test would have failed above.
        // Reaching here means filter:hasLinks was accepted as a valid argument.
    }

    // MARK: - C: media_type:voice and media_type:image accepted on moot_memory_search

    /// media_type:voice on moot_memory_search must be accepted and dispatch without error.
    /// Routes to .hasFeatureFlag(.hasVoice) in the filter chain.
    @Test func mediaTypeVoiceIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("test"),
                "media_type": .string("voice"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "media_type:voice must be accepted by moot_memory_search")
    }

    /// media_type:image on moot_memory_search must be accepted and dispatch without error.
    /// Routes to .hasFeatureFlag(.hasImage) in the filter chain.
    @Test func mediaTypeImageIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("test"),
                "media_type": .string("image"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "media_type:image must be accepted by moot_memory_search")
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

    /// moot_memory_search schema must include the filter property with 'pinned' in its
    /// description, and must expose the media_type property.
    @Test func memorySearchSchemaDocumentsNewArgs() throws {
        let tools = ToolProjection.tools()
        guard let tool = tools.first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found in tools()")
            return
        }
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        #expect(properties["media_type"] != nil,
                "moot_memory_search schema must expose media_type")
        guard let filterProp = properties["filter"]?.objectValue,
              let filterDesc = filterProp["description"]?.stringValue else {
            Issue.record("moot_memory_search filter property must have a description field")
            return
        }
        #expect(filterDesc.contains("pinned"),
                "filter description must mention 'pinned'; got: \(filterDesc)")
    }

    /// moot_synthesize schema must expose the filter property with 'hasLinks' in its
    /// description so clients can discover the citation-scoped synthesis path.
    @Test func groundedSynthesisSchemaDocumentsHasLinks() throws {
        let tools = ToolProjection.tools()
        guard let tool = tools.first(where: { $0.name == "moot_synthesize" }) else {
            Issue.record("moot_synthesize not found in tools()")
            return
        }
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        guard let filterProp = properties["filter"]?.objectValue,
              let filterDesc = filterProp["description"]?.stringValue else {
            Issue.record("moot_synthesize filter property must have a description field; schema: \(properties)")
            return
        }
        #expect(filterDesc.contains("hasLinks"),
                "moot_synthesize filter description must mention 'hasLinks'; got: \(filterDesc)")
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
