// ConformanceRunner.swift
//
// Backend-agnostic conformance fixture runner per ADR §10 / Q8.
// Every backend produces identical observable results for the
// same fixture sequence under a deterministic seed.

import Testing
import Foundation
import PersistenceKit
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

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

    public func runAll() async throws {
        try await schemaFixtures()
        try await multiKitSchemaFixtures()
        try await freshOpenAddColumnIdempotentFixtures()
        try await rowFixtures()
        try await predicateFixtures()
        try await blobFixtures()
        try await vectorFixtures()
        try await auditFixtures()
        try await transactionFixtures()
        try await generatedColumnFixtures()
        try await appendOnlyFixtures()
    }

    // MARK: - Schema fixtures

    func schemaFixtures() async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        let version = try await storage.currentSchemaVersion()
        #expect(version == 1, "\(backendName): schema version after open")
        await storage.close()
    }

    // MARK: - Multi-kit schema fixtures

    /// Verifies that two kits sharing one storage instance track their schema
    /// versions independently. Kit A migrates to version 2; Kit B stays at
    /// version 1. `currentSchemaVersion(for:)` must return the correct version
    /// for each kit, and the values must differ.
    func multiKitSchemaFixtures() async throws {
        let storage = try await factory()

        // Kit A starts at version 1, migrates to version 2.
        let schemaA_v1 = SchemaDeclaration(
            kitID: "ConformanceKitA",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "kit_a_items",
                    columns: [.uuid("id"), .text("name")],
                    primaryKey: ["id"]
                )
            ]
        )
        let schemaA_v2 = SchemaDeclaration(
            kitID: "ConformanceKitA",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "kit_a_items",
                    columns: [.uuid("id"), .text("name"), .text("note", nullable: true)],
                    primaryKey: ["id"]
                )
            ],
            migrations: [
                Migration(fromVersion: 1, toVersion: 2, operations: [
                    .addColumn(table: "kit_a_items", column: .text("note", nullable: true))
                ])
            ]
        )

        // Kit B stays at version 1.
        let schemaB_v1 = SchemaDeclaration(
            kitID: "ConformanceKitB",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "kit_b_items",
                    columns: [.uuid("id"), .int("count")],
                    primaryKey: ["id"]
                )
            ]
        )

        try await storage.open(schema: schemaA_v1)
        try await storage.migrate(to: schemaA_v2)
        try await storage.open(schema: schemaB_v1)

        let vA = try await storage.currentSchemaVersion(for: "ConformanceKitA")
        let vB = try await storage.currentSchemaVersion(for: "ConformanceKitB")

        #expect(vA == 2, "\(backendName): Kit A migrated to version 2")
        #expect(vB == 1, "\(backendName): Kit B stays at version 1")
        #expect(vA != vB, "\(backendName): per-kit versions are independent")

        // No-arg method still returns a value ≥ either kit's version.
        let global = try await storage.currentSchemaVersion()
        #expect(global >= vA, "\(backendName): global version ≥ Kit A version")

        await storage.close()
    }

    // MARK: - Fresh-open addColumn idempotence

    /// Opening a FRESH database directly at a schema whose latest table already
    /// declares the column an addColumn migration adds must succeed on every
    /// backend. The open path creates each table at the latest schema first, then
    /// replays migrations from version 0 — so the addColumn targets a column that
    /// already exists. The emitter must treat addColumn idempotently (ADD COLUMN
    /// IF NOT EXISTS semantics), mirroring CREATE TABLE IF NOT EXISTS.
    func freshOpenAddColumnIdempotentFixtures() async throws {
        let storage = try await factory()
        let schemaV2 = SchemaDeclaration(
            kitID: "ConformanceFreshAddColumn",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "fresh_items",
                    // Latest schema already carries the column the migration adds.
                    columns: [.uuid("id"), .text("name"), .text("note", nullable: true)],
                    primaryKey: ["id"]
                )
            ],
            migrations: [
                Migration(fromVersion: 1, toVersion: 2, operations: [
                    .addColumn(table: "fresh_items", column: .text("note", nullable: true))
                ])
            ]
        )
        // Direct open on a brand-new store — addColumn replays against a table
        // that already has `note`. Must succeed, not throw "duplicate column".
        try await storage.open(schema: schemaV2)
        let version = try await storage.currentSchemaVersion(for: "ConformanceFreshAddColumn")
        #expect(version == 2, "\(backendName): fresh open with addColumn migration reaches version 2")
        await storage.close()
    }

    // MARK: - Row fixtures

    func rowFixtures() async throws {
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
        #expect(total == 10, "\(backendName): count after 10 inserts")

        let active = try await storage.rowStore.count(
            table: "items",
            where: .eq(Column(table: "items", name: "active"), .bool(true))
        )
        #expect(active == 5, "\(backendName): active=true count")

        let ordered = try await storage.rowStore.query(
            table: "items",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "items", name: "count"), direction: .ascending)],
            limit: 3,
            offset: nil
        )
        #expect(ordered.count == 3, "\(backendName): limit honored")
        #expect(ordered[0]["count"] == .int(0), "\(backendName): ascending order")
        #expect(ordered[2]["count"] == .int(20), "\(backendName): ascending order tail")
    }

    // MARK: - Predicate fixtures

    func predicateFixtures() async throws {
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
        #expect(allBit0 == 4, "\(backendName): bitmaskAll 0x01 → 0x01,0x03,0x07,0x0F")

        let allBit012 = try await storage.rowStore.count(table: "items", where: .bitmaskAll(col, mask: 0x07))
        #expect(allBit012 == 2, "\(backendName): bitmaskAll 0x07 → 0x07,0x0F")

        // bitmaskAny
        let anyBit47 = try await storage.rowStore.count(table: "items", where: .bitmaskAny(col, mask: 0x90))
        #expect(anyBit47 == 2, "\(backendName): bitmaskAny 0x90 → 0x10,0x80")

        // bitmaskNone
        let noneHighBits = try await storage.rowStore.count(table: "items", where: .bitmaskNone(col, mask: 0xF0))
        #expect(noneHighBits == 4, "\(backendName): bitmaskNone 0xF0 → 0x01,0x03,0x07,0x0F")

        // bitwiseEq
        let exactMatch = try await storage.rowStore.count(table: "items", where: .bitwiseEq(col, expected: 0x03, mask: 0x0F))
        #expect(exactMatch == 1, "\(backendName): bitwiseEq exact 0x03")

        // logical combinations
        let andCount = try await storage.rowStore.count(
            table: "items",
            where: .and([
                .bitmaskAll(col, mask: 0x01),
                .bitmaskNone(col, mask: 0xF0)
            ])
        )
        #expect(andCount == 4, "\(backendName): AND combination")

        let orCount = try await storage.rowStore.count(
            table: "items",
            where: .or([
                .eq(col, .bitmap(0x10)),
                .eq(col, .bitmap(0x80))
            ])
        )
        #expect(orCount == 2, "\(backendName): OR combination")

        let notCount = try await storage.rowStore.count(
            table: "items",
            where: .not(.bitmaskAll(col, mask: 0x01))
        )
        #expect(notCount == 2, "\(backendName): NOT combination")

        // comparison
        let countCol = Column(table: "items", name: "count")
        let gt = try await storage.rowStore.count(table: "items", where: .gt(countCol, .int(10)))
        #expect(gt == 3, "\(backendName): count > 10 → 0x0F=15, 0x10=16, 0x80=128")

        let inCount = try await storage.rowStore.count(
            table: "items",
            where: .in(col, [.bitmap(0x01), .bitmap(0x80)])
        )
        #expect(inCount == 2, "\(backendName): IN")
    }

    // MARK: - Blob fixtures

    func blobFixtures() async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.testSchema)
        defer { Task { await storage.close() } }

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        try await storage.blobStore.put(key: "test/binary", bytes: payload)

        let retrieved = try await storage.blobStore.get(key: "test/binary")
        #expect(retrieved == payload, "\(backendName): blob round-trip preserves bytes")

        let exists = try await storage.blobStore.exists(key: "test/binary")
        #expect(exists, "\(backendName): blob exists after put")

        let size = try await storage.blobStore.size(key: "test/binary")
        #expect(size == 8, "\(backendName): blob size matches payload")

        try await storage.blobStore.delete(key: "test/binary")
        let afterDelete = try await storage.blobStore.exists(key: "test/binary")
        #expect(!afterDelete, "\(backendName): blob gone after delete")

        let missing = try await storage.blobStore.get(key: "nonexistent")
        #expect(missing == nil, "\(backendName): missing blob returns nil")
    }

    // MARK: - Vector accommodation schema

    /// Schema that mirrors how VectorKit stores embeddings on a backend: a
    /// keyed row carrying an opaque binary vector payload (`payload_binary`,
    /// e.g. a 32-byte packed Engram/fingerprint) and a float32 payload
    /// (`payload_float32`, e.g. a 384-d MiniLM embedding serialized to bytes).
    /// PersistenceKit owns no vector engine — these are plain BLOB columns.
    /// The fixtures below assert the ACCOMMODATION contract (ADR-008): every
    /// backend round-trips, bulk-hydrates, counts, and deletes vector-payload
    /// rows through the general RowStore surface.
    static let vectorAccommodationSchema = SchemaDeclaration(
        kitID: "ConformanceVectorAccommodationKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "vector_rows",
                columns: [
                    .uuid("id"),
                    .blob("payload_binary"),
                    .blob("payload_float32"),
                    .text("model_id"),
                    .int("dim")
                ],
                primaryKey: ["id"]
            )
        ]
    )

    // MARK: - Vector accommodation fixtures

    /// The vector-storage accommodation guarantee (ADR-008 / PERSISTENCEKIT_SPEC
    /// "Vector accommodation contract"). PersistenceKit does NOT own a k-NN
    /// engine; dense-embedding search lives in VectorKit. What every backend
    /// MUST guarantee is that it accommodates a vector workload's STORAGE needs:
    ///   1. vector-payload row round-trip — a 32-byte binary payload and a
    ///      384-d float32 payload survive insert→query byte-for-byte;
    ///   2. bulk hydration at scale — ≥1k vector rows load back fully;
    ///   3. count and delete over those rows.
    /// All exercised through RowStore/BlobStore, no vector-specific surface.
    func vectorFixtures() async throws {
        let storage = try await factory()
        try await storage.open(schema: Self.vectorAccommodationSchema)
        defer { Task { await storage.close() } }

        // (1) Vector-payload row round-trip.
        // Binary lane: a 32-byte packed payload (Engram/fingerprint width).
        let binaryPayload = Data((0..<32).map { UInt8($0 & 0xFF) })
        // Float lane: a 384-d float32 embedding serialized little-endian.
        let floats: [Float] = (0..<384).map { Float($0) * 0.001 - 0.19 }
        var floatBytes = Data(capacity: 384 * 4)
        for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { floatBytes.append(contentsOf: $0) } }

        let roundTripID = UUID()
        _ = try await storage.rowStore.insert(
            table: "vector_rows",
            values: [
                "id": .uuid(roundTripID),
                "payload_binary": .blob(binaryPayload),
                "payload_float32": .blob(floatBytes),
                "model_id": .text("MiniLM-L6-v2"),
                "dim": .int(384)
            ]
        )

        let fetched = try await storage.rowStore.query(
            table: "vector_rows",
            where: .eq(Column(table: "vector_rows", name: "id"), .uuid(roundTripID))
        )
        #expect(fetched.count == 1, "\(backendName): vector-payload row present")
        #expect(fetched[0]["payload_binary"] == .blob(binaryPayload),
                "\(backendName): 32-byte binary vector payload round-trips byte-for-byte")
        #expect(fetched[0]["payload_float32"] == .blob(floatBytes),
                "\(backendName): 384-d float32 vector payload round-trips byte-for-byte")
        #expect(fetched[0]["dim"] == .int(384), "\(backendName): vector dimensionality preserved")

        // (2) Bulk hydration at scale: ≥1k vector rows load back fully.
        let bulkCount = 1_000
        for i in 0..<bulkCount {
            // Distinct 32-byte payload per row so a decode bug can't alias rows.
            let payload = Data((0..<32).map { UInt8((i + Int($0)) & 0xFF) })
            _ = try await storage.rowStore.insert(
                table: "vector_rows",
                values: [
                    "id": .uuid(UUID()),
                    "payload_binary": .blob(payload),
                    "payload_float32": .blob(floatBytes),
                    "model_id": .text("MiniLM-L6-v2"),
                    "dim": .int(384)
                ]
            )
        }

        let hydrated = try await storage.rowStore.query(table: "vector_rows", where: nil)
        #expect(hydrated.count == bulkCount + 1,
                "\(backendName): bulk hydration returns all \(bulkCount + 1) vector rows")
        // Every hydrated row must carry a 32-byte binary payload and a 384*4-byte float payload.
        let widthsOK = hydrated.allSatisfy { row in
            if case let .blob(b) = row["payload_binary"], b.count == 32,
               case let .blob(f) = row["payload_float32"], f.count == 384 * 4 {
                return true
            }
            return false
        }
        #expect(widthsOK, "\(backendName): every hydrated vector row preserves payload widths")

        // (3) Count and delete.
        let total = try await storage.rowStore.count(table: "vector_rows", where: nil)
        #expect(total == bulkCount + 1, "\(backendName): vector-row count")

        _ = try await storage.rowStore.delete(
            table: "vector_rows",
            where: .eq(Column(table: "vector_rows", name: "id"), .uuid(roundTripID))
        )
        let afterDelete = try await storage.rowStore.count(table: "vector_rows", where: nil)
        #expect(afterDelete == bulkCount, "\(backendName): vector-row count after delete")
    }

    // MARK: - Audit fixtures

    func auditFixtures() async throws {
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
        #expect(count == 5, "\(backendName): audit count after batch")

        // Idempotence: re-appending should not duplicate
        try await storage.auditLog.appendBatch(events)
        let countAfterReplay = try await storage.auditLog.count()
        #expect(countAfterReplay == 5, "\(backendName): audit idempotent on (eventID, hlc)")

        // Per-row events
        let rowAEvents = try await storage.auditLog.eventsForRow(rowA)
        #expect(rowAEvents.count == 3, "\(backendName): rowA has 3 events (i=0,2,4)")

        // HLC ordering
        for i in 0..<(rowAEvents.count - 1) {
            #expect(rowAEvents[i].hlc < rowAEvents[i + 1].hlc,
                    "\(backendName): events ordered by HLC")
        }

        // Iterate after cursor
        let mid = HLC(physicalTime: Int64(1_700_000_002), logicalCount: 0, nodeID: 1)
        let after = try await storage.auditLog.iterate(after: mid, rowID: nil, limit: 100)
        #expect(after.count == 2, "\(backendName): iterate after HLC=2 → events 3,4")
    }

    // MARK: - Transaction fixtures

    func transactionFixtures() async throws {
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
        #expect(committedCount == 1, "\(backendName): committed row persists")

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
        #expect(threw, "\(backendName): transaction propagated error")
        let rolledBackCount = try await storage.rowStore.count(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rolledBackID))
        )
        #expect(rolledBackCount == 0, "\(backendName): rolled-back row not persisted")
    }

    // MARK: - Generated column fixtures

    func generatedColumnFixtures() async throws {
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
        #expect(rowsA.count == 1, "\(backendName): generated row A present")
        #expect(rowsA[0]["low_nibble"] == .int(0x5),
                "\(backendName): low_nibble of 0xA5")
        #expect(rowsA[0]["high_nibble"] == .int(0xA),
                "\(backendName): high_nibble of 0xA5")
        #expect(rowsA[0]["has_bit7"] == .bool(true),
                "\(backendName): has_bit7 of 0xA5")

        let rowsB = try await storage.rowStore.query(
            table: "gen_items",
            where: .eq(Column(table: "gen_items", name: "id"), .uuid(idB))
        )
        #expect(rowsB[0]["low_nibble"] == .int(0x2),
                "\(backendName): low_nibble of 0x42")
        #expect(rowsB[0]["has_bit7"] == .bool(false),
                "\(backendName): has_bit7 of 0x42")

        // The generated column is filterable like any other column.
        let lowIsFive = try await storage.rowStore.count(
            table: "gen_items",
            where: .eq(Column(table: "gen_items", name: "low_nibble"), .int(0x5))
        )
        #expect(lowIsFive == 1, "\(backendName): filter on generated column")

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
        #expect(rowsBUpdated[0]["low_nibble"] == .int(0xF),
                "\(backendName): generated value recomputed on update")
        #expect(rowsBUpdated[0]["has_bit7"] == .bool(false),
                "\(backendName): bit7 still clear after update to 0x0F")
    }

    // MARK: - Append-only fixtures

    func appendOnlyFixtures() async throws {
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
        #expect(updateThrew, "\(backendName): UPDATE rejected on append-only table")

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
        #expect(deleteThrew, "\(backendName): DELETE rejected on append-only table")

        // Both rows survive: no mutation took effect.
        let total = try await storage.rowStore.count(table: "ledger", where: nil)
        #expect(total == 2, "\(backendName): append-only rows intact after rejected mutations")
        let firstRow = try await storage.rowStore.query(
            table: "ledger",
            where: .eq(Column(table: "ledger", name: "id"), .uuid(id1))
        )
        #expect(firstRow[0]["amount"] == .int(100),
                "\(backendName): original value unchanged after rejected UPDATE")
    }
}
