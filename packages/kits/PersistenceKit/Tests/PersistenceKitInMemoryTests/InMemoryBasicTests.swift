// InMemoryBasicTests.swift

import XCTest
import PersistenceKit
import PersistenceKitInMemory
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

final class InMemoryBasicTests: XCTestCase {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func makeSchema(version: Int = 1) -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "TestKit",
            version: version,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .uuid("row_id"),
                        .bitmap("adjective"),
                        .bitmap("operational"),
                        .bitmap("provenance"),
                        .text("verbatim"),
                        .timestamp("captured_at")
                    ],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    func testOpenAndSchemaVersion() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema(version: 1))
        let v = try await storage.currentSchemaVersion()
        XCTAssertEqual(v, 1)
    }

    func testInsertAndQuery() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let handle = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "row_id": .uuid(rowID),
                "adjective": .bitmap(0x01),
                "operational": .bitmap(0x02),
                "provenance": .bitmap(0x04),
                "verbatim": .text("hello"),
                "captured_at": .timestamp(Date(timeIntervalSince1970: 1000))
            ]
        )
        XCTAssertEqual(handle.table, "drawers")
        XCTAssertEqual(handle.key, rowID)

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "row_id"), .uuid(rowID))
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["verbatim"], .text("hello"))
    }

    func testBitmaskPredicate() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        for bits: Int64 in [0x01, 0x03, 0x07, 0x0F] {
            _ = try await storage.rowStore.insert(
                table: "drawers",
                values: [
                    "row_id": .uuid(UUID()),
                    "adjective": .bitmap(bits),
                    "operational": .bitmap(0),
                    "provenance": .bitmap(0),
                    "verbatim": .text("row_\(bits)"),
                    "captured_at": .timestamp(Date())
                ]
            )
        }

        // All rows with bit 0 set (= 0x01) → 4 rows (0x01, 0x03, 0x07, 0x0F)
        let allBit0 = try await storage.rowStore.count(
            table: "drawers",
            where: .bitmaskAll(Column(table: "drawers", name: "adjective"), mask: 0x01)
        )
        XCTAssertEqual(allBit0, 4)

        // All rows with bits 0+1+2 set (= 0x07) → 2 rows (0x07, 0x0F)
        let all0x07 = try await storage.rowStore.count(
            table: "drawers",
            where: .bitmaskAll(Column(table: "drawers", name: "adjective"), mask: 0x07)
        )
        XCTAssertEqual(all0x07, 2)

        // Rows with NO bits in 0xF0 set (= mask none) → 4 rows (all)
        let none0xF0 = try await storage.rowStore.count(
            table: "drawers",
            where: .bitmaskNone(Column(table: "drawers", name: "adjective"), mask: 0xF0)
        )
        XCTAssertEqual(none0xF0, 4)
    }

    func testAuditAppendIdempotent() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let eventID = UUID()
        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        let event = AuditEvent(
            eventID: eventID,
            estateUuid: UUID(),
            rowId: UUID(),
            hlc: hlc,
            verb: "capture",
            beforeBitmaps: nil,
            afterBitmaps: (1, 2, 4),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "test"
        )

        try await storage.auditLog.append(event)
        try await storage.auditLog.append(event)  // duplicate, should be no-op
        try await storage.auditLog.append(event)  // ditto

        let count = try await storage.auditLog.count()
        XCTAssertEqual(count, 1)
    }

    func testTransactionRollback() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        struct TestError: Error {}

        let rowID = UUID()
        await XCTAssertThrowsErrorAsync {
            try await storage.transaction { txn in
                _ = try await txn.rowStore.insert(
                    table: "drawers",
                    values: [
                        "row_id": .uuid(rowID),
                        "adjective": .bitmap(0),
                        "operational": .bitmap(0),
                        "provenance": .bitmap(0),
                        "verbatim": .text("should not commit"),
                        "captured_at": .timestamp(Date())
                    ]
                )
                throw TestError()
            }
        }

        let count = try await storage.rowStore.count(table: "drawers", where: nil)
        XCTAssertEqual(count, 0, "rollback should leave no rows")
    }

    func testTransactionCommit() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        try await storage.transaction { txn in
            _ = try await txn.rowStore.insert(
                table: "drawers",
                values: [
                    "row_id": .uuid(rowID),
                    "adjective": .bitmap(0),
                    "operational": .bitmap(0),
                    "provenance": .bitmap(0),
                    "verbatim": .text("should commit"),
                    "captured_at": .timestamp(Date())
                ]
            )
        }

        let count = try await storage.rowStore.count(table: "drawers", where: nil)
        XCTAssertEqual(count, 1)
    }

    func testVectorKNN() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let k1 = UUID(), k2 = UUID(), k3 = UUID()
        try await storage.vectorIndex.add(key: k1, vector: [1, 0, 0], metadata: [:])
        try await storage.vectorIndex.add(key: k2, vector: [0, 1, 0], metadata: [:])
        try await storage.vectorIndex.add(key: k3, vector: [0.9, 0.1, 0], metadata: [:])

        let results = try await storage.vectorIndex.knn(
            query: [1, 0, 0],
            k: 2,
            metric: .cosine,
            filter: nil,
            searchParameters: nil
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].key, k1, "exact match wins")
        XCTAssertEqual(results[1].key, k3, "near match comes second")
    }

    func testBlobRoundtrip() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await storage.blobStore.put(key: "test/blob", bytes: payload)
        let retrieved = try await storage.blobStore.get(key: "test/blob")
        XCTAssertEqual(retrieved, payload)
        let exists = try await storage.blobStore.exists(key: "test/blob")
        XCTAssertTrue(exists)
        let size = try await storage.blobStore.size(key: "test/blob")
        XCTAssertEqual(size, 4)
    }
}

// MARK: - Helpers

func XCTAssertThrowsErrorAsync<T>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw", file: file, line: line)
    } catch {
        // success
    }
}
