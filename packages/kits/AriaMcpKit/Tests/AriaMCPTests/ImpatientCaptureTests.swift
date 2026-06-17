// ImpatientCaptureTests.swift
//
// Dual-Path Intake — ARIA_MCP arg threading (D-A).
//
// `moot_file_memory` gains an optional `impatient: bool` (default false). It is
// an EXECUTION OPTION on the write verb — threaded from the MCP arg to the GLK
// verb param — NOT a field on CaptureFrame. These tests assert:
//   1. the tool schema advertises the `impatient` property,
//   2. an impatient file_memory makes the content immediately semantically
//      searchable (no drain wait),
//   3. a regular file_memory makes the content searchable once the estate's
//      encode queue drains.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Dual-Path Intake — moot_file_memory impatient option (D-A)")
struct ImpatientCaptureTests {

    // MARK: - Schema advertises the impatient option

    @Test func fileMemorySchemaAdvertisesImpatient() throws {
        let tool = try #require(
            ToolProjection.tools().first { $0.name == "moot_file_memory" })
        // Drill into inputSchema.properties.impatient and assert it is a boolean.
        guard case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              case let .object(impatient)? = props["impatient"],
              case let .string(type)? = impatient["type"]
        else {
            Issue.record("moot_file_memory schema must expose an `impatient` property")
            return
        }
        #expect(type == "boolean", "impatient must be a boolean schema; got \(type)")
        // It must NOT be required — default false keeps existing callers working.
        if case let .array(required)? = schema["required"] {
            let names = required.compactMap { v -> String? in
                if case let .string(s) = v { return s }; return nil
            }
            #expect(!names.contains("impatient"),
                "impatient must be optional (not in required) so existing callers are unchanged")
        }
    }

    // MARK: - End-to-end behaviour through the dispatcher

    /// Provision a GLK estate (Corpus + encode queue wired) and build a
    /// ToolDispatcher on its handle.
    private func makeDispatcherOnGLKEstate() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "impatient-capture-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "Impatient Capture Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        return (dispatcher, kit, handle)
    }

    /// Extract the text payload from a `textResult` JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// An impatient file_memory is IMMEDIATELY searchable — no drain wait.
    @Test func impatientFileMemoryIsImmediatelySearchable() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcherOnGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "peregrine falcon stooping dive raptor velocity record"
        _ = try await dispatcher.runFileMemory([
            "content": .string(content),
            "location": .string("birds"),
            "impatient": .bool(true),
        ])

        // No awaitEncodeDrain — impatient encoded inline. Search must find it.
        let result = try await dispatcher.runMemorySearch([
            "query": .string("peregrine falcon raptor"),
        ])
        #expect(text(of: result).contains("peregrine falcon"),
            "impatient-filed memory must be immediately searchable; got: \(text(of: result))")
    }

    /// A regular file_memory becomes searchable once the encode queue drains.
    @Test func regularFileMemoryIsSearchableAfterDrain() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcherOnGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "basalt obsidian rhyolite volcanic rock classification notes"
        // Default (no impatient arg) = regular mode.
        _ = try await dispatcher.runFileMemory([
            "content": .string(content),
            "location": .string("geology"),
        ])

        // Regular mode encodes in the background — wait for the encode queue.
        try await kit.awaitEncodeDrain(for: handle)

        let result = try await dispatcher.runMemorySearch([
            "query": .string("volcanic rock basalt"),
        ])
        #expect(text(of: result).contains("basalt obsidian"),
            "regular-filed memory must be searchable after the encode queue drains; got: \(text(of: result))")
    }
}
