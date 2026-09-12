import Foundation
import CognitionKit
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

private actor V2RecordingMonitoringControl: MonitoringControl {
    private var enabled: Bool?
    private var reads = 0
    private var writes = 0

    init(enabled: Bool?) {
        self.enabled = enabled
    }

    func read() async -> Bool? {
        reads += 1
        return enabled
    }

    func set(_ enabled: Bool) async {
        writes += 1
        self.enabled = enabled
    }

    func counts() -> (reads: Int, writes: Int) {
        (reads, writes)
    }
}

private final class V2CommunityHandlerInvocationLog: @unchecked Sendable {
    var toolListReads = 0
    var routeChecks = 0
    var dispatches = 0
}

private struct V2CommunityHandlerSpy: CommunityToolHandler {
    let log: V2CommunityHandlerInvocationLog

    func isCommunityTool(_ name: String) -> Bool {
        log.routeChecks += 1
        return true
    }

    var communityToolList: [ProjectedTool] {
        log.toolListReads += 1
        return [ProjectedTool(
            name: "moot_community_test",
            description: "Community test tool.",
            inputSchema: .object(["type": .string("object")]),
            provenance: .community)]
    }

    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        log.dispatches += 1
        return .object(["source": .string("community")])
    }
}

private actor V2FirstPartyHandlerSpy: FirstPartyToolHandler {
    private var toolListReads = 0
    private var routeChecks = 0
    private var dispatches = 0

    func isFirstPartyTool(_ name: String) async -> Bool {
        routeChecks += 1
        return true
    }

    var firstPartyToolList: [ProjectedTool] {
        get async {
            toolListReads += 1
            return [ProjectedTool(
                name: "first_party.test",
                description: "First-party test tool.",
                inputSchema: .object(["type": .string("object")]),
                provenance: .product)]
        }
    }

    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        dispatches += 1
        return .object(["source": .string("first-party")])
    }

    func invocationCounts() -> (toolListReads: Int, routeChecks: Int, dispatches: Int) {
        (toolListReads, routeChecks, dispatches)
    }
}

@Suite("ARIA v2 selected surface", .serialized)
struct AriaSurfaceV2Tests {
    private static let pinnedEnvironment = [
        BenchClock.envKey: "2026-09-08T00:00:00Z",
    ]

    private func makeDispatcher(
        frozen: Bool = false,
        control: V2RecordingMonitoringControl? = nil,
        environment: [String: String] = [:]
    ) async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-surface-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (
            ToolDispatcher(
                kit: kit,
                handle: handle,
                monitoringControl: control,
                environment: Self.pinnedEnvironment.merging(environment) { _, override in override },
                posture: frozen ? .frozen : .live),
            kit,
            handle)
    }

    private func firstText(_ result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/aria_v2_mission01_vectors.json")
    }

    private func loadFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private func mission02CatalogOperation(_ name: String) throws -> [String: JSONValue] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/aria_v2_mission02_vectors.json")
        let fixture = try JSONValue.parse(Data(contentsOf: fixtureURL))
        let operations = try #require(fixture.objectValue?["catalog"]?.objectValue?["operations"]?.arrayValue)
        return try #require(operations.first {
            $0.objectValue?["name"]?.stringValue == name
        }?.objectValue)
    }

    private func fixtureVector(_ name: String, from root: [String: Any]) throws -> [String: Any] {
        guard let vector = (root["vectors"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return vector
    }

    private func expectedMCPResult(_ name: String, from root: [String: Any]) throws -> JSONValue {
        let vector = try fixtureVector(name, from: root)
        guard let expected = vector["expected_mcp_result"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONValue.from(expected)
    }

    private func testIdentity() -> FirstPartyServerIdentity {
        FirstPartyServerIdentity(
            name: "aria-v2-test",
            binaryVersion: "test",
            instanceIdentifier: UUID(),
            estateIdentifier: UUID(),
            descriptorGeneration: 1,
            credentialGeneration: 1,
            contractRevision: 1,
            mcpProtocolVersion: "2025-03-26")
    }

    private func listedToolNames(_ dispatcher: ARIA_MCPDispatcher) async throws -> [String] {
        let response = try #require(await dispatcher.handle(
            JSONRPCRequest(id: .integer(1), method: "tools/list", params: nil)))
        guard case .result(let result) = response.payload else {
            Issue.record("tools/list did not return a result")
            return []
        }
        return result.objectValue?["tools"]?.arrayValue?.compactMap {
            $0.objectValue?["name"]?.stringValue
        } ?? []
    }

    private func expectInactiveTeachmeRejected(_ dispatcher: ARIA_MCPDispatcher) async throws {
        let response = try #require(await dispatcher.handle(JSONRPCRequest(
            id: .integer(2), method: "tools/call",
            params: .object([
                "name": .string("moot_inactive_legacy_memory_action"),
                "arguments": .object(["teachme": .bool(true)]),
            ]))))
        guard case .error(let error) = response.payload else {
            Issue.record("inactive v1 tool unexpectedly returned a result")
            return
        }
        #expect(error.code == JSONRPCErrorCode.methodNotFound)
    }

    @Test func selectedCatalogAdvertisesOnlyReadyTypedHandlers() throws {
        let tools = ToolProjection.tools(environment: [:])
        #expect(tools.map(\.name) == [
            "moot_confirm_memory", "moot_connection_map", "moot_connection_search", "moot_dataset_query", "moot_dataset_stats", "moot_drain_status", "moot_dream",
            "moot_erase_memory", "moot_estate_map", "moot_estate_ping", "moot_estate_status",
            "moot_fact_search", "moot_fact_timeline", "moot_federated_recall", "moot_file_dataset", "moot_file_fact", "moot_file_memory",
            "moot_help", "moot_hunt_contradictions",
            "moot_json_import",
            "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations", "moot_lens_bias",
            "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts", "moot_lens_constellation", "moot_lens_contradiction", "moot_lens_divergence",
            "moot_lens_drift", "moot_lens_free_association", "moot_lens_keystones", "moot_lens_latent_themes",
            "moot_lens_moment", "moot_lens_node_motion", "moot_lens_overlap", "moot_lens_partial_cue",
            "moot_lens_precedence", "moot_lens_rhythm", "moot_lens_successors", "moot_lens_theme_weather",
            "moot_lens_trust_synthesis", "moot_link_memories",
            "moot_list_lenses", "moot_list_recipes", "moot_memory_get",
            "moot_memory_list", "moot_memory_recall_transcript", "moot_memory_search", "moot_migration_confirm", "moot_migration_run",
            "moot_monitoring_set", "moot_monitoring_status", "moot_move_memory",
            "moot_palace_import", "moot_propose_contradictions",
            "moot_read_journal", "moot_rebuild_status", "moot_recall_connected",
            "moot_recall_distilled", "moot_recall_precise", "moot_recall_shaped",
            "moot_recall_temporal", "moot_recall_vague", "moot_recall_walk", "moot_reclassify_fdc", "moot_reindex",
            "moot_retire_fact", "moot_review_tunnel", "moot_synthesize", "moot_timing_report", "moot_update_memory",
            "moot_vault_export", "moot_vault_import", "moot_vault_job", "moot_vault_reconcile", "moot_vault_status",
            "moot_withdraw_memory", "moot_write_journal",
        ])
        #expect(tools.count == 80)
        #expect(tools.allSatisfy { $0.outputSchema != nil })
        #expect(tools.allSatisfy { $0.annotations != nil })
        #expect(tools.first { $0.name == "moot_memory_get" }?.annotations == .object([
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false), "openWorldHint": .bool(false),
        ]))
        #expect(tools.first { $0.name == "moot_file_memory" }?.annotations == .object([
            "readOnlyHint": .bool(false), "destructiveHint": .bool(false), "openWorldHint": .bool(false),
        ]))
        #expect(tools.first { $0.name == "moot_erase_memory" }?.annotations == .object([
            "readOnlyHint": .bool(false), "destructiveHint": .bool(true), "openWorldHint": .bool(false),
        ]))
        #expect(tools.first { $0.name == "moot_vault_export" }?.annotations == .object([
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false), "openWorldHint": .bool(true),
        ]))
        let memoryList = try #require(tools.first { $0.name == "moot_memory_list" })
        let dataSchema = memoryList.outputSchema?.objectValue?["properties"]?
            .objectValue?["data"]?.objectValue
        #expect(dataSchema?["additionalProperties"] == .bool(false))
        #expect(dataSchema?["required"]?.arrayValue == [
            .string("memories"), .string("has_more"), .string("revision"),
        ])
        let memorySearch = try #require(tools.first { $0.name == "moot_memory_search" })
        let searchItemProperties = memorySearch.outputSchema?.objectValue?["properties"]?
            .objectValue?["data"]?.objectValue?["properties"]?
            .objectValue?["results"]?.objectValue?["items"]?
            .objectValue?["properties"]?.objectValue
        #expect(searchItemProperties?["excerpt"]?.objectValue == [
            "type": .string("string"), "maxLength": .integer(512),
        ])

        let diagnosticNames = Set([
            "moot_estate_ping", "moot_estate_status", "moot_estate_map",
            "moot_drain_status", "moot_rebuild_status", "moot_timing_report",
        ])
        let diagnosticTools = tools.filter { diagnosticNames.contains($0.name) }
        #expect(Set(diagnosticTools.map(\.name)) == diagnosticNames)
        for tool in diagnosticTools {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue
            #expect((properties.map { Set($0.keys) } ?? Set<String>()) == Set(["estate_id"]))
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
            let data = tool.outputSchema?.objectValue?["properties"]?.objectValue?["data"]?.objectValue
            #expect(data?["additionalProperties"] == .bool(false))
        }

        let mutationNames = Set([
            "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory",
            "moot_confirm_memory", "moot_move_memory", "moot_link_memories", "moot_review_tunnel",
        ])
        let mutationTools = tools.filter { mutationNames.contains($0.name) }
        #expect(Set(mutationTools.map(\.name)) == mutationNames)
        for tool in mutationTools {
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
            let data = tool.outputSchema?.objectValue?["properties"]?.objectValue?["data"]?.objectValue
            #expect(data != nil)
            #expect(
                data?["oneOf"] != nil
                    || (data?["type"] == .string("object")
                        && data?["additionalProperties"] == .bool(false)))
        }
        let eraseInput = try #require(tools.first { $0.name == "moot_erase_memory" }?.inputSchema.objectValue)
        let eraseProperties = try #require(eraseInput["properties"]?.objectValue)
        #expect(eraseProperties["confirmation"]?.objectValue?["type"] == .string("boolean"))
        #expect(eraseProperties["confirmation"]?.objectValue?["const"] == .bool(true))
        #expect(eraseProperties["reason"]?.objectValue?["type"] == .string("string"))
        #expect(eraseInput["required"]?.arrayValue == [.string("memory_id"), .string("confirmation")])

        let mobilityNames = Set([
            "moot_reindex", "moot_reclassify_fdc", "moot_palace_import", "moot_json_import",
            "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
            "moot_vault_status", "moot_vault_reconcile",
        ])
        let mobilityTools = tools.filter { mobilityNames.contains($0.name) }
        #expect(Set(mobilityTools.map(\.name)) == mobilityNames)
        for tool in mobilityTools where ![
            "moot_reclassify_fdc", "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
        ].contains(tool.name) {
            let data = tool.outputSchema?.objectValue?["properties"]?.objectValue?["data"]?.objectValue
            #expect(data?["additionalProperties"] == .bool(false))
        }
    }

    @Test func selectedCatalogUsesEffectiveVaultAvailabilityForListHelpDispatchAndDigest() async throws {
        let enabled = ToolProjection.tools(environment: [:])
        let explicitlyEnabled = ToolProjection.tools(environment: ["MOOTX01_VAULT": "1"])
        let disabled = ToolProjection.tools(environment: ["MOOTX01_VAULT": "0"])
        #expect(enabled.count == 80)
        #expect(explicitlyEnabled.map(\.name) == enabled.map(\.name))
        #expect(disabled.count == 73)
        #expect(disabled.allSatisfy { !$0.name.hasPrefix("moot_vault_") })
        #expect(disabled.allSatisfy { !["moot_palace_import", "moot_json_import"].contains($0.name) })
        #expect(
            AriaV2SelectedCatalog.capabilityDigest(environment: ["MOOTX01_VAULT": "0"])
                != AriaV2SelectedCatalog.capabilityDigest
        )

        let (dispatcher, kit, handle) = try await makeDispatcher(
            environment: ["MOOTX01_VAULT": "0"])
        defer { Task { try? await kit.close(handle) } }

        let help = try await dispatcher.dispatch(name: "moot_help", arguments: .object([:]))
        let structured = try #require(help.objectValue?["structuredContent"]?.objectValue)
        let operations = try #require(structured["data"]?.objectValue?["operations"]?.arrayValue)
        #expect(operations.count == 73)
        #expect(operations.allSatisfy {
            $0.objectValue?["name"]?.stringValue != "moot_vault_export"
        })
        #expect(structured["meta"]?.objectValue?["capability_digest"] == .string(
            AriaV2SelectedCatalog.capabilityDigest(environment: ["MOOTX01_VAULT": "0"])))

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_vault_export",
                arguments: .object(["vaultPath": .string("/tmp/disabled")]))
            Issue.record("vault-disabled selected surface dispatched a removed operation")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.methodNotFound)
        }
    }

    @Test func selectedDatasetCatalogMatchesFrozenMission02Schemas() throws {
        for name in [
            "moot_reclassify_fdc", "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
        ] {
            let expected = try mission02CatalogOperation(name)
            let actual = try #require(AriaV2SelectedCatalog.descriptors.first { $0.publicName == name })
            #expect(actual.inputSchema == expected["inputSchema"])
            #expect(actual.projection.outputSchema == expected["outputSchema"])
            #expect(actual.help.description == expected["description"]?.stringValue)
            #expect(actual.effect.rawValue == expected["effect"]?.stringValue)
        }
    }

    @Test func selectedFiniteAndExclusiveInputsMatchFrozenMission02Schemas() throws {
        let tools = ToolProjection.tools(environment: [:])
        for name in [
            "moot_memory_get", "moot_memory_search", "moot_link_memories",
            "moot_review_tunnel", "moot_file_dataset",
            "moot_dream", "moot_lens_partial_cue",
        ] {
            let expected = try mission02CatalogOperation(name)
            let actual = try #require(tools.first { $0.name == name })
            #expect(actual.inputSchema == expected["inputSchema"], "\(name) input schema")
        }
    }

    @Test func selectedVaultLifecycleUsesTypedJobCustodyAndFrozenPolicy() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let unknown = try await dispatcher.dispatch(
            name: "moot_vault_job",
            arguments: .object(["job_id": .string(UUID().uuidString)]))
        let unknownStructured = unknown.objectValue?["structuredContent"]?.objectValue
        #expect(unknownStructured?["tool"] == .string("moot_vault_job"))
        #expect(unknownStructured?["error"]?.objectValue?["code"] == .string("mobility_unavailable"))

        let (frozen, frozenKit, frozenHandle) = try await makeDispatcher(frozen: true)
        defer { Task { try? await frozenKit.close(frozenHandle) } }
        let refused = try await frozen.dispatch(
            name: "moot_vault_import",
            arguments: .object(["vaultPath": .string("/tmp/aria-v2-unopened-vault")]))
        #expect(refused.objectValue?["structuredContent"]?.objectValue?["error"]?
            .objectValue?["code"] == .string("estate_frozen"))
    }

    @Test func selectedRecallFamilyUsesDirectTypedProjection() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let names = [
            "moot_recall_precise", "moot_recall_temporal", "moot_recall_connected",
            "moot_recall_shaped", "moot_recall_distilled", "moot_recall_vague",
            "moot_recall_walk",
        ]
        for name in names {
            let result = try await dispatcher.dispatch(
                name: name, arguments: .object(["query": .string("typed recall")]))
            let structured = try #require(result.objectValue?["structuredContent"]?.objectValue)
            #expect(structured["tool"] == .string(name))
            #expect(structured["error"] == nil)
            #expect(structured["data"]?.objectValue?["results"]?.arrayValue != nil)
            #expect(structured["meta"]?.objectValue?["effect"] == .string("read"))
        }
    }

    @Test func selectedDatasetQueryUsesDirectTypedProjection() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let filed = try await dispatcher.dispatch(name: "moot_file_dataset", arguments: .object([
            "name": .string("scores"),
            "location": .string("test"),
            "columns": .array([.object(["name": .string("score"), "type": .string("int")])]),
            "rows": .array([.object(["score": .integer(7)])]),
        ]))
        let filedData = try #require(filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        let datasetID = try #require(filedData["dataset_id"]?.stringValue)
        #expect(filed.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("write"))

        let queried = try await dispatcher.dispatch(name: "moot_dataset_query", arguments: .object([
            "dataset_id": .string(datasetID),
            "where": .object(["col": .string("score"), "op": .string("gte"), "val": .integer(7)]),
            "limit": .integer(1),
        ]))
        let queryData = try #require(queried.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(queryData["dataset_id"] == .string(datasetID))
        #expect(queryData["rows_returned"] == .integer(1))
        #expect(queried.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func selectedLensSliceUsesDirectTypedProjection() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let result = try await dispatcher.dispatch(
            name: "moot_lens_keystones", arguments: .object(["wing": .string("work")]))
        let structured = try #require(result.objectValue?["structuredContent"]?.objectValue)
        #expect(structured["tool"] == .string("moot_lens_keystones"))
        #expect(structured["error"] == nil)
        #expect(structured["data"]?.objectValue?["keystones"]?.arrayValue != nil)
        #expect(structured["meta"]?.objectValue?["effect"] == .string("read"))

        let weather = try await dispatcher.dispatch(
            name: "moot_lens_theme_weather", arguments: .object([:]))
        let weatherData = weather.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect(weatherData?["weather"]?.arrayValue != nil)

        let complexity = try await dispatcher.dispatch(
            name: "moot_lens_complexity", arguments: .object(["fieldA": .string("room")]))
        let complexityData = complexity.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        if case .double? = complexityData?["result"]?.objectValue?["entropyA"] {
            // Expected typed numeric projection.
        } else {
            Issue.record("expected complexity entropyA to be a double")
        }
    }

    @Test func selectedSynthesisUsesDirectTypedProjection() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        for sensitivity in [
            LocusKit.Sensitivity.normal, .elevated, .restricted, .secret,
        ] {
            let label = String(describing: sensitivity).lowercased()
            let suffix = sensitivity == .normal ? String(repeating: "🦀", count: 513) : "\(label)token"
            _ = try await kit.capture(handle, CaptureFrame(
                content: "typed synthesis q29 \(label) \(suffix)",
                channel: .typed,
                room: "q29-synthesis",
                latticeAnchor: .udc("004"),
                addedBy: "aria-v2-tests",
                embeddingModelID: "test-model-v1",
                provenanceSensitivity: sensitivity,
                subject: "q29 \(label)"))
        }
        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object(["query": .string("typed synthesis q29"), "limit": .integer(10)]))
        let structured = try #require(result.objectValue?["structuredContent"]?.objectValue)
        #expect(structured["tool"] == .string("moot_synthesize"))
        #expect(structured["error"] == nil)
        let data = try #require(structured["data"]?.objectValue)
        let summary = try #require(data["summary"]?.stringValue)
        let rows = try #require(data["results"]?.arrayValue)
        let subjects = Set(rows.compactMap { $0.objectValue?["subject"]?.stringValue })
        #expect(subjects == Set(["q29 normal", "q29 elevated"]))
        #expect(!summary.contains("restrictedtoken"))
        #expect(!summary.contains("secrettoken"))
        for row in rows {
            let object = try #require(row.objectValue)
            #expect(object["context"] == nil)
            #expect((object["excerpt"]?.stringValue?.unicodeScalars.count ?? 0) <= 512)
            #expect(object["fetch"]?.objectValue?["tool"] == .string("moot_memory_get"))
        }
        #expect(structured["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func selectedSynthesisRanksAnOlderQueryMatchAboveRecentDistractors() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let relevant = try await kit.capture(handle, CaptureFrame(
            content: "Orchard radio calibration uses channel 17 and the amber coupler.",
            channel: .typed,
            room: "q29-query",
            latticeAnchor: .udc("004"),
            addedBy: "aria-v2-tests",
            embeddingModelID: "test-model-v1",
            subject: "orchard radio"))
        for index in 0..<3 {
            _ = try await kit.capture(handle, CaptureFrame(
                content: "Recent unrelated distractor \(index).",
                channel: .typed,
                room: "q29-query",
                latticeAnchor: .udc("004"),
                addedBy: "aria-v2-tests",
                embeddingModelID: "test-model-v1",
                subject: "unrelated \(index)"))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object([
                "query": .string("orchard radio calibration"),
                "limit": .integer(1),
            ]))
        let rows = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue)
        #expect(rows.count == 1)
        #expect(rows[0].objectValue?["memory_id"] == .string(relevant.id.lowercased()))
    }

    @Test func selectedEstateDiagnosticsUseTypedProviderAndExactReadData() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let ping = try await dispatcher.dispatch(name: "moot_estate_ping", arguments: .object([:]))
        let pingData = ping.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect((pingData.map { Set($0.keys) } ?? Set<String>()) == Set(["estate_id", "estate_name", "state", "build_serial"]))
        #expect(pingData?["estate_id"] == .string(handle.estateUUID.uuidString.lowercased()))
        #expect(pingData?["state"] == .string("mounted"))

        let drains = try await dispatcher.dispatch(name: "moot_drain_status", arguments: .object([:]))
        let drainData = drains.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect((drainData.map { Set($0.keys) } ?? Set<String>()) == Set(["drains"]))
        #expect(drainData?["drains"] == .array([]))

        let rebuild = try await dispatcher.dispatch(name: "moot_rebuild_status", arguments: .object([:]))
        let rebuildData = rebuild.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect(rebuildData == ["state": .string("idle")])
        #expect(rebuild.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func selectedCognitionDirectoriesUseLiveTypedRegistries() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let lenses = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object(["verbose": .bool(true)]))
        let lensData = lenses.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let tools = try #require(lensData?["tools"]?.arrayValue)
        #expect(tools.map { $0.objectValue?["name"]?.stringValue } == [
            "moot_list_lenses", "moot_list_recipes", "moot_synthesize",
            "moot_recall_precise", "moot_recall_temporal", "moot_recall_shaped",
            "moot_recall_connected", "moot_dream", "moot_recall_distilled", "moot_recall_vague",
            "moot_hunt_contradictions", "moot_recall_walk", "moot_lens_keystones",
            "moot_lens_constellation", "moot_lens_free_association",
            "moot_lens_theme_weather", "moot_lens_latent_themes", "moot_lens_bias",
            "moot_lens_drift", "moot_lens_node_motion", "moot_lens_cohesion", "moot_lens_contradiction", "moot_lens_trust_synthesis",
            "moot_lens_partial_cue", "moot_lens_anticipate", "moot_lens_successors",
            "moot_lens_overlap", "moot_lens_divergence", "moot_lens_moment", "moot_lens_rhythm",
            "moot_lens_precedence", "moot_lens_complexity", "moot_lens_associations", "moot_lens_concepts",
            "moot_lens_apriori",
        ])
        for tool in tools {
            let row = try #require(tool.objectValue)
            #expect(row["description"]?.stringValue != nil)
            #expect(row["input_schema"]?.objectValue != nil)
        }
        #expect(lenses.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))

        // verbose:true to fetch the full row including required_capabilities.
        let recipes = try await dispatcher.dispatch(
            name: "moot_list_recipes", arguments: .object(["verbose": .bool(true)]))
        let recipeData = recipes.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let rows = try #require(recipeData?["recipes"]?.arrayValue)
        #expect(rows.count == RecipeCatalog.all.count)
        let first = try #require(rows.first?.objectValue)
        #expect(first["name"] == .string(RecipeCatalog.all[0].name))
        #expect(first["version"] == .string(RecipeCatalog.all[0].version))
        #expect(first["required_capabilities"]?.arrayValue != nil)

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_list_lenses", arguments: .object(["verbose": .string("true")]))
            Issue.record("typed cognition directory accepted a non-boolean verbose value")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    @Test func inactiveNamesRejectBeforeClockAndSessionMutationEvenWithTeachme() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_inactive_legacy_memory_action",
                arguments: .object(["teachme": .bool(true)]))
            Issue.record("inactive v1 name unexpectedly reached dispatch")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.methodNotFound)
        } catch {
            Issue.record("inactive v1 name returned an unexpected error: \(error)")
        }

        let sessionSnapshot = await dispatcher.modeSessionState.snapshot
        #expect(sessionSnapshot.totalCalls == 0)
        let firstClockSample = dispatcher.benchClock.now()
        let pinnedBase = try #require(dispatcher.benchClock.pinnedBase)
        #expect(firstClockSample == pinnedBase)
    }

    @Test func monitoringResultsUseV2ReadEnvelopeIncludingUnavailable() async throws {
        for (expectedState, control) in [
            ("enabled", V2RecordingMonitoringControl(enabled: true)),
            ("unavailable", nil),
        ] as [(String, V2RecordingMonitoringControl?)] {
            let (dispatcher, kit, handle) = try await makeDispatcher(control: control)
            let result = try await dispatcher.dispatch(
                name: "moot_monitoring_status", arguments: .object([:]))
            let structured = result.objectValue?["structuredContent"]?.objectValue
            #expect(structured?["data"]?.objectValue?["monitoring"] == .string(expectedState))
            #expect(structured?["meta"]?.objectValue?["effect"] == .string("read"))
            #expect(structured?["meta"]?.objectValue?["capability_digest"] == .string(AriaV2SelectedCatalog.capabilityDigest))
            #expect(structured?["meta"]?.objectValue?["build_id"] == .string(dispatcher.buildSerial))
            if let control {
                let counts = await control.counts()
                #expect(counts.reads == 1)
                #expect(counts.writes == 0)
            }
            try await kit.close(handle)
        }
    }

    @Test func invalidArgumentErrorsMatchSharedFixtureBeforeReading() async throws {
        let fixture = try loadFixture()
        let control = V2RecordingMonitoringControl(enabled: true)
        let (dispatcher, kit, handle) = try await makeDispatcher(control: control)
        defer { Task { try? await kit.close(handle) } }

        for vectorName in ["non_object_arguments_are_invalid", "enabled_argument_is_invalid_for_inspection"] {
            let vector = try fixtureVector(vectorName, from: fixture)
            let request = try #require(vector["request"] as? [String: Any])
            let arguments = try JSONValue.from(try #require(request["arguments"]))
            let expected = try JSONValue.from(try #require(vector["expected_jsonrpc_error"]))
            do {
                _ = try await dispatcher.dispatch(
                    name: try #require(request["name"] as? String), arguments: arguments)
                Issue.record("v2 monitoring inspection accepted invalid vector \(vectorName)")
            } catch let error as JSONRPCError {
                #expect(error.asJSONValue == expected)
            } catch {
                Issue.record("v2 monitoring inspection returned an unexpected error for \(vectorName): \(error)")
            }
        }
        let rejectedCounts = await control.counts()
        #expect(rejectedCounts.reads == 0)
        #expect(rejectedCounts.writes == 0)
    }

    @Test func frozenV2InspectionReadsAndRendersTypedEnvelopeWithoutWriting() async throws {
        let control = V2RecordingMonitoringControl(enabled: true)
        let (dispatcher, kit, handle) = try await makeDispatcher(frozen: true, control: control)
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(name: "moot_monitoring_status", arguments: .object([:]))
        let structured = result.objectValue?["structuredContent"]?.objectValue
        #expect(structured?["data"]?.objectValue?["monitoring"] == .string("enabled"))
        #expect(structured?["meta"]?.objectValue?["effect"] == .string("read"))
        let inspectionCounts = await control.counts()
        #expect(inspectionCounts.reads == 1)
        #expect(inspectionCounts.writes == 0)

        let diagnostic = try await dispatcher.dispatch(name: "moot_drain_status", arguments: .object([:]))
        #expect(diagnostic.objectValue?["isError"] == .bool(false))
        #expect(diagnostic.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))

        let cognitionDirectory = try await dispatcher.dispatch(name: "moot_list_lenses", arguments: .object([:]))
        #expect(cognitionDirectory.objectValue?["isError"] == .bool(false))
        #expect(cognitionDirectory.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func monitoringSetWritesOnlyWhenLiveAndReturnsConfirmedState() async throws {
        let liveControl = V2RecordingMonitoringControl(enabled: true)
        let (live, liveKit, liveHandle) = try await makeDispatcher(control: liveControl)
        let written = try await live.dispatch(
            name: "moot_monitoring_set", arguments: .object(["enabled": .bool(false)]))
        #expect(written.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["monitoring"] == .string("disabled"))
        #expect(written.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("write"))
        let liveCounts = await liveControl.counts()
        #expect(liveCounts.reads == 1)
        #expect(liveCounts.writes == 1)
        try await liveKit.close(liveHandle)

        let frozenControl = V2RecordingMonitoringControl(enabled: true)
        let (frozen, frozenKit, frozenHandle) = try await makeDispatcher(
            frozen: true, control: frozenControl)
        defer { Task { try? await frozenKit.close(frozenHandle) } }
        let refused = try await frozen.dispatch(
            name: "moot_monitoring_set", arguments: .object(["enabled": .bool(false)]))
        #expect(refused.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("estate_frozen"))
        let frozenCounts = await frozenControl.counts()
        #expect(frozenCounts.reads == 0)
        #expect(frozenCounts.writes == 0)
    }

    @Test func typedMemoryVerticalFilesSearchesAndGetsWithoutLegacyDispatch() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let filed = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("ARIA v2 direct typed memory."),
                "subject": .string("ARIA v2 direct typed memory."),
                "location": .string("typed-memory-tests"),
                "wing": .string("ARIA V2 Memory List Tests"),
            ]))
        let memoryID = try #require(
            filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memory_id"]?.stringValue)
        #expect(UUID(uuidString: memoryID) != nil)
        #expect(filed.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("write"))

        let searched = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("direct typed memory"), "limit": .integer(5)]))
        #expect(searched.objectValue?["isError"] == .bool(false))
        #expect(searched.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))

        let fetched = try await dispatcher.dispatch(
            name: "moot_memory_get",
            arguments: .object(["memory_id": .string(memoryID), "depth": .string("full")]))
        let memories = fetched.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memories"]?.arrayValue
        #expect(memories?.first?.objectValue?["memory_id"] == .string(memoryID))
        #expect(memories?.first?.objectValue?["content"] == .string("ARIA v2 direct typed memory."))

        let secondFiled = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("ARIA v2 second direct typed memory."),
                "subject": .string("ARIA v2 second direct typed memory."),
                "location": .string("typed-memory-tests"),
                "wing": .string("ARIA V2 Memory List Tests"),
            ]))
        let secondMemoryID = try #require(
            secondFiled.objectValue?["structuredContent"]?.objectValue?["data"]?
                .objectValue?["memory_id"]?.stringValue)

        let listed = try await dispatcher.dispatch(
            name: "moot_memory_list",
            arguments: .object([
                "wing": .string("ARIA V2 Memory List Tests"),
                "limit": .integer(1),
            ]))
        let listedData = listed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let listedMemories = listedData?["memories"]?.arrayValue ?? []
        #expect(listed.objectValue?["isError"] == .bool(false))
        #expect(listedData?["revision"]?.stringValue?.count == 64)
        #expect(listedData?["has_more"] == .bool(true))
        let cursor = try #require(listedData?["next_cursor"]?.stringValue)

        let continued = try await dispatcher.dispatch(
            name: "moot_memory_list",
            arguments: .object([
                "wing": .string("ARIA V2 Memory List Tests"),
                "limit": .integer(1),
                "cursor": .string(cursor),
            ]))
        let continuedData = continued.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let continuedMemories = continuedData?["memories"]?.arrayValue ?? []
        #expect(continued.objectValue?["isError"] == .bool(false))
        #expect(continuedData?["revision"] == listedData?["revision"])
        #expect(continuedData?["has_more"] == .bool(false))
        let listedIDs = Set((listedMemories + continuedMemories).compactMap {
            $0.objectValue?["memory_id"]?.stringValue
        })
        #expect(listedIDs == Set([memoryID, secondMemoryID]))
        #expect((listedMemories + continuedMemories).allSatisfy { row in
            let listedID = row.objectValue?["memory_id"]?.stringValue
            return row.objectValue?["fetch"]?.objectValue?["arguments"]?
                .objectValue?["memory_id"]?.stringValue == listedID
        })
        #expect((listedMemories + continuedMemories).allSatisfy { row in
            Set(row.objectValue?.keys.map { $0 } ?? [])
                .isSubset(of: ["memory_id", "subject", "score", "provenance", "context", "fetch"])
        })

        let help = try await dispatcher.dispatch(name: "moot_help", arguments: .object([:]))
        let helpOperations = help.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["operations"]?.arrayValue
        #expect(helpOperations?.count == ToolProjection.tools(environment: Self.pinnedEnvironment).count)
    }

    @Test func frozenV2MutationRefusesBeforeClockOrEstateWrite() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(frozen: true)
        defer { Task { try? await kit.close(handle) } }
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("must not land"),
                "subject": .string("must not land"),
                "location": .string("frozen"),
            ]))
        #expect(result.objectValue?["isError"] == .bool(true))
        #expect(result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("estate_frozen"))
        let firstClockSample = dispatcher.benchClock.now()
        #expect(firstClockSample == dispatcher.benchClock.pinnedBase)
    }

    @Test func selectedKnowledgeJournalFilesSearchesAndReadsWithoutLegacyDispatch() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let memory = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Source for the typed knowledge journal regression."),
                "subject": .string("Typed knowledge journal source."),
                "location": .string("typed-knowledge-journal-tests"),
            ]))
        let sourceID = try #require(
            memory.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memory_id"]?.stringValue)

        let filed = try await dispatcher.dispatch(
            name: "moot_file_fact",
            arguments: .object([
                "subject": .string("typed knowledge journal"),
                "predicate": .string("uses"),
                "object": .string("direct lower calls"),
                "source_memory_id": .string(sourceID),
            ]))
        let fact = filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect(filed.objectValue?["isError"] == .bool(false))
        #expect(fact?["source_memory_id"] == .string(sourceID))
        #expect(filed.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("write"))

        let searched = try await dispatcher.dispatch(
            name: "moot_fact_search", arguments: .object(["query": .string("direct lower")]))
        let facts = searched.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["facts"]?.arrayValue
        #expect(facts?.contains { $0.objectValue?["source_memory_id"] == .string(sourceID) } == true)
        #expect(searched.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))

        let written = try await dispatcher.dispatch(
            name: "moot_write_journal",
            arguments: .object([
                "content": .string("Typed journal entry."),
                "tags": .string("aria-v2"),
            ]))
        #expect(written.objectValue?["isError"] == .bool(false))
        #expect(written.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("write"))

        let journal = try await dispatcher.dispatch(
            name: "moot_read_journal", arguments: .object(["limit": .integer(10)]))
        let entries = journal.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["entries"]?.arrayValue
        #expect(entries?.contains { $0.objectValue?["entry"] == .string("Typed journal entry.") } == true)
        #expect(journal.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func frozenKnowledgeJournalWritesRefuseBeforeLowerCalls() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(frozen: true)
        defer { Task { try? await kit.close(handle) } }

        let requests: [(String, JSONValue)] = [
            ("moot_file_fact", .object([
                "subject": .string("blocked"), "predicate": .string("is"), "object": .string("blocked"),
            ])),
            ("moot_retire_fact", .object(["fact_id": .string(UUID().uuidString)])),
            ("moot_write_journal", .object(["content": .string("blocked")])),
        ]
        for (name, arguments) in requests {
            let result = try await dispatcher.dispatch(name: name, arguments: arguments)
            #expect(result.objectValue?["isError"] == .bool(true))
            #expect(result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("estate_frozen"))
        }
    }

    @Test func selectedMemoryMutationsUseTypedAdaptersAndFrozenGate() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let filed = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Mutation target."),
                "subject": .string("Mutation target."),
                "location": .string("typed-mutation-tests"),
            ]))
        let memoryID = try #require(
            filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memory_id"]?.stringValue)

        let confirmed = try await dispatcher.dispatch(
            name: "moot_confirm_memory", arguments: .object(["memory_id": .string(memoryID)]))
        let confirmedData = confirmed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect(confirmedData == ["memory_id": .string(memoryID), "mutation": .string("confirm")])
        #expect(confirmed.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("write"))

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_confirm_memory",
                arguments: .object(["memory_id": .string(memoryID), "unexpected": .bool(true)]))
            Issue.record("selected mutation accepted an unknown argument")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }

        let (frozen, frozenKit, frozenHandle) = try await makeDispatcher(frozen: true)
        defer { Task { try? await frozenKit.close(frozenHandle) } }
        let refused = try await frozen.dispatch(
            name: "moot_confirm_memory", arguments: .object(["memory_id": .string(UUID().uuidString)]))
        #expect(refused.objectValue?["isError"] == .bool(true))
        #expect(refused.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("estate_frozen"))
    }

    @Test func toolsListUsesTheSameSelectedCatalogAsDispatch() async throws {
        let expectedNames = ToolProjection.tools(environment: Self.pinnedEnvironment).map(\.name)
        let (tooling, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let server = ARIA_MCPDispatcher(
            info: .init(name: "aria-v2-test", version: "test"), tooling: tooling)
        let rawResponse = await server.handle(
            JSONRPCRequest(id: .integer(1), method: "tools/list", params: nil))
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("tools/list did not return a result")
            return
        }
        let tools = try #require(result.objectValue?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0.objectValue?["name"]?.stringValue } == expectedNames)
        #expect(tools.allSatisfy { $0.objectValue?["annotations"] != nil })
        #expect(tools.first { $0.objectValue?["name"] == .string("moot_memory_get") }?
            .objectValue?["annotations"]?.objectValue?["readOnlyHint"] == .bool(true))

        let rawMonitoringResponse = await server.handle(JSONRPCRequest(
            id: .integer(2), method: "tools/call",
            params: .object([
                "name": .string("moot_monitoring_status"),
                "arguments": .object([:]),
            ])))
        let monitoringResponse = try #require(rawMonitoringResponse)
        guard case .result(let monitoringResult) = monitoringResponse.payload else {
            Issue.record("full v2 server did not return typed monitoring inspection")
            return
        }
        #expect(monitoringResult.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["monitoring"] == .string("unavailable"))
        #expect(monitoringResult.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func selectedMemorySearchAndGetExcludeProvenanceSensitiveRows() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        var hiddenIDs: [String] = []
        for sensitivity in [
            LocusKit.Sensitivity.normal, .elevated, .restricted, .secret,
        ] {
            let label = String(describing: sensitivity).lowercased()
            let drawer = try await kit.capture(handle, CaptureFrame(
                content: "q23 provenance boundary \(label) common-token",
                channel: .typed,
                room: "q23-provenance",
                latticeAnchor: .udc("004"),
                addedBy: "aria-v2-tests",
                embeddingModelID: "test-model-v1",
                provenanceSensitivity: sensitivity,
                subject: "q23 \(label)"))
            if sensitivity == .restricted || sensitivity == .secret {
                hiddenIDs.append(drawer.id)
            }
        }

        let searched = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("q23 provenance boundary common-token"), "limit": .integer(10)]))
        let rows = try #require(searched.objectValue?["structuredContent"]?.objectValue?["data"]?
            .objectValue?["results"]?.arrayValue)
        let subjects = Set(rows.compactMap { $0.objectValue?["subject"]?.stringValue })
        #expect(subjects.contains("q23 normal"))
        #expect(subjects.contains("q23 elevated"))
        #expect(!subjects.contains("q23 restricted"))
        #expect(!subjects.contains("q23 secret"))

        for memoryID in hiddenIDs {
            let response = try await dispatcher.dispatch(
                name: "moot_memory_get",
                arguments: .object(["memory_id": .string(memoryID)]))
            #expect(response.objectValue?["isError"] == .bool(true))
            #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?
                .objectValue?["code"] == .string("memory_not_found"))
        }
    }

    @Test func communityOnlyV2SurfaceStaysEmptyAcrossDirectAuthenticatedAndPublicLanes() async throws {
        let communityLog = V2CommunityHandlerInvocationLog()
        let firstPartyHandler = V2FirstPartyHandlerSpy()
        let direct = ARIA_MCPDispatcher(
            info: .init(name: "aria-v2-test", version: "test"),
            communityHandler: V2CommunityHandlerSpy(log: communityLog),
            firstPartyHandler: firstPartyHandler)
        let authenticated = direct.withFirstPartyIdentity(testIdentity())
        let publicLane = authenticated.publicLane

        #expect(direct.firstPartyIdentity == nil)
        #expect(authenticated.firstPartyIdentity != nil)
        #expect(publicLane.firstPartyIdentity == nil)
        #expect(publicLane.firstPartyHandler == nil)
        #expect(direct.tools.isEmpty)
        #expect(authenticated.tools.isEmpty)
        #expect(publicLane.tools.isEmpty)

        for dispatcher in [direct, authenticated, publicLane] {
            #expect(try await listedToolNames(dispatcher).isEmpty)
            try await expectInactiveTeachmeRejected(dispatcher)
        }

        #expect(communityLog.toolListReads == 0)
        #expect(communityLog.routeChecks == 0)
        #expect(communityLog.dispatches == 0)
        let firstPartyCounts = await firstPartyHandler.invocationCounts()
        #expect(firstPartyCounts.toolListReads == 0)
        #expect(firstPartyCounts.routeChecks == 0)
        #expect(firstPartyCounts.dispatches == 0)
    }
}

