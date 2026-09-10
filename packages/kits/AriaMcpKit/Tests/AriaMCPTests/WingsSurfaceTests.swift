// WingsSurfaceTests.swift
//
// wing organization Wings SURFACE lane — AriaMcpKit changes.
//
// Tests for:
//   Change 1: `moot_file_memory` accepts an optional `wing` argument that
//             routes the drawer into the named wing; absent defaults to
//             LocusKit.defaultWingName ("Agentic Memory").
//   Change 2: `moot_estate_map` shows hint drawers (AI_Charter_Hint room) as
//             normal room count lines — no inline "charter:" special rendering.
//   Change 3: `moot_memory_search`, `moot_recall_precise`, and
//             `moot_recall_shaped` accept an optional `wing` argument
//             that scopes recall to a single wing.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// wing surface tests — estate_map hint drawers as normal entries + recall wing scoping.
///
/// `.serialized`: every case provisions a live in-memory GLK estate; preserve
/// one-at-a-time execution to avoid shared state between cases.
@Suite("wing organization Wings Surface — estate_map hint-drawer entries + recall wing scoping", .serialized)
struct WingsSurfaceTests {

    // MARK: - Shared harness

    /// Provision a fresh GLK estate (seeds the seven default wings with their
    /// hint drawers in AI_Charter_Hint room) and return a wired ToolDispatcher.
    private func makeProvisionedDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "wings-surface-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "Wings Surface Test Estate",
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

    /// Extract the `text` string from a textResult JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Extract estate_map content from a v2 response.
    ///
    /// The v2 estate_map stores map data in structuredContent.data.wings (not in
    /// the compact text block). This helper converts the structured wings/rooms
    /// data to the canonical "  WingName/\n    RoomName: N" text format so that
    /// assertions written against that format work correctly on the v2 surface.
    /// Falls back to the compact text block if structured content is absent
    /// (v1 path compatibility).
    private func estateMapText(of result: JSONValue) -> String {
        if let wings = result.objectValue?["structuredContent"]?.objectValue?["data"]?
                .objectValue?["wings"]?.arrayValue {
            var lines: [String] = []
            for wingVal in wings {
                guard let wingObj = wingVal.objectValue,
                      let name = wingObj["name"]?.stringValue,
                      !name.isEmpty,
                      let rooms = wingObj["rooms"]?.arrayValue
                else { continue }
                lines.append("  \(name)/")
                for roomVal in rooms {
                    guard let roomObj = roomVal.objectValue,
                          let roomName = roomObj["name"]?.stringValue,
                          let count = roomObj["memory_count"]?.integerValue
                    else { continue }
                    lines.append("    \(roomName): \(count)")
                }
            }
            return lines.joined(separator: "\n")
        }
        return text(of: result)
    }

    // MARK: - Change 1: moot_file_memory wing routing

    /// `moot_file_memory` with an explicit `wing` must land the drawer in that wing.
    /// `moot_estate_map` confirms placement after capture.
    @Test func fileMemoryExplicitWingLandsInCorrectWing() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("explicit-wing-routing-test memory"),
                "subject": .string("explicit-wing-routing-test memory"),
                "location": .string("test-room"),
                "wing": .string("Projects"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map", arguments: .object([:]))
        // v2 estate_map stores data in structuredContent; estateMapText extracts it.
        let output = estateMapText(of: result)
        #expect(output.contains("Projects/"),
            "estate_map must show the 'Projects' wing after explicit wing routing; got:\n\(output)")
    }

    /// `moot_file_memory` without a `wing` argument must land in "Agentic Memory"
    /// (the default wing — LocusKit.defaultWingName). Recall scoped to that wing
    /// must find the drawer; recall scoped to a different wing must not find it.
    @Test func fileMemoryAbsentWingDefaultsToAgenticMemory() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("absent-wing-defaults-to-agentic-memory-test"),
                "subject": .string("absent-wing-defaults-to-agentic-memory-test"),
                "location": .string("test-room"),
            ]))

        // moot_memory_search with wing="Agentic Memory" must find the drawer.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("absent-wing-defaults-to-agentic-memory-test"),
                "wing": .string("Agentic Memory"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "absent wing must default to Agentic Memory and be findable; got: \(obj)")
    }

    /// `moot_file_memory` `wing` schema must advertise an optional `wing` property.
    @Test func fileMemorySchemaAdvertisesWingArgument() throws {
        let tool = try #require(
            ToolProjection.tools().first { $0.name == "moot_file_memory" })
        guard case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              case let .object(wingProp)? = props["wing"]
        else {
            Issue.record("moot_file_memory schema must expose a `wing` property")
            return
        }
        guard case let .string(type)? = wingProp["type"] else {
            Issue.record("moot_file_memory `wing` schema must have a `type` field")
            return
        }
        #expect(type == "string", "file_memory wing must be a string schema; got \(type)")

        // `wing` must be optional — not in `required`.
        if case let .array(required)? = schema["required"] {
            let names = required.compactMap { v -> String? in
                if case let .string(s) = v { return s }; return nil
            }
            #expect(!names.contains("wing"),
                "file_memory wing must be optional (not in `required`) so existing callers are unchanged")
        }
    }

    // MARK: - Change 2: estate_map shows hint drawers as normal room entries

    /// `moot_estate_map` must show the "Agentic Memory" wing with its hint drawer
    /// counted as a normal room entry (AI_Charter_Hint: 1). No inline "charter: <text>"
    /// special rendering — hint drawers are normal drawers.

    /// `moot_estate_map` must show the "Agentic Memory" wing with its hint drawer
    /// counted as a normal room entry (AI_Charter_Hint: 1). No inline "charter: <text>"
    /// special rendering — hint drawers are normal drawers.
    @Test func estateMapSurfacesAgenticMemoryWithHintDrawerCount() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map", arguments: .object([:]))
        // v2 estate_map stores data in structuredContent; estateMapText extracts it.
        let output = estateMapText(of: result)

        #expect(output.contains("Agentic Memory/"),
            "estate_map must show Agentic Memory wing; got:\n\(output)")
        #expect(output.contains("AI_Charter_Hint"),
            "estate_map must show AI_Charter_Hint room as a normal count entry; got:\n\(output)")
    }

    /// All seven default wings must appear in `moot_estate_map` output.
    @Test func estateMapSurfacesAllSevenDefaultWings() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map", arguments: .object([:]))
        // v2 estate_map stores data in structuredContent; estateMapText extracts it.
        let output = estateMapText(of: result)

        let expectedWings = ["Agentic Memory", "User Canon", "Source Corpus",
                              "Personal", "Professional", "Projects", "Temp"]
        for wing in expectedWings {
            #expect(output.contains("\(wing)/"),
                "estate_map must show \(wing) wing; got:\n\(output)")
        }
    }

    /// Hint drawers (AI_Charter_Hint room) must appear as a normal room count line
    /// under each wing, not as inline "charter: <text>" and not as "_charter: N".
    @Test func estateMapShowsHintDrawerAsNormalRoomCount() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map", arguments: .object([:]))
        // v2 estate_map stores data in structuredContent; estateMapText extracts it.
        let output = estateMapText(of: result)

        // AI_Charter_Hint must appear as a room count line (e.g. "    AI_Charter_Hint: 1"),
        // not as an inline "charter: <text>" rendering.
        #expect(output.contains("AI_Charter_Hint:"),
            "hint drawer must appear as 'AI_Charter_Hint: N' count line, not inline charter text; got:\n\(output)")
        #expect(!output.contains("charter: "),
            "estate_map must not contain inline 'charter: <text>' rendering; got:\n\(output)")
    }

    /// The old `_charter` room name must not appear in estate_map output at all —
    /// neither as a count line nor as inline charter text.
    @Test func estateMapDoesNotReferenceOldCharterRoomName() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map", arguments: .object([:]))
        let output = text(of: result)

        #expect(!output.contains("_charter"),
            "estate_map must not reference old _charter room name; got:\n\(output)")
    }

    // MARK: - Change 3: schema verification — wing argument declared

    /// `moot_memory_search` schema must advertise an optional `wing` property.
    @Test func memorySearchSchemaAdvertisesWingArgument() throws {
        let tool = try #require(
            ToolProjection.tools().first { $0.name == "moot_memory_search" })
        guard case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              props["wing"] != nil
        else {
            Issue.record("moot_memory_search schema must expose a `wing` property")
            return
        }
        // wing must be optional — not in required.
        if case let .array(required)? = schema["required"] {
            let names = required.compactMap { v -> String? in
                if case let .string(s) = v { return s }; return nil
            }
            #expect(!names.contains("wing"),
                "moot_memory_search wing must be optional (not in required)")
        }
    }

    /// `moot_recall_precise` schema must advertise an optional `wing` property.
    @Test func recallPreciseSchemaAdvertisesWingArgument() throws {
        let tool = try #require(
            ToolProjection.tools().first { $0.name == "moot_recall_precise" })
        guard case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              case let .object(wingProp)? = props["wing"]
        else {
            Issue.record("moot_recall_precise schema must expose a `wing` property")
            return
        }
        guard case let .string(type)? = wingProp["type"] else {
            Issue.record("moot_recall_precise `wing` must have a `type` field")
            return
        }
        #expect(type == "string", "wing must be a string schema; got \(type)")
    }

    /// `moot_recall_shaped` schema must advertise an optional `wing` property.
    @Test func recallShapedSchemaAdvertisesWingArgument() throws {
        let tool = try #require(
            ToolProjection.tools().first { $0.name == "moot_recall_shaped" })
        guard case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              case let .object(wingProp)? = props["wing"]
        else {
            Issue.record("moot_recall_shaped schema must expose a `wing` property")
            return
        }
        guard case let .string(type)? = wingProp["type"] else {
            Issue.record("moot_recall_shaped `wing` must have a `type` field")
            return
        }
        #expect(type == "string", "wing must be a string schema; got \(type)")
    }

    // MARK: - Change 3: behaviour — moot_memory_search

    /// `moot_memory_search` without a `wing` arg must succeed unchanged.
    /// Confirms the default path (no wing filter) is unbroken.
    @Test func memorySearchWithoutWingSucceedsUnchanged() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("arctic fox camouflage snow winter survival"),
                "subject": .string("arctic fox camouflage snow winter survival"),
                "location": .string("wildlife"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("arctic fox")]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "memory_search without wing must succeed; got: \(obj)")
    }

    /// `moot_memory_search` with `wing` = "Agentic Memory" must succeed.
    /// Captured content lands in defaultWingName ("Agentic Memory"), so the
    /// scoped search must not error.
    @Test func memorySearchWithDefaultWingScopedSucceeds() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("wing-scoped-search-agentic-memory"),
                "subject": .string("wing-scoped-search-agentic-memory"),
                "location": .string("wildlife"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("wing-scoped-search-agentic-memory"),
                "wing": .string("Agentic Memory"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "memory_search scoped to 'Agentic Memory' must succeed; got: \(obj)")
    }

    /// `moot_memory_search` scoped to an empty wing must succeed (no error)
    /// even when no content is in that wing. Empty is a valid result.
    @Test func memorySearchWithEmptyWingScopedSucceeds() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("empty-wing-test"),
                "wing": .string("Projects"),  // wing exists but has no relevant content
            ]))
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "memory_search on an empty wing must succeed with no results, not error")
    }

    // MARK: - Change 3: behaviour — moot_recall_precise

    /// `moot_recall_precise` without `wing` must succeed unchanged.
    @Test func recallPreciseWithoutWingSucceedsUnchanged() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("black bear foraging berry season omnivore"),
                "subject": .string("black bear foraging berry season omnivore"),
                "location": .string("wildlife"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("black bear"),
                "filter": .string("unconfirmed"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "recall_precise without wing must succeed; got: \(obj)")
    }

    /// `moot_recall_precise` with `wing` = "Agentic Memory" must succeed.
    /// The wing filter is composed with the existing base filter via Filter.all.
    @Test func recallPreciseWithWingSucceeds() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("mountain lion cougar puma altitude range stealth"),
                "subject": .string("mountain lion cougar puma altitude range stealth"),
                "location": .string("wildlife"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("mountain lion"),
                "filter": .string("unconfirmed"),
                "wing": .string("Agentic Memory"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "recall_precise scoped to 'Agentic Memory' must succeed; got: \(obj)")
    }

    // MARK: - Change 3: behaviour — moot_recall_shaped

    /// `moot_recall_shaped` without `wing` must succeed unchanged.
    @Test func recallShapedWithoutWingSucceedsUnchanged() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("wolverine boreal forest solitary wide range"),
                "subject": .string("wolverine boreal forest solitary wide range"),
                "location": .string("wildlife"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object([
                "query": .string("wolverine"),
                "filter": .string("unconfirmed"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "recall_shaped without wing must succeed; got: \(obj)")
    }

    /// `moot_recall_shaped` with `wing` = "Agentic Memory" must succeed.
    /// The wing filter is composed with the existing base filter via Filter.all.
    @Test func recallShapedWithWingSucceeds() async throws {
        let (dispatcher, kit, handle) = try await makeProvisionedDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("snowy owl arctic tundra silent flight prey"),
                "subject": .string("snowy owl arctic tundra silent flight prey"),
                "location": .string("wildlife"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object([
                "query": .string("snowy owl"),
                "filter": .string("unconfirmed"),
                "wing": .string("Agentic Memory"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false),
            "recall_shaped scoped to 'Agentic Memory' must succeed; got: \(obj)")
    }
}
