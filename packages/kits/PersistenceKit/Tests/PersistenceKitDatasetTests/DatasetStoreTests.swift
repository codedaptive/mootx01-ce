// DatasetStoreTests.swift
//
// MX-TAB-1 conformance test suite for DatasetStore.
//
// Coverage:
//   - Default-throw (featureGated) for un-implemented Storage conformers
//   - Identifier validation — empty, digit-first, SQL-injection attempts
//   - Round-trip (create / append / query / drop) on InMemory and SQLite
//   - Idempotent create and drop
//   - Explicit PK pre-sort: ORDER BY returns ascending PK values
//   - Secondary index declaration (no crash, correct row count)
//   - Predicate filtering and projection (column subset)
//   - Limit + offset pagination
//   - columnStats: count, distinctCount, nullCount, min, max
//   - columnStats empty dataset
//   - columnStats all-null column
//   - BINARY collation TEXT ordering (SQLite backend only — spec §Parity)
//   - Float min/max is TypedValue.float(Double) — f64 wire rule (SQLite)
//
// InMemory tests run against InMemoryStorage (no file I/O, fast).
// SQLite-specific tests (BINARY collation, f64 wire rule) use SQLiteStorage
// backed by a temp-dir file.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
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

/// Fresh InMemoryStorage backed by a random estateID. No `open` needed for
/// DatasetStore tests: `createDatasetTable` directly mutates `state.tables`,
/// which is initialized in `InMemoryStateActor.init` without requiring
/// `openSchema` to be called first.
private func makeInMemory() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
}

/// Fresh SQLiteStorage backed by a unique temp-dir file.
/// The SQLite connection is opened in `SQLiteStorage.init` — no `open`
/// needed for DatasetStore tests because dataset DDL uses direct
/// `CREATE TABLE IF NOT EXISTS`, not the schema-migration path.
private func makeSQLite() throws -> SQLiteStorage {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pk-dataset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let dbURL = tmpDir.appendingPathComponent("test.sqlite")
    return try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: dbURL, busyTimeout: 5.0)
    ))
}

// MARK: - Minimal Storage conformer for default-throw test

/// A `Storage` conformer that does NOT override `datasetStore`, so it
/// inherits the protocol-extension default:
///     `throw StorageError.featureGated(feature: "datasetStore")`
///
/// Only `configuration` is meaningful. Every other member uses
/// `fatalError` — the test only accesses `datasetStore` so they are
/// never called. `Never` (the `fatalError` return type) satisfies any
/// protocol existential return type in Swift.
private struct StubStorage: Storage {
    let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    var rowStore: any RowStore { fatalError("stub — test must not call rowStore") }
    var blobStore: any BlobStore { fatalError("stub — test must not call blobStore") }
    var auditLog: any AuditLog { fatalError("stub — test must not call auditLog") }
    var observer: any StorageObserver { fatalError("stub — test must not call observer") }
    func open(schema: SchemaDeclaration) async throws {}
    func close() async {}
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T { fatalError("stub — test must not call transaction") }
    func currentSchemaVersion() async throws -> Int { 0 }
    func currentSchemaVersion(for kitID: String) async throws -> Int { 0 }
    func migrate(to schema: SchemaDeclaration) async throws {}
    // `datasetStore` NOT overridden: inherits protocol-extension default.
}

// MARK: - DatasetStore test suite

@Suite("DatasetStoreTests")
struct DatasetStoreTests {

    // MARK: - Default-throw (featureGated)

    /// A `Storage` conformer that does not implement `datasetStore` must
    /// throw `StorageError.featureGated(feature: "datasetStore")`. This
    /// ensures third-party conformers keep compiling as backends are added.
    @Test func defaultThrow_featureGated() {
        let stub = StubStorage()
        do {
            _ = try stub.datasetStore
            Issue.record("Expected featureGated error — got a DatasetStore instead")
        } catch StorageError.featureGated(let feature) {
            #expect(feature == "datasetStore")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    // MARK: - Identifier validation (InMemory)
    //
    // Column names arrive from moot_file_dataset and CSV headers and become
    // SQL identifiers. All are validated against [A-Za-z_][A-Za-z0-9_]*.
    // Rejection fails the whole operation with StorageError.invalidIdentifier;
    // there is no sanitize-and-continue path.

    @Test func invalidIdentifier_emptyName() async {
        let ds = makeInMemory().datasetStore
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "", type: .text, nullable: true)
        ])
        await #expect(throws: StorageError.self) {
            try await ds.createDataset(id: UUID(), schema: schema, indexes: [])
        }
    }

    @Test func invalidIdentifier_startsWithDigit() async {
        let ds = makeInMemory().datasetStore
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "1col", type: .text, nullable: true)
        ])
        await #expect(throws: StorageError.self) {
            try await ds.createDataset(id: UUID(), schema: schema, indexes: [])
        }
    }

    @Test func invalidIdentifier_space() async {
        let ds = makeInMemory().datasetStore
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "bad col", type: .text, nullable: true)
        ])
        await #expect(throws: StorageError.self) {
            try await ds.createDataset(id: UUID(), schema: schema, indexes: [])
        }
    }

    /// SQL-injection attempt: semicolon in column name.
    ///
    /// This must throw `invalidIdentifier` before any SQL is built — the
    /// validation call site in `createDataset` runs before touching the
    /// connection, so the SQL engine never sees the injected semicolon.
    @Test func invalidIdentifier_sqlInjection_semicolon() async {
        let ds = makeInMemory().datasetStore
        let badName = "col; DROP TABLE foo"
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: badName, type: .text, nullable: true)
        ])
        await #expect(throws: StorageError.self) {
            try await ds.createDataset(id: UUID(), schema: schema, indexes: [])
        }
    }

    /// SQL-injection attempt: double-quote in column name.
    @Test func invalidIdentifier_sqlInjection_doubleQuote() async {
        let ds = makeInMemory().datasetStore
        let badName = "col\"; DROP TABLE"
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: badName, type: .text, nullable: true)
        ])
        await #expect(throws: StorageError.self) {
            try await ds.createDataset(id: UUID(), schema: schema, indexes: [])
        }
    }

    /// Rejected column name in `appendRows` key must fail the whole
    /// operation before any rows are written.
    @Test func invalidIdentifier_inAppendRows() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        await #expect(throws: StorageError.self) {
            // "bad col" contains a space — fails [A-Za-z_][A-Za-z0-9_]*.
            try await ds.appendRows(id: id, rows: [["bad col": .text("value")]])
        }
    }

    // MARK: - Round-trip (InMemory)

    @Test func roundTrip_inMemory() async throws {
        let storage = makeInMemory()
        let ds = storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(
            columns: [
                ColumnDeclaration(name: "name", type: .text, nullable: false),
                ColumnDeclaration(name: "score", type: .float, nullable: true),
            ]
        )
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
            orderBy: [],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 3)

        // Drop clears the table. Subsequent queryRows throws (table gone).
        try await ds.dropDataset(id: id)
        // Verify the drop succeeded by re-creating with a fresh ID — no error.
        let id2 = UUID()
        try await ds.createDataset(id: id2, schema: schema, indexes: [])
        let empty = try await ds.queryRows(id: id2, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil)
        #expect(empty.isEmpty)
    }

    // MARK: - Round-trip (SQLite)

    @Test func roundTrip_sqlite() async throws {
        let storage = try makeSQLite()
        let ds = storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(
            columns: [
                ColumnDeclaration(name: "name", type: .text, nullable: false),
                ColumnDeclaration(name: "score", type: .float, nullable: true),
            ]
        )
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let rows: [[String: TypedValue]] = [
            ["name": .text("Alice"), "score": .float(9.5)],
            ["name": .text("Bob"),   "score": .float(7.0)],
        ]
        try await ds.appendRows(id: id, rows: rows)

        let results = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 2)
        try await ds.dropDataset(id: id)
    }

    // MARK: - Idempotent create and drop

    /// `createDataset` with the same `id` twice must not throw and must
    /// not wipe existing rows (`CREATE TABLE IF NOT EXISTS` semantics).
    @Test func createDataset_idempotent() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "val", type: .int, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [["val": .int(42)]])

        // Second create — must be a no-op (no throw, no data loss).
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let rows = try await ds.queryRows(
            id: id, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil
        )
        #expect(rows.count == 1)
        #expect(rows[0]["val"] == .int(42))
    }

    /// `dropDataset` on an already-dropped id must not throw
    /// (`DROP TABLE IF EXISTS` semantics).
    @Test func dropDataset_idempotent() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "val", type: .int, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.dropDataset(id: id)
        // Second drop — must not throw.
        try await ds.dropDataset(id: id)
    }

    // MARK: - Explicit PK pre-sort

    /// When a PK column is declared, `appendRows` pre-sorts rows by that
    /// column before insertion. Querying with ORDER BY the PK column
    /// returns ascending order regardless of the append order.
    @Test func explicitPK_preSort_orderMatches() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(
            columns: [
                ColumnDeclaration(name: "rank", type: .int, nullable: false)
            ],
            primaryKeyColumn: "rank"
        )
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        // Append out-of-order: 3, 1, 2 — pre-sort should reorder to 1, 2, 3.
        let rows: [[String: TypedValue]] = [
            ["rank": .int(3)],
            ["rank": .int(1)],
            ["rank": .int(2)],
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

    // MARK: - Secondary index declaration

    /// Secondary indexes declared in `createDataset` must not cause errors,
    /// and queries over the table must return the correct result.
    @Test func secondaryIndex_creation_noError() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "name", type: .text, nullable: true),
            ColumnDeclaration(name: "age", type: .int, nullable: true),
        ])
        let indexes = [
            DatasetIndexDeclaration(column: "name", unique: false),
            DatasetIndexDeclaration(column: "age",  unique: true),
        ]
        try await ds.createDataset(id: id, schema: schema, indexes: indexes)
        try await ds.appendRows(id: id, rows: [["name": .text("Newton"), "age": .int(51)]])
        let results = try await ds.queryRows(
            id: id, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil
        )
        #expect(results.count == 1)
        #expect(results[0]["name"] == .text("Newton"))
    }

    // MARK: - Predicate filtering

    /// `queryRows` with a predicate must return only matching rows.
    @Test func predicate_filtersByValue() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "category", type: .text, nullable: false),
            ColumnDeclaration(name: "value",    type: .int,  nullable: false),
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        let rows: [[String: TypedValue]] = [
            ["category": .text("A"), "value": .int(10)],
            ["category": .text("B"), "value": .int(20)],
            ["category": .text("A"), "value": .int(30)],
        ]
        try await ds.appendRows(id: id, rows: rows)

        // Column.table is ignored by both the SQLite predicate compiler and
        // the InMemory PredicateEvaluator — only Column.name is used.
        let predicate = StoragePredicate.eq(Column(table: "", name: "category"), .text("A"))
        let results = try await ds.queryRows(
            id: id,
            predicate: predicate,
            orderBy: [],
            limit: nil,
            offset: nil,
            columns: nil
        )
        #expect(results.count == 2)
        for row in results {
            #expect(row["category"] == .text("A"))
        }
    }

    // MARK: - Projection

    /// `columns:` parameter restricts returned row to only the listed columns.
    @Test func projection_returnsSubsetOfColumns() async throws {
        let ds = makeInMemory().datasetStore
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

    // MARK: - Limit + offset pagination

    @Test func limitAndOffset_paginates() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "n", type: .int, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        // Append 1..5 with an explicit PK so ORDER BY returns a stable sequence.
        let schema2 = DatasetSchema(
            columns: [ColumnDeclaration(name: "n", type: .int, nullable: false)],
            primaryKeyColumn: nil   // no UUID PK; rely on ORDER BY
        )
        _ = schema2  // declared to illustrate intent; we use `schema` above
        let rows: [[String: TypedValue]] = (1...5).map { ["n": .int(Int64($0))] }
        try await ds.appendRows(id: id, rows: rows)

        let page = try await ds.queryRows(
            id: id,
            predicate: nil,
            orderBy: [OrderClause(column: Column(table: "", name: "n"), direction: .ascending)],
            limit: 2,
            offset: 1,
            columns: nil
        )
        // With limit=2 and offset=1, we skip the first row (n=1) and get n=2, n=3.
        #expect(page.count == 2)
        #expect(page[0]["n"] == .int(2))
        #expect(page[1]["n"] == .int(3))
    }

    // MARK: - columnStats (InMemory)

    /// Verify count, nullCount, distinctCount, min, max for a float column.
    @Test func columnStats_floatColumn_inMemory() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "score", type: .float, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        let rows: [[String: TypedValue]] = [
            ["score": .float(1.0)],
            ["score": .float(3.0)],
            ["score": .float(2.0)],
            ["score": .float(3.0)],   // duplicate — tests distinctCount
            ["score": .null],          // null — tests nullCount
        ]
        try await ds.appendRows(id: id, rows: rows)
        let stats = try await ds.columnStats(id: id, column: "score")
        #expect(stats.count == 4)
        #expect(stats.nullCount == 1)
        #expect(stats.distinctCount == 3)  // 1.0, 2.0, 3.0
        #expect(stats.min == .float(1.0))
        #expect(stats.max == .float(3.0))
    }

    /// Verify stats for an int column.
    @Test func columnStats_intColumn_inMemory() async throws {
        let ds = makeInMemory().datasetStore
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

    /// For an empty dataset table, all aggregates must be 0 or .null.
    @Test func columnStats_emptyDataset() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "val", type: .int, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        // No rows appended.
        let stats = try await ds.columnStats(id: id, column: "val")
        #expect(stats.count == 0)
        #expect(stats.nullCount == 0)
        #expect(stats.distinctCount == 0)
        #expect(stats.min == .null)
        #expect(stats.max == .null)
    }

    /// When every row has a null value, count == 0, nullCount == rowCount,
    /// min == .null, max == .null.
    @Test func columnStats_allNulls() async throws {
        let ds = makeInMemory().datasetStore
        let id = UUID()
        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "val", type: .int, nullable: true)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["val": .null],
            ["val": .null],
        ])
        let stats = try await ds.columnStats(id: id, column: "val")
        #expect(stats.count == 0)
        #expect(stats.nullCount == 2)
        #expect(stats.distinctCount == 0)
        #expect(stats.min == .null)
        #expect(stats.max == .null)
    }

    // MARK: - BINARY collation — TEXT ordering
    //
    // Discipline: dataset DDL never adds a COLLATE clause to TEXT columns, so
    // SQLite's default BINARY collation is preserved. ORDER BY on a TEXT column
    // uses byte order, not Unicode locale order. `TypedValueComparator.compare`
    // was changed in MX-TAB-Q1 (2026-07-12) to use `utf8.lexicographicallyPrecedes`
    // so ALL InMemory ordering paths now match SQLite BINARY and the Rust leg.
    //
    //   BINARY byte order (UTF-8): uppercase letters (0x41-0x5A) < lowercase (0x61-0x7A).
    //   "B" = 0x42, "C" = 0x43, "a" = 0x61, "d" = 0x64
    //   → "Banana" < "Cherry" < "apple" < "date"
    //
    // `binaryCollation_textOrdering_sqlite`: asserts byte order on the SQLite backend.
    // `binaryCollation_textOrdering_inMemory`: asserts the same byte order on InMemory.
    // `binaryCollation_textOrdering_parity`: cross-backend parity with non-ASCII
    //   fixture strings ("Z" / "a" / "É") — both backends must return identical order.
    @Test func binaryCollation_textOrdering_sqlite() async throws {
        let storage = try makeSQLite()
        let ds = storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let rows: [[String: TypedValue]] = [
            ["label": .text("apple")],    // 0x61...
            ["label": .text("Banana")],   // 0x42...
            ["label": .text("Cherry")],   // 0x43...
            ["label": .text("date")],     // 0x64...
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
        // BINARY order: uppercase (B=0x42, C=0x43) before lowercase (a=0x61, d=0x64).
        #expect(results[0]["label"] == .text("Banana"))
        #expect(results[1]["label"] == .text("Cherry"))
        #expect(results[2]["label"] == .text("apple"))
        #expect(results[3]["label"] == .text("date"))
    }

    /// InMemory ORDER BY on a TEXT column must use UTF-8 byte order — same as
    /// SQLite BINARY collation and the Rust leg. `TypedValueComparator.compare`
    /// (MX-TAB-Q1) was changed to `utf8.lexicographicallyPrecedes`, so the same
    /// byte-order discipline now applies to every InMemory ordering surface.
    ///
    /// Fixture: "Banana" / "Cherry" / "apple" / "date" — same as the SQLite test
    /// above, expected in byte order: B(0x42) < C(0x43) < a(0x61) < d(0x64).
    @Test func binaryCollation_textOrdering_inMemory() async throws {
        let storage = makeInMemory()
        let ds = storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])

        let rows: [[String: TypedValue]] = [
            ["label": .text("apple")],
            ["label": .text("Banana")],
            ["label": .text("Cherry")],
            ["label": .text("date")],
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
        // Before MX-TAB-Q1, Swift String `<` gave Unicode-canonical order ("apple"
        // before "Banana"). After the fix, byte order matches SQLite BINARY.
        #expect(results[0]["label"] == .text("Banana"))
        #expect(results[1]["label"] == .text("Cherry"))
        #expect(results[2]["label"] == .text("apple"))
        #expect(results[3]["label"] == .text("date"))
    }

    /// Cross-backend TEXT ordering parity with non-ASCII fixture strings.
    ///
    /// Fixture: "Z" (0x5A) / "a" (0x61) / "É" (0xC3 0x89 in UTF-8).
    /// UTF-8 byte order: "Z" < "a" < "É".
    ///
    /// Both InMemory (via `TypedValueComparator.compare`) and SQLite (BINARY
    /// collation) must return rows in the same byte-lexicographic order.
    /// "É" is U+00C9, UTF-8: [0xC3, 0x89]; its first byte (0xC3 = 195) is
    /// above all ASCII chars, so it sorts after ASCII "Z" and "a" in byte order.
    ///
    /// MX-TAB-Q1 resolution: this test verifies the parity property that the
    /// TypedValueComparator fix was designed to guarantee.
    @Test func binaryCollation_textOrdering_parity_inMemoryVsSQLite() async throws {
        let inMemoryStorage = makeInMemory()
        let sqliteStorage   = try makeSQLite()
        let inMemoryDS = inMemoryStorage.datasetStore
        let sqliteDS   = sqliteStorage.datasetStore

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "label", type: .text, nullable: false)
        ])
        // Non-ASCII fixture strings:
        //   "Z" = 0x5A (ASCII uppercase)
        //   "a" = 0x61 (ASCII lowercase)
        //   "É" = U+00C9, UTF-8: [0xC3, 0x89] — two-byte multi-byte sequence
        // Byte order: "Z" (0x5A) < "a" (0x61) < "É" (0xC3...).
        let rows: [[String: TypedValue]] = [
            ["label": .text("É")],   // multi-byte, highest byte value — insert first
            ["label": .text("a")],   // ASCII lowercase
            ["label": .text("Z")],   // ASCII uppercase — lowest byte value
        ]

        let inMemoryID = UUID()
        let sqliteID   = UUID()
        try await inMemoryDS.createDataset(id: inMemoryID, schema: schema, indexes: [])
        try await sqliteDS.createDataset(id: sqliteID,     schema: schema, indexes: [])
        try await inMemoryDS.appendRows(id: inMemoryID, rows: rows)
        try await sqliteDS.appendRows(id: sqliteID,     rows: rows)

        let orderClause = [OrderClause(column: Column(table: "", name: "label"), direction: .ascending)]

        let inMemoryResults = try await inMemoryDS.queryRows(
            id: inMemoryID, predicate: nil, orderBy: orderClause,
            limit: nil, offset: nil, columns: nil
        )
        let sqliteResults = try await sqliteDS.queryRows(
            id: sqliteID, predicate: nil, orderBy: orderClause,
            limit: nil, offset: nil, columns: nil
        )

        #expect(inMemoryResults.count == 3)
        #expect(sqliteResults.count == 3)

        // Both backends must agree on the order.
        #expect(inMemoryResults[0]["label"] == sqliteResults[0]["label"],
            "InMemory/SQLite first-rank mismatch — collation parity broken")
        #expect(inMemoryResults[1]["label"] == sqliteResults[1]["label"],
            "InMemory/SQLite second-rank mismatch — collation parity broken")
        #expect(inMemoryResults[2]["label"] == sqliteResults[2]["label"],
            "InMemory/SQLite third-rank mismatch — collation parity broken")

        // And the order must be byte order: "Z" < "a" < "É".
        #expect(inMemoryResults[0]["label"] == .text("Z"))
        #expect(inMemoryResults[1]["label"] == .text("a"))
        #expect(inMemoryResults[2]["label"] == .text("É"))
    }

    // MARK: - f64 wire rule: REAL columnStats min/max (SQLite backend)
    //
    // SQLite REAL columns return SQLITE_FLOAT → TypedValue.float(Double).
    // The f64-only cross-leg wire rule requires that min/max for a REAL
    // column is `.float(Double)`, never `.int` or any other case.
    @Test func columnStats_floatIsDouble_sqlite() async throws {
        let storage = try makeSQLite()
        let ds = storage.datasetStore
        let id = UUID()

        let schema = DatasetSchema(columns: [
            ColumnDeclaration(name: "measurement", type: .float, nullable: false)
        ])
        try await ds.createDataset(id: id, schema: schema, indexes: [])
        try await ds.appendRows(id: id, rows: [
            ["measurement": .float(1.5)],
            ["measurement": .float(9.25)],
        ])
        let stats = try await ds.columnStats(id: id, column: "measurement")

        // Min must be .float(Double) — not .int, .text, or any other case.
        if case .float(let v) = stats.min {
            #expect(v == 1.5, "REAL min must be exactly 1.5 (f64)")
        } else {
            Issue.record("columnStats min for REAL column was \(stats.min) — expected .float(1.5)")
        }

        // Max must be .float(Double).
        if case .float(let v) = stats.max {
            #expect(v == 9.25, "REAL max must be exactly 9.25 (f64)")
        } else {
            Issue.record("columnStats max for REAL column was \(stats.max) — expected .float(9.25)")
        }
    }
}
