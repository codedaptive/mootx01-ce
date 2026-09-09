import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 direct data-mobility lower bindings")
struct AriaV2DataMobilityDirectTests {
    @Test("advertises only source-backed direct mobility lower operations")
    func supportedOperationsAreExplicit() {
        #expect(AriaV2DataMobilityLower.supported == [
            "moot_reindex", "moot_reclassify_fdc", "moot_palace_import", "moot_json_import",
            "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
            "moot_vault_status", "moot_vault_reconcile",
        ])
    }

    @Test("remaining typed lowers retain strict query bounds and projections")
    func remainingLowerRequestsAreStrict() throws {
        let reclassify = try AriaV2DataMobilityRequest.decode(
            tool: "moot_reclassify_fdc", arguments: .object([:]))
        #expect(reclassify.tool == "moot_reclassify_fdc")
        #expect(reclassify.effect == .write)

        let query = try AriaV2DataMobilityRequest.decode(
            tool: "moot_dataset_query",
            arguments: .object([
                "dataset_id": .string("11111111-1111-4111-8111-111111111111"),
                "where": .object(["col": .string("score"), "op": .string("gte"), "val": .integer(1)]),
                "order_by": .array([.object(["col": .string("score"), "dir": .string("desc")])]),
                "limit": .integer(1_000),
                "columns": .array([.string("score")]),
            ]))
        #expect(query.tool == "moot_dataset_query")
        #expect(query.effect == .read)

        do {
            _ = try AriaV2DataMobilityRequest.decode(
                tool: "moot_dataset_query",
                arguments: .object([
                    "dataset_id": .string("11111111-1111-4111-8111-111111111111"),
                    "limit": .integer(1_001),
                ]))
            Issue.record("Expected query limit above 1000 to be refused")
        } catch {}

        do {
            _ = try AriaV2DataMobilityRequest.decode(
                tool: "moot_dataset_query",
                arguments: .object([
                    "dataset_id": .string("11111111-1111-4111-8111-111111111111"),
                    "columns": .array([.string("")]),
                ]))
            Issue.record("Expected an empty projection column to be refused")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    @Test("file dataset requires exactly one inline or CSV source")
    func fileDatasetRejectsMissingOrConflictingSources() throws {
        let base: [String: JSONValue] = ["name": .string("events"), "location": .string("lab")]
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2DataMobilityRequest.decode(
                tool: "moot_file_dataset", arguments: .object(base))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2DataMobilityRequest.decode(
                tool: "moot_file_dataset", arguments: .object(base.merging([
                    "rows": .array([]), "csv_path": .string("/tmp/events.csv"),
                ]) { _, replacement in replacement }))
        }
    }

    @Test("selected mobility tools decode to stable identity and effect")
    func selectedMobilitySurfaceIdentity() throws {
        let cases: [(String, [String: JSONValue], AriaOperation, AriaV2OperationEffect)] = [
            ("moot_reindex", [:], .reindex, .write),
            ("moot_palace_import", ["palace_path": .string("/tmp/palace")], .palaceImport, .write),
            ("moot_json_import", ["path": .string("/tmp/seed.json")], .jsonImport, .write),
            ("moot_vault_status", ["vaultPath": .string("/tmp/vault")], .vaultStatus, .read),
            ("moot_vault_reconcile", ["vaultPath": .string("/tmp/vault")], .vaultReconcile, .write),
        ]

        for (tool, arguments, operation, effect) in cases {
            let request = try AriaSurfaceDecoder.decode(name: tool, arguments: arguments)
            #expect(request.operation.rawValue == operation.rawValue)
            switch (effect, request.operation.effect) {
            case (.read, .inspection), (.write, .mutation):
                break
            default:
                Issue.record("Unexpected operation effect for \(tool)")
            }
            guard case .dataMobility(let mobility) = request else {
                Issue.record("Expected data-mobility request for \(tool)")
                continue
            }
            #expect(mobility.tool == tool)
            #expect(mobility.effect == effect)
        }
    }

    @Test("typed selected request executes without argument reconstruction")
    func typedRequestRendersDirectOutcome() async throws {
        let result = try await AriaV2DataMobility(authority: ReindexReceiptAuthority()).execute(
            .reindex(estateID: nil))
        let structured = result.objectValue?["structuredContent"]?.objectValue
        #expect(structured?["tool"] == .string("moot_reindex"))
        #expect(structured?["data"] == .object(["state": .string("already_running")]))
        #expect(structured?["meta"]?.objectValue?["effect"] == .string("write"))
    }

    @Test("vault status snapshots preserve missing and stamped manifest state")
    func vaultStatusSnapshot() throws {
        let vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aria-v2-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let empty = try VaultTools.statusSnapshot(vaultURL: vault)
        #expect(empty.path == vault.path)
        #expect(empty.manifest == nil)

        let manifest = VaultTools.ExportManifest(
            version: VaultTools.manifestSchemaVersion,
            exportedAt: "2026-09-08T12:00:00Z",
            noteCount: 3,
            files: [:]
        )
        try VaultTools.writeManifest(manifest, to: vault)
        let stamped = try VaultTools.statusSnapshot(vaultURL: vault)
        #expect(stamped.manifest?.noteCount == 3)
        #expect(stamped.manifest?.exportedAt == "2026-09-08T12:00:00Z")
    }

    @Test("JSON import projects real drawer identifiers as canonical lowercase UUIDs")
    func jsonImportCanonicalizesRealDrawerIDs() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let handle = try await kit.provision(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "aria-v2-json-id-map"),
            params: EstateProvisionParams(
                estateName: "ARIA v2 JSON ID map",
                kind: .glk,
                zoomWindowLow: 1,
                zoomWindowHigh: 10,
                frameworkProfile: "KnowledgeWork",
                syncMode: .none),
            embeddingModels: [.deterministic])
        defer { Task { try? await kit.close(handle) } }

        let seed = FileManager.default.temporaryDirectory
            .appendingPathComponent("aria-v2-json-id-map-\(UUID().uuidString).json")
        try Data("""
            {"format_version":1,"name":"canonical-id-map","records":[
              {"id":"source-record","content":"canonical id map sentinel","event_time":"2026-09-09T00:00:00Z","room":"tests/id-map","exportability":"public"}
            ]}
            """.utf8).write(to: seed)
        defer { try? FileManager.default.removeItem(at: seed) }

        let result = try await AriaV2DataMobility(
            authority: AriaV2GeniusLocusDataMobilityAuthority(
                kit: kit,
                handle: handle,
                selectedEstateID: handle.estateUUID,
                now: Date(timeIntervalSince1970: 1_788_912_000)))
            .execute(tool: "moot_json_import", arguments: .object(["path": .string(seed.path)]))
        let map = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["id_map"]?.objectValue)
        let projected = try #require(map["source-record"]?.stringValue)
        let parsed = try #require(UUID(uuidString: projected))
        #expect(projected == parsed.uuidString.lowercased())
        #expect(map.count == 1)
    }

    @Test("JSON import refusal then corrected retry writes only the corrected seed")
    func jsonImportFailureThenCorrectedRetryHasOneReceipt() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.provision(storage: storage, owner: OwnerCredentials(ownerIdentifier: "aria-v2-import-retry"), params: EstateProvisionParams(estateName: "retry", kind: .glk, zoomWindowLow: 1, zoomWindowHigh: 10, frameworkProfile: "KnowledgeWork", syncMode: .none), embeddingModels: [.deterministic])
        defer { Task { try? await kit.close(handle) } }
        let seed = FileManager.default.temporaryDirectory.appendingPathComponent("aria-v2-import-retry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: seed) }
        try Data("{not-json".utf8).write(to: seed)
        let mobility = AriaV2DataMobility(authority: AriaV2GeniusLocusDataMobilityAuthority(kit: kit, handle: handle, selectedEstateID: handle.estateUUID, now: Date(timeIntervalSince1970: 1_788_912_000)))
        let refused = try await mobility.execute(tool: "moot_json_import", arguments: .object(["path": .string(seed.path)]))
        #expect(refused.objectValue?["isError"] == .bool(true))
        try Data("{\"format_version\":1,\"name\":\"retry\",\"records\":[{\"id\":\"once\",\"content\":\"corrected retry\",\"event_time\":\"2026-09-09T00:00:00Z\",\"room\":\"handoff/room\",\"exportability\":\"public\"}]}".utf8).write(to: seed)
        let recovered = try await mobility.execute(tool: "moot_json_import", arguments: .object(["path": .string(seed.path)]))
        let data = try #require(recovered.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["drawers_written"] == .integer(1))
        #expect(data["id_map"]?.objectValue?.count == 1)
    }

    @Test("typed lower refusal preserves its operational reason")
    func lowerRefusalIsNotCollapsed() async throws {
        let result = try await AriaV2DataMobility(authority: RefusingAuthority()).execute(
            tool: "moot_dataset_query",
            arguments: .object(["dataset_id": .string("11111111-1111-4111-8111-111111111111")])
        )
        let error = result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
        #expect(error?["code"] == .string("mobility_lower_unavailable"))
        #expect(error?["retryable"] == .bool(false))
    }

    @Test("v2 dataset lower validates columns and comparison types against the handle")
    func datasetQueryUsesHandleSchemaBeforeStorage() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let handle = try await kit.provision(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "aria-v2-dataset-schema"),
            params: EstateProvisionParams(
                estateName: "ARIA v2 dataset schema",
                kind: .glk,
                zoomWindowLow: 1,
                zoomWindowHigh: 10,
                frameworkProfile: "KnowledgeWork",
                syncMode: .none),
            embeddingModels: [.deterministic])
        defer { Task { try? await kit.close(handle) } }

        let filed = try await DatasetTools.directFileDataset(
            arguments: [
                "name": .string("typed-query"),
                "location": .string("tests/dataset"),
                "columns": .array([
                    .object(["name": .string("label"), "type": .string("text")]),
                    .object(["name": .string("score"), "type": .string("int")]),
                    .object(["name": .string("ratio"), "type": .string("float")]),
                    .object(["name": .string("enabled"), "type": .string("bool")]),
                ]),
                "rows": .array([
                    .object([
                        "label": .string("alpha"), "score": .integer(7),
                        "ratio": .double(1.5), "enabled": .bool(true),
                    ]),
                    .object([
                        "label": .string("beta"), "score": .integer(2),
                        "ratio": .double(3.5), "enabled": .bool(false),
                    ]),
                ]),
            ],
            kit: kit,
            handle: handle,
            now: Date(timeIntervalSince1970: 1_788_912_000))
        let datasetID = try #require(filed.objectValue?["dataset_id"]?.stringValue)

        let valid = try await DatasetTools.directDatasetQuery(
            arguments: [
                "id": .string(datasetID),
                "where": .object([
                    "and": .array([
                        .object(["col": .string("score"), "op": .string("gte"), "val": .integer(7)]),
                        .object(["col": .string("enabled"), "op": .string("eq"), "val": .bool(true)]),
                    ]),
                ]),
                "order_by": .array([.object(["col": .string("ratio"), "dir": .string("desc")])]),
                "columns": .array([.string("label"), .string("score")]),
            ],
            kit: kit,
            handle: handle)
        #expect(valid.objectValue?["rows_returned"] == .integer(1))
        #expect(valid.objectValue?["rows"]?.arrayValue?.first?.objectValue == [
            "label": .string("alpha"), "score": .integer(7),
        ])

        let invalidArguments: [[String: JSONValue]] = [
            ["where": .object(["col": .string("unknown"), "op": .string("neq"), "val": .integer(0)])],
            ["where": .object(["col": .string("enabled"), "op": .string("eq"), "val": .integer(1)])],
            ["where": .object(["col": .string("enabled"), "op": .string("lt"), "val": .bool(true)])],
            ["where": .object(["col": .string("score"), "op": .string("eq"), "val": .double(7.0)])],
            ["where": .object(["col": .string("ratio"), "op": .string("eq"), "val": .string("1.5")])],
            ["where": .object(["col": .string("label"), "op": .string("eq"), "val": .integer(7)])],
            ["order_by": .array([.object(["col": .string("unknown"), "dir": .string("asc")])])],
            ["order_by": .array([.object(["col": .string("score"), "dir": .string("ascending")])])],
            ["columns": .array([.string("")])],
            ["columns": .array([.string("unknown")])],
        ]
        for invalid in invalidArguments {
            var arguments = invalid
            arguments["id"] = .string(datasetID)
            do {
                _ = try await DatasetTools.directDatasetQuery(
                    arguments: arguments, kit: kit, handle: handle)
                Issue.record("Expected handle-schema validation to reject \(invalid)")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams)
            }
        }
    }
}

private struct RefusingAuthority: AriaV2DataMobilityAuthority {
    func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        throw AriaV2DataMobilityLower.unavailable(request.tool)
    }
}

private struct ReindexReceiptAuthority: AriaV2DataMobilityAuthority {
    func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        guard case .reindex = request else {
            throw AriaV2DataMobilityLower.unavailable(request.tool)
        }
        return .init(
            data: .object(["state": .string("already_running")]),
            compactText: "Reindexing is already running.")
    }
}
