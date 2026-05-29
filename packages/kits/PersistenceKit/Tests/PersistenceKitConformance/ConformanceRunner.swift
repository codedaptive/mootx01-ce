// ConformanceRunner.swift
//
// Backend-agnostic conformance fixture runner per ADR §10 / Q8.
// Every backend produces identical observable results for the
// same fixture sequence under a deterministic seed.

import XCTest
import PersistenceKit
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

/// Backend factory: each backend's test target supplies one.
public typealias StorageFactory = @Sendable () async throws -> any Storage

public struct ConformanceRunner {
    public let backendName: String
    public let factory: StorageFactory

    public init(backendName: String, factory: @escaping StorageFactory) {
        self.backendName = backendName
        self.factory = factory
    }

    // MARK: - Schema

    static let testSchema = SchemaDeclaration(
        kitID: "ConformanceTestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [
                    .uuid("id"),
                    .bitmap("flags"),
                    .text("name"),
                    .int("count"),
                    .timestamp("created"),
                    .bool("active", nullable: true),
                    .float("score", nullable: true)
                ],
                primaryKey: ["id"]
            )
        ]
    )

    /// Schema exercising generated columns: a bitmap source column
    /// plus three derived columns covering mask, shift-then-mask,
    /// and a boolean presence test.
    static let generatedSchema = SchemaDeclaration(
        kitID: "ConformanceGeneratedKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "gen_items",
                columns: [
                    .uuid("id"),
                    .bitmap("flags"),
                    .text("name")
                ],
                primaryKey: ["id"],
                generatedColumns: [
                    GeneratedColumn(
                        name: "low_nibble",
                        type: .int,
                        expression: .bitAnd(.column("flags"), .literal(0x0F))
                    ),
                    GeneratedColumn(
                        name: "high_nibble",
                        type: .int,
                        expression: .bitAnd(.shiftRight(.column("flags"), 4), .literal(0x0F))
                    ),
                    GeneratedColumn(
                        name: "has_bit7",
                        type: .bool,
                        expression: .notEqual(.bitAnd(.column("flags"), .literal(0x80)), .literal(0))
                    )
                ]
            )
        ],
        indices: [
            IndexDeclaration(name: "idx_gen_low", table: "gen_items", columns: ["low_nibble"])
        ]
    )

    /// Schema with an append-only table: INSERT allowed, UPDATE and
    /// DELETE rejected by every backend.
    static let appendOnlySchema = SchemaDeclaration(
        kitID: "ConformanceAppendOnlyKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "ledger",
                columns: [
                    .uuid("id"),
                    .text("entry"),
                    .int("amount")
                ],
                primaryKey: ["id"],
                appendOnly: true
            )
        ]
    )

    // MARK: - Fixture groups

    public func runAll(in test: XCTestCase) async throws {
        try await schemaFixtures(in: test)
        try await rowFixtures(in: test)
        try await predicateFixtures(in: test)
        try await blobFixtures(in: test)
        try await vectorFixtures(in: test)
        try await auditFixtures(in: test)
        try await transactionFixtures(in: test)
        try await generatedColumnFixtures(in: test)
        try await appendOnlyFixtures(in: test)
    }

    // MARK: - Schema fixtures

    func schemaFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        let version = try await storage.currentSchemaVersion()
        XCTAssertEqual(version, 1, "\(backendName): schema version after open")
        await storage.close()
    }

    // MARK: - Row fixtures

    func rowFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        var items: [[String: TypedValue]] = []
        for i in 0..<10 {
            var row: [String: TypedValue] = [:]
            row["id"] = .uuid(UUID())
            row["flags"] = .bitmap(Int64(i) & 0x0F)
            row["name"] = .text("item-\(i)")
            row["count"] = .int(Int64(i * 10))
            row["created"] = .timestamp(Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)))
            row["active"] = .bool(i % 2 == 0)
            row["score"] = .float(Double(i) * 1.5)
            items.append(row)
        }

        for item in items {
            _ = try await storage.rowStore.insert(table: "items", values: item)
        }

        let total = try await storage.rowStore.count(table: "items", where: nil)
        XCTAssertEqual(total, 10, "\(backendName): count after 10 inserts")

        let active = try await storage.rowStore.count(
            table: "items",
            where: .eq(Column(table: "items", name: "active"), .bool(true))
        )
        XCTAssertEqual(active, 5, "\(backendName): active=true count")

        let ordered = try await storage.rowStore.query(
            table: "items",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "items", name: "count"), direction: .ascending)],
            limit: 3,
            offset: nil
        )
        XCTAssertEqual(ordered.count, 3, "\(backendName): limit honored")
        XCTAssertEqual(ordered[0]["count"], .int(0), "\(backendName): ascending order")
        XCTAssertEqual(ordered[2]["count"], .int(20), "\(backendName): ascending order tail")
    }

    // MARK: - Predicate fixtures

    func predicateFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        for bits: Int64 in [0x01, 0x03, 0x07, 0x0F, 0x10, 0x80] {
            _ = try await storage.rowStore.insert(
                table: "items",
                values: [
                    "id": .uuid(UUID()),
                    "flags": .bitmap(bits),
                    "name": .text("bits_\(bits)"),
                    "count": .int(bits),
                    "created": .timestamp(Date())
                ]
            )
        }

        let col = Column(table: "items", name: "flags")

        // bitmaskAll
        let allBit0 = try await storage.rowStore.count(table: "items", where: .bitmaskAll(col, mask: 0x01))
        XCTAssertEqual(allBit0, 4, "\(backendName): bitmaskAll 0x01 → 0x01,0x03,0x07,0x0F")

        let allBit012 = try await storage.rowStore.count(table: "items", where: .bitmaskAll(col, mask: 0x07))
        XCTAssertEqual(allBit012, 2, "\(backendName): bitmaskAll 0x07 → 0x07,0x0F")

        // bitmaskAny
        let anyBit47 = try await storage.rowStore.count(table: "items", where: .bitmaskAny(col, mask: 0x90))
        XCTAssertEqual(anyBit47, 2, "\(backendName): bitmaskAny 0x90 → 0x10,0x80")

        // bitmaskNone
        let noneHighBits = try await storage.rowStore.count(table: "items", where: .bitmaskNone(col, mask: 0xF0))
        XCTAssertEqual(noneHighBits, 4, "\(backendName): bitmaskNone 0xF0 → 0x01,0x03,0x07,0x0F")

        // bitwiseEq
        let exactMatch = try await storage.rowStore.count(table: "items", where: .bitwiseEq(col, expected: 0x03, mask: 0x0F))
        XCTAssertEqual(exactMatch, 1, "\(backendName): bitwiseEq exact 0x03")

        // logical combinations
        let andCount = try await storage.rowStore.count(
            table: "items",
            where: .and([
                .bitmaskAll(col, mask: 0x01),
                .bitmaskNone(col, mask: 0xF0)
            ])
        )
        XCTAssertEqual(andCount, 4, "\(backendName): AND combination")

        let orCount = try await storage.rowStore.count(
            table: "items",
            where: .or([
                .eq(col, .bitmap(0x10)),
                .eq(col, .bitmap(0x80))
            ])
        )
        XCTAssertEqual(orCount, 2, "\(backendName): OR combination")

        let notCount = try await storage.rowStore.count(
            table: "items",
            where: .not(.bitmaskAll(col, mask: 0x01))
        )
        XCTAssertEqual(notCount, 2, "\(backendName): NOT combination")

        // comparison
        let countCol = Column(table: "items", name: "count")
        let gt = try await storage.rowStore.count(table: "items", where: .gt(countCol, .int(10)))
        XCTAssertEqual(gt, 3, "\(backendName): count > 10 → 0x0F=15, 0x10=16, 0x80=128")

        let inCount = try await storage.rowStore.count(
            table: "items",
            where: .in(col, [.bitmap(0x01), .bitmap(0x80)])
        )
        XCTAssertEqual(inCount, 2, "\(backendName): IN")
    }

    // MARK: - Blob fixtures

    func blobFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        try await storage.blobStore.put(key: "test/binary", bytes: payload)

        let retrieved = try await storage.blobStore.get(key: "test/binary")
        XCTAssertEqual(retrieved, payload, "\(backendName): blob round-trip preserves bytes")

        let exists = try await storage.blobStore.exists(key: "test/binary")
        XCTAssertTrue(exists, "\(backendName): blob exists after put")

        let size = try await storage.blobStore.size(key: "test/binary")
        XCTAssertEqual(size, 8, "\(backendName): blob size matches payload")

        try await storage.blobStore.delete(key: "test/binary")
        let afterDelete = try await storage.blobStore.exists(key: "test/binary")
        XCTAssertFalse(afterDelete, "\(backendName): blob gone after delete")

        let missing = try await storage.blobStore.get(key: "nonexistent")
        XCTAssertNil(missing, "\(backendName): missing blob returns nil")
    }

    // MARK: - Vector fixtures

    func vectorFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        let k1 = UUID(), k2 = UUID(), k3 = UUID(), k4 = UUID()
        try await storage.vectorIndex.add(key: k1, vector: [1, 0, 0], metadata: [:])
        try await storage.vectorIndex.add(key: k2, vector: [0, 1, 0], metadata: [:])
        try await storage.vectorIndex.add(key: k3, vector: [0.95, 0.05, 0], metadata: [:])
        try await storage.vectorIndex.add(key: k4, vector: [0, 0, 1], metadata: [:])

        let count = try await storage.vectorIndex.count()
        XCTAssertEqual(count, 4, "\(backendName): vector count")

        let topK = try await storage.vectorIndex.knn(
            query: [1, 0, 0],
            k: 2,
            metric: .cosine,
            filter: nil,
            searchParameters: nil
        )
        XCTAssertEqual(topK.count, 2, "\(backendName): kNN returns k results")
        XCTAssertEqual(topK[0].key, k1, "\(backendName): exact match first")
        XCTAssertEqual(topK[1].key, k3, "\(backendName): near match second")

        try await storage.vectorIndex.delete(key: k1)
        let afterDelete = try await storage.vectorIndex.count()
        XCTAssertEqual(afterDelete, 3, "\(backendName): count after delete")
    }

    // MARK: - Audit fixtures

    func auditFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        let estateUuid = UUID()
        let rowA = UUID(), rowB = UUID()
        let anchor = LatticeAnchor(udcCode: 0)

        var events: [AuditEvent] = []
        for i in 0..<5 {
            let rowID: UUID = (i % 2 == 0) ? rowA : rowB
            let hlc = HLC(physicalTime: Int64(1_700_000_000 + i), logicalCount: 0, nodeID: 1)
            let after: (adjective: Int64, operational: Int64, provenance: Int64) = (Int64(i), 0, 0)
            let event = AuditEvent(
                eventID: UUID(),
                estateUuid: estateUuid,
                rowId: rowID,
                hlc: hlc,
                verb: "capture",
                beforeBitmaps: nil,
                afterBitmaps: after,
                beforeLatticeAnchor: nil,
                afterLatticeAnchor: anchor,
                actor: "test"
            )
            events.append(event)
        }

        try await storage.auditLog.appendBatch(events)
        let count = try await storage.auditLog.count()
        XCTAssertEqual(count, 5, "\(backendName): audit count after batch")

        // Idempotence: re-appending should not duplicate
        try await storage.auditLog.appendBatch(events)
        let countAfterReplay = try await storage.auditLog.count()
        XCTAssertEqual(countAfterReplay, 5, "\(backendName): audit idempotent on (eventID, hlc)")

        // Per-row events
        let rowAEvents = try await storage.auditLog.eventsForRow(rowA)
        XCTAssertEqual(rowAEvents.count, 3, "\(backendName): rowA has 3 events (i=0,2,4)")

        // HLC ordering
        for i in 0..<(rowAEvents.count - 1) {
            XCTAssertLessThan(rowAEvents[i].hlc, rowAEvents[i + 1].hlc,
                              "\(backendName): events ordered by HLC")
        }

        // Iterate after cursor
        let mid = HLC(physicalTime: Int64(1_700_000_002), logicalCount: 0, nodeID: 1)
        let after = try await storage.auditLog.iterate(after: mid, rowID: nil, limit: 100)
        XCTAssertEqual(after.count, 2, "\(backendName): iterate after HLC=2 → events 3,4")
    }

    // MARK: - Transaction fixtures

    func transactionFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        // Commit
        let committedID = UUID()
        try await storage.transaction { txn in
            _ = try await txn.rowStore.insert(
                table: "items",
                values: [
                    "id": .uuid(committedID),
                    "flags": .bitmap(0),
                    "name": .text("committed"),
                    "count": .int(0),
                    "created": .timestamp(Date())
                ]
            )
        }
        let committedCount = try await storage.rowStore.count(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(committedID))
        )
        XCTAssertEqual(committedCount, 1, "\(backendName): committed row persists")

        // Rollback
        struct TestErr: Error {}
        let rolledBackID = UUID()
        var threw = false
        do {
            try await storage.transaction { txn in
                _ = try await txn.rowStore.insert(
                    table: "items",
                    values: [
                        "id": .uuid(rolledBackID),
                        "flags": .bitmap(0),
                        "name": .text("rollback"),
                        "count": .int(0),
                        "created": .timestamp(Date())
                    ]
                )
                throw TestErr()
            }
        } catch is TestErr {
            threw = true
        }
        XCTAssertTrue(threw, "\(backendName): transaction propagated error")
        let rolledBackCount = try await storage.rowStore.count(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rolledBackID))
        )
        XCTAssertEqual(rolledBackCount, 0, "\(backendName): rolled-back row not persisted")
    }

    // MARK: - Generated column fixtures

    func generatedColumnFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.generatedSchema)
        defer { Task { await storage.close() } }

        // 0xA5 = 1010_0101: low=0x5, high=0xA, bit7 set.
        let idA = UUID()
        _ = try await storage.rowStore.insert(
            table: "gen_items",
            values: ["id": .uuid(idA), "flags": .bitmap(0xA5), "name": .text("a")]
        )
        // 0x42 = 0100_0010: low=0x2, high=0x4, bit7 clear.
        let idB = UUID()
        _ = try await storage.rowStore.insert(
            table: "gen_items",
            values: ["id": .uuid(idB), "flags": .bitmap(0x42), "name": .text("b")]
        )

        let rowsA = try await storage.rowStore.query(
            table: "gen_items",
            where: .eq(Column(table: "gen_items", name: "id"), .uuid(idA))
        )
        XCTAssertEqual(rowsA.count, 1, "\(backendName): generated row A present")
        XCTAssertEqual(rowsA[0]["low_nibble"], .int(0x5),
                       "\(backendName): low_nibble of 0xA5")
        XCTAssertEqual(rowsA[0]["high_nibble"], .int(0xA),
                       "\(backendName): high_nibble of 0xA5")
        XCTAssertEqual(rowsA[0]["has_bit7"], .bool(true),
                       "\(backendName): has_bit7 of 0xA5")

        let rowsB = try await storage.rowStore.query(
            table: "gen_items",
            where: .eq(Column(table: "gen_items", name: "id"), .uuid(idB))
        )
        XCTAssertEqual(rowsB[0]["low_nibble"], .int(0x2),
                       "\(backendName): low_nibble of 0x42")
        XCTAssertEqual(rowsB[0]["has_bit7"], .bool(false),
                       "\(backendName): has_bit7 of 0x42")

        // The generated column is filterable like any other column.
        let lowIsFive = try await storage.rowStore.count(
            table: "gen_items",
            where: .eq(Column(table: "gen_items", name: "low_nibble"), .int(0x5))
        )
        XCTAssertEqual(lowIsFive, 1, "\(backendName): filter on generated column")

        // Updating the source column recomputes the generated value.
        _ = try await storage.rowStore.update(
            table: "gen_items",
            values: ["flags": .bitmap(0x0F)],
            where: .eq(Column(table: "gen_items", name: "id"), .uuid(idB))
        )
        let rowsBUpdated = try await storage.rowStore.query(
            table: "gen_items",
            where: .eq(Column(table: "gen_items", name: "id"), .uuid(idB))
        )
        XCTAssertEqual(rowsBUpdated[0]["low_nibble"], .int(0xF),
                       "\(backendName): generated value recomputed on update")
        XCTAssertEqual(rowsBUpdated[0]["has_bit7"], .bool(false),
                       "\(backendName): bit7 still clear after update to 0x0F")
    }

    // MARK: - Append-only fixtures

    func appendOnlyFixtures(in test: XCTestCase) async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.appendOnlySchema)
        defer { Task { await storage.close() } }

        let id1 = UUID(), id2 = UUID()
        _ = try await storage.rowStore.insert(
            table: "ledger",
            values: ["id": .uuid(id1), "entry": .text("first"), "amount": .int(100)]
        )
        _ = try await storage.rowStore.insert(
            table: "ledger",
            values: ["id": .uuid(id2), "entry": .text("second"), "amount": .int(200)]
        )

        // UPDATE must be rejected.
        var updateThrew = false
        do {
            _ = try await storage.rowStore.update(
                table: "ledger",
                values: ["amount": .int(999)],
                where: .eq(Column(table: "ledger", name: "id"), .uuid(id1))
            )
        } catch {
            updateThrew = true
        }
        XCTAssertTrue(updateThrew, "\(backendName): UPDATE rejected on append-only table")

        // DELETE must be rejected.
        var deleteThrew = false
        do {
            _ = try await storage.rowStore.delete(
                table: "ledger",
                where: .eq(Column(table: "ledger", name: "id"), .uuid(id1))
            )
        } catch {
            deleteThrew = true
        }
        XCTAssertTrue(deleteThrew, "\(backendName): DELETE rejected on append-only table")

        // Both rows survive: no mutation took effect.
        let total = try await storage.rowStore.count(table: "ledger", where: nil)
        XCTAssertEqual(total, 2, "\(backendName): append-only rows intact after rejected mutations")
        let firstRow = try await storage.rowStore.query(
            table: "ledger",
            where: .eq(Column(table: "ledger", name: "id"), .uuid(id1))
        )
        XCTAssertEqual(firstRow[0]["amount"], .int(100),
                       "\(backendName): original value unchanged after rejected UPDATE")
    }
}
