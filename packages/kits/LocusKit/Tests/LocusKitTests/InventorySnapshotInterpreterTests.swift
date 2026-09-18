import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

@Suite("Locus inventory snapshot interpreter")
struct InventorySnapshotInterpreterTests {
    private let rootID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let wingID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let roomID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let drawerID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    @Test("strictly decodes complete rows and preserves root-to-room ancestry")
    func decodesValidInventory() throws {
        let snapshot = InventorySnapshot(
            drawers: [drawer(parent: roomID)],
            nodes: [
                node(id: rootID, parent: nil, name: "Estate", depth: 0),
                node(id: wingID, parent: rootID, name: "Memory", depth: 1),
                node(id: roomID, parent: wingID, name: "Inbox", depth: 2),
            ]
        )
        let decoded = try LocusInventorySnapshotInterpreter.decode(snapshot)
        #expect(decoded.drawers.count == 1)
        #expect(decoded.drawers[0].drawer.id == drawerID.uuidString.lowercased())
        #expect(decoded.drawers[0].ancestry.map(\.id) == [rootID, wingID, roomID])
    }

    @Test("decodes node UUID text returned by the SQLite inventory snapshot")
    func decodesSQLiteNodeUUIDText() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        try await storage.open(schema: LocusKitSchema.schema)
        let nodes = NodeStore(storage: storage)
        let root = try await nodes.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1))
        let wing = try await nodes.createNode(displayName: "Memory", parentId: root.id, now: Date(timeIntervalSince1970: 2))
        _ = try await nodes.createNode(displayName: "Inbox", parentId: wing.id, now: Date(timeIntervalSince1970: 3))

        let snapshot = try await storage.captureInventorySnapshot()
        #expect(snapshot.nodes.count == 3)
        #expect(snapshot.nodes.allSatisfy {
            if case .text = $0["id"] { return true }
            return false
        })
        #expect(try LocusInventorySnapshotInterpreter.decode(snapshot).drawers.isEmpty)
        await storage.close()
    }

    @Test("rejects corrupt rows instead of omitting them")
    func rejectsCorruptDrawer() {
        var values = drawer(parent: roomID).values
        values["adjectiveBitmap"] = .int(0)
        let snapshot = InventorySnapshot(
            drawers: [.init(values: values)],
            nodes: validNodes()
        )
        #expect(throws: LocusInventorySnapshotError.self) {
            try LocusInventorySnapshotInterpreter.decode(snapshot)
        }
    }

    @Test("rejects reserved drawer state and sensitivity raws without a partial snapshot")
    func rejectsReservedDrawerAdjectiveBitmapValues() {
        for bitmap in [Int64(4), Int64(1) << 6] {
            var invalid = drawer(parent: roomID).values
            invalid["id"] = .text("55555555-5555-4555-8555-555555555555")
            invalid["adjectiveBitmap"] = .bitmap(bitmap)
            let snapshot = InventorySnapshot(
                drawers: [drawer(parent: roomID), .init(values: invalid)],
                nodes: validNodes()
            )
            #expect(throws: LocusInventorySnapshotError.self) {
                try LocusInventorySnapshotInterpreter.decode(snapshot)
            }
        }
    }

    @Test("rejects a drawer whose parent is not a room")
    func rejectsInvalidAncestry() {
        let snapshot = InventorySnapshot(drawers: [drawer(parent: wingID)], nodes: validNodes())
        #expect(throws: LocusInventorySnapshotError.self) {
            try LocusInventorySnapshotInterpreter.decode(snapshot)
        }
    }

    @Test("accepts omitted optional fields but rejects a present wrong optional type")
    func handlesSparseOptionalFieldsStrictly() throws {
        let optionalDrawerColumns = [
            "sourceFile", "chunkIndex", "eventTime", "tombstonedAt", "removedByBatch",
            "udcFacets", "wikidataQID", "wikidataQidsSecondary", "ext", "keyID",
            "content_hash", "content_fingerprint", "ssc_facts", "subject",
            "subject_pipeline_version", "subject_at",
        ]
        let optionalNodeColumns = ["parent_id", "tombstoned_hlc", "tombstoned_at", "merkle_root", "ext"]
        let sparseNodes = validNodes().enumerated().map { index, row -> StorageRow in
            var values = row.values
            for column in optionalNodeColumns where index == 0 || column != "parent_id" {
                values.removeValue(forKey: column)
            }
            return .init(values: values)
        }
        var sparseDrawer = drawer(parent: roomID).values
        for column in optionalDrawerColumns { sparseDrawer.removeValue(forKey: column) }
        #expect(try LocusInventorySnapshotInterpreter.decode(
            .init(drawers: [.init(values: sparseDrawer)], nodes: sparseNodes)
        ).drawers.count == 1)

        var malformedNodes = sparseNodes
        var malformedRoot = malformedNodes[0].values
        malformedRoot["tombstoned_hlc"] = .text("not-an-hlc")
        malformedNodes[0] = .init(values: malformedRoot)
        #expect(throws: LocusInventorySnapshotError.self) {
            try LocusInventorySnapshotInterpreter.decode(
                .init(drawers: [.init(values: sparseDrawer)], nodes: malformedNodes)
            )
        }
    }

    private func validNodes() -> [StorageRow] {
        [
            node(id: rootID, parent: nil, name: "Estate", depth: 0),
            node(id: wingID, parent: rootID, name: "Memory", depth: 1),
            node(id: roomID, parent: wingID, name: "Inbox", depth: 2),
        ]
    }

    private func node(id: UUID, parent: UUID?, name: String, depth: Int) -> StorageRow {
        .init(values: [
            "id": .uuid(id),
            "parent_id": parent.map { .uuid($0) } ?? .null,
            "display_name": .text(name),
            "lookup_name": .text(Node.normalizeLookupName(name)),
            "depth": .int(Int64(depth)),
            "lifecycle": .int(0),
            "created_hlc": .hlc(.zero),
            "tombstoned_hlc": .null,
            "tombstoned_at": .null,
            "merkle_root": .null,
            "created_at": .timestamp(Date(timeIntervalSince1970: 1)),
            "updated_at": .timestamp(Date(timeIntervalSince1970: 1)),
            "ext": .null,
        ])
    }

    private func drawer(parent: UUID) -> StorageRow {
        .init(values: [
            "id": .text(drawerID.uuidString.lowercased()),
            "content": .text("record"),
            "parent_node_id": .text(parent.uuidString.lowercased()),
            "sourceFile": .null,
            "chunkIndex": .null,
            "addedBy": .text("test"),
            "filedAt": .timestamp(Date(timeIntervalSince1970: 1)),
            "eventTime": .null,
            "embeddingModelID": .text("test-model"),
            "tombstonedAt": .null,
            "removedByBatch": .null,
            "provenance": .bitmap(0),
            "adjectiveBitmap": .bitmap(0),
            "operationalBitmap": .bitmap(0),
            "lineageID": .text(""),
            "udcCode": .text("004"),
            "udcFacets": .null,
            "wikidataQID": .null,
            "wikidataQidsSecondary": .null,
            "ext": .null,
            "keyID": .null,
            "content_hash": .null,
            "content_fingerprint": .null,
            "ssc_facts": .null,
            "subject": .null,
            "subject_pipeline_version": .null,
            "subject_at": .null,
        ])
    }
}
