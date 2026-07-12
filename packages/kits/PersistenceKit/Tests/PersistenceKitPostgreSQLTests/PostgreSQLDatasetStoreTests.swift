// PostgreSQLDatasetStoreTests.swift
//
// MX-TAB-2 PostgreSQL conformance tests for PostgreSQLDatasetStore.
//
// Gated on POSTGRES_TEST_URL. Each test creates an isolated estate (unique
// estateID UUID → unique PostgreSQL schema) so tests don't interfere with
// each other or with the rest of the test suite. When POSTGRES_TEST_URL is
// unset the test body returns early — vacuously green — which is the
// swift-testing analogue of XCTSkip.
//
// Coverage:
//   - Round-trip: create / append / query / drop (both PK modes)
//   - Declared PK: column named; pre-sort verified via ORDER BY
//   - Synthetic PK: no declared PK — identity column; __ds_pk NOT in results
//   - Secondary indexes: declared; no error; correct row count
//   - Identifier rejection: SQL injection attempt fails BEFORE DDL
//   - C-collation TEXT ordering: byte order parity with SQLite BINARY
//     ("Z" / "a" / "É" — same fixture as DatasetStoreTests.binaryCollation*)
//   - columnStats float column: min/max are TypedValue.float(Double) (f64 rule)
//   - columnStats empty dataset: count=0, nullCount=0, min=.null, max=.null
//   - columnStats all-null column: count=0, nullCount==rowCount

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitPostgreSQL
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

// MARK: - Helpers

/// Return the Postgres test URL from the environment, or nil if unset.
/// Tests gate on this value at their entry point and return early
/// (vacuously green) when nil.
private func pgTestURL() -> String? {
    ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"]
}

/// Fresh PostgreSQLStorage with a unique estate ID (→ unique PG schema).
/// Using unique IDs prevents cross-test table collisions even when tests
/// run in parallel — each estate lives in its own `pk_<hex>` PG schema.
private func makeStorage(_ cs: String) -> PostgreSQLStorage {
    PostgreSQLStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .postgresql(connectionString: cs, poolSize: 2)
    ))
}

// MARK: - PostgreSQLDatasetStoreTests

@Suite("PostgreSQLDatasetStoreTests")
struct PostgreSQLDatasetStoreTests {

    // MARK: - Round-trip (create / append / query / drop)

    /// Full round-trip with the synthetic PK mode (no declared PK):
    ///   1. createDataset — DDL emits `__ds_pk BIGINT GENERATED ALWAYS AS IDENTITY`
    ///   2. appendRows — inserts 3 rows in a transaction
    ///   3. queryRows — returns all 3 rows; `__ds_pk` is NOT in the result set
    ///   4. dropDataset — table dropped; re-createDataset with same id must not throw
    @Test func roundTrip_syntheticPK() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "name",  type: .text,  nullable: false),
            ColumnDeclaration(name: "score", type: .float, nullable: true),
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let rows: [[String: TypedValue]] = [
            ["name": .text("Alice"), "score": .float(9.5)],
            ["name": .text("Bob"),   "score": .float(7.0)],
            ["name": .text("Carol"), "score": .null],
        ]
        try await ds.appendRows(id: id, rows: rows)

        let results = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [OrderClause(column: Column(table: "", name: "name"), direction: .ascending)],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 3)

        // __ds_pk must NOT appear in the projection — it is an internal
        // identity column hidden from the result set.
        for row in results {
            #expect(row["__ds_pk"] == nil, "hidden identity column leaked into queryRows result")
        }

        // DROP then re-create: idempotent semantics.
        try await ds.dropDataset(id: id)
        let id2 = UUID()
        try await ds.createDataset(id: id2, schema: schema, indexes: [])
        let empty = try await ds.queryRows(
            id: id2, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil
        )
        #expect(empty.isEmpty)
    }

    // MARK: - Declared PK mode

    /// When `DatasetSchema.primaryKeyColumn` is set, appendRows pre-sorts rows
    /// ascending by the PK column before INSERT. ORDER BY PK ascending returns
    /// rows in key order regardless of call-site append order. The PK column
    /// IS included in queryRows results (it is a user-declared column).
    @Test func pkMode_declaredPK_presort() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(
            columns: [
                ColumnDeclaration(name: "rank",  type: .int,  nullable: false),
                ColumnDeclaration(name: "label", type: .text, nullable: true),
            ],
            primaryKeyColumn: "rank"
        )
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        // Append OUT of order: 3, 1, 2 — pre-sort must reorder to 1, 2, 3
        // before INSERT so sequential rowid assignment tracks key order.
        let rows: [[String: TypedValue]] = [
            ["rank": .int(3), "label": .text("gamma")],
            ["rank": .int(1), "label": .text("alpha")],
            ["rank": .int(2), "label": .text("beta")],
        ]
        try await ds.appendRows(id: id, rows: rows)

        let results = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [OrderClause(column: Column(table: "", name: "rank"), direction: .ascending)],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 3)
        #expect(results[0]["rank"] == .int(1))
        #expect(results[1]["rank"] == .int(2))
        #expect(results[2]["rank"] == .int(3))
    }

    // MARK: - Secondary indexes

    /// Secondary indexes declared in createDataset must not cause errors.
    /// Queries over the indexed columns must return the correct result.
    @Test func secondaryIndexes_creation() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "name", type: .text, nullable: true),
            ColumnDeclaration(name: "age",  type: .int,  nullable: true),
        ])
        let indexes = [
            DatasetIndexDeclaration(column: "name", unique: false),
            DatasetIndexDeclaration(column: "age",  unique: true),
        ]
        try await ds.createDataset(id: id, schema: schema, indexes: indexes)
        try await ds.appendRows(id: id, rows: [
            ["name": .text("Newton"), "age": .int(51)]
        ])

        let results = try await ds.queryRows(
            id: id, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil
        )
        #expect(results.count == 1)
        #expect(results[0]["name"] == .text("Newton"))
    }

    // MARK: - Identifier rejection (before DDL)

    /// A SQL-injection-attempt column name must be rejected by
    /// validateDatasetColumnIdentifier BEFORE any DDL is built.
    /// The connection is never acquired when validation fails; the injected
    /// SQL never reaches the PostgreSQL server.
    @Test func identifierRejection_createDataset_sqlInjection() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "col\"; DROP TABLE foo--", type: .text, nullable: true)
        ])
        await #expect(throws: StorageError.self) {
            try await ds.createDataset(id: UUID(), schema: schema, indexes: [])
        }
    }

    /// A malicious column name in appendRows must also be rejected before
    /// any DML is built.
    @Test func identifierRejection_appendRows_sqlInjection() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        await #expect(throws: StorageError.self) {
            // Space in the column name fails [A-Za-z_][A-Za-z0-9_]*.
            try await ds.appendRows(id: id, rows: [["bad col": .text("x")]])
        }
    }

    // MARK: - C-collation TEXT ordering

    /// PostgreSQL TEXT columns in dataset tables carry COLLATE "C" in their
    /// CREATE TABLE DDL (byte-order lock, matching SQLite BINARY default).
    ///
    /// Fixture: "Z" (0x5A) / "a" (0x61) / "É" (U+00C9, UTF-8: [0xC3, 0x89]).
    /// Byte order: "Z" (0x5A) < "a" (0x61) < "É" (0xC3...).
    ///
    /// This is the same fixture as DatasetStoreTests.binaryCollation_textOrdering_parity
    /// so the Postgres leg can be verified against the SQLite/InMemory results
    /// in the corpus tests.
    @Test func cCollation_textOrdering_byteOrder() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        // Insert in reverse byte order so we can verify the ORDER BY sorts them.
        let rows: [[String: TypedValue]] = [
            ["label": .text("É")],   // highest byte value (0xC3...) — inserted first
            ["label": .text("a")],   // 0x61
            ["label": .text("Z")],   // lowest byte value (0x5A) — inserted last
        ]
        try await ds.appendRows(id: id, rows: rows)

        let results = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [OrderClause(column: Column(table: "", name: "label"), direction: .ascending)],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 3)
        // COLLATE "C" on the column forces byte-order sorting:
        //   "Z" (0x5A) < "a" (0x61) < "É" (0xC3 0x89)
        // Under locale-sensitive collation (the Postgres default), "a" < "É" < "Z"
        // (or similar locale-dependent order). COLLATE "C" gives us byte order.
        #expect(results[0]["label"] == .text("Z"), "byte-order sort: Z must come first (0x5A)")
        #expect(results[1]["label"] == .text("a"), "byte-order sort: a second (0x61)")
        #expect(results[2]["label"] == .text("É"), "byte-order sort: É last (0xC3 0x89)")
    }

    /// Verify COLLATE "C" also applies to the ASCII range fixture used in
    /// DatasetStoreTests.binaryCollation_textOrdering_sqlite:
    /// "Banana" (B=0x42) < "Cherry" (C=0x43) < "apple" (a=0x61) < "date" (d=0x64).
    @Test func cCollation_textOrdering_asciiRange() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let rows: [[String: TypedValue]] = [
            ["label": .text("apple")],    // 0x61
            ["label": .text("Banana")],   // 0x42
            ["label": .text("Cherry")],   // 0x43
            ["label": .text("date")],     // 0x64
        ]
        try await ds.appendRows(id: id, rows: rows)

        let results = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [OrderClause(column: Column(table: "", name: "label"), direction: .ascending)],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 4)
        // Byte order: uppercase (B=0x42, C=0x43) before lowercase (a=0x61, d=0x64).
        // This matches SQLite BINARY collation exactly (same fixture in
        // DatasetStoreTests.binaryCollation_textOrdering_sqlite).
        #expect(results[0]["label"] == .text("Banana"))
        #expect(results[1]["label"] == .text("Cherry"))
        #expect(results[2]["label"] == .text("apple"))
        #expect(results[3]["label"] == .text("date"))
    }

    // MARK: - columnStats: float column (f64 wire rule)

    /// columnStats for a DOUBLE PRECISION column must return min/max as
    /// TypedValue.float(Double) — not .int, .text, or any other case.
    ///
    /// This is the cross-leg f64 wire rule: Swift and Rust produce identical
    /// JSON on the tool surface when min/max carry f64 wire values.
    @Test func columnStats_floatColumn_f64Wire() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "measurement", type: .float, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["measurement": .float(1.5)],
            ["measurement": .float(9.25)],
            ["measurement": .float(3.14)],
            ["measurement": .null],
        ])

        let stats = try await ds.columnStats(id: id, column: "measurement")
        #expect(stats.count == 3)
        #expect(stats.nullCount == 1)
        #expect(stats.distinctCount == 3)

        // Min must be TypedValue.float(Double) — not .int, not .text.
        if case .float(let v) = stats.min {
            #expect(v == 1.5, "min must be exactly 1.5 (f64 wire rule)")
        } else {
            Issue.record("columnStats min for DOUBLE PRECISION column was \(stats.min) — expected .float(1.5)")
        }

        // Max must be TypedValue.float(Double).
        if case .float(let v) = stats.max {
            #expect(v == 9.25, "max must be exactly 9.25 (f64 wire rule)")
        } else {
            Issue.record("columnStats max for DOUBLE PRECISION column was \(stats.max) — expected .float(9.25)")
        }
    }

    // MARK: - columnStats: integer column

    @Test func columnStats_intColumn() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "age", type: .int, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["age": .int(25)],
            ["age": .int(30)],
            ["age": .int(25)],
        ])

        let stats = try await ds.columnStats(id: id, column: "age")
        #expect(stats.count == 3)
        #expect(stats.nullCount == 0)
        #expect(stats.distinctCount == 2)
        #expect(stats.min == .int(25))
        #expect(stats.max == .int(30))
    }

    // MARK: - columnStats: empty dataset

    /// An empty dataset must yield count=0, nullCount=0, distinctCount=0,
    /// min=.null, max=.null. This is the SQL MIN()/MAX() behaviour for an
    /// empty set.
    @Test func columnStats_emptyDataset() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "val", type: .int, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let stats = try await ds.columnStats(id: id, column: "val")
        #expect(stats.count == 0)
        #expect(stats.nullCount == 0)
        #expect(stats.distinctCount == 0)
        #expect(stats.min == .null)
        #expect(stats.max == .null)
    }

    // MARK: - columnStats: all-null column

    /// When every row has a null value: count=0, nullCount=rowCount,
    /// distinctCount=0, min=.null, max=.null.
    @Test func columnStats_allNulls() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "val", type: .int, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["val": .null],
            ["val": .null],
            ["val": .null],
        ])

        let stats = try await ds.columnStats(id: id, column: "val")
        #expect(stats.count == 0)
        #expect(stats.nullCount == 3)
        #expect(stats.distinctCount == 0)
        #expect(stats.min == .null)
        #expect(stats.max == .null)
    }

    // MARK: - Predicate filtering

    /// queryRows with a predicate returns only matching rows.
    @Test func predicate_filtersByValue() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "category", type: .text, nullable: false),
            ColumnDeclaration(name: "value",    type: .int,  nullable: false),
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["category": .text("A"), "value": .int(10)],
            ["category": .text("B"), "value": .int(20)],
            ["category": .text("A"), "value": .int(30)],
        ])

        let pred = StoragePredicate.eq(Column(table: "", name: "category"), .text("A"))
        let results = try await ds.queryRows(
            id: id, predicate: pred, orderBy: [], limit: nil, offset: nil, columns: nil
        )
        #expect(results.count == 2)
        for row in results {
            #expect(row["category"] == .text("A"))
        }
    }

    // MARK: - Projection

    /// columns: parameter restricts the returned rows to the listed columns.
    @Test func projection_returnsSubsetOfColumns() async throws {
        guard let cs = pgTestURL() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        defer { Task { await storage.close() } }

        let ds = try storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "col_a", type: .text, nullable: true),
            ColumnDeclaration(name: "col_b", type: .int,  nullable: true),
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["col_a": .text("hello"), "col_b": .int(42)]
        ])

        let results = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [],
            limit: nil,
            offset: nil,
            columns: ["col_a"]   // project col_a only
        )
        #expect(results.count == 1)
        #expect(results[0]["col_a"] == .text("hello"))
        #expect(results[0]["col_b"] == nil)  // excluded by projection
    }
}
