import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
import WorkPacketKit
@testable import AriaMCP

@Suite("ARIA v2 typed packet operations", .serialized)
struct AriaV2PacketOperationsTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeOperations() async throws -> (AriaV2PacketOperations, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-packet-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let fixedNow = now
        let context = AriaV2MemoryOperationContext(
            estateID: handle.estateUUID, callerID: "test", serverIdentity: "test",
            now: { fixedNow })
        return (AriaV2PacketOperations(
            kit: kit, handle: handle, context: context, grantCeiling: nil), kit, handle)
    }

    private func makeSQLiteOperations() async throws -> (AriaV2PacketOperations, GeniusLocusKit, EstateHandle, SQLiteStorage, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aria-v2-packet-lowercase-nodes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("estate.sqlite")
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-packet-lowercase-nodes")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let fixedNow = now
        let context = AriaV2MemoryOperationContext(
            estateID: handle.estateUUID, callerID: "test", serverIdentity: "test",
            now: { fixedNow })
        return (AriaV2PacketOperations(
            kit: kit, handle: handle, context: context, grantCeiling: nil), kit, handle, storage, directory)
    }

    private func physicalID(_ value: TypedValue?) throws -> String {
        switch value {
        case .uuid(let id): return id.uuidString
        case .text(let value): return value
        default: throw NSError(domain: "AriaV2PacketOperationsTests", code: 1)
        }
    }

    private func drawerID(_ response: JSONValue) throws -> String {
        try #require(response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["drawer_id"]?.stringValue)
    }

    private func fileArgs(_ objective: String, lineage: [JSONValue] = []) -> JSONValue {
        .object([
            "objective": .string(objective),
            "model": .string("test-model"),
            "agent": .string("packet-test"),
            "sources": .array([.object([
                "description": .string("packet contract"), "kind": .string("file"),
            ])]),
            "claims": .array([.object([
                "statement": .string("direct typed packets preserve identity"), "confidence": .double(0.9),
            ])]),
            "lineage_links": .array(lineage),
        ])
    }

    private func fixture(named name: String) throws -> JSONValue {
        try JSONValue.parse(fixtureData(named: name))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Conformance/\(name)")
            .standardizedFileURL
        return try Data(contentsOf: url)
    }

    private func requiredDataKeys(tool: String) throws -> Set<String> {
        let fixture = try fixture(named: "aria_v2_output_schemas_edge.json")
        let schema = try #require(fixture.objectValue?["operations"]?.objectValue?[tool]?.objectValue?["data_schema"]?.objectValue)
        return Set(try #require(schema["required"]?.arrayValue).compactMap(\.stringValue))
    }

    @Test func selectedPacketCatalogConsumesSharedInputSchemas() throws {
        let fixture = try fixture(named: "aria_v2_mission02_vectors.json")
        let records = try #require(fixture.objectValue?["catalog"]?.objectValue?["operations"]?.arrayValue)
        for name in [
            AriaV2PacketFileRequest.toolName, AriaV2PacketGetRequest.toolName,
            AriaV2PacketListRequest.toolName, AriaV2PacketLineageRequest.toolName,
        ] {
            let expected = try #require(records.first { $0.objectValue?["name"]?.stringValue == name }?.objectValue)
            let actual = try #require(AriaV2SelectedCatalog.descriptors.first { $0.publicName == name })
            #expect(actual.inputSchema == expected["inputSchema"])
            #expect(actual.help.description == expected["description"]?.stringValue)
            #expect(actual.effect.rawValue == expected["effect"]?.stringValue)
        }
    }

    @Test func fileGetAndListUseStructuredPacketStoreSemantics() async throws {
        let (operations, kit, handle) = try await makeOperations()
        defer { Task { try? await kit.close(handle) } }

        let filed = try await operations.file(AriaV2PacketFileRequest(arguments: fileArgs("Store a source-faithful work packet.")))
        let id = try drawerID(filed)
        let filedData = try #require(filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(Set(filedData.keys) == (try requiredDataKeys(tool: AriaV2PacketFileRequest.toolName)))
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())
        #expect(filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["sensitivity"] == .string("normal"))

        let fetched = try await operations.get(AriaV2PacketGetRequest(arguments: .object([
            "drawer_id": .string(id.uppercased()),
        ])))
        let packet = fetched.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packet"]?.objectValue
        let fetchedData = try #require(fetched.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(Set(fetchedData.keys) == (try requiredDataKeys(tool: AriaV2PacketGetRequest.toolName)))
        #expect(packet?["drawer_id"] == .string(id))
        #expect(packet?["objective"] == .string("Store a source-faithful work packet."))
        #expect(packet?["provenance"]?.objectValue?["created_at"] == .string("2023-11-14T22:13:20Z"))

        let listed = try await operations.list(AriaV2PacketListRequest(arguments: .object([:])))
        let rows = listed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packets"]?.arrayValue
        let listedData = try #require(listed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(Set(listedData.keys) == (try requiredDataKeys(tool: AriaV2PacketListRequest.toolName)))
        #expect(rows?.first?.objectValue?["drawer_id"] == .string(id))

        var restrictedArguments = try #require(fileArgs("Restricted packet.").objectValue)
        restrictedArguments["sensitivity"] = .string("restricted")
        let restricted = try await operations.file(AriaV2PacketFileRequest(arguments: .object(restrictedArguments)))
        let restrictedID = try drawerID(restricted)
        let relisted = try await operations.list(AriaV2PacketListRequest(arguments: .object([:])))
        let relistedIDs = Set((try #require(relisted.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packets"]?.arrayValue)).compactMap {
            $0.objectValue?["drawer_id"]?.stringValue
        })
        #expect(!relistedIDs.contains(restrictedID))
    }

    @Test func lineageUsesEmbeddedLinksAndFiltersMissingRootWithoutOracle() async throws {
        let (operations, kit, handle) = try await makeOperations()
        defer { Task { try? await kit.close(handle) } }

        let ancestor = try await operations.file(AriaV2PacketFileRequest(arguments: fileArgs("Ancestor packet.")))
        let ancestorID = try drawerID(ancestor)
        let child = try await operations.file(AriaV2PacketFileRequest(arguments: fileArgs(
            "Child packet.", lineage: [.object([
                "kind": .string("derivesFrom"), "targetPacketID": .string(ancestorID),
            ])])))
        let childID = try drawerID(child)

        let lineage = try await operations.lineage(AriaV2PacketLineageRequest(arguments: .object([
            "drawer_id": .string(childID),
        ])))
        let lineageData = try #require(lineage.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(Set(lineageData.keys) == (try requiredDataKeys(tool: AriaV2PacketLineageRequest.toolName)))
        #expect(lineage.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["antecedents"] == .array([.string(ancestorID)]))

        let missing = UUID().uuidString.lowercased()
        let missingResult = try await operations.get(AriaV2PacketGetRequest(arguments: .object([
            "drawer_id": .string(missing),
        ])))
        let missingLineage = try await operations.lineage(AriaV2PacketLineageRequest(arguments: .object([
            "drawer_id": .string(missing),
        ])))
        #expect(missingResult.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("packet_not_found"))
        #expect(missingLineage.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("packet_not_found"))
    }

    @Test func nondefaultWingPacketIDsResolveWithoutWeakeningExplicitScope() async throws {
        let (operations, kit, handle) = try await makeOperations()
        defer { Task { try? await kit.close(handle) } }
        var parentArgs = try #require(fileArgs("Parent in Lab").objectValue)
        parentArgs["wing"] = .string("Lab")
        let parentID = try drawerID(try await operations.file(AriaV2PacketFileRequest(arguments: .object(parentArgs))))
        var childArgs = try #require(fileArgs("Child in Lab", lineage: [.object([
            "kind": .string("derivesFrom"), "targetPacketID": .string(parentID),
        ])]).objectValue)
        childArgs["wing"] = .string("Lab")
        let childID = try drawerID(try await operations.file(AriaV2PacketFileRequest(arguments: .object(childArgs))))
        let fetched = try await operations.get(AriaV2PacketGetRequest(arguments: .object(["drawer_id": .string(childID)])))
        #expect(fetched.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packet"]?.objectValue?["objective"] == .string("Child in Lab"))
        let lineage = try await operations.lineage(AriaV2PacketLineageRequest(arguments: .object(["drawer_id": .string(childID)])))
        #expect(lineage.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["antecedents"] == .array([.string(parentID)]))
        let wrong = JSONValue.object(["drawer_id": .string(childID), "wing": .string("Wrong")])
        let wrongGet = try await operations.get(AriaV2PacketGetRequest(arguments: wrong))
        let wrongLineage = try await operations.lineage(AriaV2PacketLineageRequest(arguments: wrong))
        for response in [wrongGet, wrongLineage] {
            #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("packet_not_found"))
        }
        childArgs["sensitivity"] = .string("restricted")
        let hiddenID = try drawerID(try await operations.file(AriaV2PacketFileRequest(arguments: .object(childArgs))))
        let hidden = try await operations.get(AriaV2PacketGetRequest(arguments: .object(["drawer_id": .string(hiddenID)])))
        #expect(hidden.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("packet_not_found"))
    }

    @Test func exactRustPacketPayloadDecodesAtPortableBoundary() throws {
        let packet = try WorkPacketStore.portableJSONDecoder().decode(
            WorkPacket.self, from: fixtureData(named: "aria_v2_q28_rust_packet_payload.json"))
        #expect(packet.id == "9a737563-c1bb-4854-aa9f-ce071fcdc459")
        #expect(packet.sources.map(\.id) == ["323b1b1c-699a-4e48-89c1-3184d39b8947"])
        #expect(packet.claims.flatMap(\.supportingSourceIDs) == ["dc906641-c37a-4cd2-900c-64cadfdfb5a9"])
    }

    @Test func omittedWingReadsExactRustPacketPayload() async throws {
        let (operations, kit, handle) = try await makeOperations()
        defer { Task { try? await kit.close(handle) } }
        let rustPacket = try #require(String(
            data: fixtureData(named: "aria_v2_q28_rust_packet_payload.json"), encoding: .utf8))
        let estate = try await kit.estate(for: handle)
        var frame = CaptureFrame(
            content: rustPacket, channel: .actuator, room: WorkPacketStore.room,
            latticeAnchor: .udc("004"), addedBy: "WorkPacketKit", embeddingModelID: "none")
        frame.kind = .structuredJSON
        frame.wing = "Lab"
        frame.eventTime = now
        let captured = try await estate.capture(frame)
        let spanIndexed = try await estate.setSpanIndexed(drawerId: captured.id)
        #expect(spanIndexed == 1)
        #expect(((captured.provenance >> 30) & 0x3f) == 0)
        #expect(captured.adjectiveBitmap == 0)

        // This is the literal Rust packet body with its millisecond timestamp,
        // captured at raw provenance 0 in the nondefault Lab wing. Query using
        // canonical lowercase storage identity so omitted-wing discovery and
        // portable decoding run through the actual v2 adapter path.
        let response = try await operations.get(AriaV2PacketGetRequest(arguments: .object([
            "drawer_id": .string(captured.id.lowercased()),
        ])))
        let packet = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packet"]?.objectValue
        #expect(packet?["objective"] == .string("Resume the valve qualification handoff."))
        #expect(packet?["uncertainties"] == .array([.string("Pressure retest remains pending.")]))
        #expect(packet?["provenance"]?.objectValue?["created_at"] != nil)

        let malformedPacket = #"""
        {"schemaVersion":1,"id":"0f3e3f5e-2a0d-4c08-ae34-038e5d761a4e","objective":"Malformed timestamp packet.","sources":[],"claims":[],"uncertainties":[],"nextSteps":[],"provenance":{"model":"fixture-author","agent":"qualification-preparer","createdAt":"not-a-timestamp","updatedAt":"2026-09-09T09:07:29.692Z"},"lineageLinks":[]}
        """#
        var malformedFrame = CaptureFrame(
            content: malformedPacket, channel: .actuator, room: WorkPacketStore.room,
            latticeAnchor: .udc("004"), addedBy: "WorkPacketKit", embeddingModelID: "none")
        malformedFrame.kind = .structuredJSON
        malformedFrame.wing = "Lab"
        let malformed = try await estate.capture(malformedFrame)

        let listed = try await operations.list(AriaV2PacketListRequest(arguments: .object([
            "wing": .string("Lab"),
        ])))
        let packets = listed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packets"]?.arrayValue
        #expect(packets?.contains { $0.objectValue?["drawer_id"] == .string(captured.id.lowercased()) } == true)
        #expect(packets?.contains { $0.objectValue?["drawer_id"] == .string(malformed.id.lowercased()) } == false)
        #expect(packets?.count == 1)
    }

    @Test func malformedPortablePacketTimestampRemainsUnavailable() async throws {
        let (operations, kit, handle) = try await makeOperations()
        defer { Task { try? await kit.close(handle) } }
        let malformedPacket = #"""
        {"schemaVersion":1,"id":"9a737563-c1bb-4854-aa9f-ce071fcdc459","objective":"Malformed timestamp packet.","sources":[],"claims":[],"uncertainties":[],"nextSteps":[],"provenance":{"model":"fixture-author","agent":"qualification-preparer","createdAt":"not-a-timestamp","updatedAt":"2026-09-09T09:07:29.692Z"},"lineageLinks":[]}
        """#
        let estate = try await kit.estate(for: handle)
        var frame = CaptureFrame(
            content: malformedPacket, channel: .actuator, room: WorkPacketStore.room,
            latticeAnchor: .udc("004"), addedBy: "WorkPacketKit", embeddingModelID: "none")
        frame.kind = .structuredJSON
        frame.wing = "Lab"
        let captured = try await estate.capture(frame)
        let response = try await operations.get(AriaV2PacketGetRequest(arguments: .object([
            "drawer_id": .string(captured.id.lowercased()),
        ])))
        #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("packet_not_found"))
    }


    @Test func v2PacketReadsRustLowercaseNodeTopologyWithoutChangingLegacyLookup() async throws {
        let (operations, kit, handle, storage, directory) = try await makeSQLiteOperations()
        defer {
            Task {
                try? await kit.close(handle)
                await storage.close()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let estate = try await kit.estate(for: handle)
        var frame = CaptureFrame(
            content: try #require(String(data: fixtureData(named: "aria_v2_q28_rust_packet_payload.json"), encoding: .utf8)),
            channel: .actuator, room: WorkPacketStore.room,
            latticeAnchor: .udc("004"), addedBy: "WorkPacketKit", embeddingModelID: "none")
        frame.kind = .structuredJSON
        frame.wing = "Lab"
        let captured = try await estate.capture(frame)

        // Rewrite the complete root → wing → room ancestry and drawer identity
        // through SQLite's raw row seam. This matches Rust's lowercase TEXT
        // persistence, rather than a Swift-created uppercase UUID substitute.
        let roomRows = try await storage.rowStore.query(
            table: "nodes", where: .eq(Column(table: "nodes", name: "id"), .uuid(UUID(uuidString: captured.parentNodeId)!)))
        let room = try #require(roomRows.first)
        let wingID = try physicalID(room["parent_id"])
        let wingRows = try await storage.rowStore.query(
            table: "nodes", where: .eq(Column(table: "nodes", name: "id"), .uuid(UUID(uuidString: wingID)!)))
        let wing = try #require(wingRows.first)
        let rootID = try physicalID(wing["parent_id"])
        let rustRoot = "215c85f8-0be9-4725-a95d-314d4712de24"
        let rustWing = "0a1c6ccf-a77c-4dad-a11b-e4260e079581"
        let rustRoom = "5cf10139-ac9e-4988-a809-636845dbf827"
        let rustDrawer = "5b6a5cd2-2cf3-4051-bf35-0ce62b285c31"
        let nodes = Column(table: "nodes", name: "id")
        _ = try await storage.rowStore.update(table: "nodes", values: ["id": .text(rustRoot)],
            where: .eq(nodes, .uuid(UUID(uuidString: rootID)!)))
        _ = try await storage.rowStore.update(table: "nodes", values: ["id": .text(rustWing), "parent_id": .text(rustRoot)],
            where: .eq(nodes, .uuid(UUID(uuidString: wingID)!)))
        _ = try await storage.rowStore.update(table: "nodes", values: ["id": .text(rustRoom), "parent_id": .text(rustWing)],
            where: .eq(nodes, .uuid(UUID(uuidString: captured.parentNodeId)!)))
        _ = try await storage.rowStore.update(table: "drawers", values: [
            "id": .text(rustDrawer), "parent_node_id": .text(rustRoom), "operationalBitmap": .bitmap(134_217_989),
        ], where: .eq(Column(table: "drawers", name: "id"), .uuid(UUID(uuidString: captured.id)!)))

        #expect(try await kit.resolveNodeNames(handle, parentNodeIds: [rustRoom]).isEmpty,
            "legacy typed UUID lookup must not acquire portable SQLite spelling behavior")
        #expect(try await kit.resolveNodeNames(handle, parentNodeIds: [rustRoom], preservePhysicalUUIDSpellings: true)[rustRoom]?.wing == "Lab")

        let get = try await operations.get(AriaV2PacketGetRequest(arguments: .object(["drawer_id": .string(rustDrawer)])))
        #expect(get.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packet"]?.objectValue?["drawer_id"] == .string(rustDrawer))
        let list = try await operations.list(AriaV2PacketListRequest(arguments: .object(["wing": .string("Lab")])))
        #expect(list.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["packets"]?.arrayValue?.map { $0.objectValue?["drawer_id"] } == [.string(rustDrawer)])
    }

    @Test func strictRequestsRejectUnknownArguments() {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2PacketListRequest(arguments: .object(["verbose": .bool(true)]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2PacketFileRequest(arguments: .object([
                "objective": .string("x"), "model": .string("m"), "agent": .string("a"),
                "unexpected": .string("no"),
            ]))
        }
    }
}
